/// Persists opaque blobs keyed by a string.
///
/// This is the only storage contract the engine depends on. Serialisation and
/// encryption both sit above this interface, keeping adapters trivially thin.
abstract interface class BlobStore {
  /// Opens the store. Must be called before any other method.
  Future<void> open();

  /// Returns the blob stored at [key], or `null` if absent.
  Future<List<int>?> read(String key);

  /// Writes [bytes] at [key], replacing any existing value.
  Future<void> write(String key, List<int> bytes);

  /// Deletes the blob at [key]. No-op when the key is absent.
  Future<void> delete(String key);

  /// Lists stored keys, optionally filtered to those starting with [prefix].
  Future<List<String>> keys({String? prefix});

  /// Closes the store, releasing any held resources.
  Future<void> close();
}
