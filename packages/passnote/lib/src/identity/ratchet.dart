import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart'
    show KeyPairType, SimpleKeyPairData, SimplePublicKey, X25519;

import '../ports/cipher.dart';

/// A forward-secret symmetric ratchet for a peer-to-peer transport session.
///
/// The session root is derived from the shared group key and an X25519
/// agreement between per-connection ephemeral keys, each signed by its
/// device's roster identity (see [deriveRatchetRoot]), so every connection
/// gets a fresh chain that no long-term key can rebuild, and a reconnect
/// starts over. Each direction has its own hash chain: a
/// message key is derived from the current chain key, then the chain key is
/// advanced and the previous one is wiped. A key extracted after step _n_
/// therefore cannot derive any message key from before step _n_.
///
/// Within one connection this is a hash ratchet: it gives forward secrecy, not
/// post-compromise security. A Diffie-Hellman re-key on a schedule inside a
/// long-lived connection (full double ratchet) is a later addition behind this
/// same seam.
class RatchetSession {
  RatchetSession._(this._send, this._recv, this._cipherFor);

  final _Chain _send;
  final _Chain _recv;
  final Cipher Function(List<int> key) _cipherFor;

  /// Establishes a session from [root]. [thisNodeIsLow] must be `true` on the
  /// side whose node id sorts first, so the two sides pick opposite send /
  /// receive chains.
  static RatchetSession establish({
    required List<int> root,
    required bool thisNodeIsLow,
    required Cipher Function(List<int> key) cipherFactory,
  }) {
    final low = _hkdf(root, const [], _ascii('passnote-ratchet-chain-low'), 32);
    final high =
        _hkdf(root, const [], _ascii('passnote-ratchet-chain-high'), 32);
    return RatchetSession._(
      _Chain(thisNodeIsLow ? low : high),
      _Chain(thisNodeIsLow ? high : low),
      cipherFactory,
    );
  }

  /// Encrypts [plaintext] with the next sending message key. The returned bytes
  /// are `counter(4) ‖ ciphertext`.
  Future<List<int>> seal(List<int> plaintext) async {
    final (counter, messageKey) = _send.next();
    final sealed = await _cipherFor(messageKey).encrypt(plaintext);
    _wipe(messageKey);
    return [..._u32(counter), ...sealed];
  }

  /// Decrypts a `counter(4) ‖ ciphertext` frame, or returns `null` if the frame
  /// is malformed, the key has already been ratcheted past, or authentication
  /// fails.
  Future<List<int>?> open(List<int> framed) async {
    if (framed.length < 4) return null;
    final counter = _readU32(framed);
    final messageKey = _recv.keyFor(counter);
    if (messageKey == null) return null;
    try {
      final plain = await _cipherFor(messageKey).decrypt(framed.sublist(4));
      _wipe(messageKey);
      return plain;
    } catch (_) {
      _wipe(messageKey);
      return null;
    }
  }

  /// Wipes both chains' key material.
  void dispose() {
    _send.dispose();
    _recv.dispose();
  }
}

/// A short, non-secret tag identifying a group-key generation.
///
/// Two devices pair their ratchet nonces only when their tags match, so a
/// nonce minted under an older key — or under the *other* branch of two
/// concurrent rotations that share an epoch number — can never establish a
/// session with mismatched roots. Eight bytes of SHA-256 under a dedicated
/// domain: enough to tell generations apart, useless for recovering the key.
List<int> ratchetKeyTag(List<int> groupKey) => sha256
    .convert([...utf8.encode('passnote-ratchet-key-tag-v1'), ...groupKey])
    .bytes
    .sublist(0, 8);

/// Derives the shared ratchet root for one peer pair.
///
/// The input keying material is the group key followed by [sharedSecret], the
/// X25519 agreement between the two sides' per-connection ephemeral keys
/// ([ephemeralA], [ephemeralB]). The ephemeral private halves exist only in
/// memory and are wiped when the session ends, so a device stolen later —
/// with its identity, group and passphrase keys — cannot rebuild the root of
/// a recorded session: that is the forward secrecy. The group key keeps the
/// session bound to the group: a revoked device that still completes an
/// agreement derives a different root.
///
/// Deterministic and symmetric: both peers compute the same root from the
/// same inputs, in either argument order.
List<int> deriveRatchetRoot({
  required List<int> groupKey,
  required List<int> sharedSecret,
  required List<int> ephemeralA,
  required List<int> ephemeralB,
  required String nodeA,
  required String nodeB,
}) {
  final (e1, e2) = _sortBytes(ephemeralA, ephemeralB);
  final (id1, id2) =
      nodeA.compareTo(nodeB) <= 0 ? (nodeA, nodeB) : (nodeB, nodeA);
  final info = <int>[
    ..._ascii('passnote-ratchet-root-v2'),
    0,
    ...utf8.encode(id1),
    0,
    ...utf8.encode(id2),
    0,
    ...e1,
    0,
    ...e2,
  ];
  return _hkdf([...groupKey, ...sharedSecret], const [], info, 32);
}

/// A cryptographically random 16-byte value.
@Deprecated(
  'Sessions are rooted in an ephemeral X25519 agreement since 1.1.0; '
  'use RatchetEphemeral.generate. Removed in 2.0.0.',
)
List<int> newRatchetNonce() {
  final rng = Random.secure();
  return List<int>.generate(16, (_) => rng.nextInt(256));
}

