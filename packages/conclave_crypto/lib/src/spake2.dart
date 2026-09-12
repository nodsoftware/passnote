import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/secp256r1.dart';

/// SPAKE2 (RFC 9382) over the `P256-SHA256-HKDF-HMAC` ciphersuite.
///
/// SPAKE2 is a balanced PAKE: two parties that share a low-entropy secret `w`
/// end up with a strong shared key `Ke`, and an active attacker who does not
/// know `w` gets at most one online guess per run. Conclave uses it so a short
/// pairing code can authorise a device join without ever being the data key.
///
/// Roles are asymmetric: the [Spake2Role.prover] (RFC "A") sends first and
/// blinds with the point `M`; the [Spake2Role.verifier] (RFC "B") blinds with
/// `N`. Both sides must agree on the identity strings and any additional
/// authenticated data.
///
/// Correctness is pinned to the RFC 9382 Appendix B vectors in
/// `spake2_test.dart`.
enum Spake2Role {
  /// RFC 9382 party "A": sends its message first, blinds with `M`.
  prover,

  /// RFC 9382 party "B": blinds with `N`.
  verifier,
}

/// Thrown when a peer's SPAKE2 message is not a valid group element.
class Spake2ProtocolError implements Exception {
  /// Creates the error with its diagnostic [message].
  const Spake2ProtocolError(this.message);

  /// What went wrong, for diagnostics only.
  final String message;
  @override
  String toString() => 'Spake2ProtocolError: $message';
}

/// The output of a completed SPAKE2 exchange.
///
/// [sharedSecret] is RFC 9382 `Ke` (16 bytes). The two confirmation MACs must
/// still be exchanged and checked: send [localConfirmation] to the peer, then
/// verify the value it sends against [expectedPeerConfirmation] with
/// [spake2ConstantTimeEquals] before trusting the key.
class Spake2Result {
  /// Creates a completed exchange result.
  const Spake2Result({
    required this.sharedSecret,
    required this.localConfirmation,
    required this.expectedPeerConfirmation,
    required this.transcript,
  });

  /// RFC 9382 `Ke`, the shared secret. 16 bytes.
  final Uint8List sharedSecret;

  /// This party's key-confirmation MAC (`cA` for the prover, `cB` for the
  /// verifier). 32 bytes. Send it to the peer.
  final Uint8List localConfirmation;

  /// The MAC the peer must send back. Compare in constant time.
  final Uint8List expectedPeerConfirmation;

  /// RFC 9382 `TT`. Exposed for the published test vectors.
  final Uint8List transcript;
}

/// A single SPAKE2 run. Not reusable: build one with [Spake2.start], send
/// [outboundMessage], then call [finish] once with the peer's message.
class Spake2 {
  Spake2._(
    this._role,
    this._w,
    this._scalar,
    this._proverId,
    this._verifierId,
    this._aad,
    this._outbound,
  );

  final Spake2Role _role;
  final BigInt _w;
  final BigInt _scalar; // x (prover) or y (verifier)
  final Uint8List _proverId;
  final Uint8List _verifierId;
  final Uint8List _aad;
  final Uint8List _outbound;

  static final ECCurve_secp256r1 _p256 = ECCurve_secp256r1();
  static final ECPoint _pointM = _decodeConst(
    '02886e2f97ace46e55ba9dd7242579f2993b64e16ef3dcab95afd497333d8fa12f',
  );
  static final ECPoint _pointN = _decodeConst(
    '03d8bbd6c639c62937b04d997f38c3770719c629d7014d49a24b4f98baa1292b49',
  );

  static BigInt get _order => _p256.n;

  static final Random _rng = Random.secure();

