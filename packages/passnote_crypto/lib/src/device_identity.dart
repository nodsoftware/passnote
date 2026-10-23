import 'dart:convert';
import 'dart:typed_data';

import 'package:passnote/passnote.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:meta/meta.dart';

import 'key_derivation.dart';

/// Default [Identity]: an X25519 key-exchange keypair and an Ed25519 signing
/// keypair, generated once and then kept in the injected [KeyStore].
///
/// - [wrapFor] / [unwrap] seal a symmetric key with X25519 → HKDF-SHA256 →
///   AES-256-GCM, using a fresh ephemeral sender keypair per wrap so each wrap
///   is independent. The wrap key is bound to both the ephemeral and the
///   recipient public key (`passnote-key-wrap-v2`); wraps made by 1.0
///   (`passnote-key-wrap-v1`, recipient key only) still open.
/// - [sign] is Ed25519 over the raw message.
/// - [deviceId] is `base32(SHA-256(publicKey))` truncated to 16 characters —
///   short enough for a pairing UI, wide enough not to collide.
///
/// Persistence is one [KeyStore] entry holding a 128-byte blob:
/// `x25519Pub ‖ x25519Priv ‖ ed25519Pub ‖ ed25519Priv`.
class DeviceIdentity implements Identity {
  DeviceIdentity._(
    this._keyExchangeKeyPair,
    this._signingKeyPair,
    this._publicKey,
  ) : deviceId = _fingerprint(_publicKey);

  /// Loads this device's identity from [keyStore], generating and storing a new
  /// one under [entryKey] the first time.
  static Future<DeviceIdentity> load({
    required KeyStore keyStore,
    String entryKey = 'passnote/device-identity',
  }) async {
    final stored = await keyStore.getKey(entryKey);
    if (stored != null) return _fromBlob(stored);

    final identity = await generate();
    await keyStore.setKey(entryKey, identity._toBlob());
    return identity;
  }

  /// Generates a fresh identity without touching any [KeyStore]. Use [load] for
  /// the normal persistent path.
  static Future<DeviceIdentity> generate() async {
    final kx = await (await X25519().newKeyPair()).extract();
    final signing = await (await Ed25519().newKeyPair()).extract();
    final publicKey = DevicePublicKey(
      keyExchange: kx.publicKey.bytes,
      signing: signing.publicKey.bytes,
    );
    return DeviceIdentity._(kx, signing, publicKey);
  }

  /// Derives the deterministic identity behind a recovery [phrase]: the same
  /// phrase and app [salt] always produce the same keypairs, so a wrap sealed
  /// to this identity can be opened years later on a fresh install.
  ///
  /// Pipeline: BIP39 seed → Argon2id under a recovery-specific domain
  /// ([deriveRecoverySecret]) → one seed per keypair by domain-separated
  /// SHA-256. Never persisted; derive it, use it, drop it.
  static Future<DeviceIdentity> fromRecoveryPhrase(
    String phrase, {
    required String salt,
  }) async {
    final master = await deriveRecoverySecret(phrase, salt);
    List<int> seedFor(String domain) =>
        crypto.sha256.convert([...utf8.encode(domain), ...master]).bytes;
    final kx = await (await X25519()
            .newKeyPairFromSeed(seedFor('passnote-recovery-kx-v1')))
        .extract();
    final signing = await (await Ed25519()
            .newKeyPairFromSeed(seedFor('passnote-recovery-sign-v1')))
        .extract();
    final publicKey = DevicePublicKey(
      keyExchange: kx.publicKey.bytes,
      signing: signing.publicKey.bytes,
    );
    return DeviceIdentity._(kx, signing, publicKey);
  }

  static Future<DeviceIdentity> _fromBlob(List<int> blob) async {
    if (blob.length != 128) {
      throw ArgumentError(
        'device-identity blob must be 128 bytes, got ${blob.length}',
      );
    }
    final kxPub = blob.sublist(0, 32);
    final kxPriv = blob.sublist(32, 64);
    final sigPub = blob.sublist(64, 96);
    final sigPriv = blob.sublist(96, 128);
    return DeviceIdentity._(
      SimpleKeyPairData(
        kxPriv,
        publicKey: SimplePublicKey(kxPub, type: KeyPairType.x25519),
        type: KeyPairType.x25519,
      ),
      SimpleKeyPairData(
        sigPriv,
        publicKey: SimplePublicKey(sigPub, type: KeyPairType.ed25519),
        type: KeyPairType.ed25519,
      ),
      DevicePublicKey(keyExchange: kxPub, signing: sigPub),
    );
  }

  final SimpleKeyPairData _keyExchangeKeyPair;
  final SimpleKeyPairData _signingKeyPair;
  final DevicePublicKey _publicKey;

  final _x25519 = X25519();
  final _ed25519 = Ed25519();
  final _aesGcm = AesGcm.with256bits();
  final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  @override
  final String deviceId;

  @override
  Future<DevicePublicKey> get publicKey async => _publicKey;

  @override
  String fingerprintOf(DevicePublicKey publicKey) => _fingerprint(publicKey);

  @override
  Future<List<int>> sign(List<int> message) async {
    final signature = await _ed25519.sign(message, keyPair: _signingKeyPair);
    return signature.bytes;
  }

  @override
  Future<bool> verify(
    List<int> message, {
    required List<int> signature,
    required DevicePublicKey signer,
  }) async {
    try {
      return await _ed25519.verify(
        message,
        signature: Signature(
          signature,
          publicKey: SimplePublicKey(signer.signing, type: KeyPairType.ed25519),
        ),
      );
    } catch (_) {
      // A malformed signature or key never verifies; it must not throw.
      return false;
    }
  }

