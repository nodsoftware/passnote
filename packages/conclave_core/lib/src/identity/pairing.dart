import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../ports/cipher.dart';
import '../ports/identity.dart';
import '../ports/pake.dart';
import '../ports/transport.dart';

/// A one-time code that authorises a device join.
///
/// Nine digits, shown grouped (`123 456 789`). Entropy is deliberately low —
/// the PAKE makes an offline guess impossible and limits an online attacker to
/// one try per exchange, and the sponsor rate-limits failed tries.
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

  @override
  String toString() => display;
}

/// Raised when the sponsor rejects a join: wrong code, too many tries, or the
/// code was already used.
class PairingRejected implements Exception {
  const PairingRejected(this.reason);
  final String reason;
  @override
  String toString() => 'PairingRejected: $reason';
}

/// Raised when a join does not complete within the allowed time.
class PairingTimeout implements Exception {
  const PairingTimeout();
  @override
  String toString() => 'PairingTimeout: the other device did not respond';
}

/// What a sponsor hands a newly paired device: the key for the reserved roster
/// collection. The database room tag derives from it, and the device's own
/// wrapped group key arrives by normal sync once it opens the database.
class PairingBundle {
  const PairingBundle({required this.rosterKey});
  final List<int> rosterKey;
}

/// Callbacks the coordinator needs from [Conclave].
typedef PairingFrameSender = Future<void> Function(PeerId to, Frame frame);
typedef PairingPeerSource = Set<PeerId> Function();
typedef PairingKeyDeriver = Future<List<int>> Function(
    String passphrase, String salt);
typedef PairingAdmit = Future<void> Function(DevicePublicKey joiner);

/// Drives the pairing exchange over the [Transport], on both sides.
///
/// One coordinator per [Conclave]; at most one exchange is active at a time.
/// The sponsor calls [arm]; the joiner calls [join]. [Conclave] feeds rendezvous
/// frames to [handleFrame] and routes by [rendezvousRoom].
class PairingCoordinator {
  PairingCoordinator({
    required String appId,
    required Pake pake,
    required PairingKeyDeriver deriveKey,
    required Cipher Function(List<int> key) cipherFactory,
    required String Function(List<int> key) roomTag,
    required PairingFrameSender send,
    required PairingPeerSource peers,
    Duration timeout = const Duration(seconds: 20),
    int maxAttempts = 3,
  })  : _appId = appId,
        _pake = pake,
        _deriveKey = deriveKey,
        _cipherFactory = cipherFactory,
        _roomTag = roomTag,
        _send = send,
        _peers = peers,
        _timeout = timeout,
        _maxAttempts = maxAttempts;

  final String _appId;
  final Pake _pake;
  final PairingKeyDeriver _deriveKey;
  final Cipher Function(List<int> key) _cipherFactory;
  final String Function(List<int> key) _roomTag;
  final PairingFrameSender _send;
  final PairingPeerSource _peers;
  final Duration _timeout;
  final int _maxAttempts;

  static final List<int> _joinerId = utf8.encode('conclave-pair-joiner');
  static final List<int> _sponsorId = utf8.encode('conclave-pair-sponsor');

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
    final room = _roomTag(await _rendezvousKey());
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
    final room = _roomTag(await _rendezvousKey());
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
    await _broadcast(room, hello);

