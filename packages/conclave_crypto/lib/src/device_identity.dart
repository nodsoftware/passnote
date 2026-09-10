import 'dart:convert';
import 'dart:typed_data';

import 'package:conclave/conclave.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

/// Default [Identity]: an X25519 key-exchange keypair and an Ed25519 signing
/// keypair, generated once and then kept in the injected [KeyStore].
///
/// - [wrapFor] / [unwrap] seal a symmetric key with X25519 → HKDF-SHA256 →
///   AES-256-GCM, using a fresh ephemeral sender keypair per wrap so each wrap
///   is independent.
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
    String entryKey = 'conclave/device-identity',
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
  Future<WrappedKey> wrapFor(DevicePublicKey peer, List<int> key) async {
    final ephemeral = await _x25519.newKeyPair();
    final shared = await _x25519.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey:
          SimplePublicKey(peer.keyExchange, type: KeyPairType.x25519),
    );
    final wrapKey = await _deriveWrapKey(shared, peer.keyExchange);
    final nonce = _aesGcm.newNonce();
    final box = await _aesGcm.encrypt(key, secretKey: wrapKey, nonce: nonce);
    return WrappedKey(
      ephemeralPublicKey: (await ephemeral.extractPublicKey()).bytes,
      nonce: nonce,
      ciphertext: Uint8List.fromList([...box.cipherText, ...box.mac.bytes]),
    );
  }

  @override
  Future<List<int>> unwrap(WrappedKey wrapped) async {
    final shared = await _x25519.sharedSecretKey(
      keyPair: _keyExchangeKeyPair,
      remotePublicKey: SimplePublicKey(
        wrapped.ephemeralPublicKey,
        type: KeyPairType.x25519,
      ),
    );
    final wrapKey = await _deriveWrapKey(shared, _publicKey.keyExchange);
    if (wrapped.ciphertext.length < 16) {
      throw ArgumentError('wrapped key ciphertext is too short');
    }
    final split = wrapped.ciphertext.length - 16;
    final box = SecretBox(
      wrapped.ciphertext.sublist(0, split),
      nonce: wrapped.nonce,
      mac: Mac(wrapped.ciphertext.sublist(split)),
    );
    try {
      return await _aesGcm.decrypt(box, secretKey: wrapKey);
    } on SecretBoxAuthenticationError {
      throw StateError(
        'wrapped key was not sealed to this device, or is corrupt',
      );
    }
  }

  /// HKDF over the X25519 shared secret, bound to the recipient's key-exchange
  /// public key so the wrap key is specific to (sender ephemeral, recipient).
  Future<SecretKey> _deriveWrapKey(
    SecretKey shared,
    List<int> recipientKeyExchangePub,
  ) =>
      _hkdf.deriveKey(
        secretKey: shared,
        nonce: const [], // no salt; the ECDH output is already high-entropy
        info: [
          ...utf8.encode('conclave-key-wrap-v1'),
          ...recipientKeyExchangePub,
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
