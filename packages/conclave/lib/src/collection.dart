import 'dart:async';
import 'dart:convert';

import 'package:crdt/crdt.dart';

import 'codec.dart';
import 'crdt/crdt_type.dart';
import 'map_crdt_table.dart';
import 'merge_strategies.dart';
import 'ports/crdt_table.dart';
import 'ports/merge_strategy.dart';
import 'ports/query.dart';
import 'typed_crdt_table.dart';

part 'query/query.dart';

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
/// Document ids and field paths must not contain the ASCII Unit Separator
/// (`\x1F`, U+001F), which is reserved as the id/field separator.
///
/// The initial load is asynchronous. [put], [delete], [get], [all], [where],
/// and [query] await it before returning meaningful results.
class Collection<T> {
  Collection._(
    this._name,
    this._codec, {
    required MergeStrategy merge,
    FutureOr<CrdtTable> Function()? engine,
    List<String> indexedFields = const [],
    void Function()? onLocalChange,
    void Function(String documentId)? onRemoteConflict,
  })  : _merge = merge,
        // A synchronous placeholder so [length] / [maxHlc] are safe before the
        // real engine is built in [_ready]. Reads against it just return empty.
        _engine = TypedCrdtTable(MapCrdtTable(_name)),
        _onLocalChange = onLocalChange,
        _onRemoteConflict = onRemoteConflict,
        _queryIndexPaths = List.unmodifiable(indexedFields) {
    if (indexedFields.isNotEmpty && merge is ObjectMergeStrategy) {
      throw ArgumentError(
        'indexedFields with ObjectMergeStrategy: the default merge '
        "strategy stores each document as a single record (key '') "
        'and produces no per-field rows to index or query. Use '
        'ShallowMergeStrategy or DeepMergeStrategy instead.',
      );
    }
    indexedFields.forEach(CollectionQuery._validatePath);
    _ready = _serialize(() async {
      if (engine != null) {
        // The typed layer gives OrSet / PnCounter fields their merge
        // semantics over any engine the factory produces.
        final built = await Future.sync(engine);
        _engine = built is TypedCrdtTable ? built : TypedCrdtTable(built);
      }
      if (_engine.isPersistent) await _engine.init();
      for (final path in _queryIndexPaths) {
        await _engine.ensureQueryIndex(_name, path);
      }
    });
  }

  /// Reserved separator between a document id and a field path in CRDT keys.
  /// The unit separator never appears in well-formed document ids or field
  /// names.
  static const String _sep = '\x1F';

  final String _name;
  final Codec<T> _codec;
  final MergeStrategy _merge;
  TypedCrdtTable _engine;
  final void Function()? _onLocalChange;
  final void Function(String documentId)? _onRemoteConflict;

  /// Field paths declared for engine-side query indexes at creation time.
  final List<String> _queryIndexPaths;

  /// Tracks open [watch] stream controllers so they can be closed on
  /// [dispose]. Closed automatically when the controller's subscription is
  /// cancelled.
  final Set<StreamController<List<T>>> _watchers = {};

  /// Maps each open watch controller to its current engine subscription, so
  /// [compact] can re-point watchers after replacing the engine.
  final Map<StreamController<List<T>>, StreamSubscription<void>?> _watcherSubs =
      {};

  /// Maps each open watch controller to the closure that recomputes and emits
  /// its snapshot — `all()` for [watch], the query page for
  /// [CollectionQuery.watch] — so engine events and [compact] drive every
  /// watcher the same way.
  final Map<StreamController<List<T>>, Future<void> Function()>
      _watcherRefresh = {};

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
  /// decode documents and is therefore cheaper than `all().length`.
  ///
  /// Safe to call before [ready] — relies on the engine's sync [liveKeys].
  int get length {
    final keys = _engine.liveKeys(_name, '');
    final aliveIds = <String>{};
    final idsWithFields = <String>{};
    for (final key in keys) {
      final sep = key.indexOf(_sep);
      if (sep < 0) {
        aliveIds.add(key);
      } else {
        idsWithFields.add(key.substring(0, sep));
      }
    }
    return aliveIds.intersection(idsWithFields).length;
  }

  /// Returns the document identified by [documentId], or `null` if absent or
  /// deleted.
  ///
  /// A document exists only while its existence register is live; field records
  /// that linger after a delete are ignored. Awaits the initial storage load
  /// before returning.
  Future<T?> get(String documentId) async {
    await _ready;
    final exists = await _engine.value(_name, documentId);
    if (exists == null) return null;
    final fields = await _fieldsForDoc(documentId);
    if (fields.isEmpty) return null;
    return _codec.fromMap(_merge.unflatten(_rows(fields)));
  }

