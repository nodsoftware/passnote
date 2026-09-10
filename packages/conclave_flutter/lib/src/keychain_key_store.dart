import 'dart:convert';

import 'package:conclave/conclave.dart' show KeyStore;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A [KeyStore] backed by the platform secure storage (iOS/macOS Keychain,
/// Android Keystore-wrapped EncryptedSharedPreferences, etc.) via
/// `flutter_secure_storage`.
///
/// Each database's 32-byte key is stored base64-encoded under a namespaced
/// entry so multiple Conclave databases never collide with each other or with
/// unrelated app secrets.
class KeychainKeyStore implements KeyStore {
  /// Creates a key store.
  ///
  /// [storage] may be supplied to customise platform options or for testing;
  /// it defaults to a standard [FlutterSecureStorage]. [namespace] prefixes
  /// every entry key.
  KeychainKeyStore({
    FlutterSecureStorage? storage,
    String namespace = 'conclave',
  })  : _storage = storage ?? const FlutterSecureStorage(),
        _namespace = namespace;

  final FlutterSecureStorage _storage;
  final String _namespace;

  String _entryKey(String databaseId) => '$_namespace.$databaseId';

  @override
  Future<List<int>?> getKey(String databaseId) async {
    final encoded = await _storage.read(key: _entryKey(databaseId));
    if (encoded == null) return null;
    return base64Decode(encoded);
  }

  @override
  Future<void> setKey(String databaseId, List<int> key) async {
    await _storage.write(
      key: _entryKey(databaseId),
      value: base64Encode(key),
    );
  }

  @override
  Future<void> clear(String databaseId) async {
    await _storage.delete(key: _entryKey(databaseId));
  }
}
