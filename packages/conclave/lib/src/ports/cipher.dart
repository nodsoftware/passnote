/// An authenticated symmetric cipher.
///
/// Implementations must guarantee that [decrypt] throws [CipherAuthError] for
/// any ciphertext that was not produced by [encrypt] with the same key. This
/// property doubles as both integrity and authentication: a frame from a node
/// that does not hold the shared key will never decrypt successfully.
abstract interface class Cipher {
  /// Encrypts [plaintext] and returns authenticated ciphertext.
  Future<List<int>> encrypt(List<int> plaintext);

  /// Decrypts [ciphertext].
  ///
  /// Throws [CipherAuthError] when the key is wrong or the ciphertext has been
  /// tampered with.
  Future<List<int>> decrypt(List<int> ciphertext);
}

/// Thrown when decryption fails due to an incorrect key or tampered ciphertext.
class CipherAuthError implements Exception {
  const CipherAuthError();

  @override
  String toString() => 'CipherAuthError: decryption authentication failed';
}