    try {
      return await joiner.done.future.timeout(_timeout);
    } on TimeoutException {
      throw const PairingTimeout();
    } finally {
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
        await _onGrant(msg);
      case 'deny':
        final joiner = _joiner;
        if (joiner != null && !joiner.done.isCompleted) {
          joiner.done.completeError(
            PairingRejected((msg['reason'] as String?) ?? 'rejected'),
          );
        }
    }
    return true;
  }

  // --- sponsor handlers ---------------------------------------------------

  Future<void> _onHello(PeerId from, Map<String, dynamic> msg) async {
    final sponsor = _sponsor;
    if (sponsor == null) return;

    // Every join attempt costs one try. A wrong code fails on the joiner side
    // (it can't match the sponsor's confirmation) and never reaches _onCommit,
    // so the limit has to bite here.
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
    sponsor.pending = _SponsorExchange(peer: from, result: result);
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
    final pending = sponsor?.pending;
    if (sponsor == null || pending == null || pending.peer != from) return;

    final peerConf = base64.decode(msg['c'] as String);
    if (!_constantTimeEquals(
        peerConf, pending.result.expectedPeerConfirmation)) {
      sponsor.pending = null;
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

    final box = _cipherFactory(await _boxKey(pending.result.sharedSecret));
    final DevicePublicKey joinerKey;
    try {
      final plain = await box.decrypt(base64.decode(msg['box'] as String));
      joinerKey = DevicePublicKey.fromBytes(plain);
    } catch (_) {
      sponsor.pending = null;
      await _send(from,
          _frame(sponsor.room, _encode({'t': 'deny', 'reason': 'bad key'})));
      return;
    }

    await sponsor.onAdmit(joinerKey);

    final grant = await box.encrypt(
      utf8.encode(jsonEncode({'rosterKey': base64.encode(sponsor.rosterKey)})),
    );
    await _send(
      from,
      _frame(
          sponsor.room, _encode({'t': 'grant', 'box': base64.encode(grant)})),
    );
    sponsor.dispose();
    _sponsor = null; // single use
  }

  // --- joiner handlers --------------------------------------------------

  Future<void> _onResp(PeerId from, Map<String, dynamic> msg) async {
    final joiner = _joiner;
    if (joiner == null || joiner.result != null || joiner.done.isCompleted) {
      return;
    }
    final PakeResult result;
    try {
      result = joiner.session.finish(base64.decode(msg['m'] as String));
    } catch (e) {
      joiner.done.completeError(PairingRejected('exchange failed: $e'));
      return;
    }
    final sponsorConf = base64.decode(msg['c'] as String);
    if (!_constantTimeEquals(sponsorConf, result.expectedPeerConfirmation)) {
      joiner.done.completeError(const PairingRejected('wrong code'));
      return;
    }
    joiner.result = result;
    final box = _cipherFactory(await _boxKey(result.sharedSecret));
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

  Future<void> _onGrant(Map<String, dynamic> msg) async {
    final joiner = _joiner;
    final result = joiner?.result;
    if (joiner == null || result == null || joiner.done.isCompleted) return;
    try {
      final box = _cipherFactory(await _boxKey(result.sharedSecret));
      final plain = await box.decrypt(base64.decode(msg['box'] as String));
      final json = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
      joiner.done.complete(
        PairingBundle(rosterKey: base64.decode(json['rosterKey'] as String)),
      );
    } catch (e) {
      joiner.done.completeError(PairingRejected('could not open grant: $e'));
    }
  }

  // --- helpers --------------------------------------------------------

  // The rendezvous room is app-wide, not code-derived: every join attempt
  // reaches the sponsor, so a wrong guess costs the attacker one of the
  // sponsor's [_maxAttempts] rather than being silently unroutable.
  Future<List<int>> _rendezvousKey() =>
      _deriveKey(_appId, 'conclave/$_appId/pairing-rendezvous-v1');

  Future<List<int>> _boxKey(List<int> sharedSecret) => _deriveKey(
      base64.encode(sharedSecret), 'conclave/$_appId/pairing-box-v1');

  Future<void> _broadcast(String room, List<int> payload) async {
    for (final peer in _peers()) {
      await _send(peer, _frame(room, payload));
    }
  }

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

  int attempts = 0;
  _SponsorExchange? pending;

  void dispose() => pending = null;
}

class _SponsorExchange {
  _SponsorExchange({required this.peer, required this.result});
  final PeerId peer;
  final PakeResult result;
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

  PakeResult? result;

  void dispose() {
    if (!done.isCompleted) {
      done.future.ignore();
      done.completeError(const PairingRejected('pairing was cancelled'));
    }
  }
}
