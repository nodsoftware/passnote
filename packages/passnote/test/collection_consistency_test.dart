// A put writes a document as several records. A read must never see some of
// them and not the others, and a failure part-way through must not leave the
// document half-written on disk.
@TestOn('vm')
library;

import 'dart:io';

import 'package:passnote/engine.dart';
import 'package:passnote/passnote.dart';
import 'package:passnote/src/collection.dart' as internal;
import 'package:test/test.dart';

final _codec = JsonCodec<Map<String, dynamic>>(
  toMap: (m) => m,
  fromMap: (m) => m,
  idOf: (m) => m['id'] as String,
);

Map<String, dynamic> _note(String v) =>
    {'id': 'n', 'title': v, 'body': v, 'tags': v};

void main() {
  test('a read during a put sees the document before or after it',
      () async {
    final notes = internal.Collection.create<Map<String, dynamic>>(
      'notes',
      _codec,
      merge: const ShallowMergeStrategy(),
    );
    addTearDown(notes.dispose);
    await notes.ready;
    await notes.put(_note('old'));

    final seen = <Map<String, dynamic>?>[];
    var writing = true;
    Future<void> readWhileWriting(
        Future<Map<String, dynamic>?> Function() read) async {
      while (writing) {
        seen.add(await read());
      }
    }

    final readers = [
      readWhileWriting(() => notes.get('n')),
      readWhileWriting(() async => (await notes.all()).single),
    ];
    for (var i = 0; i < 5; i++) {
      await notes.put(_note('new-$i'));
    }
    writing = false;
    await Future.wait(readers);
    expect(seen, isNotEmpty);

    for (final doc in seen) {
      expect({doc!['title'], doc['body'], doc['tags']}, hasLength(1),
          reason: 'a read saw a half-written document: $doc');
    }
  });

  group('SqliteCrdtTable.atomically', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('passnote_atomic'));
    tearDown(() => tmp.deleteSync(recursive: true));
    final key = List<int>.filled(32, 9);

    test('keeps every write when the block completes', () async {
      final path = '${tmp.path}/t.sqlite';
      var table = await SqliteCrdtTable.open(path, encryptionKey: key);
      await table.atomically(() async {
        await table.put('items', 'a', 1);
        await table.put('items', 'b', 2);
      });
      await table.close();

      table = await SqliteCrdtTable.open(path, encryptionKey: key);
      addTearDown(table.close);
      expect(await table.value('items', 'a'), 1);
      expect(await table.value('items', 'b'), 2);
    });

    test('keeps none of them when the block fails', () async {
      final path = '${tmp.path}/t.sqlite';
      var table = await SqliteCrdtTable.open(path, encryptionKey: key);
      await table.put('items', 'a', 'before');
      await expectLater(
        table.atomically(() async {
          await table.put('items', 'a', 'during');
          await table.put('items', 'b', 'during');
          throw StateError('interrupted');
        }),
        throwsStateError,
      );
      // Still usable, and later writes are not inside a dangling transaction.
      await table.put('items', 'c', 'after');
      await table.close();

      table = await SqliteCrdtTable.open(path, encryptionKey: key);
      addTearDown(table.close);
      expect(await table.value('items', 'a'), 'before');
      expect(await table.value('items', 'b'), isNull);
      expect(await table.value('items', 'c'), 'after');
    });
  });
}
