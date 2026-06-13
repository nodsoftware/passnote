import 'dart:async';
import 'dart:convert';

import 'package:crdt/crdt.dart';
import 'package:crdt/map_crdt.dart';

import 'codec.dart';
import 'merge_strategies.dart';
import 'ports/blob_store.dart';
import 'ports/merge_strategy.dart';

/// A typed, queryable set of documents backed by a per-collection [MapCrdt].
///
/// Documents are identified by the string returned from [Codec.idOf]. Each
/// document is split into one or more independently timestamped CRDT records by a
/// [MergeStrategy]; how concurrent edits to the same document merge depends on
/// that strategy (whole-document, per-field, or deep). Edits to different
/// documents always both survive.
///
/// Document *existence* is tracked separately from its fields by a single
/// last-write-wins record (the "existence register"), keyed by the bare
/// document id. This makes deletion atomic at the document level regardless of
/// the merge strategy: a delete and a concurrent field edit are reconciled on
/// that one register (latest wins), so a document can never come back missing
/// some of its fields. The field records of a deleted document are intentionally
/// left untouched, which guarantees that a revived document still carries its
/// full field set; they are harmless until overwritten or compacted.
///
/// Document ids and field paths must not contain the NUL character (`\u0000`),
/// which is reserved as the id/field separator.
///
/// Storage loading is asynchronous. [put] and [delete] await the initial load
/// before writing; [get] and [all] return empty results if called before the
/// load completes, but [watch] will emit the correct list once ready.
class Collection<T> {
  Collection._(
    this._name,
    this._codec,
    this._store, {
    required MergeStrategy merge,
    void Function()? onLocalChange,
  })  : _merge = merge,
        _onLocalChange = onLocalChange,
        _crdt = MapCrdt([_name]) {
    _ready = _serialize(_restore);
  }

  /// Reserved separator between a document id and a field path in CRDT keys.
  /// NUL never appears in JSON object keys or in well-formed document ids.
  static const String _sep = '\u0000';

  final String _name;
  final Codec<T> _codec;
  final BlobStore _store;
  final MergeStrategy _merge;
  final MapCrdt _crdt;
  final void Function()? _onLocalChange;

  late final Future<void> _ready;

  // Serialises every mutating CRDT operation (restore, put, delete, merge). The
  // `crdt` package's `merge` is not atomic: it reads the canonical time, awaits
  // a write, then asserts `hlc >= canonicalTime`. A local `put` landing during
  // that await would bump the canonical time and trip the assertion, so all
  // writers run one-at-a-time through this chain.
  Future<void> _writes = Future<void>.value();

  Future<void> _serialize(Future<void> Function() action) {
    final done = _writes.then((_) => action());
    // Keep the chain alive even if an action fails; the failure still surfaces
    // to the caller via [done].
    _writes = done.catchError((_) {});
    return done;
  }

  // ---------------------------------------------------------------------------
  // Public API

  /// Returns the document identified by [documentId], or `null` if absent or
  /// deleted.
  ///
  /// A document exists only while its existence register is live; field records
  /// that linger after a delete are ignored.
  T? get(String documentId) {
    final map = _crdt.getMap(_name);
    if (!map.containsKey(documentId)) return null;
    final fields = _fieldsFor(documentId, map);
    if (fields.isEmpty) return null;
    return _codec.fromMap(_merge.unflatten(fields));
  }

  /// All live (non-deleted) documents in unspecified order.
  List<T> get all {
    final map = _crdt.getMap(_name);
    final aliveIds = <String>{};
    final grouped = <String, Map<String, Object?>>{};
    for (final entry in map.entries) {
      final sep = entry.key.indexOf(_sep);
      if (sep < 0) {
        // A separator-free key is an existence register: the document is alive.
        aliveIds.add(entry.key);
        continue;
      }
      final id = entry.key.substring(0, sep);
      final path = entry.key.substring(sep + 1);
      (grouped[id] ??= <String, Object?>{})[path] = entry.value;
    }
    return [
      for (final id in aliveIds)
        if (grouped[id] case final fields?)
          _codec.fromMap(_merge.unflatten(fields)),
    ];
  }

