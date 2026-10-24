import 'dart:convert';

import 'package:bip39/bip39.dart' as bip39;
import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

/// Argon2id parameters, at the OWASP 2023 recommended minimum for interactive
/// use: 19 MiB of memory, 2 passes, 1 lane. Argon2id is memory-hard, so this
/// resists GPU and ASIC cracking far better than a PBKDF2 iteration count.
///
/// `memory` is counted in 1 KiB blocks. The passphrase is entered rarely
/// (device pairing / first unlock), so the cost is unnoticeable: the pure-Dart
/// Argon2id runs in ~100 ms on a 2021 laptop, so a mid-range phone lands in the
/// low-hundreds of milliseconds — well under a second.
const int _argon2Memory = 19456; // 19 MiB
const int _argon2Iterations = 2;
const int _argon2Parallelism = 1;

/// Number of PBKDF2 iterations for the FIPS fallback [deriveKeyPbkdf2].
///
/// 600,000 follows the OWASP 2023 recommendation for PBKDF2-HMAC-SHA256.
const int _pbkdf2Iterations = 600000;

/// Domain-separation suffix mixed into the room-tag hash.
const String _roomTagDomain = 'passnote-room';

/// Length of the room tag in base32 characters.
const int _roomTagLength = 16;

/// Derives a 32-byte (256-bit) symmetric key from a [passphrase] and an
/// app-wide [salt].
///
/// The pipeline is: BIP39 mnemonic → 512-bit BIP39 seed → Argon2id
/// (19 MiB / 2 passes / 1 lane, salted) → 256-bit key. The [salt] ensures the
/// same passphrase produces a different key per app; it is hashed to a
/// fixed-length Argon2 salt so any string is accepted.
///
/// The seed follows BIP39 exactly: PBKDF2-HMAC-SHA512 over the NFKD-normalised
/// UTF-8 bytes of the passphrase. Before 1.2 a passphrase with characters
/// outside ASCII derived differently (see [deriveKeyLegacy]); an ASCII
/// passphrase, which includes every generated one, derives the same key.
Future<List<int>> deriveKey(String passphrase, String salt) async =>
    _argon2(await bip39Seed(passphrase), _argonSalt(salt));

/// [deriveKey] as Passnote 1.0 and 1.1 computed it, for opening data and
/// groups whose passphrase has characters outside ASCII.
///
/// The bip39 package fed PBKDF2 the low byte of each UTF-16 code unit of the
/// unnormalised passphrase instead of its NFKD UTF-8 bytes, so distinct
/// characters collided (`Ł`, U+0141, read as `A`) and the seed matched no
/// other BIP39 implementation. Identical to [deriveKey] for ASCII.
Future<List<int>> deriveKeyLegacy(String passphrase, String salt) async =>
    _argon2(bip39.mnemonicToSeed(passphrase), _argonSalt(salt));

/// The 64-byte BIP39 seed of [phrase] with an empty BIP39 passphrase:
/// PBKDF2-HMAC-SHA512, 2048 iterations, salt `"mnemonic"`, over the UTF-8
/// bytes of the NFKD-normalised phrase.
Future<List<int>> bip39Seed(String phrase) async {
  final pbkdf2 = Pbkdf2(
    macAlgorithm: Hmac.sha512(),
    iterations: 2048,
    bits: 512,
  );
  final seed = await pbkdf2.deriveKey(
    secretKey: SecretKey(utf8.encode(unorm.nfkd(phrase))),
    nonce: utf8.encode('mnemonic'),
  );
  return seed.extractBytes();
}

Future<List<int>> _argon2(List<int> seed, List<int> salt) async {
  final argon2 = Argon2id(
    memory: _argon2Memory,
    iterations: _argon2Iterations,
    parallelism: _argon2Parallelism,
    hashLength: 32,
  );
  final derived = await argon2.deriveKey(
    secretKey: SecretKey(seed),
    nonce: salt,
  );
  return derived.extractBytes();
}

/// Derives the deterministic 32-byte master secret behind a recovery
/// [phrase], for `DeviceIdentity.fromRecoveryPhrase`.
///
/// Same pipeline as [deriveKey] — BIP39 seed → Argon2id — but under its own
/// domain-separated salt, so a phrase used (wrongly) as both passphrase and
/// recovery phrase still yields unrelated keys. The [salt] is the app-wide
/// salt: the same phrase recovers a different keypair per app.
///
/// A recovery phrase is a valid English BIP39 mnemonic, which is ASCII, so
/// its derivation is the same as in 1.0 and 1.1.
Future<List<int>> deriveRecoverySecret(String phrase, String salt) async =>
    _argon2(await bip39Seed(phrase), _argonSalt('recovery-v1/$salt'));

/// FIPS fallback: the pre-Argon2id pipeline, BIP39 seed → PBKDF2-HMAC-SHA256
/// (600 000 iterations). Use only where an approved KDF list rules Argon2id out.
/// The seed is [bip39Seed]'s, as for [deriveKey].
Future<List<int>> deriveKeyPbkdf2(String passphrase, String salt) async =>
    _pbkdf2(await bip39Seed(passphrase), salt);

/// [deriveKeyPbkdf2] as Passnote 1.0 and 1.1 computed it; see
/// [deriveKeyLegacy].
Future<List<int>> deriveKeyPbkdf2Legacy(String passphrase, String salt) async =>
    _pbkdf2(bip39.mnemonicToSeed(passphrase), salt);

Future<List<int>> _pbkdf2(List<int> seed, String salt) async {
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

/// Hashes an arbitrary [salt] string to a 16-byte Argon2 salt (Argon2 requires
/// a salt of at least 8 bytes).
List<int> _argonSalt(String salt) => crypto.sha256
    .convert(utf8.encode('passnote-kdf-salt/$salt'))
    .bytes
    .sublist(0, 16);

/// Computes the public, non-reversible discovery tag for a database [key].
///
/// The tag is `base32(SHA-256(key ‖ "passnote-room"))` truncated to 16
/// characters. Because it is a one-way hash it is safe to broadcast over mDNS
/// for peer discovery without revealing the key.
String roomTag(List<int> key) {
  final digest =
      crypto.sha256.convert([...key, ...utf8.encode(_roomTagDomain)]);
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
