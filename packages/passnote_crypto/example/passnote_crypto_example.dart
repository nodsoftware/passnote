// Derive a key from a passphrase, encrypt a record with it, and compute the
// public discovery tag. Inside Passnote these calls run behind the builder;
// use them directly only for custom wiring.
import 'dart:convert';

import 'package:passnote_crypto/passnote_crypto.dart';

Future<void> main() async {
  final passphrase = generateMnemonic(words: 12).join(' ');
  final key = await deriveKey(passphrase, 'myapp:v1');

  final cipher = XChaChaPoly1305Cipher(key);
  final frame = await cipher.encrypt(utf8.encode('a secret record'));
  print(utf8.decode(await cipher.decrypt(frame))); // a secret record

  // Safe to broadcast: a one-way hash of the key.
  print(roomTag(key));
}
