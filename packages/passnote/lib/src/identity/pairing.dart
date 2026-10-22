import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' show sha256;

import '../ports/cipher.dart';
import '../ports/identity.dart';
import '../ports/pake.dart';
import '../ports/transport.dart';
import 'hkdf.dart';

/// A one-time code that authorises a device join.
///
/// Nine digits, shown grouped (`123 456 789`). Entropy is deliberately low —
/// the PAKE makes an offline guess impossible and limits an online attacker to
/// one try per exchange, and the sponsor caps the tries per code.
class PairingCode {
  const PairingCode._(this.digits);

  /// Generates a fresh random code.
  factory PairingCode.generate() {
    final rng = Random.secure();
    final sb = StringBuffer();
    for (var i = 0; i < 9; i++) {
      sb.write(rng.nextInt(10));
    }
    return PairingCode._(sb.toString());
  }

  /// Parses user input, ignoring spaces, dashes, and other separators.
  ///
  /// Throws [FormatException] unless exactly nine digits remain.
  factory PairingCode.parse(String input) {
    final digits = input.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length != 9) {
      throw const FormatException('a pairing code is nine digits');
    }
    return PairingCode._(digits);
  }

  /// The bare nine-digit string.
  final String digits;

  /// The grouped form for display: `123 456 789`.
  String get display =>
      '${digits.substring(0, 3)} ${digits.substring(3, 6)} ${digits.substring(6)}';

  /// The bytes fed to the PAKE as the shared secret.
  List<int> get secretBytes => utf8.encode(digits);

  /// Redacted: the code is a secret. Read [display] deliberately for the
  /// pairing UI; a stray log of the object must not leak it.
  @override
  String toString() => 'PairingCode(*** *** ***)';
}

/// Raised when the sponsor rejects a join: wrong code, too many tries, or the
/// code was already used.
class PairingRejected implements Exception {
  /// Creates the rejection with its human-readable [reason].
  const PairingRejected(this.reason);

  /// Why the sponsor refused the join.
  final String reason;
  @override
  String toString() => 'PairingRejected: $reason';
}

/// Raised when a join does not complete within the allowed time.
class PairingTimeout implements Exception {
  /// Creates the timeout.
  const PairingTimeout();
  @override
  String toString() => 'PairingTimeout: the other device did not respond';
}

/// What a sponsor hands a newly paired device: the key for the reserved roster
/// collection, and the sponsor's roster trust pins. The database room tag
/// derives from the key, and the device's own wrapped group key arrives by
/// normal sync once it opens the database.
class PairingBundle {
  /// Creates the bundle.
  const PairingBundle({required this.rosterKey, this.rosterPins = const []});

  /// The key that unlocks the reserved roster collection.
  final List<int> rosterKey;

  /// The sponsor's validated roster trust state (founder, member keys,
  /// revocations), which the new device adopts before its first sync instead
  /// of trusting whichever roster reaches it first.
  final List<int> rosterPins;
}

/// Sends one rendezvous frame to a peer (backed by the transport).
typedef PairingFrameSender = Future<void> Function(PeerId to, Frame frame);

/// The currently connected peers, for broadcasting the joiner's hello.
typedef PairingPeerSource = Set<PeerId> Function();

/// Admits an authenticated joiner to the roster and returns the sponsor's
/// roster trust pins for it to adopt.
typedef PairingAdmit = Future<List<int>> Function(DevicePublicKey joiner);

/// Drives the pairing exchange over the [Transport], on both sides.
///
/// One coordinator per [Passnote]; at most one exchange is active at a time.
/// The sponsor calls [arm]; the joiner calls [join]. [Passnote] feeds rendezvous
/// frames to [handleFrame] and routes by [rendezvousRoom].
class PairingCoordinator {
  /// Creates the coordinator; one per [Passnote].
  PairingCoordinator({
    required String appId,
    required Pake pake,
    required Cipher Function(List<int> key) cipherFactory,
    required String Function(List<int> key) roomTag,
    required PairingFrameSender send,
    required PairingPeerSource peers,
    Duration timeout = const Duration(seconds: 20),
    Duration discoveryTimeout = const Duration(seconds: 90),
    int maxAttemptsPerPeer = 3,
    int maxAttempts = 20,
  })  : _appId = appId,
        _discoveryTimeout = discoveryTimeout,
        _pake = pake,
        _cipherFactory = cipherFactory,
        _roomTag = roomTag,
        _send = send,
        _peers = peers,
        _timeout = timeout,
        _maxAttemptsPerPeer = maxAttemptsPerPeer,
        _maxAttempts = maxAttempts;

