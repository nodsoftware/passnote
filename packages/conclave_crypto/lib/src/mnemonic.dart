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
  return bip39.generateMnemonic(strength: strength).split(' ');
}

/// Returns `true` if [mnemonic] is a valid BIP39 phrase (checksum included).
bool validateMnemonic(String mnemonic) => bip39.validateMnemonic(mnemonic);
