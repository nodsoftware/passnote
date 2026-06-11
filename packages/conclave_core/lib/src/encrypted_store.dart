import 'ports/blob_store.dart';
import 'ports/cipher.dart';

/// Wraps a [BlobStore] with symmetric encryption so that every blob at rest
/// is ciphertext. Decryption failure is also an authentication failure — a
/// frame from a peer that does not hold the key is silently dropped.
class EncryptedStore implements BlobStore {
  EncryptedStore(this._inner, this._cipher);

  final BlobStore _inner;
  final Cipher _cipher;

  @override
  Future<void> open() => _inner.open();

  @override
  Future<List<int>?> read(String key) async {
    final bytes = await _inner.read(key);
    return bytes == null ? null : await _cipher.decrypt(bytes);
  }

  @override
  Future<void> write(String key, List<int> bytes) async =>
      _inner.write(key, await _cipher.encrypt(bytes));

  @override
  Future<void> delete(String key) => _inner.delete(key);

  @override
  Future<List<String>> keys({String? prefix}) => _inner.keys(prefix: prefix);

  @override
  Future<void> close() => _inner.close();
}
