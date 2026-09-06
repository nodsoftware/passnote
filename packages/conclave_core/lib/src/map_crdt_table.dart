import 'package:crdt/crdt.dart';
import 'package:crdt/map_crdt.dart';

import 'ports/crdt_table.dart';

/// [CrdtTable] adapter backed by [MapCrdt].
///
/// The default table used by [Collection]. Keeps the full dataset in memory,
/// which is fine for small collections and tests. For large or long-lived
/// datasets, wire in a disk-backed table via [Collection.create]'s `table`
/// parameter once a lazy adapter is available (see Task 03 Phase 2).
class MapCrdtTable implements CrdtTable {
  MapCrdtTable(String table) : _crdt = MapCrdt([table]);

  final MapCrdt _crdt;

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

  @override
  Future<void> put(
    String table,
    String key,
    Object? value, {
    bool isDeleted = false,
  }) =>
      _crdt.put(table, key, value, isDeleted);

  @override
  Future<Object?> value(String table, String key) =>
      Future.value(_crdt.get(table, key));

  @override
  Future<Map<String, Object?>> liveFields(String table, String prefix) {
    final map = _crdt.getMap(table);
    if (prefix.isEmpty) return Future.value(Map.of(map));
    return Future.value({
      for (final e in map.entries)
        if (e.key.startsWith(prefix)) e.key: e.value,
    });
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

  @override
  Future<CrdtChangeset> changeset(String table, {String? sinceHlc}) =>
      Future.value(_crdt.getChangeset(
        onlyTables: [table],
        modifiedAfter:
            (sinceHlc == null || sinceHlc.isEmpty) ? null : Hlc.parse(sinceHlc),
      ));

  @override
  String maxHlc(String table) {
    final cs = _crdt.getChangeset(onlyTables: [table]);
    if (cs.isEmpty) return '';
    return _crdt.getLastModified().toString();
  }

  @override
  Future<void> merge(CrdtChangeset changeset) => _crdt.merge(changeset);

  @override
  Stream<void> watch(String table) => _crdt.watch(table).map<void>((_) {});
}
