import 'dart:async';
import 'dart:convert';

import 'package:crdt/crdt.dart';

import 'codec.dart';
import 'map_crdt_table.dart';
import 'merge_strategies.dart';
import 'ports/blob_store.dart';
import 'ports/crdt_table.dart';
import 'ports/merge_strategy.dart';

/// A function that transforms a document id into an opaque storage-key token.
///
/// Used by [Collection] to hide document ids from plaintext blob-store keys.
/// See [Conclave.open] and [createIdMasker] for wiring.
typedef IdMasker = String Function(String id);


/// A typed, queryable set of documents backed by a per-collection [CrdtTable].
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
/// Document ids and field paths must not contain the ASCII Unit Separator (`\x1F`, U+001F),
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
    IdMasker? idMasker,
    CrdtTable? table,
    List<String> indexedFields = const [],
    void Function()? onLocalChange,
    void Function(String documentId)? onRemoteConflict,
  })  : _merge = merge,
        _idMasker = idMasker,
        _engine = table ?? MapCrdtTable(_name),
        _onLocalChange = onLocalChange,
        _onRemoteConflict = onRemoteConflict,
        _index = _Index(indexedFields),
        assert(
          indexedFields.isEmpty || merge is! ObjectMergeStrategy,
          'indexedFields with ObjectMergeStrategy: the default merge '
              "strategy flattens each document to a single record (key '') "
              'and will not populate individual declared field paths '
              'in the index. Use ShallowMergeStrategy or '
              'DeepMergeStrategy instead.',
        ) {
    _ready = _serialize(_restore);
  }

  /// Reserved separator between a document id and a field path in CRDT keys.
  /// NUL never appears in JSON object keys or in well-formed document ids.
  static const String _sep = '\x1F';

  final String _name;
  final Codec<T> _codec;
  final BlobStore _store;
  final MergeStrategy _merge;
  final CrdtTable _engine;
  final void Function()? _onLocalChange;
  final void Function(String documentId)? _onRemoteConflict;

  /// Optional function that masks a document id before it appears in a
  /// storage key. When set, on-disk blob keys under `"<name>/d/"` carry the
  /// masked id rather than the raw id, so document ids are never visible as
  /// plaintext storage keys. When null, raw ids are used (fine for in-memory
  /// test stores or unencrypted adapters).
  final IdMasker? _idMasker;

  /// Secondary index for equality lookups on declared indexed fields.
  /// Only active when [indexedFields] was non-empty at creation time.
  final _Index _index;

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

  /// A future that completes when the initial storage load finishes.
  ///
  /// [get], [all], and [where] return empty results if called before this
  /// future completes. Use [ready] or [watch] to await readiness.
  Future<void> get ready => _ready;

  /// The number of live documents in this collection.
  ///
  /// Counts only documents that have both a live existence register and at
  /// least one field record — the same set that [all] returns. Does not
  /// decode documents and is therefore cheaper than `all.length`.
  int get length {
    final map = _engine.liveFields(_name, '');
    final aliveIds = <String>{};
    final idsWithFields = <String>{};
    for (final entry in map.entries) {
      final sep = entry.key.indexOf(_sep);
      if (sep < 0) {
        aliveIds.add(entry.key);
      } else {
        idsWithFields.add(entry.key.substring(0, sep));
      }
    }
    return aliveIds.intersection(idsWithFields).length;
  }

  /// Returns the document identified by [documentId], or `null` if absent or
  /// deleted.
  ///
  /// A document exists only while its existence register is live; field records
  /// that linger after a delete are ignored.
  T? get(String documentId) {
    if (_engine.value(_name, documentId) == null) return null;
    final fields = _fieldsForDoc(documentId);
    if (fields.isEmpty) return null;
    return _codec.fromMap(_merge.unflatten(fields));
  }

  /// All live (non-deleted) documents in unspecified order.
  ///
  /// When [limit] and/or [offset] are provided, **only the requested page is
  /// decoded** — decoding (the expensive step) scales with the page size, not
  /// the collection size. The collection's stored keys are still scanned once
  /// to enumerate documents, so that part stays O(collection) with the default
  /// in-memory engine. Offset is the number of documents to skip before
  /// returning results; limit is the maximum number of documents to return.
  List<T> all({int? limit, int? offset}) {
    final (:aliveIds, :grouped) = _scan();

    final start = offset ?? 0;
    if (start >= aliveIds.length) return [];
    final ids = aliveIds.toList();
    final end = limit != null
        ? (start + limit < ids.length ? start + limit : ids.length)
        : ids.length;

    return [
      for (final id in ids.sublist(start, end))
        if (grouped[id] case final fields?)
          _codec.fromMap(_merge.unflatten(fields)),
    ];
  }

  /// All live documents that satisfy [test].
  ///
  /// [test] runs against decoded documents, so this always scans and decodes up
  /// to the point it stops: when [limit] is provided, decoding stops once
  /// [limit] matching documents have been found (after skipping [offset]
  /// matches). For an equality match on a declared field, prefer [findBy], which
  /// avoids decoding non-matching documents entirely.
  Iterable<T> where(bool Function(T) test, {int? limit, int? offset}) {
    final off = offset ?? 0;
    return _whereLazy(test, limit, off);
  }

  /// All live documents whose indexed [field] equals [value].
  ///
  /// Only fields declared in [indexedFields] at collection creation time can
  /// be queried; throws [ArgumentError] otherwise. Only equality is supported —
  /// range, prefix and ordering queries are out of scope; use [where] for those.
  /// Results are in an unspecified but stable (within a session) order.
  ///
  /// ## Cost
  ///
  /// The index lookup is O(1) and **only the matching documents are decoded**
  /// (O(matches)), unlike [where], which decodes every document. The matched
  /// documents' field records are then materialised through the engine; with
  /// the default in-memory [MapCrdtTable] that materialisation costs a single
  /// O(collection) scan of the stored keys (string comparisons, no decoding),
  /// because a hash-backed table cannot range-scan. A disk- or SQL-backed
  /// [CrdtTable] can serve the same matched ids without the full scan — the
  /// decode savings hold regardless. So today the win is "stop decoding the
  /// whole collection on every query"; true sub-linear lookup arrives with a
  /// range-capable engine (see [CrdtTable.liveFields]).
  ///
  /// When [limit] and/or [offset] are provided, only the requested page is
  /// decoded.
  Iterable<T> findBy(String field, Object? value, {int? limit, int? offset}) {
    final docIds = _index.lookup(field, value); // throws if field not indexed
    _debugVerifyIndex(field, value, docIds);
    if (docIds.isEmpty) return [];

    // Single scan, decoding only matched documents. Intersecting with the
    // freshly scanned live ids shares [all]'s liveness semantics and is a cheap
    // backstop against index/CRDT drift (also guarded by [_debugVerifyIndex]).
    final (:aliveIds, :grouped) = _scan(onlyDocs: docIds);
    final live = [for (final id in docIds) if (aliveIds.contains(id)) id];

    final start = offset ?? 0;
    if (start >= live.length) return [];
    final end = limit != null
        ? (start + limit < live.length ? start + limit : live.length)
        : live.length;

    return [
      for (final id in live.sublist(start, end))
        if (grouped[id] case final fields?)
          _codec.fromMap(_merge.unflatten(fields)),
    ];
  }

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
      final current = _fieldsForDoc(id);

      // Mark the document alive. Refreshing this on every write means an edit
      // competes with a concurrent delete on a single register (latest wins).
      await _engine.put(_name, id, true);

      for (final field in fields.entries) {
        // Only write fields whose value actually changed. Rewriting an unchanged
        // field would stamp it with a fresher HLC and clobber a concurrent edit
        // to that field made on another node.
        if (current.containsKey(field.key) &&
            jsonEncode(current[field.key]) == jsonEncode(field.value)) {
          continue;
        }
        await _engine.put(_name, '$prefix${field.key}', field.value);
      }
      // Tombstone fields that no longer exist on the document (e.g. a key removed
      // from a map under shallow/deep merge). The schema of a fixed type rarely
      // changes, but custom strategies may vary the field set.
      for (final path in current.keys) {
        if (!fields.containsKey(path)) {
          await _engine.put(_name, '$prefix$path', null, isDeleted: true);
        }
      }
      await _persistDocuments({id});
      if (_index.isActive) _index.reindex(id, fields);
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
      await _engine.put(_name, documentId, null, isDeleted: true);
      await _persistDocuments({documentId});
      if (_index.isActive) _index.removeDoc(documentId);
    });
    _onLocalChange?.call();
  }

  /// Returns a stream that emits the current document list once the initial
  /// storage load completes, then on every subsequent change.
  Stream<List<T>> watch() {
    // `_engine.watch` is a broadcast stream that drops events while it has no
    // listener. Subscribe to it *before* emitting the initial snapshot so a
    // merge that lands between subscription and the first emit is never lost.
    late final StreamController<List<T>> controller;
    StreamSubscription<void>? sub;
    controller = StreamController<List<T>>(
      onListen: () {
        sub = _engine.watch(_name).listen((_) => controller.add(all()));
        _ready.then((_) => controller.add(all()));
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
  String get maxHlc => _engine.maxHlc(_name);

  /// Returns records modified after [sinceHlc] (or all records when null) in
  /// [CrdtChangeset] format ready for wire serialisation.
  CrdtChangeset getChangeset({String? sinceHlc}) =>
      _engine.changeset(_name, sinceHlc: sinceHlc);

  /// Merges a [CrdtChangeset] received from a peer and persists the result.
  /// Does NOT trigger [onLocalChange] — remote changes must not be re-broadcast.
  Future<void> mergeChangeset(CrdtChangeset changeset) async {
    await _ready;
    await _serialize(() async {
      final touched = <String>{};
      final conflicted = <String>{};
      for (final records in changeset.values) {
        for (final record in records) {
          final key = record['key'] as String;
          final sep = key.indexOf(_sep);
          final docId = sep < 0 ? key : key.substring(0, sep);
          touched.add(docId);
          if (_onRemoteConflict != null &&
              _engine.value(_name, docId) != null) {
            conflicted.add(docId);
          }
        }
      }
      await _engine.merge(changeset);
      await _persistDocuments(touched);
      if (_index.isActive) {
        for (final docId in touched) {
          if (_engine.value(_name, docId) != null) {
            _index.reindex(docId, _fieldsForDoc(docId));
          } else {
            _index.removeDoc(docId);
          }
        }
      }
      for (final docId in conflicted) {
        _onRemoteConflict!(docId);
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Scan helpers

  /// Scans the engine's live fields and returns:
  ///
  /// - [aliveIds]: document ids whose existence register is live (separator-free
  ///   keys in the CRDT).
  /// - [grouped]: field records grouped by document id, keyed by the field path
  ///   (the portion of the CRDT key after the `"$id\x1F"` prefix).
  /// When [onlyDocs] is given, [grouped] (and the alive-id set) is restricted to
  /// those document ids — the scan still visits every key once (the in-memory
  /// engine can't range-scan), but field maps are only built for the documents
  /// of interest, so memory stays O(onlyDocs) rather than O(collection). Used by
  /// [findBy], where the index has already narrowed the result to a few ids.
  ({Set<String> aliveIds, Map<String, Map<String, Object?>> grouped}) _scan(
      {Set<String>? onlyDocs}) {
    final map = _engine.liveFields(_name, '');
    final aliveIds = <String>{};
    final grouped = <String, Map<String, Object?>>{};
    for (final entry in map.entries) {
      final sep = entry.key.indexOf(_sep);
      if (sep < 0) {
        if (onlyDocs == null || onlyDocs.contains(entry.key)) {
          aliveIds.add(entry.key);
        }
        continue;
      }
      final id = entry.key.substring(0, sep);
      if (onlyDocs != null && !onlyDocs.contains(id)) continue;
      final path = entry.key.substring(sep + 1);
      (grouped[id] ??= <String, Object?>{})[path] = entry.value;
    }
    return (aliveIds: aliveIds, grouped: grouped);
  }

  /// Like [where] but backed by a `sync*` generator so that decoding stops
  /// once [limit] matching documents are found.
  Iterable<T> _whereLazy(
      bool Function(T) test, int? limit, int offset) sync* {
    final (:aliveIds, :grouped) = _scan();
    var matched = 0;
    var skipped = 0;
    for (final id in aliveIds) {
      if (limit != null && matched >= limit) break;
      if (grouped[id] case final fields?) {
        final doc = _codec.fromMap(_merge.unflatten(fields));
        if (test(doc)) {
          if (skipped < offset) {
            skipped++;
          } else {
            matched++;
            yield doc;
          }
        }
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Field helpers

  /// Returns the live field entries (field-path → value) for [documentId],
  /// scoped to a single document. Strips the `"$id\x1F"` prefix from the keys
  /// so the result is path → value as [MergeStrategy.unflatten] expects.
  ///
  /// Uses the engine's scoped [CrdtTable.liveFields] so a lazy adapter can
  /// load only the requested document without scanning the full table.
  Map<String, Object?> _fieldsForDoc(String documentId) {
    final prefix = '$documentId$_sep';
    return {
      for (final e in _engine.liveFields(_name, prefix).entries)
        e.key.substring(prefix.length): e.value,
    };
  }

  // ---------------------------------------------------------------------------
  // Persistence helpers

  /// Returns the blob key for [id]'s per-document blob.
  ///
  /// When [_idMasker] is set the raw id is transformed before embedding in the key
  /// so that document ids are not visible as plaintext storage keys.
  String _docBlobKey(String id) => '$_name/d/${_idMasker?.call(id) ?? id}';

  /// Persists exactly the documents whose ids are in [docIds].
  ///
  /// A document with no records is removed from storage. Persisting multiple
  /// blobs in one call is not atomic — a crash between writes leaves some docs
  /// persisted and others not — but a CRDT converges this safely on the next
  /// sync without data loss.
  Future<void> _persistDocuments(Set<String> docIds) async {
    final cs = _engine.changeset(_name);
    final rows = cs[_name] ?? const [];

    // Group all rows by their document id.
    final byDoc = <String, List<Map<String, Object?>>>{};
    for (final r in rows) {
      final key = r['key'] as String;
      final sep = key.indexOf(_sep);
      final id = sep < 0 ? key : key.substring(0, sep);
      if (docIds.contains(id)) {
        (byDoc[id] ??= []).add(r);
      }
    }

    for (final id in docIds) {
      final docRows = byDoc[id];
      final blobKey = _docBlobKey(id);
      if (docRows == null || docRows.isEmpty) {
        await _store.delete(blobKey);
      } else {
        final payload = <String, Map<String, dynamic>>{
          for (final r in docRows)
            (r['key'] as String): {
              'v': r['value'],
              'd': r['is_deleted'] as bool,
              'h': (r['hlc'] as Hlc).toString(),
            },
        };
        await _store.write(blobKey, utf8.encode(jsonEncode(payload)));
      }
    }
  }

  /// Restores all documents from per-document blobs under `"<name>/d/"`.
  Future<void> _restore() async {
    final keys = await _store.keys(prefix: '$_name/d/');
    final rows = <Map<String, Object?>>[];
    for (final k in keys) {
      List<int>? bytes;
      try {
        bytes = await _store.read(k);
      } catch (_) {
        // Corrupt or tampered blob (e.g. CipherAuthError after a partial
        // re-encryption). Skip it — the CRDT will re-converge on next sync.
        continue;
      }
      if (bytes == null) continue;
      final raw = jsonDecode(utf8.decode(bytes));
      if (raw is! Map) continue;
      for (final e in (raw as Map<String, dynamic>).entries) {
        final data = e.value as Map<String, dynamic>;
        rows.add({
          'key': e.key,
          'value': data['v'],
          'is_deleted': data['d'] as bool,
          'hlc': Hlc.parse(data['h'] as String),
        });
      }
    }
    if (rows.isNotEmpty) {
      await _engine.merge({_name: rows});
    }
    _rebuildIndex();
  }

  void _rebuildIndex() {
    if (!_index.isActive) return;
    _index.clear();
    final (:aliveIds, :grouped) = _scan();
    for (final id in aliveIds) {
      if (grouped[id] case final fields?) {
        _index.reindex(id, fields);
      }
    }
  }

  /// Debug-only: cross-checks [findBy] results against a full scan.
  ///
  /// Only runs when the `CONCLAVE_VERIFY_INDEX` environment variable is set
  /// (checked at compile time via `bool.fromEnvironment`). Not called in
  /// production.
  void _debugVerifyIndex(String field, Object? value, Set<String> docIds) {
    if (!_index.isActive) return;
    if (!const bool.fromEnvironment('CONCLAVE_VERIFY_INDEX')) return;
    final expected = <String>{};
    final (:aliveIds, :grouped) = _scan();
    for (final id in aliveIds) {
      if (grouped[id] case final fields?) {
        if (jsonEncode(fields[field]) == jsonEncode(value)) {
          expected.add(id);
        }
      }
    }
    if (docIds.length != expected.length ||
        !docIds.every(expected.contains)) {
      throw StateError(
        'Index drift detected for $field=$value: '
        'live index returned $docIds, full scan returned $expected',
      );
    }
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
  /// [masker] is an optional function that hides document ids from plaintext
  /// storage keys. When provided it is applied to every document id before
  /// constructing the blob key; the raw id stays inside the encrypted payload.
  ///
  /// [onLocalChange] is called after every [put] or [delete] so that [Database]
  /// can push deltas to connected peers. It is intentionally NOT called by
  /// [mergeChangeset] to prevent re-broadcasting received data.
  ///
  /// [onRemoteConflict] is called during [mergeChangeset] for every document
  /// that existed locally before the merge and whose key appears in the
  /// incoming changeset. Use this to detect when a document was edited on
  /// another device.
  ///
  /// [indexedFields] declares field paths that should be indexed for
  /// equality lookups via [findBy]. The values are the flattened field paths
  /// produced by [merge] (top-level keys for [ShallowMergeStrategy], dotted
  /// paths for [DeepMergeStrategy], etc.). The index is derived state —
  /// rebuilt on load and updated incrementally. Defaults to no indexes.
  ///
  /// [table] overrides the default [MapCrdtTable]. Pass a custom
  /// [CrdtTable] implementation to back the collection with disk-based or
  /// otherwise lazy storage.
  static Collection<T> create<T>(
    String name,
    Codec<T> codec,
    BlobStore store, {
    MergeStrategy merge = const ObjectMergeStrategy(),
    IdMasker? idMasker,
    CrdtTable? table,
    List<String> indexedFields = const [],
    void Function()? onLocalChange,
    void Function(String documentId)? onRemoteConflict,
  }) =>
      Collection._(
        name,
        codec,
        store,
        merge: merge,
        idMasker: idMasker,
        table: table,
        indexedFields: indexedFields,
        onLocalChange: onLocalChange,
        onRemoteConflict: onRemoteConflict,
      );
}

/// In-memory secondary index for a [Collection]'s declared indexed fields.
///
/// Maintains a mapping of field path → JSON-encoded value → set of document ids
/// that have that field set to that value. The index is rebuilt on load from
/// storage (derived state — not persisted independently) and updated
/// incrementally on every [Collection.put], [Collection.delete], and
/// [Collection.mergeChangeset].
///
/// Only the fields listed in [fields] are tracked. The values come from the
/// merge strategy's flattened field map, so the index granularity (whole-doc,
/// per-field, or deep) matches the merge granularity automatically.
class _Index {
  _Index(List<String> fields) : _fields = fields.toSet();

  /// The set of indexed field paths.
  final Set<String> _fields;

  // field → jsonValue → Set<docId>
  final _data = <String, Map<String, Set<String>>>{};

  // docId → {field: jsonValue} — enables cleanup when a doc is reindexed
  // or removed without needing to re-read the doc from the engine.
  final _entries = <String, Map<String, String>>{};

  /// Whether this index has any indexed fields (and therefore needs updating).
  bool get isActive => _fields.isNotEmpty;

  /// Removes [docId] from the index, then adds entries for its current
  /// [flattenedFields] (already flattened by the merge strategy).
  void reindex(String docId, Map<String, Object?> flattenedFields) {
    _removeDoc(docId);
    _addDoc(docId, flattenedFields);
  }

  /// Removes all index entries for [docId].
  void removeDoc(String docId) => _removeDoc(docId);

  /// Removes every entry from this index.
  void clear() {
    _data.clear();
    _entries.clear();
  }

  /// Returns the set of document ids whose indexed [field] equals [value].
  ///
  /// Throws [ArgumentError] if [field] was not declared in this index's
  /// field set.
  Set<String> lookup(String field, Object? value) {
    if (!_fields.contains(field)) {
      throw ArgumentError(
        'Field "$field" is not indexed. Indexed fields: $_fields',
      );
    }
    final byValue = _data[field];
    if (byValue == null) return const {};
    return byValue[jsonEncode(value)] ?? const {};
  }

  void _addDoc(String docId, Map<String, Object?> flattenedFields) {
    final entry = <String, String>{};
    for (final field in _fields) {
      if (flattenedFields.containsKey(field)) {
        final jv = jsonEncode(flattenedFields[field]);
        _data.putIfAbsent(field, () => <String, Set<String>>{});
        _data[field]!.putIfAbsent(jv, () => <String>{});
        _data[field]![jv]!.add(docId);
        entry[field] = jv;
      }
    }
    if (entry.isNotEmpty) _entries[docId] = entry;
  }

  void _removeDoc(String docId) {
    final old = _entries.remove(docId);
    if (old != null) {
      for (final entry in old.entries) {
        _data[entry.key]?[entry.value]?.remove(docId);
      }
    }
  }
}