  /// All live (non-deleted) documents in unspecified order.
  ///
  /// When [limit] and/or [offset] are provided, **only the requested page is
  /// decoded** — decoding (the expensive step) scales with the page size, not
  /// the collection size. The collection's stored keys are still scanned once
  /// to enumerate documents, so that part stays O(collection) with the default
  /// in-memory engine. Offset is the number of documents to skip before
  /// returning results; limit is the maximum number of documents to return.
  /// Awaits the initial storage load before returning.
  Future<List<T>> all({int? limit, int? offset}) async {
    await _ready;
    final (:aliveIds, :grouped) = await _scan();

    final start = offset ?? 0;
    if (start >= aliveIds.length) return [];
    final ids = aliveIds.toList();
    final end = limit != null
        ? (start + limit < ids.length ? start + limit : ids.length)
        : ids.length;

    return [
      for (final id in ids.sublist(start, end))
        if (grouped[id] case final fields?)
          _codec.fromMap(_merge.unflatten(_rows(fields))),
    ];
  }

  /// All live documents that satisfy [test].
  ///
  /// [test] runs against decoded documents, so this always scans and decodes up
  /// to the point it stops: when [limit] is provided, decoding stops once
  /// [limit] matching documents have been found (after skipping [offset]
  /// matches). For a match the engine can evaluate — equality, comparison, set
  /// membership on stored fields — prefer [query], which runs in the engine and
  /// decodes only matching documents. Awaits the initial storage load before
  /// returning.
  Future<Iterable<T>> where(bool Function(T) test,
      {int? limit, int? offset}) async {
    await _ready;
    final (:aliveIds, :grouped) = await _scan();
    final result = <T>[];
    var matched = 0;
    var skipped = 0;
    final off = offset ?? 0;
    for (final id in aliveIds) {
      if (limit != null && matched >= limit) break;
      if (grouped[id] case final fields?) {
        final doc = _codec.fromMap(_merge.unflatten(_rows(fields)));
        if (test(doc)) {
          if (skipped < off) {
            skipped++;
          } else {
            matched++;
            result.add(doc);
          }
        }
      }
    }
    return result;
  }

  /// Starts a typed query over this collection.
  ///
  /// Chain [CollectionQuery.where], [CollectionQuery.orderBy],
  /// [CollectionQuery.limit], and [CollectionQuery.startAfter], then execute
  /// with [CollectionQuery.get] or [CollectionQuery.page]. The query runs in
  /// the storage engine (as SQL on the disk-backed engine, using the indexes
  /// declared via `indexedFields`) and decodes only the matching documents.
  ///
  /// Requires a merge strategy that produces per-field records; a query on a
  /// collection using [ObjectMergeStrategy] throws [ArgumentError].
  CollectionQuery<T> query() =>
      CollectionQuery._(this, const [], null, false, null, null);

  /// Persists [value], using [Codec.idOf] as the document key.
  ///
  /// The document is flattened into CRDT records by the collection's
  /// [MergeStrategy]; fields present on a previous version but absent now are
  /// tombstoned. The document's existence register is (re)marked live so that a
  /// concurrent delete on another node is reconciled last-write-wins. Awaits the
  /// initial storage load before writing.
  ///
  /// Fields the strategy types as [OrSet] hold a list; a put adds the elements
  /// that joined the list and removes the ones that left it, so concurrent
  /// edits on other devices are preserved. Fields typed as [PnCounter] hold a
  /// number that can only change through [increment]: the first put seeds the
  /// counter with the document's starting number, and a later put whose number
  /// differs from the counter's current value throws [ArgumentError].
  Future<void> put(T value) async {
    await _ready;
    await _serialize(() async {
      final id = _codec.idOf(value);
      final specs = _merge.fields(_codec.toMap(value)).toList();
      final prefix = '$id$_sep';
      final current = await _fieldsForDoc(id);
      final livePaths = {for (final s in specs) s.path};

      // Mark the document alive. Refreshing this on every write means an edit
      // competes with a concurrent delete on a single register (latest wins).
      await _engine.put(_name, id, true);

      for (final spec in specs) {
        // Only write fields whose value actually changed. Rewriting an unchanged
        // field would stamp it with a fresher HLC and clobber a concurrent edit
        // to that field made on another node.
        if (current.containsKey(spec.path) &&
            jsonEncode(current[spec.path]) == jsonEncode(spec.value)) {
          continue;
        }
        await _engine.put(_name, '$prefix${spec.path}', spec.value,
            crdtType: spec.type);
      }
      // Tombstone fields that no longer exist on the document (e.g. a key removed
      // from a map under shallow/deep merge). The schema of a fixed type rarely
      // changes, but custom strategies may vary the field set.
      for (final path in current.keys) {
        if (!livePaths.contains(path)) {
          await _engine.put(_name, '$prefix$path', null, isDeleted: true);
        }
      }
    });
    _onLocalChange?.call();
  }

