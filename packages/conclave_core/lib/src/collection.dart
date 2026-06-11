import 'dart:async';
import 'dart:convert';

import 'package:crdt/crdt.dart';
import 'package:crdt/map_crdt.dart';

import 'codec.dart';
import 'ports/blob_store.dart';

/// A typed, queryable set of documents backed by a per-collection [MapCrdt].
///
/// Documents are identified by the string returned from [Codec.idOf].
/// Concurrent edits to the same document key merge last-write-wins via Hybrid
/// Logical Clock arbitration; edits to different keys always both survive.
///
/// Storage loading is asynchronous. [put] and [delete] await the initial load
/// before writing; [get] and [all] return empty results if called before the
/// load completes, but [watch] will emit the correct list once ready.
class Collection<T> {
  Collection._(this._name, this._codec, this._store, {void Function()? onLocalChange})
      : _onLocalChange = onLocalChange,
        _crdt = MapCrdt([_name]) {
    _ready = _restore();
  }

  final String _name;
  final Codec<T> _codec;
  final BlobStore _store;
  final MapCrdt _crdt;
  final void Function()? _onLocalChange;

  late final Future<void> _ready;

  // ---------------------------------------------------------------------------
  // Public API

  /// Returns the document identified by [documentId], or `null` if absent or
  /// deleted.
  T? get(String documentId) {
    final value = _crdt.get(_name, documentId) as String?;
    return value == null ? null : _codec.decode(value);
  }

  /// All live (non-deleted) documents in unspecified order.
  List<T> get all {
    final map = _crdt.getMap(_name);
    return map.values.cast<String>().map(_codec.decode).toList();
  }

  /// All live documents that satisfy [test].
  Iterable<T> where(bool Function(T) test) => all.where(test);

  /// Persists [value], using [Codec.idOf] as the document key.
  ///
  /// Awaits the initial storage load before writing.
  Future<void> put(T value) async {
    await _ready;
    await _crdt.put(_name, _codec.idOf(value), _codec.encode(value));
    await _persist();
    _onLocalChange?.call();
  }

  /// Soft-deletes the document identified by [documentId].
  ///
  /// Awaits the initial storage load before writing.
  Future<void> delete(String documentId) async {
    await _ready;
    await _crdt.put(_name, documentId, null, true);
    await _persist();
    _onLocalChange?.call();
  }

  /// Returns a stream that emits the current document list immediately and on
  /// every subsequent change.
  Stream<List<T>> watch() {
    // `_crdt.watch` is a broadcast stream that drops events while it has no
    // listener. Subscribe to it *before* emitting the initial snapshot so a
    // merge that lands between subscription and the first emit is never lost.
    late final StreamController<List<T>> controller;
    StreamSubscription<void>? sub;
    controller = StreamController<List<T>>(
      onListen: () {
        sub = _crdt.watch(_name).listen((_) => controller.add(all));
        _ready.then((_) => controller.add(all));
      },
      onCancel: () async {
        await sub?.cancel();
      },
    );
    return controller.stream;
  }

  // ---------------------------------------------------------------------------
  // Engine-internal API — used by Database for the sync protocol.
  // Not part of the application-facing surface.

  /// The collection's table name inside the CRDT.
  String get name => _name;

  /// The highest modified-HLC seen in this collection as a string, or the
  /// empty string when the collection is empty.
  String get maxHlc {
    final cs = _crdt.getChangeset(onlyTables: [_name]);
    if (cs.isEmpty) return '';
    return _crdt.getLastModified().toString();
  }

  /// Returns records modified after [sinceHlc] (or all records when null) in
  /// [CrdtChangeset] format ready for wire serialisation.
  CrdtChangeset getChangeset({String? sinceHlc}) => _crdt.getChangeset(
        onlyTables: [_name],
        modifiedAfter:
            (sinceHlc == null || sinceHlc.isEmpty) ? null : Hlc.parse(sinceHlc),
      );

  /// Merges a [CrdtChangeset] received from a peer and persists the result.
  /// Does NOT trigger [onLocalChange] — remote changes must not be re-broadcast.
  Future<void> mergeChangeset(CrdtChangeset changeset) async {
    await _crdt.merge(changeset);
    await _persist();
  }

  // ---------------------------------------------------------------------------
  // Persistence helpers

  Future<void> _persist() async {
    final cs = _crdt.getChangeset(onlyTables: [_name]);
    final rows = cs[_name] ?? [];
    final payload = <String, Map<String, dynamic>>{
      for (final r in rows)
        (r['key'] as String): {
          'v': r['value'],
          'd': r['is_deleted'] as bool,
          'h': (r['hlc'] as Hlc).toString(),
        },
    };
    await _store.write(_name, utf8.encode(jsonEncode(payload)));
  }

  Future<void> _restore() async {
    final bytes = await _store.read(_name);
    if (bytes == null) return;
    final raw = jsonDecode(utf8.decode(bytes));
    if (raw is! Map || raw.isEmpty) return;

    final changeset = <String, List<Map<String, Object?>>>{
      _name: (raw as Map<String, dynamic>).entries.map((e) {
        final data = e.value as Map<String, dynamic>;
        return <String, Object?>{
          'key': e.key,
          'value': data['v'],
          'is_deleted': data['d'] as bool,
          'hlc': Hlc.parse(data['h'] as String),
        };
      }).toList(),
    };
    await _crdt.merge(changeset);
  }

  // ---------------------------------------------------------------------------
  // Factory — used by Database

  /// Creates a collection named [name] backed by [store], starting an
  /// asynchronous load from storage in the background.
  ///
  /// [onLocalChange] is called after every [put] or [delete] so that [Database]
  /// can push deltas to connected peers. It is intentionally NOT called by
  /// [mergeChangeset] to prevent re-broadcasting received data.
  static Collection<T> create<T>(
    String name,
    Codec<T> codec,
    BlobStore store, {
    void Function()? onLocalChange,
  }) =>
      Collection._(name, codec, store, onLocalChange: onLocalChange);
}
