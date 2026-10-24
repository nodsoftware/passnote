import 'dart:math' show Random, log;
import 'dart:typed_data';

import 'package:bip39/bip39.dart' as bip39;

/// Valid BIP39 word counts mapped to their entropy strength in bits.
///
/// 12 → 128 bit, 15 → 160 bit, 18 → 192 bit, 21 → 224 bit, 24 → 256 bit.
const Map<int, int> _wordsToStrength = {
  12: 128,
  15: 160,
  18: 192,
  21: 224,
  24: 256,
};

/// Generates a fresh BIP39 mnemonic with the requested number of [words].
///
/// [words] must be one of 12, 15, 18, 21, or 24; any other value throws an
/// [ArgumentError]. The returned list contains the individual mnemonic words
/// in order.
List<String> generateMnemonic({int words = 24}) {
  final strength = _wordsToStrength[words];
  if (strength == null) {
    throw ArgumentError.value(
      words,
      'words',
      'must be one of ${_wordsToStrength.keys.join(', ')}',
    );
  }
  return bip39
      .generateMnemonic(strength: strength, randomBytes: _secureBytes)
      .split(' ');
}

/// [size] uniformly random bytes. bip39's own default draws each byte with
/// `nextInt(255)`, so a byte is never 0xFF and the entropy is biased.
Uint8List _secureBytes(int size) {
  final rng = Random.secure();
  return Uint8List.fromList([for (var i = 0; i < size; i++) rng.nextInt(256)]);
}

/// Returns `true` if [phrase] is a valid BIP39 mnemonic, checksum included
/// (so its entropy is known and adequate). Apps that accept user-supplied
/// passphrases should gate on this or on an explicit "I understand the risk"
/// path.
bool isValidMnemonic(String phrase) => bip39.validateMnemonic(phrase);

/// A coarse entropy estimate in bits for a free-form passphrase, for surfacing
/// a strength meter.
///
/// Estimates are based on charset size × length — the actual entropy may be
/// lower (e.g. dictionary words). **Not a security guarantee.**
double estimatePassphraseBits(String phrase) {
  if (phrase.isEmpty) return 0.0;

  // Detect character sets present in the phrase.
  var hasLower = false;
  var hasUpper = false;
  var hasDigit = false;
  var hasSpecial = false;

  for (var i = 0; i < phrase.length; i++) {
    final c = phrase.codeUnitAt(i);
    if (c >= 0x61 && c <= 0x7a) {
      hasLower = true;
    } else if (c >= 0x41 && c <= 0x5a) {
      hasUpper = true;
    } else if (c >= 0x30 && c <= 0x39) {
      hasDigit = true;
    } else {
      hasSpecial = true;
    }
  }

  // Compute charset size.
  var charset = 0;
  if (hasLower) charset += 26;
  if (hasUpper) charset += 26;
  if (hasDigit) charset += 10;
  if (hasSpecial) charset += 32; // approx pool of common special chars

  if (charset == 0) return 0.0;

  return phrase.length * (log(charset) / log(2));
}