  /// All live documents that satisfy [test].
  Iterable<T> where(bool Function(T) test) => all.where(test);

  /// Persists [value], using [Codec.idOf] as the document key.
  ///
  /// The document is flattened into CRDT records by the collection's
  /// [MergeStrategy]; fields present on a previous version but absent now are
  /// tombstoned. The document's existence register is (re)marked live so that a
  /// concurrent delete on another node is reconciled last-write-wins. Awaits the
  /// initial storage load before writing.
  Future<void> put(T value) async {
    await _ready;
    await _serialize(() async {
      final id = _codec.idOf(value);
      final fields = _merge.flatten(_codec.toMap(value));
      final prefix = '$id$_sep';
      final current = _fieldsFor(id, _crdt.getMap(_name));

      // Mark the document alive. Refreshing this on every write means an edit
      // competes with a concurrent delete on a single register (latest wins).
      await _crdt.put(_name, id, true);

      for (final field in fields.entries) {
        // Only write fields whose value actually changed. Rewriting an unchanged
        // field would stamp it with a fresher HLC and clobber a concurrent edit
        // to that field made on another node.
        if (current.containsKey(field.key) &&
            jsonEncode(current[field.key]) == jsonEncode(field.value)) {
          continue;
        }
        await _crdt.put(_name, '$prefix${field.key}', field.value);
      }
      // Tombstone fields that no longer exist on the document (e.g. a key removed
      // from a map under shallow/deep merge). The schema of a fixed type rarely
      // changes, but custom strategies may vary the field set.
      for (final path in current.keys) {
        if (!fields.containsKey(path)) {
          await _crdt.put(_name, '$prefix$path', null, true);
        }
      }
      await _persist();
    });
    _onLocalChange?.call();
  }

  /// Deletes the document identified by [documentId] by tombstoning its
  /// existence register.
  ///
  /// Field records are intentionally left intact so that a concurrent edit that
  /// wins the existence register revives a document with its full field set,
  /// rather than one missing the fields the edit did not touch. Awaits the
  /// initial storage load before writing.
  Future<void> delete(String documentId) async {
    await _ready;
    await _serialize(() async {
      await _crdt.put(_name, documentId, null, true);
      await _persist();
    });
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

  /// The runtime type of this collection's [MergeStrategy]. Used by [Database]
  /// to detect a mismatched `merge:` argument on a repeated `collection()` call.
  Type get mergeType => _merge.runtimeType;

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
    await _ready;
    await _serialize(() async {
      await _crdt.merge(changeset);
      await _persist();
    });
  }

  // ---------------------------------------------------------------------------
  // Field helpers

  /// Collects the live field entries (field-path → value) for [documentId] from
  /// a CRDT live-record [map].
  Map<String, Object?> _fieldsFor(String documentId, Map<String, dynamic> map) {
    final prefix = '$documentId$_sep';
    final fields = <String, Object?>{};
    for (final entry in map.entries) {
      if (entry.key.startsWith(prefix)) {
        fields[entry.key.substring(prefix.length)] = entry.value;
      }
    }
    return fields;
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
  /// [merge] controls how documents are decomposed into CRDT records and
  /// therefore how concurrent edits merge; it defaults to whole-document
  /// last-write-wins via [ObjectMergeStrategy].
  ///
  /// [onLocalChange] is called after every [put] or [delete] so that [Database]
  /// can push deltas to connected peers. It is intentionally NOT called by
  /// [mergeChangeset] to prevent re-broadcasting received data.
  static Collection<T> create<T>(
    String name,
    Codec<T> codec,
    BlobStore store, {
    MergeStrategy merge = const ObjectMergeStrategy(),
    void Function()? onLocalChange,
  }) =>
      Collection._(
        name,
        codec,
        store,
        merge: merge,
        onLocalChange: onLocalChange,
      );
}
