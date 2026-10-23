import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// HKDF-SHA256 (RFC 5869): [length] bytes from [ikm], [salt] (32 zero bytes
/// when empty) and [info].
List<int> hkdfSha256(
    List<int> ikm, List<int> salt, List<int> info, int length) {
  final prk =
      Hmac(sha256, salt.isEmpty ? Uint8List(32) : salt).convert(ikm).bytes;
  final out = <int>[];
  var block = <int>[];
  var counter = 1;
  while (out.length < length) {
    block = Hmac(sha256, prk).convert([...block, ...info, counter]).bytes;
    out.addAll(block);
    counter++;
  }
  return out.sublist(0, length);
}
