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
  Future<void> put(
    String table,
    String key,
    Object? value, {
    bool isDeleted = false,
  }) =>
      _crdt.put(table, key, value, isDeleted);

  @override
  Object? value(String table, String key) => _crdt.get(table, key);

  @override
  Map<String, Object?> liveFields(String table, String prefix) {
    final map = _crdt.getMap(table);
    if (prefix.isEmpty) return Map.of(map);
    return {
      for (final e in map.entries)
        if (e.key.startsWith(prefix)) e.key: e.value,
    };
  }

  @override
  CrdtChangeset changeset(String table, {String? sinceHlc}) =>
      _crdt.getChangeset(
        onlyTables: [table],
        modifiedAfter: (sinceHlc == null || sinceHlc.isEmpty)
            ? null
            : Hlc.parse(sinceHlc),
      );

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
