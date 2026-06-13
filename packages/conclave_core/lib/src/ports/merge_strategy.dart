/// Controls the granularity at which a document is split into independently
/// timestamped CRDT records, and therefore how concurrent edits to the same
/// document merge.
///
/// A `Collection<T>` converts each document to a JSON map (via its [Codec]) and
/// hands it to a [MergeStrategy], which flattens it into a set of field entries.
/// Each entry becomes its own CRDT record with its own Hybrid Logical Clock, so
/// concurrent edits to *different* entries both survive a merge, while
/// concurrent edits to the *same* entry resolve last-write-wins.
///
/// Built-in strategies:
///
/// - `ObjectMergeStrategy` — the whole document is a single record
///   (whole-document last-write-wins). The default.
/// - `ShallowMergeStrategy` — each top-level field is its own record; nested
///   objects and lists are atomic.
/// - `DeepMergeStrategy` — nested maps are flattened recursively; lists and
///   scalars are leaves.
///
/// Implement this interface to define a custom decomposition.
abstract interface class MergeStrategy {
  /// Flattens [document] into a map of field-path → value. Each entry becomes
  /// an independently merged CRDT record.
  ///
  /// Field paths must be stable across versions of the same document and must
  /// not contain a NUL (`\u0000`) character, which the engine reserves as the
  /// document-id/field-path separator.
  Map<String, Object?> flatten(Map<String, dynamic> document);

  /// Rebuilds the document map from its [fields] (field-path → value), the
  /// inverse of [flatten].
  Map<String, dynamic> unflatten(Map<String, Object?> fields);
}
