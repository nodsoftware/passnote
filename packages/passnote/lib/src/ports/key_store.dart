/// Secure storage for per-database encryption keys.
///
/// One entry per database id. On mobile the backing store is the OS keychain
/// via [passnote_flutter]; for tests an in-memory map suffices.
abstract interface class KeyStore {
  /// Returns the encryption key for [databaseId], or `null` if not set.
  Future<List<int>?> getKey(String databaseId);

  /// Stores [key] for [databaseId], replacing any existing value.
  Future<void> setKey(String databaseId, List<int> key);

  /// Removes the entry for [databaseId].
  Future<void> clear(String databaseId);
}