  /// Begins a run for [role].
  ///
  /// [w] is the shared secret scalar as big-endian bytes; it is reduced mod
  /// the group order. Conclave feeds the raw pairing-code bytes in: SPAKE2's
  /// security argument does not depend on the entropy of `w` — an active
  /// attacker gets one online guess per run and the transcript reveals
  /// nothing offline — so no stretching is applied.
  ///
  /// [proverId] / [verifierId] are the parties' identity strings — pass the
  /// same values on both sides, or leave both empty only when identities are
  /// implicit in the surrounding protocol. [aad] is optional extra
  /// authenticated data folded into the confirmation keys.
  ///
  /// [scalarOverride] fixes the secret scalar (`x` or `y`); it exists for the
  /// test vectors and must not be used in production.
  factory Spake2.start({
    required Spake2Role role,
    required List<int> w,
    List<int> proverId = const [],
    List<int> verifierId = const [],
    List<int> aad = const [],
    BigInt? scalarOverride,
  }) {
    final wBig = _osToInt(w) % _order;
    final scalar = scalarOverride ?? _randomScalar();
    final base = role == Spake2Role.prover ? _pointM : _pointN;
    final xp = (_p256.G * scalar)!; // X = scalar*P
    final blind = (base * wBig)!; // w*M or w*N
    final outbound = (blind + xp)!; // pA or pB
    return Spake2._(
      role,
      wBig,
      scalar,
      _asBytes(proverId),
      _asBytes(verifierId),
      _asBytes(aad),
      outbound.getEncoded(false),
    );
  }

  /// This party's SPAKE2 message: RFC `pA` (prover) or `pB` (verifier),
  /// uncompressed SEC1, 65 bytes. Send it to the peer.
  Uint8List get outboundMessage => Uint8List.fromList(_outbound);

  /// Consumes the peer's message and derives the shared secret and both
  /// confirmation MACs. Call exactly once.
  ///
  /// Throws [Spake2ProtocolError] if [peerMessage] is not a valid P-256 point.
  Spake2Result finish(List<int> peerMessage) {
    final peer = _decodePoint(peerMessage);

    // K = h * scalar * (peer - w*(N or M)). P-256 has cofactor h = 1.
    final unblind = _role == Spake2Role.prover ? _pointN : _pointM;
    final k = ((peer - (unblind * _w)!)! * _scalar)!;
    if (k.isInfinity) {
      throw const Spake2ProtocolError('shared point is the identity');
    }
    final kEnc = k.getEncoded(false);

    final pA = _role == Spake2Role.prover ? _outbound : _asBytes(peerMessage);
    final pB = _role == Spake2Role.prover ? _asBytes(peerMessage) : _outbound;

    final transcript = (BytesBuilder(copy: false)
          ..add(_ttField(_proverId))
          ..add(_ttField(_verifierId))
          ..add(_ttField(pA))
          ..add(_ttField(pB))
          ..add(_ttField(kEnc))
          ..add(_ttField(_intToOs(_w, 32))))
        .toBytes();

    final hash = Uint8List.fromList(crypto.sha256.convert(transcript).bytes);
    final ke = Uint8List.sublistView(hash, 0, 16);
    final ka = Uint8List.sublistView(hash, 16, 32);

    final okm = _hkdfSha256(
      salt: const [],
      ikm: ka,
      info: [...utf8.encode('ConfirmationKeys'), ..._aad],
      length: 32,
    );
    final kcA = Uint8List.sublistView(okm, 0, 16);
    final kcB = Uint8List.sublistView(okm, 16, 32);

    final cA = _hmacSha256(kcA, transcript);
    final cB = _hmacSha256(kcB, transcript);

    final isProver = _role == Spake2Role.prover;
    return Spake2Result(
      sharedSecret: Uint8List.fromList(ke),
      localConfirmation: isProver ? cA : cB,
      expectedPeerConfirmation: isProver ? cB : cA,
      transcript: transcript,
    );
  }

  // --- point / scalar helpers -------------------------------------------------

  static ECPoint _decodeConst(String hex) {
    final point = _p256.curve.decodePoint(_fromHex(hex));
    if (point == null) throw StateError('bad SPAKE2 constant');
    return point;
  }

