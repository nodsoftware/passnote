// bip39's default generator drew each entropy byte with nextInt(255), so a
// mnemonic never encoded the byte 0xFF (F-9, found by the Rust port).
import 'package:bip39/bip39.dart' as bip39;
import 'package:passnote_crypto/passnote_crypto.dart';
import 'package:test/test.dart';

void main() {
  test('mnemonic entropy covers every byte value (F-9)', () {
    final seen = <int>{};
    // 400 phrases are 12 800 bytes: missing any one value by chance is
    // about (255/256)^12800, under 1e-21.
    for (var i = 0; i < 400; i++) {
      final hex = bip39.mnemonicToEntropy(generateMnemonic().join(' '));
      for (var j = 0; j < hex.length; j += 2) {
        seen.add(int.parse(hex.substring(j, j + 2), radix: 16));
      }
    }
    expect(seen, contains(0xFF));
    expect(seen, hasLength(256));
  });
}
