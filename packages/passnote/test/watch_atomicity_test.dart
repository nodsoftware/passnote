// A watcher must never observe a document mid-write. `put` writes one record
// per field, so between the first record and the last the store holds a
// document whose codec cannot decode it.
import 'dart:async';
import 'dart:io';

import 'package:passnote/passnote.dart';
import 'package:passnote/engine.dart';
import 'package:test/test.dart';

class _Note {
  _Note(this.id, this.title, this.votes, this.tags);

  final String id;

  /// Required, with no default: decoding a half-written document throws.
  final String title;
  final num votes;
  final List<String> tags;

  static final codec = JsonCodec<_Note>(
    toMap: (n) =>
        {'id': n.id, 'title': n.title, 'votes': n.votes, 'tags': n.tags},
    fromMap: (m) => _Note(
      m['id'] as String,
      m['title'] as String,
      m['votes'] as num,
      (m['tags'] as List).cast<String>(),
    ),
    idOf: (n) => n.id,
  );
}

const _schema = SchemaMergeStrategy({'votes': PnCounter(), 'tags': OrSet()});

void main() {
  late Directory tmp;
  setUpAll(() => tmp = Directory.systemTemp.createTempSync('passnote_watch'));
  tearDownAll(() => tmp.deleteSync(recursive: true));
  var counter = 0;

  for (final (label, engine) in <(String, FutureOr<CrdtTable> Function())>[
    ('in-memory', () => MapCrdtTable('notes')),
    ('SQLite', () => SqliteCrdtTable('${tmp.path}/db_${counter++}.sqlite')),
  ]) {
    group(label, () {
      test('watch() never emits a half-written document', () async {
        final col = Collection.create<_Note>('notes', _Note.codec,
            merge: _schema, engine: engine);
        addTearDown(col.dispose);
        await col.ready;

        final errors = <Object>[];
        final seen = <List<_Note>>[];
        final sub = col.watch().listen(seen.add, onError: errors.add);

        await col.put(_Note('n1', 'hello', 0, const ['a']));
        await col.put(_Note('n2', 'world', 0, const []));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await sub.cancel();

        expect(errors, isEmpty,
            reason: 'a watcher decoded a partially written document');
        expect(seen.last.map((n) => n.title), containsAll(['hello', 'world']));
      });

      test('watch() reports a failed initial load on the stream', () async {
        final col = Collection.create<_Note>(
          'notes',
          _Note.codec,
          merge: _schema,
          engine: () => throw StateError('this device is not paired'),
        );
        await expectLater(col.watch(), emitsError(isStateError));
      });
    });
  }
}
