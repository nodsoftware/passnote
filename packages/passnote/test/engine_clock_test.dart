// The engines' local clock: what it resumes from after a reopen, and how it
// advances after adopting a peer's record. Each case is a defect found by the
// Rust port of Passnote (F-1, F-2, F-7, F-11).
@TestOn('vm')
library;

import 'dart:io';

import 'package:crdt/crdt.dart' show Hlc;
import 'package:passnote/engine.dart';
import 'package:test/test.dart';

final _key = List<int>.filled(32, 3);

Map<String, Object?> _record(String key, Hlc hlc) => {
      'key': key,
      'value': 'from the peer',
      'is_deleted': false,
      'hlc': hlc,
    };

Hlc _ahead(Duration by, {int counter = 0}) =>
    Hlc(DateTime.now().toUtc().add(by), counter, 'peernode');

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('passnote_clock'));
  tearDown(() => tmp.deleteSync(recursive: true));
  String path() => '${tmp.path}/t.sqlite';

  group('SqliteCrdtTable after a reopen', () {
    test('stamps local writes with its own node id (F-1)', () async {
      var table = await SqliteCrdtTable.open(path(), encryptionKey: _key);
      final own = table.nodeId;
      await table.merge({
        'items': [_record('peer-doc', _ahead(const Duration(seconds: 5)))],
      });
      await table.close();

      table = await SqliteCrdtTable.open(path(), encryptionKey: _key);
      addTearDown(table.close);
      await table.put('items', 'mine', 'local');
      final stamped = Hlc.parse((await table.recordHlc('items', 'mine'))!);
      expect(stamped.nodeId, own,
          reason: 'a local write carried the peer\'s node id');
    });

    test('keeps writing while a stored record is minutes ahead (F-2)',
        () async {
      var table = await SqliteCrdtTable.open(path(), encryptionKey: _key);
      await table.merge({
        'items': [_record('peer-doc', _ahead(const Duration(minutes: 5)))],
      });
      await table.put('items', 'before', 'ok');
      await table.close();

      table = await SqliteCrdtTable.open(path(), encryptionKey: _key);
      addTearDown(table.close);
      await table.put('items', 'after', 'still ok');
      expect(await table.value('items', 'after'), 'still ok');
    });
  });

  group('a received record at the counter limit (F-7)', () {
    Future<void> writesKeepWorking(CrdtTable table) async {
      await table.init();
      await table.merge({
        'items': [
          _record(
              'peer-doc', _ahead(const Duration(seconds: 30), counter: 0xFFFF)),
        ],
      });
      Hlc? previous;
      for (var i = 0; i < 3; i++) {
        await table.put('items', 'mine-$i', i);
        final hlc = Hlc.parse((await table.recordHlc('items', 'mine-$i'))!);
        if (previous != null) expect(hlc > previous, isTrue);
        previous = hlc;
      }
    }

    test('does not block local writes on disk', () async {
      final table = SqliteCrdtTable(path(), encryptionKey: _key);
      addTearDown(table.close);
      await writesKeepWorking(table);
    });

    test('does not block local writes in memory', () async {
      await writesKeepWorking(MapCrdtTable('items'));
    });
  });

  test('the in-memory engine merges a record minutes ahead, like disk (F-11)',
      () async {
    final table = MapCrdtTable('items');
    await table.merge({
      'items': [
        _record('far', _ahead(const Duration(minutes: 5))),
        _record('near', _ahead(const Duration(seconds: 1))),
      ],
    });
    expect(await table.value('items', 'far'), 'from the peer');
    expect(await table.value('items', 'near'), 'from the peer');
    // And the record that was too far ahead did not drag the clock along.
    await table.put('items', 'mine', 1);
  });
}
