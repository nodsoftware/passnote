// Pins the reserved-separator invariant: the engine joins a document id and a
// field path into one record key with the ASCII Unit Separator (\x1F), so an
// id or field name containing it would collide with another document's
// records (id "d1\x1Fa" with field "b" keys identically to id "d1" with
// field "a\x1Fb"). Local writes reject the character instead of writing the
// ambiguous key.
import 'package:passnote/passnote.dart';
import 'package:test/test.dart';

void main() {
  final codec = JsonCodec<Map<String, dynamic>>(
    toMap: (m) => m,
    fromMap: (m) => m,
    idOf: (m) => m['id'] as String,
  );

  test('put rejects a document id containing \\x1F', () async {
    final col = Collection.create<Map<String, dynamic>>('items', codec);
    await expectLater(
      col.put({'id': 'd1\x1Fa', 'v': 1}),
      throwsArgumentError,
    );
    // The colliding twin would have been: id "d1" with field "a\x1Fv"... and
    // a healthy write still works.
    await col.put({'id': 'd1', 'v': 1});
    expect((await col.get('d1'))?['v'], 1);
  });

  test('put rejects a field path containing \\x1F', () async {
    final col = Collection.create<Map<String, dynamic>>(
      'items',
      codec,
      merge: const ShallowMergeStrategy(),
    );
    await expectLater(
      col.put({'id': 'd1', 'a\x1Fb': 1}),
      throwsArgumentError,
    );
  });

  test('increment and delete reject ids and paths containing \\x1F', () async {
    final col = Collection.create<Map<String, dynamic>>(
      'items',
      codec,
      merge: const SchemaMergeStrategy({'qty': PnCounter()}),
    );
    await col.put({'id': 'd1', 'qty': 0});
    await expectLater(col.increment('d1\x1Fx', 'qty'), throwsArgumentError);
    await expectLater(col.increment('d1', 'qty\x1Fx'), throwsArgumentError);
    await expectLater(col.delete('d1\x1Fx'), throwsArgumentError);
    // Healthy calls still work.
    await col.increment('d1', 'qty');
    expect((await col.get('d1'))?['qty'], 1);
  });
}
