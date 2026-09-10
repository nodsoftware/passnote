import 'dart:convert';

/// A device's long-lived public identity: the key-exchange and signing public
/// keys that peers use to seal keys to it and to verify what it signs.
///
/// The private halves never leave the device that owns them (see [Identity]).
class DevicePublicKey {
  const DevicePublicKey({
    required this.keyExchange,
    required this.signing,
  });

  /// Builds a [DevicePublicKey] from its [toBytes] encoding.
  factory DevicePublicKey.fromBytes(List<int> bytes) {
    if (bytes.length != 64) {
      throw ArgumentError.value(
        bytes.length,
        'bytes.length',
        'a DevicePublicKey encoding is 64 bytes (32 key-exchange + 32 signing)',
      );
    }
    return DevicePublicKey(
      keyExchange: List<int>.unmodifiable(bytes.sublist(0, 32)),
      signing: List<int>.unmodifiable(bytes.sublist(32, 64)),
    );
  }

  /// The X25519 public key other devices use with [Identity.wrapFor].
  final List<int> keyExchange;

  /// The Ed25519 public key used to verify [Identity.sign] output.
  final List<int> signing;

  /// A flat 64-byte encoding: `keyExchange ‖ signing`.
  List<int> toBytes() => [...keyExchange, ...signing];

  @override
  bool operator ==(Object other) =>
      other is DevicePublicKey &&
      _listEquals(other.keyExchange, keyExchange) &&
      _listEquals(other.signing, signing);

  @override
  int get hashCode => Object.hashAll([...keyExchange, ...signing]);

  @override
  String toString() => 'DevicePublicKey(${base64Url.encode(toBytes())})';
}

/// A symmetric key encrypted ("sealed") to one device's [DevicePublicKey].
///
/// Produced by [Identity.wrapFor] and consumed by [Identity.unwrap] on the
/// target device. Opaque to everyone else.
class WrappedKey {
  const WrappedKey({
    required this.ephemeralPublicKey,
    required this.nonce,
    required this.ciphertext,
  });

  /// Builds a [WrappedKey] from its [toBytes] encoding.
  factory WrappedKey.fromBytes(List<int> bytes) {
    if (bytes.length < 32 + 12 + 16) {
      throw ArgumentError.value(
        bytes.length,
        'bytes.length',
        'a WrappedKey encoding is at least 60 bytes',
      );
    }
    return WrappedKey(
      ephemeralPublicKey: List<int>.unmodifiable(bytes.sublist(0, 32)),
      nonce: List<int>.unmodifiable(bytes.sublist(32, 44)),
      ciphertext: List<int>.unmodifiable(bytes.sublist(44)),
    );
  }

  /// The sender's one-time X25519 public key for this wrap.
  final List<int> ephemeralPublicKey;

  /// The AEAD nonce (12 bytes).
  final List<int> nonce;

  /// The AEAD ciphertext of the wrapped key, including its authentication tag.
  final List<int> ciphertext;

  /// A flat encoding: `ephemeralPublicKey(32) ‖ nonce(12) ‖ ciphertext`.
  List<int> toBytes() => [...ephemeralPublicKey, ...nonce, ...ciphertext];
}

/// This device's cryptographic identity.
///
/// Backs device pairing, sealing the group key to a new device, verifying
/// signed control messages, and — later — rotation and revocation. One
/// implementation per app instance; the private keys live only in the
/// platform key store.
abstract interface class Identity {
  /// This device's public identity. Safe to share with peers.
  Future<DevicePublicKey> get publicKey;

  /// A short, stable, unique fingerprint of [publicKey] — used wherever a
  /// device needs to be named (pairing UIs, revocation lists, logs).
  String get deviceId;

  /// The fingerprint for an arbitrary device's [publicKey], by the same rule as
  /// [deviceId]. Lets a device key roster rows for a peer whose private keys it
  /// does not hold.
  String fingerprintOf(DevicePublicKey publicKey);

  /// Signs [message] with this device's Ed25519 key. Verifiable against
  /// `publicKey.signing`.
  Future<List<int>> sign(List<int> message);

  /// Seals [key] so that only the device owning [peer] can [unwrap] it.
  Future<WrappedKey> wrapFor(DevicePublicKey peer, List<int> key);

  /// Opens a [WrappedKey] that a peer sealed to this device with [wrapFor].
  ///
  /// Throws if [wrapped] was not sealed to this device or has been tampered
  /// with.
  Future<List<int>> unwrap(WrappedKey wrapped);
}

bool _listEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
