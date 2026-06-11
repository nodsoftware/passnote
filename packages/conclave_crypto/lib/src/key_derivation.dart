import 'dart:convert';

import 'package:bip39/bip39.dart' as bip39;
import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

/// Number of PBKDF2 iterations applied on top of the BIP39 seed.
const int _pbkdf2Iterations = 100000;

/// Domain-separation suffix mixed into the room-tag hash.
const String _roomTagDomain = 'conclave-room';

/// Length of the room tag in base32 characters.
const int _roomTagLength = 16;

/// Derives a 32-byte (256-bit) symmetric key from a [passphrase] mnemonic and
/// an app-wide [salt].
///
/// The pipeline is: BIP39 mnemonic → 512-bit BIP39 seed →
/// PBKDF2-HMAC-SHA256 (100 000 iterations, salted) → 256-bit key. The [salt]
/// ensures the same passphrase produces a different key per app.
Future<List<int>> deriveKey(String passphrase, String salt) async {
  final seed = bip39.mnemonicToSeed(passphrase);
  final pbkdf2 = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: _pbkdf2Iterations,
    bits: 256,
  );
  final derived = await pbkdf2.deriveKey(
    secretKey: SecretKey(seed),
    nonce: utf8.encode(salt),
  );
  return derived.extractBytes();
}

/// Computes the public, non-reversible discovery tag for a database [key].
///
/// The tag is `base32(SHA-256(key ‖ "conclave-room"))` truncated to 16
/// characters. Because it is a one-way hash it is safe to broadcast over mDNS
/// for peer discovery without revealing the key.
String roomTag(List<int> key) {
  final digest = crypto.sha256.convert([...key, ...utf8.encode(_roomTagDomain)]);
  return _base32Encode(digest.bytes).substring(0, _roomTagLength);
}

/// RFC 4648 base32 alphabet (no padding).
const String _base32Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

/// Encodes [bytes] as unpadded RFC 4648 base32.
String _base32Encode(List<int> bytes) {
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
