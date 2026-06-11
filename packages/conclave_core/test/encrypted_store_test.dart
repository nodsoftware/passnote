import 'dart:async';
import 'dart:typed_data';

import 'package:conclave_core/conclave_core.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Fakes

/// In-memory BlobStore used in unit tests.
class _MemStore implements BlobStore {
  final Map<String, List<int>> _data = {};

  @override
  Future<void> open() async {}

  @override
  Future<List<int>?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, List<int> bytes) async =>
      _data[key] = List.of(bytes);

  @override
  Future<void> delete(String key) async => _data.remove(key);

  @override
  Future<List<String>> keys({String? prefix}) async => prefix == null
      ? _data.keys.toList()
      : _data.keys.where((k) => k.startsWith(prefix)).toList();

  @override
  Future<void> close() async {}
}

/// Cipher that XORs every byte with a fixed key byte for testing.
class _XorCipher implements Cipher {
  const _XorCipher(this._key);

  final int _key;

  @override
  Future<List<int>> encrypt(List<int> plaintext) async =>
      plaintext.map((b) => b ^ _key).toList();

  @override
  Future<List<int>> decrypt(List<int> ciphertext) async =>
      ciphertext.map((b) => b ^ _key).toList();
}

/// Cipher that always throws [CipherAuthError] on decrypt.
class _BadCipher implements Cipher {
  const _BadCipher();

  @override
  Future<List<int>> encrypt(List<int> plaintext) async =>
      Uint8List(plaintext.length);

  @override
  Future<List<int>> decrypt(List<int> ciphertext) =>
      Future.error(const CipherAuthError());
}

// ---------------------------------------------------------------------------
// Tests

void main() {
  group('EncryptedStore', () {
    late _MemStore inner;
    late EncryptedStore store;

    setUp(() async {
      inner = _MemStore();
      store = EncryptedStore(inner, const _XorCipher(0xAB));
      await store.open();
    });

    test('write encrypts bytes at rest', () async {
      final plaintext = [1, 2, 3];
      await store.write('k', plaintext);
      final raw = await inner.read('k');
      expect(raw, isNotNull);
      expect(raw, isNot(equals(plaintext)));
    });

    test('read decrypts stored bytes', () async {
      final plaintext = [10, 20, 30, 40];
      await store.write('k', plaintext);
      expect(await store.read('k'), equals(plaintext));
    });

    test('read returns null for missing key', () async {
      expect(await store.read('missing'), isNull);
    });

    test('delete removes the key', () async {
      await store.write('k', [1]);
      await store.delete('k');
      expect(await store.read('k'), isNull);
    });

    test('keys delegates to inner store', () async {
      await store.write('col/a', [1]);
      await store.write('col/b', [2]);
      await store.write('other', [3]);
      expect(await store.keys(prefix: 'col/'),
          unorderedEquals(['col/a', 'col/b']));
    });

    test('wrong key throws CipherAuthError', () async {
      final encryptingStore = EncryptedStore(inner, const _XorCipher(0xAB));
      await encryptingStore.write('k', [1, 2, 3]);

      final decryptingStore = EncryptedStore(inner, const _BadCipher());
      expect(decryptingStore.read('k'), throwsA(isA<CipherAuthError>()));
    });
  });
}