  @override
  Future<WrappedKey> wrapFor(DevicePublicKey peer, List<int> key) async =>
      _wrapWith(await _x25519.newKeyPair(), peer, key);

  /// [wrapFor] with the ephemeral keypair derived from [ephemeralSeed], for
  /// the published known-answer test vectors only. Production wraps use a
  /// fresh random ephemeral per call.
  @visibleForTesting
  Future<WrappedKey> wrapForWithEphemeralSeed(
    DevicePublicKey peer,
    List<int> key,
    List<int> ephemeralSeed, {
    List<int>? gcmNonce,
  }) async =>
      _wrapWith(
        await _x25519.newKeyPairFromSeed(ephemeralSeed),
        peer,
        key,
        gcmNonce: gcmNonce,
      );

  Future<WrappedKey> _wrapWith(
    KeyPair ephemeral,
    DevicePublicKey peer,
    List<int> key, {
    List<int>? gcmNonce,
  }) async {
    final shared = await _agree(ephemeral, peer.keyExchange);
    if (shared == null) {
      throw ArgumentError.value(
        peer,
        'peer',
        'key-exchange public key is of low order; a wrap to it protects '
            'nothing',
      );
    }
    final ephemeralPublicKey =
        ((await ephemeral.extractPublicKey()) as SimplePublicKey).bytes;
    final wrapKey = await _deriveWrapKey(
      shared,
      recipient: peer.keyExchange,
      ephemeral: ephemeralPublicKey,
    );
    final nonce = gcmNonce ?? _aesGcm.newNonce();
    final box = await _aesGcm.encrypt(key, secretKey: wrapKey, nonce: nonce);
    return WrappedKey(
      ephemeralPublicKey: ephemeralPublicKey,
      nonce: nonce,
      ciphertext: Uint8List.fromList([...box.cipherText, ...box.mac.bytes]),
    );
  }

  /// The X25519 agreement of [keyPair] with [remote], or `null` when it is
  /// all zeroes (a low-order point on the other side contributes nothing).
  Future<SecretKey?> _agree(KeyPair keyPair, List<int> remote) async {
    final shared = await _x25519.sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: SimplePublicKey(remote, type: KeyPairType.x25519),
    );
    final bytes = await shared.extractBytes();
    return bytes.every((b) => b == 0) ? null : shared;
  }

  @override
  Future<List<int>> unwrap(WrappedKey wrapped) async {
    if (wrapped.ciphertext.length < 16) {
      throw ArgumentError('wrapped key ciphertext is too short');
    }
    const notOurs = 'wrapped key was not sealed to this device, or is corrupt';
    final shared =
        await _agree(_keyExchangeKeyPair, wrapped.ephemeralPublicKey);
    if (shared == null) throw StateError(notOurs);
    final split = wrapped.ciphertext.length - 16;
    final box = SecretBox(
      wrapped.ciphertext.sublist(0, split),
      nonce: wrapped.nonce,
      mac: Mac(wrapped.ciphertext.sublist(split)),
    );
    // Current wraps first; then the 1.0 derivation, for wraps written before
    // 1.1.0 that are still in the roster.
    for (final legacy in [false, true]) {
      final wrapKey = await _deriveWrapKey(
        shared,
        recipient: _publicKey.keyExchange,
        ephemeral: legacy ? null : wrapped.ephemeralPublicKey,
      );
      try {
        return await _aesGcm.decrypt(box, secretKey: wrapKey);
      } on SecretBoxAuthenticationError {
        // Try the next derivation.
      }
    }
    throw StateError(notOurs);
  }

  /// HKDF over the X25519 shared secret, bound to the sender's [ephemeral]
  /// and the [recipient] key-exchange public keys, so the wrap key belongs to
  /// exactly this (ephemeral, recipient) pair. A `null` [ephemeral] is the
  /// 1.0 derivation, bound to the recipient alone; it is only ever used to
  /// open old wraps.
  Future<SecretKey> _deriveWrapKey(
    SecretKey shared, {
    required List<int> recipient,
    required List<int>? ephemeral,
  }) =>
      _hkdf.deriveKey(
        secretKey: shared,
        nonce: const [], // no salt; the ECDH output is already high-entropy
        info: ephemeral == null
            ? [...utf8.encode('passnote-key-wrap-v1'), ...recipient]
            : [
                ...utf8.encode('passnote-key-wrap-v2'),
                ...ephemeral,
                ...recipient,
              ],
      );

  List<int> _toBlob() => [
        ..._publicKey.keyExchange,
        ..._keyExchangeKeyPair.bytes,
        ..._publicKey.signing,
        ..._signingKeyPair.bytes,
      ];

  static String _fingerprint(DevicePublicKey publicKey) {
    final digest = crypto.sha256.convert(publicKey.toBytes()).bytes;
    return _base32(digest).substring(0, 16);
  }
}

const String _base32Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

String _base32(List<int> bytes) {
  final buffer = StringBuffer();
  var bits = 0;
  var value = 0;
  for (final b in bytes) {
    value = (value << 8) | b;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      buffer.write(_base32Alphabet[(value >> bits) & 0x1f]);
    }
  }
  if (bits > 0) {
    buffer.write(_base32Alphabet[(value << (5 - bits)) & 0x1f]);
  }
  return buffer.toString();
}
