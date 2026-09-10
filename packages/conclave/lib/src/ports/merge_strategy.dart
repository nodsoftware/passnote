import '../crdt/crdt_type.dart';

/// One field of a document, ready to be written as its own CRDT record: a
/// stable [path], the current [value], and the [CrdtType] that governs how
/// concurrent edits to it merge.
///
/// Paths must be stable across versions of the same document and must not
/// contain the ASCII Unit Separator (`\x1F`, U+001F), which the engine reserves
/// as the document-id/field-path separator.
typedef FieldSpec = ({String path, Object? value, CrdtType type});

/// One live field record read back from storage: its [path] and current
/// [value]. The [CrdtType] is not needed to rebuild the document (the merge has
/// already happened in the engine), so it is omitted here.
typedef FieldValue = ({String path, Object? value});

/// Controls the granularity at which a document is split into independently
/// timestamped CRDT records, and therefore how concurrent edits to the same
/// document merge.
///
/// A `Collection<T>` converts each document to a JSON map (via its [Codec]) and
/// hands it to a [MergeStrategy]. [fields] decomposes it into a set of
/// [FieldSpec] entries; each entry becomes its own CRDT record with its own
/// Hybrid Logical Clock, so concurrent edits to *different* entries both survive
/// a merge. How concurrent edits to the *same* entry resolve depends on the
/// entry's [CrdtType] (last-write-wins for [LwwRegister], the default).
///
/// Built-in strategies:
///
/// - `ObjectMergeStrategy` — the whole document is a single record
///   (whole-document last-write-wins). The default.
/// - `ShallowMergeStrategy` — each top-level field is its own record; nested
///   objects and lists are atomic.
/// - `DeepMergeStrategy` — nested maps are flattened recursively; lists and
///   scalars are leaves.
/// - `SchemaMergeStrategy` — a per-field strategy that also assigns a
///   [CrdtType] to named field paths; unlisted fields stay [LwwRegister].
///
/// Implement this interface to define a custom decomposition.
abstract interface class MergeStrategy {
  /// Decomposes [document] into the CRDT records it should be stored as.
  ///
  /// Each returned [FieldSpec] becomes an independently merged record. The
  /// paths must be stable across document versions and free of the ASCII Unit
  /// Separator (`\x1F`, U+001F).
  Iterable<FieldSpec> fields(Map<String, dynamic> document);

  /// Rebuilds the document map from its live field [rows] (path → value), the
  /// inverse of [fields].
  Map<String, dynamic> unflatten(Iterable<FieldValue> rows);
}
