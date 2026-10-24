// Text outside the Basic Multilingual Plane (emoji, many CJK extensions) is
// one code point but two UTF-16 code units. The SQLite engine matched key
// prefixes by UTF-16 length (F-4), and the in-memory engine ordered text by
// UTF-16 code unit where SQLite orders by code point (F-10). Both found by
// the Rust port.
@TestOn('vm')
library;

import 'package:passnote/engine.dart';
import 'package:test/test.dart';

const _sep = '\x1F';

void main() {
  group('a document id outside the BMP (F-4)', () {
    test('finds its fields on disk', () async {
      final table = SqliteCrdtTable(':memory:', encryptionKey: const []);
      addTearDown(table.close);
      await table.init();
      await table.put('notes', '😀', true);
      await table.put('notes', '😀${_sep}title', 'smile');

      expect(await table.liveFields('notes', '😀$_sep'),
          {'😀${_sep}title': 'smile'});
      expect(table.liveKeys('notes', '😀$_sep'), {'😀${_sep}title'});
    });
  });

  test('both engines order text by code point (F-10)', () async {
    // U+FF5E sorts below U+1F600 by code point, above it by UTF-16 unit.
    const ids = ['\u{1F600}', '\u{FF5E}', 'a'];
    Future<List<String>> order(CrdtTable table) async {
      await table.init();
      for (final id in ids) {
        await table.put('notes', id, true);
        await table.put('notes', '$id${_sep}title', id);
      }
      final rows = await table.queryDocIds(
        'notes',
        const QuerySpec(predicates: [], orderByPath: 'title'),
      );
      return [for (final r in rows) r.docId];
    }

    final disk = SqliteCrdtTable(':memory:', encryptionKey: const []);
    addTearDown(disk.close);
    final expected = ['a', '\u{FF5E}', '\u{1F600}'];
    expect(await order(disk), expected);
    expect(await order(MapCrdtTable('notes')), expected);
  });
}