  final String _appId;
  final Pake _pake;
  final Cipher Function(List<int> key) _cipherFactory;
  final String Function(List<int> key) _roomTag;
  final PairingFrameSender _send;
  final PairingPeerSource _peers;
  final Duration _timeout;

  /// How long a joiner waits to find any peer before giving up. Separate from
  /// [_timeout], which bounds the exchange once one is found.
  final Duration _discoveryTimeout;

  /// Tries one peer may spend on one code: a person mistyping twice still
  /// gets in.
  final int _maxAttemptsPerPeer;

  /// Tries all peers together may spend on one code before it is withdrawn.
  /// Every try is one online guess at a one-in-a-billion code, so at the
  /// default of 20 a guesser's odds stay below 2 in 100 million.
  final int _maxAttempts;

  static final List<int> _joinerId = utf8.encode('passnote-pair-joiner');
  static final List<int> _sponsorId = utf8.encode('passnote-pair-sponsor');

  _SponsorState? _sponsor;
  _JoinerState? _joiner;

  /// The rendezvous room of the active exchange, or `null` when idle.
  String? get rendezvousRoom => _sponsor?.room ?? _joiner?.room;

  /// Sponsor side: publish a fresh code and wait for a joiner. [onAdmit] runs
  /// once the joiner proves the code; it must add the joiner to the roster.
  Future<PairingCode> arm({
    required List<int> rosterKey,
    required PairingAdmit onAdmit,
  }) async {
    _sponsor?.dispose();
    final code = PairingCode.generate();
    final room = _roomTag(_rendezvousKey());
    _sponsor = _SponsorState(
      code: code,
      room: room,
      rosterKey: rosterKey,
      onAdmit: onAdmit,
    );
    return code;
  }

  /// Cancels an armed sponsor session (the app closed the pairing screen).
  void disarm() {
    _sponsor?.dispose();
    _sponsor = null;
  }

  /// Joiner side: run the exchange for [code] and return the bundle the sponsor
  /// granted. Throws [PairingRejected] or [PairingTimeout] on failure.
  Future<PairingBundle> join(
    PairingCode code, {
    required DevicePublicKey joinerPublicKey,
  }) async {
    _joiner?.dispose();
    final room = _roomTag(_rendezvousKey());
    final session = _pake.start(
      initiator: true,
      secret: code.secretBytes,
      initiatorId: _joinerId,
      responderId: _sponsorId,
    );
    final joiner = _JoinerState(
      code: code,
      room: room,
      session: session,
      publicKey: joinerPublicKey,
    );
    _joiner = joiner;

    final hello = _encode({'t': 'hello', 'm': base64.encode(session.message)});

    // A joining device usually calls this the moment it opens, before
    // discovery has found anybody, so the peer set is still empty and a single
    // broadcast would reach nobody and never be retried. Greet peers as they
    // arrive instead, and each one exactly once: the sponsor spends one of its
    // attempts per hello, so re-sending to the same peer would deny a correct
    // code.
    final foundSomebody = Completer<void>();
    Future<void> greetNewPeers() async {
      // Copied before iterating: [_peers] is the live connection set, and this
      // runs while peers are still arriving, so awaiting a send inside a
      // direct iteration would race a concurrent modification.
      for (final peer in _peers().toList()) {
        if (joiner.greeted.add(peer)) {
          await _send(peer, _frame(room, hello));
          if (!foundSomebody.isCompleted) foundSomebody.complete();
        }
      }
    }

    await greetNewPeers();
    final sweep = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => unawaited(greetNewPeers()),
    );

