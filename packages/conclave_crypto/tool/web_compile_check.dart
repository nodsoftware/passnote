// Compile-only: proves conclave_crypto builds for the web.
import 'package:conclave_crypto/conclave_crypto.dart';

void main() async {
  generateMnemonic(words: 12);
  await deriveKey('abandon abandon about', 'app:v1');
  final cipher = XChaChaPoly1305Cipher(List<int>.filled(32, 1));
  await cipher.decrypt(await cipher.encrypt([1, 2, 3]));
  const Spake2Pake().start(initiator: true, secret: [1, 2, 3]);
}
