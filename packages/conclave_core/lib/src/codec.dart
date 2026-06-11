/// Converts values of type [T] to and from a JSON-style map, and extracts a
/// stable document identifier from each value.
///
/// The codec sits between the typed [Collection] and the field decomposition
/// performed by the merge strategy. It never sees encrypted bytes, and the map
/// it produces must be JSON-serialisable.
abstract interface class Codec<T> {
  /// Converts [value] to a JSON-serialisable map.
  Map<String, dynamic> toMap(T value);

  /// Reconstructs a [T] from [map].
  T fromMap(Map<String, dynamic> map);

  /// Extracts the stable document identifier from [value].
  String idOf(T value);
}

/// A [Codec] backed by plain functions.
///
/// ```dart
/// final codec = JsonCodec<Note>(
///   toMap: (n) => n.toJson(),
///   fromMap: Note.fromJson,
///   idOf: (n) => n.id,
/// );
/// ```
class JsonCodec<T> implements Codec<T> {
  const JsonCodec({
    required Map<String, dynamic> Function(T) toMap,
    required T Function(Map<String, dynamic>) fromMap,
    required String Function(T) idOf,
  })  : _toMap = toMap,
        _fromMap = fromMap,
        _idOf = idOf;

  final Map<String, dynamic> Function(T) _toMap;
  final T Function(Map<String, dynamic>) _fromMap;
  final String Function(T) _idOf;

  @override
  Map<String, dynamic> toMap(T value) => _toMap(value);

  @override
  T fromMap(Map<String, dynamic> map) => _fromMap(map);

  @override
  String idOf(T value) => _idOf(value);
}
