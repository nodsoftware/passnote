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
  Map<String, Object?> flatten(Map<String, dynamic> document) => {
        _wholeDocument: document,
      };

  @override
  Map<String, dynamic> unflatten(Map<String, Object?> fields) =>
      (fields[_wholeDocument] as Map).cast<String, dynamic>();
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
  Map<String, Object?> flatten(Map<String, dynamic> document) =>
      Map<String, Object?>.of(document);

  @override
  Map<String, dynamic> unflatten(Map<String, Object?> fields) =>
      Map<String, dynamic>.of(fields);
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
  Map<String, Object?> flatten(Map<String, dynamic> document) {
    final out = <String, Object?>{};
    _flattenInto('', document, out);
    return out;
  }

  void _flattenInto(String prefix, Map<dynamic, dynamic> map, Map<String, Object?> out) {
    if (map.isEmpty && prefix.isNotEmpty) {
      // Preserve empty nested objects as leaves so they round-trip.
      out[prefix] = <String, dynamic>{};
      return;
    }
    for (final entry in map.entries) {
      final key = entry.key as String;
      final path = prefix.isEmpty ? key : '$prefix$pathSeparator$key';
      final value = entry.value;
      if (value is Map) {
        _flattenInto(path, value, out);
      } else {
        out[path] = value;
      }
    }
  }

  @override
  Map<String, dynamic> unflatten(Map<String, Object?> fields) {
    final root = <String, dynamic>{};
    for (final entry in fields.entries) {
      final parts = entry.key.split(pathSeparator);
      var node = root;
      for (var i = 0; i < parts.length - 1; i++) {
        node = (node[parts[i]] ??= <String, dynamic>{}) as Map<String, dynamic>;
      }
      node[parts.last] = entry.value;
    }
    return root;
  }
}