  /// Adds [by] (which may be negative) to the [PnCounter] field at [fieldPath]
  /// of the document identified by [documentId].
  ///
  /// This is the only way to change a counter's value. Each device accumulates
  /// its own deltas, so concurrent increments on different devices all count:
  /// after convergence the counter is the sum of every device's contributions.
  ///
  /// The document must exist (throws [StateError] otherwise); its existence
  /// register is refreshed like [put] does, so an increment competes with a
  /// concurrent delete last-write-wins. The field must be typed [PnCounter] by
  /// the collection's [MergeStrategy] — incrementing a field that holds
  /// anything else throws [ArgumentError]. Awaits the initial storage load
  /// before writing.
  Future<void> increment(String documentId, String fieldPath,
      {num by = 1}) async {
    await _ready;
    await _serialize(() async {
      if (await _engine.value(_name, documentId) == null) {
        throw StateError(
          'Cannot increment "$fieldPath": no document "$documentId" in '
          '"$_name".',
        );
      }
      await _engine.put(_name, documentId, true);
      await _engine.increment(_name, '$documentId$_sep$fieldPath', by);
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
    });
    _onLocalChange?.call();
  }

  /// Returns a stream that emits the current document list once the initial
  /// storage load completes, then on every subsequent change.
  ///
  /// Every emission is the full collection: **O(collection) decoded documents
  /// per change**, on every local put and every synced remote change. For a
  /// screen that shows a filtered or paginated slice, prefer
  /// `query()...watch()` ([CollectionQuery.watch]), whose cost per change is
  /// bounded by the page.
  ///
  /// The stream completes (done, not error) when the database is closed via
  /// [dispose], [Database.close], or [Database.leave].
  Stream<List<T>> watch() => _watchStream((controller) async {
        final snapshot = await all();
        if (!controller.isClosed) controller.add(snapshot);
      });

  /// The shared plumbing under [watch] and [CollectionQuery.watch]: a
  /// controller whose [refresh] runs once after the initial load and then on
  /// every engine change event, and which [compact] can re-point at a
  /// replacement engine.
  Stream<List<T>> _watchStream(
      Future<void> Function(StreamController<List<T>>) refresh) {
    // `_engine.watch` is a broadcast stream that drops events while it has no
    // listener. The engine subscription waits for [_ready] so it binds the real
    // engine (which [_ready] may build asynchronously); the first snapshot is
    // emitted immediately after, so no change is missed.
    late final StreamController<List<T>> controller;
    StreamSubscription<void>? sub;
    Future<void> boundRefresh() => refresh(controller);
    controller = StreamController<List<T>>(
      onListen: () {
        _ready.then((_) {
          sub = _engine.watch(_name).listen((_) => boundRefresh());
          _watcherSubs[controller] = sub;
          _watcherRefresh[controller] = boundRefresh;
          boundRefresh();
        });
      },
      onCancel: () async {
        await sub?.cancel();
        _watcherSubs.remove(controller);
        _watcherRefresh.remove(controller);
        _watchers.remove(controller);
      },
      onPause: () => sub?.pause(),
      onResume: () => sub?.resume(),
    );
    _watchers.add(controller);
    return controller.stream;
  }

  /// Re-encrypts the backing engine at rest under [newKey] (a no-op for the
  /// in-memory engine). Called by [Database] when the group key rotates. Awaits
  /// the initial load so the engine exists first.
  Future<void> rekeyEngine(List<int> newKey) async {
    await _ready;
    await _engine.rekey(newKey);
  }

  /// Closes any open [watch] streams and releases resources. Called by
  /// [Database.close] and [Database.leave]. Safe to call more than once.
  Future<void> dispose() async {
    for (final c in _watchers.toList()) {
      await c.close();
    }
    _watchers.clear();
    _watcherSubs.clear();
    _watcherRefresh.clear();
    await _engine.close();
  }