    try {
      // Finding a device is not part of the exchange, and it is the slower
      // half: mDNS can take tens of seconds on a busy network, while the
      // exchange itself is a handful of frames. Counting both against one
      // budget failed joins that had not yet said a word, so the exchange
      // clock starts when there is somebody to say it to.
      await foundSomebody.future.timeout(_discoveryTimeout);
      return await joiner.done.future.timeout(_timeout);
    } on TimeoutException {
      // A refusal heard on the way is the better explanation, when there is
      // one: a peer said no, and nobody else said yes in time.
      final refusal = joiner.lastRefusal;
      if (refusal != null) throw refusal;
      throw const PairingTimeout();
    } finally {
      sweep.cancel();
      joiner.dispose();
      if (identical(_joiner, joiner)) _joiner = null;
    }
  }

  /// Feeds one rendezvous frame in. Returns `true` if it was consumed.
  Future<bool> handleFrame(PeerId from, List<int> bytes) async {
    final room = rendezvousRoom;
    if (room == null) return false;
    final Map<String, dynamic> msg;
    try {
      msg = _decode(bytes);
    } catch (_) {
      return true; // addressed to us, but junk
    }
    switch (msg['t']) {
      case 'hello':
        await _onHello(from, msg);
      case 'resp':
        await _onResp(from, msg);
      case 'commit':
        await _onCommit(from, msg);
      case 'grant':
        await _onGrant(from, msg);
      case 'deny':
        _joiner?.refuse(
          from,
          PairingRejected((msg['reason'] as String?) ?? 'rejected'),
        );
    }
    return true;
  }

  // --- sponsor handlers ---------------------------------------------------

  Future<void> _onHello(PeerId from, Map<String, dynamic> msg) async {
    final sponsor = _sponsor;
    if (sponsor == null) return;

    // Every hello is one online guess at the code, whether or not the guesser
    // ever answers: a wrong code fails on the joiner side (it can't match the
    // sponsor's confirmation) and never reaches _onCommit. So the budget is
    // spent here, per peer and in total.
    final mine = (sponsor.attemptsBy[from] ?? 0) + 1;
    sponsor.attemptsBy[from] = mine;
    sponsor.attempts++;
    if (sponsor.attempts > _maxAttempts) {
      await _send(
        from,
        _frame(sponsor.room,
            _encode({'t': 'deny', 'reason': 'too many attempts'})),
      );
      disarm();
      return;
    }
    if (mine > _maxAttemptsPerPeer) {
      await _send(
        from,
        _frame(sponsor.room,
            _encode({'t': 'deny', 'reason': 'too many attempts'})),
      );
      return;
    }

    final peerMsg = base64.decode(msg['m'] as String);
    final session = _pake.start(
      initiator: false,
      secret: sponsor.code.secretBytes,
      initiatorId: _joinerId,
      responderId: _sponsorId,
    );
    final PakeResult result;
    try {
      result = session.finish(peerMsg);
    } catch (_) {
      await _send(
          from,
          _frame(
              sponsor.room, _encode({'t': 'deny', 'reason': 'bad message'})));
      return;
    }
    // Kept per peer: one peer's hello must not displace another's exchange.
    sponsor.pending[from] = result;
    await _send(
      from,
      _frame(
        sponsor.room,
        _encode({
          't': 'resp',
          'm': base64.encode(session.message),
          'c': base64.encode(result.localConfirmation),
        }),
      ),
    );
  }

  Future<void> _onCommit(PeerId from, Map<String, dynamic> msg) async {
    final sponsor = _sponsor;
    final pending = sponsor?.pending.remove(from);
    if (sponsor == null || pending == null) return;

    final peerConf = base64.decode(msg['c'] as String);
    if (!_constantTimeEquals(peerConf, pending.expectedPeerConfirmation)) {
      final exhausted = sponsor.attempts >= _maxAttempts;
      await _send(
        from,
        _frame(
          sponsor.room,
          _encode({
            't': 'deny',
            'reason': exhausted ? 'too many attempts' : 'wrong code',
          }),
        ),
      );
      if (exhausted) disarm();
      return;
    }

    final box = _cipherFactory(_boxKey(pending.sharedSecret));
    final DevicePublicKey joinerKey;
    try {
      final plain = await box.decrypt(base64.decode(msg['box'] as String));
      joinerKey = DevicePublicKey.fromBytes(plain);
    } catch (_) {
      await _send(from,
          _frame(sponsor.room, _encode({'t': 'deny', 'reason': 'bad key'})));
      return;
    }

    // Single use from here on: a second commit, even a correct one, finds
    // nothing armed.
    sponsor.dispose();
    _sponsor = null;

    final pins = await sponsor.onAdmit(joinerKey);

    final grant = await box.encrypt(
      utf8.encode(jsonEncode({
        'v': 2,
        'rosterKey': base64.encode(sponsor.rosterKey),
        'pins': base64.encode(pins),
      })),
    );
    await _send(
      from,
      _frame(
          sponsor.room, _encode({'t': 'grant', 'box': base64.encode(grant)})),
    );
  }

  // --- joiner handlers --------------------------------------------------

  Future<void> _onResp(PeerId from, Map<String, dynamic> msg) async {
    final joiner = _joiner;
    if (joiner == null || joiner.result != null || joiner.done.isCompleted) {
      return;
    }
    // Only a peer this joiner greeted can answer it.
    if (!joiner.greeted.contains(from)) return;
    final PakeResult result;
    try {
      result = joiner.session.finish(base64.decode(msg['m'] as String));
    } catch (e) {
      joiner.refuse(from, PairingRejected('exchange failed: $e'));
      return;
    }
    final sponsorConf = base64.decode(msg['c'] as String);
    if (!_constantTimeEquals(sponsorConf, result.expectedPeerConfirmation)) {
      // A wrong code, or a peer that is not the sponsor: either way this peer
      // is out, and the joiner keeps listening to the others.
      joiner.refuse(from, const PairingRejected('wrong code'));
      return;
    }
    joiner.result = result;
    joiner.sponsor = from;
    final box = _cipherFactory(_boxKey(result.sharedSecret));
    final sealed = await box.encrypt(joiner.publicKey.toBytes());
    await _send(
      from,
      _frame(
        joiner.room,
        _encode({
          't': 'commit',
          'c': base64.encode(result.localConfirmation),
          'box': base64.encode(sealed),
        }),
      ),
    );
  }

  Future<void> _onGrant(PeerId from, Map<String, dynamic> msg) async {
    final joiner = _joiner;
    final result = joiner?.result;
    if (joiner == null || result == null || joiner.done.isCompleted) return;
    if (from != joiner.sponsor) return;
    try {
      final box = _cipherFactory(_boxKey(result.sharedSecret));
      final plain = await box.decrypt(base64.decode(msg['box'] as String));
      final json = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
      final pins = json['pins'] as String?;
      if (pins == null) {
        // A sponsor that sends no trust pins leaves this device to trust the
        // first roster it is shown: refuse rather than join that way.
        joiner.done.completeError(const PairingRejected(
          'the sponsoring device runs an older Passnote; update it first',
        ));
        return;
      }
      joiner.done.complete(PairingBundle(
        rosterKey: base64.decode(json['rosterKey'] as String),
        rosterPins: base64.decode(pins),
      ));
    } catch (e) {
      joiner.done.completeError(PairingRejected('could not open grant: $e'));
    }
  }

  // --- helpers --------------------------------------------------------

  // The rendezvous room is app-wide, not code-derived: every join attempt
  // reaches the sponsor, so a wrong guess costs the attacker one of the
  // sponsor's attempts rather than being silently unroutable. It is a public
  // value, so a plain hash of the app id is enough.
  List<int> _rendezvousKey() => sha256
      .convert(utf8.encode('passnote-pairing-rendezvous-v2/$_appId'))
      .bytes;

  // The PAKE output is already a strong key: HKDF, not a password hash.
  List<int> _boxKey(List<int> sharedSecret) => hkdfSha256(
        sharedSecret,
        const [],
        utf8.encode('passnote-pairing-box-v2/$_appId'),
        32,
      );

  static Frame _frame(String room, List<int> payload) => Frame(room, payload);

  static List<int> _encode(Map<String, dynamic> m) =>
      utf8.encode(jsonEncode(m));

  static Map<String, dynamic> _decode(List<int> bytes) =>
      jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