  ECPoint _decodePoint(List<int> encoded) {
    ECPoint? point;
    try {
      point = _p256.curve.decodePoint(encoded);
    } catch (_) {
      throw const Spake2ProtocolError('peer message is not a P-256 point');
    }
    if (point == null || point.isInfinity) {
      throw const Spake2ProtocolError(
          'peer message is not a valid P-256 point');
    }
    // pointycastle's decodePoint reads the coordinates without checking the
    // curve equation, so validate y² = x³ + ax + b (mod p) here, as RFC 9382
    // §4 requires. P-256 has cofactor 1, so an on-curve non-identity point is
    // guaranteed to be in the prime-order group — without this check an
    // attacker can substitute a small-order point from another curve and
    // collapse K to a guessable value.
    if (!_isOnCurve(point)) {
      throw const Spake2ProtocolError('peer point is not on the P-256 curve');
    }
    return point;
  }

  /// The P-256 field prime (SEC 2 / FIPS 186-4).
  static final BigInt _fieldPrime = BigInt.parse(
    'ffffffff00000001000000000000000000000000ffffffffffffffffffffffff',
    radix: 16,
  );

  /// Whether [point]'s affine coordinates satisfy the P-256 curve equation.
  static bool _isOnCurve(ECPoint point) {
    final x = point.x?.toBigInteger();
    final y = point.y?.toBigInteger();
    final a = _p256.curve.a?.toBigInteger();
    final b = _p256.curve.b?.toBigInteger();
    final p = _fieldPrime;
    if (x == null || y == null || a == null || b == null) return false;
    if (x < BigInt.zero || x >= p || y < BigInt.zero || y >= p) return false;
    final lhs = y.modPow(BigInt.two, p);
    final rhs = (x.modPow(BigInt.from(3), p) + a * x + b) % p;
    return lhs == rhs;
  }

  /// A uniform scalar in `[1, n)` by rejection sampling: candidates at or
  /// above the group order are re-drawn instead of reduced, so there is no
  /// modular bias.
  static BigInt _randomScalar() {
    final order = _order;
    while (true) {
      final v = _osToInt(_secureBytes(32));
      if (v != BigInt.zero && v < order) return v;
    }
  }

  static Uint8List _secureBytes(int n) {
    final out = Uint8List(n);
    for (var i = 0; i < n; i++) {
      out[i] = _rng.nextInt(256);
    }
    return out;
  }

  // --- byte / int helpers ---------------------------------------------------

  static Uint8List _asBytes(List<int> v) =>
      v is Uint8List ? v : Uint8List.fromList(v);

  /// `len(S) || S` with an 8-byte little-endian length, per RFC 9382 §3.3.
  static Uint8List _ttField(List<int> s) {
    final out = Uint8List(8 + s.length);
    var n = s.length;
    for (var i = 0; i < 8; i++) {
      out[i] = n & 0xff;
      n >>= 8;
    }
    out.setRange(8, out.length, s);
    return out;
  }

  static BigInt _osToInt(List<int> bytes) {
    var v = BigInt.zero;
    for (final b in bytes) {
      v = (v << 8) | BigInt.from(b & 0xff);
    }
    return v;
  }

  static Uint8List _intToOs(BigInt value, int length) {
    final out = Uint8List(length);
    var v = value;
    for (var i = length - 1; i >= 0; i--) {
      out[i] = (v & BigInt.from(0xff)).toInt();
      v >>= 8;
    }
    return out;
  }

  static Uint8List _fromHex(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  // --- HKDF / HMAC (SHA-256) ----------------------------------------------

  static Uint8List _hmacSha256(List<int> key, List<int> message) =>
      Uint8List.fromList(
          crypto.Hmac(crypto.sha256, key).convert(message).bytes);

  static Uint8List _hkdfSha256({
    required List<int> salt,
    required List<int> ikm,
    required List<int> info,
    required int length,
  }) {
    final prk = _hmacSha256(salt.isEmpty ? Uint8List(32) : salt, ikm);
    final out = BytesBuilder(copy: false);
    var t = <int>[];
    var counter = 1;
    while (out.length < length) {
      t = _hmacSha256(prk, [...t, ...info, counter]);
      out.add(t);
      counter++;
    }
    return Uint8List.sublistView(out.toBytes(), 0, length);
  }
}

/// Constant-time byte-string equality, for comparing confirmation MACs.
bool spake2ConstantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
