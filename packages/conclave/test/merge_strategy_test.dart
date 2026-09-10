import 'dart:convert';
import 'dart:io';

import 'package:conclave/conclave.dart';
import 'package:conclave/engine.dart';
import 'package:crdt/crdt.dart' show Hlc;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  group('SchemaMergeStrategy', () {
    const schema = SchemaMergeStrategy({
      'qty': PnCounter(),
      'tags': OrSet(),
    });

    test('assigns the declared type per field and defaults the rest to LWW',
        () {
      final byPath = {
        for (final f in schema.fields({
          'qty': 2,
          'tags': ['a', 'b'],
          'title': 'milk',
        }))
          f.path: f.type,
      };

      expect(byPath['qty'], equals(const PnCounter()));
      expect(byPath['tags'], equals(const OrSet()));
      expect(byPath['title'], equals(const LwwRegister()));
    });

    test('keeps one record per top-level field', () {
      final paths = schema
          .fields({'qty': 1, 'tags': <String>[], 'title': 't'})
          .map((f) => f.path)
          .toSet();

      expect(paths, equals({'qty', 'tags', 'title'}));
    });

    test('reconstructs the document from its field rows', () {
      final doc = {
        'qty': 3,
        'tags': ['x', 'y'],
        'title': 'eggs',
      };

      final rebuilt = schema.unflatten(
        [for (final f in schema.fields(doc)) (path: f.path, value: f.value)],
      );

      expect(rebuilt, equals(doc));
    });

    test('an all-unknown schema is pure last-write-wins', () {
      const s = SchemaMergeStrategy({});
      final doc = {'a': 1, 'b': 2};

      expect(
        s.fields(doc).map((f) => f.type),
        everyElement(equals(const LwwRegister())),
      );
      expect(
        s.unflatten(
            [for (final f in s.fields(doc)) (path: f.path, value: f.value)]),
        equals(doc),
      );
    });
  });

  group('crdt_type column', () {
    test('is populated from the write and defaults to lww', () async {
      final table = await SqliteCrdtTable.open(':memory:');
      addTearDown(table.close);

      await table.put('c', 'k1', 1, crdtType: const PnCounter());
      await table.put('c', 'k2', <String>['a'], crdtType: const OrSet());
      await table.put('c', 'k3', 'plain'); // default

      final rows = (await table.changeset('c'))['c']!;
      final typeByKey = {
        for (final r in rows) r['key'] as String: r['crdt_type'] as String,
      };

      expect(typeByKey['k1'], equals('pn_counter'));
      expect(typeByKey['k2'], equals('or_set'));
      expect(typeByKey['k3'], equals('lww'));
    });

    test('a document written through a Collection carries its schema types',
        () async {
      final coll = Collection.create<Map<String, dynamic>>(
        'items',
        JsonCodec<Map<String, dynamic>>(
          toMap: (m) => m,
          fromMap: (m) => m,
          idOf: (m) => m['id'] as String,
        ),
        merge: const SchemaMergeStrategy({'qty': PnCounter()}),
        engine: () => SqliteCrdtTable.open(':memory:'),
      );
      addTearDown(coll.dispose);

      await coll.put({'id': 'i1', 'qty': 5, 'name': 'flour'});

      final rebuilt = await coll.get('i1');
      expect(rebuilt, equals({'id': 'i1', 'qty': 5, 'name': 'flour'}));
    });
  });

  group('migration', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('conclave_migrate'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('a v1 database gains crdt_type = lww on open', () async {
      final path = '${tmp.path}/legacy.sqlite';
      final hlc = Hlc.now('legacynode').toString();

      // Build a database in the pre-per-field-types shape: no crdt_type column,
      // user_version = 1, one record.
      final raw = sqlite3.open(path);
      raw.execute('''
        CREATE TABLE crdt_records (
          collection TEXT NOT NULL,
          key        TEXT NOT NULL,
          value      TEXT NOT NULL,
          is_deleted INTEGER NOT NULL DEFAULT 0,
          hlc        TEXT NOT NULL,
          hlc_key    TEXT NOT NULL,
          PRIMARY KEY (collection, key)
        )
      ''');
      raw.execute(
        'CREATE INDEX idx_crdt_hlc ON crdt_records (collection, hlc_key)',
      );
      raw.execute(
          'CREATE TABLE crdt_meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)');
      raw.execute(
        'INSERT INTO crdt_records '
        '(collection, key, value, is_deleted, hlc, hlc_key) '
        'VALUES (?, ?, ?, 0, ?, ?)',
        ['c', 'old', jsonEncode('kept'), hlc, hlc],
      );
      raw.execute('PRAGMA user_version = 1');
      raw.dispose();

      final table = await SqliteCrdtTable.open(path);
      addTearDown(table.close);

      final rows = (await table.changeset('c'))['c']!;
      expect(rows.single['key'], equals('old'));
      expect(rows.single['value'], equals('kept'));
      expect(rows.single['crdt_type'], equals('lww'));

      await table.close();
      final check = sqlite3.open(path);
      final version =
          check.select('PRAGMA user_version').first['user_version'] as int;
      check.dispose();
      expect(version, equals(3));
    });
  });
}
