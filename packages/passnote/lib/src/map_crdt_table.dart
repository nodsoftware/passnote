import 'package:crdt/crdt.dart';
import 'package:crdt/map_crdt.dart';

import 'crdt/clock.dart';
import 'crdt/crdt_type.dart';
import 'ports/crdt_table.dart';
import 'ports/query.dart';
import 'query/scan_query.dart';

/// In-memory [CrdtTable] backed by the `crdt` package's `MapCrdt`.
///
/// Keeps the whole dataset in RAM and is **not persisted**. It is meant for
/// tests and small, ephemeral collections. Select it explicitly with
/// `Passnote.builder(...).engine(MapCrdtTable.new)`; the default engine is
/// disk-backed (`SqliteCrdtTable`).
class MapCrdtTable implements CrdtTable {
  /// Creates an empty in-memory table named [table].
  MapCrdtTable(String table) : _crdt = _ClockedMapCrdt([table]);

  final _ClockedMapCrdt _crdt;

  @override
  String get nodeId => _crdt.nodeId;

  @override
  bool get isPersistent => false;

  @override
  Future<void> init() async {}

  @override
  Future<int> compact(String table, {required Duration horizon}) async =>
      throw UnsupportedError(
        '$runtimeType does not support in-place compaction; '
        'use Collection.compact for a rebuild-based approach.',
      );

  /// [crdtType] is ignored: the `crdt` package's `MapCrdt` record shape has no
  /// slot for it. Typed values are self-describing (they carry their own type
  /// tag), so the `TypedCrdtTable` layer above still merges them correctly; a
  /// persistent engine records the type as well.
  @override
  Future<void> put(
    String table,
    String key,
    Object? value, {
    bool isDeleted = false,
    CrdtType crdtType = const LwwRegister(),
  }) async {
    try {
      await _crdt.put(table, key, value, isDeleted);
    } on OverflowException {
      // Same rule as the disk engine: move to the next microsecond rather
      // than fail the write (see [incrementClock]).
      _crdt.skipPastOverflow();
      await _crdt.put(table, key, value, isDeleted);
    }
  }

  @override
  Future<Object?> value(String table, String key) =>
      Future.value(_crdt.get(table, key));

  @override
  Future<String?> recordHlc(String table, String key) =>
      Future.value(_crdt.getRecord(table, key)?.hlc.toString());

  @override
  Future<Map<String, Object?>> liveFields(String table, String prefix) {
    final map = _crdt.getMap(table);
    if (prefix.isEmpty) return Future.value(Map.of(map));
    return Future.value({
      for (final e in map.entries)
        if (e.key.startsWith(prefix)) e.key: e.value,
    });
  }

  /// One scan of the table, grouping only the requested documents.
  @override
  Future<Map<String, Map<String, Object?>>> docFields(
      String table, Iterable<String> docIds) {
    final wanted = docIds.toSet();
    final out = <String, Map<String, Object?>>{};
    for (final e in _crdt.getMap(table).entries) {
      final sep = e.key.indexOf('\x1F');
      if (sep < 0) continue;
      final id = e.key.substring(0, sep);
      if (!wanted.contains(id)) continue;
      (out[id] ??= {})[e.key.substring(sep + 1)] = e.value;
    }
    return Future.value(out);
  }

  @override
  Set<String> liveKeys(String table, String prefix) {
    final map = _crdt.getMap(table);
    if (prefix.isEmpty) {
      return map.keys.where((k) => _crdt.get(table, k) != null).toSet();
    }
    return {
      for (final e in map.entries)
        if (e.key.startsWith(prefix) && _crdt.get(table, e.key) != null) e.key,
    };
  }

  /// Answers by a full scan: this engine has no indexes. The scan mirrors the
  /// SQLite engine's comparison semantics, so pages line up across engines.
  @override
  Future<List<QueryRow>> queryDocIds(String table, QuerySpec spec) =>
      Future.value(evaluateQueryByScan(
        liveRows: _crdt.getMap(table),
        spec: spec,
        separator: '\x1F',
      ));

  /// A no-op: this engine has no indexes and answers queries by scanning.
  @override
  Future<void> ensureQueryIndex(String table, String fieldPath) async {}

  @override
  Future<CrdtChangeset> changeset(
    String table, {
    String? sinceHlc,
    String? untilHlc,
  }) {
    final changeset = _crdt.getChangeset(
      onlyTables: [table],
      modifiedAfter:
          (sinceHlc == null || sinceHlc.isEmpty) ? null : Hlc.parse(sinceHlc),
    );
    if (untilHlc == null) return Future.value(changeset);
    final until = Hlc.parse(untilHlc);
    return Future.value({
      for (final entry in changeset.entries)
        entry.key: [
          for (final record in entry.value)
            if ((record['hlc'] as Hlc) <= until) record,
        ],
    });
  }

  /// One pass over the full changeset — this engine is in-memory anyway.
  @override
  Future<RangeDigest> rangeDigest(
    String table, {
    String? fromHlc,
    String? toHlc,
  }) {
    final from = fromHlc == null ? null : Hlc.parse(fromHlc);
    final to = toHlc == null ? null : Hlc.parse(toHlc);
    final builder = RangeDigestBuilder();
    for (final record in _crdt.getChangeset(onlyTables: [table])[table] ??
        const <Map<String, Object?>>[]) {
      final hlc = record['hlc'] as Hlc;
      if (from != null && hlc <= from) continue;
      if (to != null && hlc > to) continue;
      builder.add(record['key'] as String, hlc);
    }
    return Future.value(builder.build());
  }

  @override
  String maxHlc(String table) {
    final changeset = _crdt.getChangeset(onlyTables: [table]);
    if (changeset.isEmpty) return '';
    return _crdt.getLastModified().toString();
  }

  @override
  Future<void> merge(CrdtChangeset changeset) => _crdt.merge(changeset);

  @override
  Stream<void> watch(String table) => _crdt.watch(table).map<void>((_) {});

  @override
  Future<void> close() async {}

  @override
  Future<void> rekey(List<int> newKey) async {}

  @override
  Stream<CrdtRecovery> get recoveries => const Stream<CrdtRecovery>.empty();
}

/// [MapCrdt] with the disk engine's merge rule: a received record that is too
/// far ahead of the wall clock, or that carries this node's id, does not move
/// the clock but is still merged, instead of failing the whole changeset.
/// The sync layer already refuses records beyond its own drift bound.
class _ClockedMapCrdt extends MapCrdt {
  _ClockedMapCrdt(super.tables);

  /// Moves the clock past a counter that has no room left.
  void skipPastOverflow() => canonicalTime = incrementClock(canonicalTime);

  @override
  Hlc validateChangeset(CrdtChangeset changeset) {
    var hlc = canonicalTime;
    for (final records in changeset.values) {
      for (final record in records) {
        try {
          hlc = hlc.merge(record['hlc'] as Hlc);
        } on ClockDriftException {
          // Kept, but it does not move the clock.
        } on DuplicateNodeException {
          // Kept, but it does not move the clock.
        }
      }
    }
    return hlc;
  }
}
