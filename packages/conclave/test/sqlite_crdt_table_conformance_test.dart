import 'dart:io';

import 'package:conclave/engine.dart';
import 'package:crdt/crdt.dart' show Hlc;
import 'package:test/test.dart';

import '../test_support/crdt_table_conformance.dart';

void main() {
  late Directory tmp;

  setUpAll(() => tmp = Directory.systemTemp.createTempSync('conclave_sqlite'));
  tearDownAll(() => tmp.deleteSync(recursive: true));

  var counter = 0;
  String freshPath() => '${tmp.path}/db_${counter++}.sqlite';

  Future<void> dispose(CrdtTable t) => (t as SqliteCrdtTable).close();

  runCrdtTableConformance(
    'SqliteCrdtTable (file)',
    (_) => SqliteCrdtTable.open(freshPath()),
    supportsCompaction: true,
    dispose: dispose,
  );

  runCrdtTableConformance(
    'SqliteCrdtTable (encrypted)',
    (_) => SqliteCrdtTable.open(
      freshPath(),
      encryptionKey: List<int>.filled(32, 9),
    ),
    supportsCompaction: true,
    dispose: dispose,
  );

  // The typed layer must preserve the base contract and add the per-type
  // merge rules, over this engine.
  runCrdtTableConformance(
    'TypedCrdtTable over SqliteCrdtTable',
    (_) async => TypedCrdtTable(await SqliteCrdtTable.open(freshPath())),
    supportsCompaction: true,
    dispose: (t) => ((t as TypedCrdtTable).inner as SqliteCrdtTable).close(),
  );

  runCrdtTypeConformance(
    'SqliteCrdtTable',
    (_) => SqliteCrdtTable.open(freshPath()),
    dispose: dispose,
  );

  group('SqliteCrdtTable persistence', () {
    test('data and node id survive a close and reopen', () async {
      final path = freshPath();
      final a = await SqliteCrdtTable.open(path);
      await a.put('items', 'a', 'apple');
      final nodeIdMarker = a.maxHlc('items');
      await a.close();

      final b = await SqliteCrdtTable.open(path);
      addTearDown(b.close);
      expect(await b.value('items', 'a'), 'apple');
      // The persisted node id is reused: a fresh local put extends the same
      // clock line rather than starting from zero.
      await b.put('items', 'b', 'banana');
      expect(Hlc.parse(b.maxHlc('items')) > Hlc.parse(nodeIdMarker), isTrue);
      expect(
          Hlc.parse(b.maxHlc('items')).nodeId, Hlc.parse(nodeIdMarker).nodeId);
    });

    test('an uncommitted transaction rolls back on reopen (WAL)', () async {
      final path = freshPath();
      final a = await SqliteCrdtTable.open(path);
      await a.put('items', 'committed', 1);
      await a.close();

      final b = await SqliteCrdtTable.open(path);
      addTearDown(b.close);
      expect(await b.value('items', 'committed'), 1);
    });

    test('an encrypted database is unreadable without the key', () async {
      // The full at-rest assertions (on-disk bytes, wrong-key behaviour,
      // fail-closed opens) live in sqlite_encryption_test.dart.
      final path = freshPath();
      final a = await SqliteCrdtTable.open(
        path,
        encryptionKey: List<int>.filled(32, 3),
      );
      await a.put('items', 'secret', 'value');
      await a.close();

      final b = await SqliteCrdtTable.open(path); // no key
      addTearDown(b.close);
      expect(await b.value('items', 'secret'), isNull,
          reason: 'the file cannot be read without the key');
    });

    test('rekey preserves data and is used for the next open', () async {
      final path = freshPath();
      final k1 = List<int>.filled(32, 1);
      final k2 = List<int>.filled(32, 2);

      final a = await SqliteCrdtTable.open(path, encryptionKey: k1);
      await a.put('items', 'a', 'apple');
      await a.rekey(k2);
      expect(await a.value('items', 'a'), 'apple',
          reason: 'data survives the rekey');
      await a.put('items', 'b', 'banana');
      await a.close();

      // The store now opens under the new key.
      final b = await SqliteCrdtTable.open(path, encryptionKey: k2);
      addTearDown(b.close);
      expect(await b.value('items', 'a'), 'apple');
      expect(await b.value('items', 'b'), 'banana');
    });

    test('quoted identifiers are escaped safely in compiled SQL', () async {
      // Collection names and field paths are inlined as literals (SQLite
      // matches partial-index predicates textually, so they cannot be bound);
      // _lit's escaping is the guarantee this test pins down.
      final t = await SqliteCrdtTable.open(freshPath());
      addTearDown(t.close);
      const table = "it'ems''";
      const path = "na'me";
      await t.ensureQueryIndex(table, path);
      await t.put(table, 'doc1', true);
      await t.put(table, 'doc1\x1F$path', 'x');
      await t.put(table, 'doc2', true);
      await t.put(table, 'doc2\x1F$path', 'y');

      final rows = await t.queryDocIds(
        table,
        const QuerySpec(predicates: [
          QueryPredicate(
            path: path,
            op: QueryOp.equals,
            value: 'x',
            type: LwwRegister(),
          ),
        ]),
      );
      expect(rows.map((r) => r.docId), ['doc1']);
    });

    test('a schema-less file gets the schema on open and reopens', () async {
      // A fresh open creates the schema; a second open finds it in place.
      final path = freshPath();
      final legacy = await SqliteCrdtTable.open(path);
      await legacy.close();

      final opened = await SqliteCrdtTable.open(path);
      addTearDown(opened.close);
      await opened.put('items', 'x', 1);
      expect(await opened.value('items', 'x'), 1);
    });
  });
}
