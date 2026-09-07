// Compile-only: proves conclave_crypto builds for the web.
import 'package:conclave_crypto/conclave_crypto.dart';

void main() {
  generateMnemonic(words: 12);
}
