import 'dart:convert';

/// Converts values of type [T] to and from a string representation, and
/// extracts a stable document identifier from each value.
///
/// The codec sits between the typed [Collection] and the raw string stored in
/// the CRDT. It never sees encrypted bytes.
abstract interface class Codec<T> {
  /// Encodes [value] to its string representation.
  String encode(T value);

  /// Decodes [raw] back to a [T].
  T decode(String raw);

  /// Extracts the stable document identifier from [value].
  String idOf(T value);
}

/// A [Codec] backed by JSON [toJson]/[fromJson] functions.
///
/// ```dart
/// final codec = JsonCodec<Note>(
///   toJson: (n) => n.toJson(),
///   fromJson: Note.fromJson,
///   id: (n) => n.id,
/// );
/// ```
class JsonCodec<T> implements Codec<T> {
  const JsonCodec({
    required this.toJson,
    required this.fromJson,
    required this.id,
  });

  /// Converts [T] to a JSON-encodable map.
  final Map<String, dynamic> Function(T) toJson;

  /// Constructs [T] from a JSON map.
  final T Function(Map<String, dynamic>) fromJson;

  /// Extracts the document id from [T].
  final String Function(T) id;

  @override
  String encode(T value) => jsonEncode(toJson(value));

  @override
  T decode(String raw) => fromJson(jsonDecode(raw) as Map<String, dynamic>);

  @override
  String idOf(T value) => id(value);
}