  /// Permanently removes tombstoned records (deleted documents and removed
  /// fields) whose HLC wall-clock is older than [horizon]. Returns the number
  /// of records physically reclaimed.
  ///
  /// ## Resurrection caveat
  ///
  /// A peer that was offline for longer than [horizon] and never observed the
  /// delete may, on reconnection, resurrect the supposedly deleted data. This
  /// is inherent to CRDT convergence — once a tombstone is physically removed
  /// there is no record of the deletion to re-sync. Choose a horizon that
  /// comfortably exceeds the longest time any peer is expected to stay offline.
  ///
  /// ## Idempotent
  ///
  /// Calling [compact] repeatedly with the same horizon is safe: records
  /// already removed are simply not present and the reclaimed count is 0.
  ///
  /// ## Watchers
  ///
  /// Existing [watch] subscriptions survive [compact]: the engine is rebuilt
  /// under the hood and every active watcher is re-pointed at the new engine.
  /// A fresh snapshot is emitted to all watchers after compaction.
  Future<int> compact({required Duration horizon}) async {
    await _ready;
    var reclaimed = 0;
    await _serialize(() async {
      if (_engine.isPersistent) {
        reclaimed = await _engine.compact(_name, horizon: horizon);
        if (reclaimed > 0) {
          // Not awaited: a query watcher's refresh samples through
          // [_serialize], and compact is the serialized action right now —
          // awaiting it here would deadlock the chain on itself.
          for (final refresh in _watcherRefresh.values.toList()) {
            unawaited(refresh());
          }
        }
        return;
      }

      final cutoff = DateTime.now().subtract(horizon);
      final cs = await _engine.changeset(_name);
      final allRows = cs[_name] ?? const [];
      if (allRows.isEmpty) return;

      // Phase 1 — identify tombstoned existence registers beyond the horizon.
      final deadDocs = <String>{};
      for (final r in allRows) {
        final key = r['key'] as String;
        final sep = key.indexOf(_sep);
        if (sep < 0 && (r['is_deleted'] as bool)) {
          final hlc = r['hlc'] as Hlc;
          if (hlc.dateTime.isBefore(cutoff)) {
            deadDocs.add(key);
            reclaimed++;
          }
        }
      }

      // Phase 2 — keep only records not belonging to dead or beyond-horizon
      // tombstones.
      final survivors = <Map<String, Object?>>[];
      for (final r in allRows) {
        final key = r['key'] as String;
        final sep = key.indexOf(_sep);
        if (sep >= 0) {
          final docId = key.substring(0, sep);
          if (deadDocs.contains(docId)) {
            // Field of a deleted doc whose existence tombstone was compacted.
            reclaimed++;
            continue;
          }
          if (r['is_deleted'] as bool) {
            final hlc = r['hlc'] as Hlc;
            if (hlc.dateTime.isBefore(cutoff)) {
              // Field tombstone older than the horizon.
              reclaimed++;
              continue;
            }
          }
        } else if (deadDocs.contains(key)) {
          // Existence register already marked as dead in phase 1 — omit.
          continue;
        }
        survivors.add(r);
      }

      if (reclaimed == 0) return;

      // Rebuild engine with the survivor set.
      final newEngine = TypedCrdtTable(MapCrdtTable(_name));
      if (survivors.isNotEmpty) {
        await newEngine.merge({_name: survivors});
      }

      // Re-point watchers at the replacement engine.
      for (final entry in _watcherSubs.entries) {
        final controller = entry.key;
        await entry.value?.cancel();
        final refresh = _watcherRefresh[controller];
        _watcherSubs[controller] =
            newEngine.watch(_name).listen((_) => refresh?.call());
      }

      // Swap engine.
      _engine = newEngine;

      // Emit fresh snapshots so watchers see the post-compact state. Not
      // awaited: a query watcher's refresh samples through [_serialize], and
      // compact is the serialized action right now.
      for (final refresh in _watcherRefresh.values.toList()) {
        unawaited(refresh());
      }
    });
    return reclaimed;
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
  ///
  /// Reads through the write chain: a put writes a document's field records
  /// one at a time, and an unserialised read between two of them would ship a
  /// document to a peer with only some of its fields.
  Future<CrdtChangeset> getChangeset(
      {String? sinceHlc, String? untilHlc}) async {
    late CrdtChangeset result;
    await _serialize(
      () async => result = await _engine.changeset(
        _name,
        sinceHlc: sinceHlc,
        untilHlc: untilHlc,
      ),
    );
    return result;
  }

  /// Summarises this collection's records in the half-open HLC range
  /// `(fromHlc, toHlc]` for range reconciliation. Reads through the write
  /// chain, so a digest never spans a half-written document.
  Future<RangeDigest> rangeDigest({String? fromHlc, String? toHlc}) async {
    late RangeDigest result;
    await _serialize(
      () async => result =
          await _engine.rangeDigest(_name, fromHlc: fromHlc, toHlc: toHlc),
    );
    return result;
  }

  /// Merges a [CrdtChangeset] received from a peer and persists the result.
  /// Does NOT trigger [onLocalChange] — remote changes must not be re-broadcast.
  Future<void> mergeChangeset(CrdtChangeset changeset) async {
    await _ready;
    await _serialize(() async {
      final conflicted = <String>{};
      for (final records in changeset.values) {
        for (final record in records) {
          final key = record['key'] as String;
          final sep = key.indexOf(_sep);
          final docId = sep < 0 ? key : key.substring(0, sep);
          if (_onRemoteConflict == null) continue;
          // A conflict needs the document to exist locally AND the incoming
          // record to be new information. The sync protocol legitimately
          // redelivers records (a push broadcast and a state-driven delta can
          // overlap), so a record no newer than the one stored is not an edit.
          if (await _engine.value(_name, docId) == null) continue;
          final stored = await _engine.recordHlc(_name, key);
          final incoming = record['hlc'];
          final incomingHlc =
              incoming is Hlc ? incoming : Hlc.parse(incoming as String);
          if (stored != null && Hlc.parse(stored) >= incomingHlc) continue;
          conflicted.add(docId);
        }
      }
      await _engine.merge(changeset);
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
  Future<({Set<String> aliveIds, Map<String, Map<String, Object?>> grouped})>
      _scan() async {
    final map = await _engine.liveFields(_name, '');
    final aliveIds = <String>{};
    final grouped = <String, Map<String, Object?>>{};
    for (final entry in map.entries) {
      final sep = entry.key.indexOf(_sep);
      if (sep < 0) {
        aliveIds.add(entry.key);
        continue;
      }
      final id = entry.key.substring(0, sep);
      final path = entry.key.substring(sep + 1);
      (grouped[id] ??= <String, Object?>{})[path] = entry.value;
    }
    return (aliveIds: aliveIds, grouped: grouped);
  }

  // ---------------------------------------------------------------------------
  // Field helpers

  /// Adapts a flat path → value map (as the engine and index use internally)
  /// to the [FieldValue] rows [MergeStrategy.unflatten] expects.
  static Iterable<FieldValue> _rows(Map<String, Object?> fields) =>
      [for (final e in fields.entries) (path: e.key, value: e.value)];

  /// Returns the live field entries (field-path → value) for [documentId],
  /// scoped to a single document, as [MergeStrategy.unflatten] expects.
  ///
  /// Uses the engine's [CrdtTable.docFields] so an indexed engine serves the
  /// document without scanning the full table.
  Future<Map<String, Object?>> _fieldsForDoc(String documentId) async =>
      (await _engine.docFields(_name, [documentId]))[documentId] ?? {};

  // ---------------------------------------------------------------------------
  // Factory — used by Database

  /// Creates a collection named [name], starting an asynchronous load in the
  /// background.
  ///
  /// [merge] controls how documents are decomposed into CRDT records and
  /// therefore how concurrent edits merge; it defaults to whole-document
  /// last-write-wins via [ObjectMergeStrategy].
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
  /// [indexedFields] declares field paths the engine should index for
  /// [query] equality lookups. The values are the flattened field paths
  /// produced by [merge] (top-level keys for [ShallowMergeStrategy], dotted
  /// paths for [DeepMergeStrategy], etc.). Index creation is idempotent and
  /// happens during the initial load; an engine without secondary indexes
  /// answers queries by scanning instead. Defaults to no indexes.
  ///
  /// [engine] builds the backing [CrdtTable]. It runs once, during the initial
  /// load, and may be async (a disk-backed engine opens a file). When omitted,
  /// the collection uses an in-memory [MapCrdtTable] and is not persisted.
  static Collection<T> create<T>(
    String name,
    Codec<T> codec, {
    MergeStrategy merge = const ObjectMergeStrategy(),
    FutureOr<CrdtTable> Function()? engine,
    List<String> indexedFields = const [],
    void Function()? onLocalChange,
    void Function(String documentId)? onRemoteConflict,
  }) =>
      Collection._(
        name,
        codec,
        merge: merge,
        engine: engine,
        indexedFields: indexedFields,
        onLocalChange: onLocalChange,
        onRemoteConflict: onRemoteConflict,
      );
}
