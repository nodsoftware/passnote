import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../ports/cipher.dart';

/// A forward-secret symmetric ratchet for a peer-to-peer transport session.
///
/// The session root is derived (no round trip) from the shared group key and a
/// random per-session nonce from each side, so every connection gets a fresh
/// chain and a reconnect starts over. Each direction has its own hash chain: a
/// message key is derived from the current chain key, then the chain key is
/// advanced and the previous one is wiped. A key extracted after step _n_
/// therefore cannot derive any message key from before step _n_.
///
/// This is a hash ratchet only — it gives forward secrecy, not post-compromise
/// security. A Diffie-Hellman re-key on a schedule (full double ratchet) is a
/// later addition behind this same seam.
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
    final low = _hkdf(root, const [], _ascii('conclave-ratchet-chain-low'), 32);
    final high =
        _hkdf(root, const [], _ascii('conclave-ratchet-chain-high'), 32);
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

/// Derives a session root from the group key and both sides' data.
///
/// Order-independent in the two nonces and the two node ids, so both peers
/// compute the same value.
List<int> deriveRatchetRoot({
  required List<int> groupKey,
  required List<int> nonceA,
  required List<int> nonceB,
  required String nodeA,
  required String nodeB,
}) {
  final (n1, n2) = _sortBytes(nonceA, nonceB);
  final (id1, id2) =
      nodeA.compareTo(nodeB) <= 0 ? (nodeA, nodeB) : (nodeB, nodeA);
  final info = <int>[
    ..._ascii('conclave-ratchet-root-v1'),
    0,
    ..._ascii(id1),
    0,
    ..._ascii(id2),
    0,
    ...n1,
    0,
    ...n2,
  ];
  return _hkdf(groupKey, const [], info, 32);
}

/// A cryptographically random session nonce.
List<int> newRatchetNonce() {
  final rng = Random.secure();
  return List<int>.generate(16, (_) => rng.nextInt(256));
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
