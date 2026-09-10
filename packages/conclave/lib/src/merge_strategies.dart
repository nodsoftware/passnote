import 'crdt/crdt_type.dart';
import 'ports/merge_strategy.dart';

/// A [MergeStrategy] that treats each document as a single, atomic CRDT record.
///
/// Concurrent edits to the same document resolve last-write-wins as a whole:
/// the edit with the higher Hybrid Logical Clock wins entirely and the other is
/// discarded. Edits to *different* documents always both survive.
///
/// This is the default strategy. Choose it when a document has cross-field
/// invariants that a partial merge could violate.
class ObjectMergeStrategy implements MergeStrategy {
  /// Creates a whole-document merge strategy.
  const ObjectMergeStrategy();

  // The single field path under which the whole document is stored.
  static const String _wholeDocument = '';

  @override
  Iterable<FieldSpec> fields(Map<String, dynamic> document) => [
        (path: _wholeDocument, value: document, type: const LwwRegister()),
      ];

  @override
  Map<String, dynamic> unflatten(Iterable<FieldValue> rows) {
    final row = rows.firstWhere((r) => r.path == _wholeDocument);
    return (row.value as Map).cast<String, dynamic>();
  }

  @override
  CrdtType typeAt(String path) => const LwwRegister();
}

/// A [MergeStrategy] that gives each top-level field its own CRDT record.
///
/// Concurrent edits to *different* top-level fields of the same document both
/// survive; concurrent edits to the *same* field resolve last-write-wins.
/// Nested objects and lists are stored as a single atomic value.
///
/// Example: if one device changes a note's `title` while another changes its
/// `content`, both edits are preserved.
class ShallowMergeStrategy implements MergeStrategy {
  /// Creates a top-level-field merge strategy.
  const ShallowMergeStrategy();

  @override
  Iterable<FieldSpec> fields(Map<String, dynamic> document) => [
        for (final entry in document.entries)
          (path: entry.key, value: entry.value, type: const LwwRegister()),
      ];

  @override
  Map<String, dynamic> unflatten(Iterable<FieldValue> rows) =>
      {for (final row in rows) row.path: row.value};

  @override
  CrdtType typeAt(String path) => const LwwRegister();
}

/// A [MergeStrategy] that flattens nested maps recursively, joining keys with
/// [pathSeparator] (default `'.'`).
///
/// Every scalar leaf — at any depth — becomes its own CRDT record, so
/// concurrent edits to distinct leaves anywhere in the document all survive.
/// Lists are treated as atomic leaves (no element-level merging).
///
/// Field names must not contain [pathSeparator], as it is used to encode the
/// nesting path.
class DeepMergeStrategy implements MergeStrategy {
  /// Creates a recursive merge strategy.
  const DeepMergeStrategy({this.pathSeparator = '.'});

  /// The separator used to join nested keys into a flat path.
  final String pathSeparator;

  @override
  Iterable<FieldSpec> fields(Map<String, dynamic> document) {
    final out = <FieldSpec>[];
    _flattenInto('', document, out);
    return out;
  }

  void _flattenInto(
      String prefix, Map<dynamic, dynamic> map, List<FieldSpec> out) {
    if (map.isEmpty && prefix.isNotEmpty) {
      // Preserve empty nested objects as leaves so they round-trip.
      out.add((
        path: prefix,
        value: <String, dynamic>{},
        type: const LwwRegister()
      ));
      return;
    }
    for (final entry in map.entries) {
      final key = entry.key as String;
      final path = prefix.isEmpty ? key : '$prefix$pathSeparator$key';
      final value = entry.value;
      if (value is Map) {
        _flattenInto(path, value, out);
      } else {
        out.add((path: path, value: value, type: const LwwRegister()));
      }
    }
  }

  @override
  Map<String, dynamic> unflatten(Iterable<FieldValue> rows) {
    final root = <String, dynamic>{};
    for (final row in rows) {
      final parts = row.path.split(pathSeparator);
      var node = root;
      for (var i = 0; i < parts.length - 1; i++) {
        node = (node[parts[i]] ??= <String, dynamic>{}) as Map<String, dynamic>;
      }
      node[parts.last] = row.value;
    }
    return root;
  }

  @override
  CrdtType typeAt(String path) => const LwwRegister();
}

/// A [MergeStrategy] that decomposes a document per top-level field and assigns
/// a [CrdtType] to named paths.
///
/// Pass a [schema] mapping field paths to their type:
///
/// ```dart
/// SchemaMergeStrategy({'qty': PnCounter(), 'tags': OrSet()})
/// ```
///
/// `qty` merges as a counter and `tags` as an observed-remove set; every other
/// field falls back to [LwwRegister], so an untyped document behaves exactly as
/// it would under [base] (a [ShallowMergeStrategy] by default).
///
/// Decomposition and reconstruction are delegated to [base]; this strategy only
/// layers the type assignment on top, so per-field records still line up with
/// [base]'s field paths.
class SchemaMergeStrategy implements MergeStrategy {
  /// Creates a schema-driven merge strategy.
  ///
  /// [schema] maps a field path (as produced by [base]) to its [CrdtType].
  /// Paths absent from [schema] use [LwwRegister]. [base] controls how the
  /// document is split into fields and defaults to [ShallowMergeStrategy].
  const SchemaMergeStrategy(
    this.schema, {
    this.base = const ShallowMergeStrategy(),
  });

  /// Field path → [CrdtType]. Paths not listed here default to [LwwRegister].
  final Map<String, CrdtType> schema;

  /// The strategy that decides how the document is split into fields.
  final MergeStrategy base;

  @override
  Iterable<FieldSpec> fields(Map<String, dynamic> document) =>
      base.fields(document).map(
            (f) => (
              path: f.path,
              value: f.value,
              type: schema[f.path] ?? const LwwRegister(),
            ),
          );

  @override
  Map<String, dynamic> unflatten(Iterable<FieldValue> rows) =>
      base.unflatten(rows);

  @override
  CrdtType typeAt(String path) => schema[path] ?? base.typeAt(path);
}
