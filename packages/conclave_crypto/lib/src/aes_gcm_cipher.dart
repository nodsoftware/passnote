import 'dart:typed_data';

import 'package:conclave_core/conclave_core.dart';
import 'package:cryptography/cryptography.dart' hide Cipher;

/// AES-256-GCM implementation of the [Cipher] port.
///
/// Wire / at-rest format is a single byte buffer:
///
/// ```
/// ┌────────────┬────────────────────┬──────────────┐
/// │ nonce (12) │ ciphertext (n)     │ tag (16)     │
/// └────────────┴────────────────────┴──────────────┘
/// ```
///
/// A fresh random 12-byte nonce is generated for every [encrypt] call, so
/// encrypting identical plaintext twice yields different ciphertext. The
/// 16-byte GCM authentication tag makes [decrypt] fail closed for any frame
/// not produced with the same 256-bit key — this is what authenticates peers.
///
/// The default cipher is [XChaChaPoly1305Cipher]; this remains available for
/// callers who need AES specifically.
class AesGcmCipher implements Cipher {
  /// Creates a cipher bound to a 32-byte (256-bit) [key].
  AesGcmCipher(this.key)
      : assert(key.length == 32, 'AES-256-GCM requires a 32-byte key'),
        _secretKey = SecretKey(key);

  /// The raw 256-bit key bytes.
  final List<int> key;

  final SecretKey _secretKey;
  final AesGcm _algorithm = AesGcm.with256bits();

  static const int _nonceLength = 12;
  static const int _tagLength = 16;

  @override
  Future<List<int>> encrypt(List<int> plaintext) async {
    final nonce = _algorithm.newNonce();
    final box = await _algorithm.encrypt(
      plaintext,
      secretKey: _secretKey,
      nonce: nonce,
    );
    return Uint8List.fromList([
      ...box.nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ]);
  }

  @override
  Future<List<int>> decrypt(List<int> ciphertext) async {
    if (ciphertext.length < _nonceLength + _tagLength) {
      throw const CipherAuthError();
    }
    final nonce = ciphertext.sublist(0, _nonceLength);
    final mac = ciphertext.sublist(ciphertext.length - _tagLength);
    final cipherBytes =
        ciphertext.sublist(_nonceLength, ciphertext.length - _tagLength);

    final box = SecretBox(cipherBytes, nonce: nonce, mac: Mac(mac));
    try {
      return await _algorithm.decrypt(box, secretKey: _secretKey);
    } on SecretBoxAuthenticationError {
      throw const CipherAuthError();
    }
  }
}
