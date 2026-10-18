import 'package:passnote/passnote.dart';
import 'package:passnote/engine.dart';
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
}