/// The bytes a device signs to vouch for its ephemeral ratchet key.
///
/// Binds the key to the sending and receiving transport ids, the signer's
/// device id and the group-key generation, so a signed hello cannot be
/// replayed towards another peer, under another device's name, or into
/// another key generation.
List<int> ratchetHelloPayload({
  required String fromNode,
  required String toNode,
  required String deviceId,
  required List<int> keyTag,
  required List<int> ephemeral,
}) =>
    [
      ..._ascii('passnote-ratchet-hello-v2'),
      0,
      ...utf8.encode(fromNode),
      0,
      ...utf8.encode(toNode),
      0,
      ...utf8.encode(deviceId),
      0,
      ...keyTag,
      0,
      ...ephemeral,
    ];

/// One side's per-connection X25519 keypair. Lives in memory only; [destroy]
/// it when the session ends.
class RatchetEphemeral {
  RatchetEphemeral._(this._keyPair, this.publicKey);

  static final X25519 _x25519 = X25519();

  final SimpleKeyPairData _keyPair;

  /// The 32-byte public key, sent to the peer in a signed hello.
  final List<int> publicKey;

  /// Generates a fresh keypair.
  static Future<RatchetEphemeral> generate() async {
    final pair = await (await _x25519.newKeyPair()).extract();
    return RatchetEphemeral._(
      pair,
      List<int>.unmodifiable(pair.publicKey.bytes),
    );
  }

  /// The X25519 agreement with [peerPublicKey], or `null` when the peer key
  /// is malformed or of low order (an all-zero result), which would make the
  /// agreement contribute nothing.
  Future<List<int>?> agree(List<int> peerPublicKey) async {
    if (peerPublicKey.length != 32) return null;
    try {
      final shared = await _x25519.sharedSecretKey(
        keyPair: _keyPair,
        remotePublicKey: SimplePublicKey(
          peerPublicKey,
          type: KeyPairType.x25519,
        ),
      );
      // A copy the caller owns, so it can wipe it.
      final bytes = Uint8List.fromList(await shared.extractBytes());
      if (bytes.every((b) => b == 0)) return null;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// Wipes the private key.
  void destroy() => _keyPair.destroy();
}

// ---------------------------------------------------------------------------

/// One direction's hash chain.
class _Chain {
  _Chain(List<int> chainKey) : _chainKey = Uint8List.fromList(chainKey);

  Uint8List? _chainKey;
  int _counter = 0;

  /// Message keys derived while catching up to an out-of-order frame, kept so a
  /// slightly-reordered frame still opens. Bounded.
  final Map<int, List<int>> _skipped = {};
  static const int _maxSkip = 128;

  static final List<int> _msgInfo = _ascii('msg');
  static final List<int> _stepInfo = _ascii('step');

  (int, List<int>) next() {
    final ck = _chainKey!;
    final messageKey = _hkdf(ck, const [], _msgInfo, 32);
    final nextCk = _hkdf(ck, const [], _stepInfo, 32);
    _wipe(ck);
    _chainKey = Uint8List.fromList(nextCk);
    _wipe(nextCk);
    return (_counter++, messageKey);
  }

  List<int>? keyFor(int counter) {
    final stashed = _skipped.remove(counter);
    if (stashed != null) return stashed;
    if (counter < _counter) return null; // ratcheted past — forward secrecy
    if (counter - _counter > _maxSkip) return null;
    while (_counter <= counter) {
      final (c, mk) = next();
      if (c == counter) return mk;
      _skipped[c] = mk;
      if (_skipped.length > _maxSkip) {
        final oldest = _skipped.keys.first;
        _wipe(_skipped.remove(oldest)!);
      }
    }
    return null;
  }

  void dispose() {
    final ck = _chainKey;
    if (ck != null) _wipe(ck);
    _chainKey = null;
    for (final mk in _skipped.values) {
      _wipe(mk);
    }
    _skipped.clear();
  }
}

List<int> _hkdf(List<int> ikm, List<int> salt, List<int> info, int length) {
  final prk =
      Hmac(sha256, salt.isEmpty ? Uint8List(32) : salt).convert(ikm).bytes;
  final out = <int>[];
  var block = <int>[];
  var counter = 1;
  while (out.length < length) {
    block = Hmac(sha256, prk).convert([...block, ...info, counter]).bytes;
    out.addAll(block);
    counter++;
  }
  return out.sublist(0, length);
}

List<int> _ascii(String s) => ascii.encode(s);

void _wipe(List<int> bytes) {
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = 0;
  }
}

List<int> _u32(int v) => [
      (v >> 24) & 0xff,
      (v >> 16) & 0xff,
      (v >> 8) & 0xff,
      v & 0xff,
    ];

int _readU32(List<int> b) => (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];

(List<int>, List<int>) _sortBytes(List<int> a, List<int> b) {
  for (var i = 0; i < a.length && i < b.length; i++) {
    if (a[i] != b[i]) return a[i] < b[i] ? (a, b) : (b, a);
  }
  return a.length <= b.length ? (a, b) : (b, a);
}
