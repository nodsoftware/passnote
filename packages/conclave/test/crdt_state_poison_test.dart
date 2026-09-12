// CRDT field state arrives from synced peers, so it is remote-fed input: a
// row whose OUTER shape is wrong already degrades to an empty state, and
// these tests pin the same fail-safe rule for the INNER values — counts that
// are not numbers, tags that are not strings, containers of the wrong type.
// Without it, one poisoned row makes get/all/query throw for the whole
// collection, and unlike a bad frame the poison is persisted.
import 'package:conclave/conclave.dart';
// The state helpers are internal; test them directly.
import 'package:conclave/src/crdt/or_set.dart' as orset;
import 'package:conclave/src/crdt/pn_counter.dart' as pn;
import 'package:crdt/crdt.dart' show Hlc;
import 'package:test/test.dart';

void main() {
  group('PN-Counter state is fail-safe on inner values', () {
    const poisoned = {
      '__t': 'pn_counter',
      'p': {'evil': 'oops', 'good': 2},
      'n': {
        'also-evil': [1, 2]
      },
    };

    test('resolve degrades malformed counts to 0 and keeps good ones', () {
      expect(pn.pnResolve(poisoned), 2);
      expect(
          pn.pnResolve(const {
            '__t': 'pn_counter',
            'p': [1],
            'n': 'x'
          }),
          0);
      expect(
          pn.pnResolve(const {
            '__t': 'pn_counter',
            'p': {1: 5}
          }),
          0);
    });

    test('merge with a poisoned side keeps the healthy contributions', () {
      final healthy = pn.pnApplyDelta(pn.pnEmpty(), 'node-a', 3);
      for (final merged in [
        pn.pnMerge(poisoned, healthy),
        pn.pnMerge(healthy, poisoned),
      ]) {
        expect(pn.pnResolve(merged), 5,
            reason: 'node-a\'s 3 plus the well-formed "good": 2 survive');
      }
      expect(pn.pnResolve(pn.pnMerge(poisoned, pn.pnEmpty())), 2);
    });
  });

  group('OR-Set state is fail-safe on inner values', () {
    test('non-string tombstones are filtered, adds survive', () {
      const state = {
        '__t': 'or_set',
        'adds': {'n#1': 'milk'},
        'tombstones': [1, 2],
      };
      expect(orset.orResolve(state), ['milk']);
      expect(orset.orResolve(orset.orMerge(state, orset.orEmpty())), ['milk']);
    });

    test('a non-map adds degrades to empty instead of throwing', () {
      const state = {
        '__t': 'or_set',
        'adds': ['x'],
        'tombstones': <String>[],
      };
      expect(orset.orResolve(state), isEmpty);
      expect(orset.orResolve(orset.orMerge(state, orset.orEmpty())), isEmpty);
    });

    test('an add with a non-string tag is dropped, the rest kept', () {
      const state = {
        '__t': 'or_set',
        'adds': {1: 'bad-tag', 'n#2': 'bread'},
        'tombstones': <String>[],
      };
      expect(orset.orResolve(state), ['bread']);
    });
  });

  group('a poisoned synced row does not kill the collection read path', () {
    final codec = JsonCodec<Map<String, dynamic>>(
      toMap: (m) => m,
      fromMap: (m) => m,
      idOf: (m) => m['id'] as String,
    );

    test('get and all survive a deep-merge row whose path crosses a scalar',
        () async {
      final col = Collection.create<Map<String, dynamic>>(
        'items',
        codec,
        merge: const DeepMergeStrategy(),
      );
      await col.put({'id': 'd1', 'a': 1});
      await col.put({'id': 'd2', 'a': 5});

      // A member-authored frame carrying a field row whose dotted path
      // descends through d1's existing scalar `a`.
      final hlc = Hlc.now('evilnode');
      await col.mergeChangeset({
        'items': [
          {'key': 'd1\x1Fa.b', 'value': 2, 'is_deleted': false, 'hlc': hlc},
        ],
      });

      expect((await col.get('d1'))?['a'], 1,
          reason: 'the poisoned field degrades; the document stays readable');
      expect((await col.get('d2'))?['a'], 5);
      expect((await col.all()).map((d) => d['id']).toSet(), {'d1', 'd2'},
          reason: 'one poisoned row must not take out the list view');
    });

    test('get, all, and query survive a pn_counter row with garbage counts',
        () async {
      final col = Collection.create<Map<String, dynamic>>(
        'items',
        codec,
        merge: const SchemaMergeStrategy({'qty': PnCounter()}),
      );
      await col.put({'id': 'd1', 'qty': 0});
      await col.increment('d1', 'qty');
      expect((await col.get('d1'))?['qty'], 1);

      // A member-authored frame carrying a counter whose counts are not
      // numbers, for a new document AND merged onto the healthy one.
      final hlc = Hlc.now('evilnode');
      const poison = {
        '__t': 'pn_counter',
        'p': {'evil': 'oops'},
        'n': <String, Object?>{},
      };
      await col.mergeChangeset({
        'items': [
          {'key': 'd2', 'value': true, 'is_deleted': false, 'hlc': hlc},
          {'key': 'd2\x1Fid', 'value': 'd2', 'is_deleted': false, 'hlc': hlc},
          {
            'key': 'd2\x1Fqty',
            'value': poison,
            'is_deleted': false,
            'hlc': hlc,
            'crdt_type': 'pn_counter',
          },
          {
            'key': 'd1\x1Fqty',
            'value': poison,
            'is_deleted': false,
            'hlc': hlc,
            'crdt_type': 'pn_counter',
          },
        ],
      });

      expect((await col.get('d1'))?['qty'], 1,
          reason: 'merging garbage onto a healthy counter keeps its value');
      expect((await col.get('d2'))?['qty'], 0,
          reason: 'a fully poisoned counter reads as empty (0), not a throw');
      expect((await col.all()).map((d) => d['id']).toSet(), {'d1', 'd2'},
          reason: 'one poisoned row must not make the whole list unreadable');
      final page =
          await col.query().where('qty', isGreaterThan: 0).limit(10).get();
      expect(page.map((d) => d['id']), ['d1']);
    });
  });
}