class _SponsorState {
  _SponsorState({
    required this.code,
    required this.room,
    required this.rosterKey,
    required this.onAdmit,
  });

  final PairingCode code;
  final String room;
  final List<int> rosterKey;
  final PairingAdmit onAdmit;

  /// Tries spent on this code, in total and per peer.
  int attempts = 0;
  final Map<PeerId, int> attemptsBy = {};

  /// PAKE results awaiting each peer's commit.
  final Map<PeerId, PakeResult> pending = {};

  void dispose() => pending.clear();
}

class _JoinerState {
  _JoinerState({
    required this.code,
    required this.room,
    required this.session,
    required this.publicKey,
  });

  final PairingCode code;
  final String room;
  final PakeSession session;
  final DevicePublicKey publicKey;
  final Completer<PairingBundle> done = Completer<PairingBundle>();

  /// Peers this joiner has said hello to.
  final Set<PeerId> greeted = {};

  /// Peers that refused or failed the exchange.
  final Set<PeerId> refusedBy = {};

  /// The most recent refusal, reported if no peer completes the exchange.
  PairingRejected? lastRefusal;

  /// The peer that proved the code; only it may grant.
  PeerId? sponsor;

  PakeResult? result;

  /// Records that [peer] refused. One peer's refusal ends the join only when
  /// every greeted peer has refused: anyone on the network can send a
  /// refusal, and it must not cut off the real sponsor's answer.
  void refuse(PeerId peer, PairingRejected refusal) {
    if (done.isCompleted || !greeted.contains(peer)) return;
    // Once a sponsor has proved the code, only it can still refuse.
    if (sponsor != null && peer != sponsor) return;
    refusedBy.add(peer);
    lastRefusal = refusal;
    if (sponsor == peer || refusedBy.containsAll(greeted)) {
      done.completeError(refusal);
    }
  }

  void dispose() {
    if (!done.isCompleted) {
      done.future.ignore();
      done.completeError(const PairingRejected('pairing was cancelled'));
    }
  }
}
