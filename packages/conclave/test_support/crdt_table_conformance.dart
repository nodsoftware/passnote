import 'dart:async';

import 'package:conclave/engine.dart';
import 'package:crdt/crdt.dart' show Hlc;
import 'package:test/test.dart';

/// Behavioural contract every [CrdtTable] implementation must satisfy.
///
/// Call it once per implementation:
///
/// ```dart
/// runCrdtTableConformance('MapCrdtTable', (t) => MapCrdtTable(t));
/// ```
///
/// [make] returns a fresh, empty table for the given table name; it may be
/// sync or async. [init] is called on it before every test.
///
/// [dispose], if given, is called on every table a test created, in `tearDown`
/// (e.g. to close a disk-backed engine's file handle).
///
/// Pass `supportsCompaction: true` for an engine whose [CrdtTable.compact]
/// works in place; the compaction cases are skipped otherwise (the in-memory
/// [MapCrdtTable] rebuilds via `Collection.compact` instead).
void runCrdtTableConformance(
  String description,
  FutureOr<CrdtTable> Function(String table) make, {
  bool supportsCompaction = false,
  FutureOr<void> Function(CrdtTable table)? dispose,
}) {
  const t = 'items';

  final created = <CrdtTable>[];

  Future<CrdtTable> fresh() async {
    final table = await Future.sync(() => make(t));
    await table.init();
    created.add(table);
    return table;
  }

  tearDown(() async {
    if (dispose != null) {
      for (final table in created) {
        await dispose(table);
      }
    }
    created.clear();
  });

  group('$description conformance', () {
    test('put then value returns the value', () async {
      final table = await fresh();
      await table.put(t, 'a', 'apple');
      expect(await table.value(t, 'a'), 'apple');
    });

    test('value is null for an absent key', () async {
      final table = await fresh();
      expect(await table.value(t, 'missing'), isNull);
    });

    test('put with isDeleted tombstones the record', () async {
      final table = await fresh();
      await table.put(t, 'a', 'apple');
      await table.put(t, 'a', null, isDeleted: true);
      expect(await table.value(t, 'a'), isNull);
    });

    test('a later put on the same key wins', () async {
      final table = await fresh();
      await table.put(t, 'a', 'one');
      await table.put(t, 'a', 'two');
      expect(await table.value(t, 'a'), 'two');
    });

    test('liveFields with an empty prefix returns every live record', () async {
      final table = await fresh();
      await table.put(t, 'a', 1);
      await table.put(t, 'b', 2);
      await table.put(t, 'c', 3);
      await table.put(t, 'c', null, isDeleted: true);
      expect(await table.liveFields(t, ''), {'a': 1, 'b': 2});
    });

    test('liveFields with a prefix returns only matching live records',
        () async {
      final table = await fresh();
      await table.put(t, 'doc1\x1Fx', 1);
      await table.put(t, 'doc1\x1Fy', 2);
      await table.put(t, 'doc2\x1Fx', 3);
      expect(await table.liveFields(t, 'doc1\x1F'),
          {'doc1\x1Fx': 1, 'doc1\x1Fy': 2});
    });

    test('liveKeys excludes tombstones and respects a prefix', () async {
      final table = await fresh();
      await table.put(t, 'doc1\x1Fx', 1);
      await table.put(t, 'doc1\x1Fy', 2);
      await table.put(t, 'doc1\x1Fy', null, isDeleted: true);
      await table.put(t, 'doc2\x1Fx', 3);
      expect(table.liveKeys(t, ''), {'doc1\x1Fx', 'doc2\x1Fx'});
      expect(table.liveKeys(t, 'doc1\x1F'), {'doc1\x1Fx'});
    });

    test('maxHlc is empty on a fresh table, then monotonic', () async {
      final table = await fresh();
      expect(table.maxHlc(t), '');
      await table.put(t, 'a', 1);
      final first = table.maxHlc(t);
      expect(first, isNotEmpty);
      await table.put(t, 'b', 2);
      final second = table.maxHlc(t);
      expect(Hlc.parse(second) > Hlc.parse(first), isTrue);
    });

    test('changeset() includes tombstones', () async {
      final table = await fresh();
      await table.put(t, 'a', 1);
      await table.put(t, 'a', null, isDeleted: true);
      final rows = (await table.changeset(t))[t]!;
      final a = rows.firstWhere((r) => r['key'] == 'a');
      expect(a['is_deleted'], isTrue);
    });

    test('changeset(sinceHlc: maxHlc) is empty', () async {
      final table = await fresh();
      await table.put(t, 'a', 1);
      await table.put(t, 'b', 2);
      final cs = await table.changeset(t, sinceHlc: table.maxHlc(t));
      expect(cs[t] ?? const [], isEmpty);
    });

    test('changeset(sinceHlc: "") returns everything', () async {
      final table = await fresh();
      await table.put(t, 'a', 1);
      final cs = await table.changeset(t, sinceHlc: '');
      expect((cs[t] ?? const []).map((r) => r['key']), contains('a'));
    });

    test('merge applies a peer changeset', () async {
      final local = await fresh();
      final peer = await fresh();
      await peer.put(t, 'p', 'from peer');

      await local.merge(await peer.changeset(t));

      expect(await local.value(t, 'p'), 'from peer');
    });

    test('merge is idempotent', () async {
      final local = await fresh();
      final peer = await fresh();
      await peer.put(t, 'p', 'v');
      final cs = await peer.changeset(t);

      await local.merge(cs);
      var emitted = false;
      final sub = local.watch(t).listen((_) => emitted = true);
      await local.merge(cs);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(await local.value(t, 'p'), 'v');
      expect(emitted, isFalse,
          reason: 're-merging the same changeset is a no-op');
    });

    test('merge is commutative', () async {
      final tableA = await fresh();
      final tableB = await fresh();
      final one = await fresh();
      final two = await fresh();

      await one.put(t, 'x', 'one');
      await two.put(t, 'y', 'two');
      final csOne = await one.changeset(t);
      final csTwo = await two.changeset(t);

      await tableA.merge(csOne);
      await tableA.merge(csTwo);
      await tableB.merge(csTwo);
      await tableB.merge(csOne);

      expect(await tableA.liveFields(t, ''), await tableB.liveFields(t, ''));
    });

    test('merge advances the local HLC past the incoming maximum', () async {
      final local = await fresh();
      final peer = await fresh();
      await peer.put(t, 'p1', 1);
      await peer.put(t, 'p2', 2);
      final peerMax = peer.maxHlc(t);

      await local.merge(await peer.changeset(t));
      await local.put(t, 'local', 3);

      expect(Hlc.parse(local.maxHlc(t)) > Hlc.parse(peerMax), isTrue);
    });

    test('sinceHlc does not echo freshly merged peer records', () async {
      final local = await fresh();
      final peer = await fresh();

      await peer.put(t, 'p1', 1);
      await peer.put(t, 'p2', 2);
      final peerMax = peer.maxHlc(t);

      await local.merge(await peer.changeset(t));

      // The sync protocol asks: "what do I have that is newer than the peer's
      // max?" The just-merged peer records are not newer than the peer's max,
      // so they must not be sent back.
      final echo = await local.changeset(t, sinceHlc: peerMax);
      final keys = (echo[t] ?? const []).map((r) => r['key']).toSet();
      expect(keys, isNot(anyElement(isIn(['p1', 'p2']))));
    });

    test('watch emits on put', () async {
      final table = await fresh();
      final events = <void>[];
      final sub = table.watch(t).listen(events.add);
      await table.put(t, 'a', 1);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(events, isNotEmpty);
    });

    test('watch emits on a merge that changes a record', () async {
      final local = await fresh();
      final peer = await fresh();
      await peer.put(t, 'p', 1);

      final events = <void>[];
      final sub = local.watch(t).listen(events.add);
      await local.merge(await peer.changeset(t));
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(events, isNotEmpty);
    });

    test('watch is a broadcast stream', () async {
      final table = await fresh();
      final s1 = table.watch(t);
      final s2 = table.watch(t);
      final a = s1.listen((_) {});
      final b = s2.listen((_) {});
      addTearDown(() async {
        await a.cancel();
        await b.cancel();
      });
      // No "already listened" error.
      await table.put(t, 'a', 1);
    });

    group('compaction', () {
      final skip = supportsCompaction
          ? null
          : 'in-memory engine compacts via Collection.compact, not in place';

      test('removes tombstones older than the horizon and counts them',
          () async {
        final table = await fresh();
        await table.put(t, 'a', 1);
        await table.put(t, 'a', null, isDeleted: true);
        // Backdate the tombstone by merging a record with an old HLC.
        final old = Hlc(
          DateTime.now().subtract(const Duration(days: 400)),
          0,
          'backdater',
        );
        await table.merge({
          t: [
            {'key': 'b', 'value': null, 'is_deleted': true, 'hlc': old},
          ],
        });

        final reclaimed =
            await table.compact(t, horizon: const Duration(days: 30));

        expect(reclaimed, greaterThanOrEqualTo(1));
        expect((await table.changeset(t))[t]!.map((r) => r['key']),
            isNot(contains('b')));
      }, skip: skip);

      test('keeps live records and young tombstones', () async {
        final table = await fresh();
        await table.put(t, 'live', 1);
        await table.put(t, 'young', 2);
        await table.put(t, 'young', null, isDeleted: true);

        await table.compact(t, horizon: const Duration(days: 30));

        expect(await table.value(t, 'live'), 1);
        final rows = (await table.changeset(t))[t]!;
        expect(rows.map((r) => r['key']), contains('young'));
      }, skip: skip);
    });
  });
}

/// Behavioural contract of the typed layer ([TypedCrdtTable]) over a
/// [CrdtTable] implementation.
///
/// Call it once per engine, with the same [make] and [dispose] passed to
/// [runCrdtTableConformance]; the suite wraps each fresh table in
/// [TypedCrdtTable] itself. Every case must hold over every engine — the typed
/// merge rules live entirely in the decorator.
void runCrdtTypeConformance(
  String description,
  FutureOr<CrdtTable> Function(String table) make, {
  FutureOr<void> Function(CrdtTable table)? dispose,
}) {
  const t = 'items';

  final created = <CrdtTable>[];

  Future<TypedCrdtTable> fresh() async {
    final inner = await Future.sync(() => make(t));
    final table = TypedCrdtTable(inner);
    await table.init();
    created.add(inner);
    return table;
  }

  /// Exchanges full changesets both ways so [a] and [b] converge.
  Future<void> syncBoth(TypedCrdtTable a, TypedCrdtTable b) async {
    await a.merge(await b.changeset(t));
    await b.merge(await a.changeset(t));
  }

  tearDown(() async {
    if (dispose != null) {
      for (final table in created) {
        await dispose(table);
      }
    }
    created.clear();
  });

  group('$description typed conformance', () {
    test('exposes a stable, non-empty node id', () async {
      final table = await fresh();
      expect(table.nodeId, isNotEmpty);
      expect(table.nodeId, table.nodeId);
    });

    test('an LwwRegister put passes through unchanged', () async {
      final table = await fresh();
      await table.put(t, 'a', 'apple');
      await table.put(t, 'a', 'apricot');
      expect(await table.value(t, 'a'), 'apricot');
    });

    group('PnCounter', () {
      test('a put seeds the counter and value resolves to a number', () async {
        final table = await fresh();
        await table.put(t, 'qty', 3, crdtType: const PnCounter());
        expect(await table.value(t, 'qty'), 3);
      });

      test('increment accumulates signed deltas', () async {
        final table = await fresh();
        await table.increment(t, 'qty', 2);
        await table.increment(t, 'qty', 5);
        await table.increment(t, 'qty', -3);
        expect(await table.value(t, 'qty'), 4);
      });

      test('a put with the current value is a no-op', () async {
        final table = await fresh();
        await table.increment(t, 'qty', 2);
        final before = table.maxHlc(t);
        await table.put(t, 'qty', 2, crdtType: const PnCounter());
        expect(table.maxHlc(t), before);
      });

      test('a put that would change the value throws', () async {
        final table = await fresh();
        await table.increment(t, 'qty', 2);
        expect(
          () => table.put(t, 'qty', 7, crdtType: const PnCounter()),
          throwsArgumentError,
        );
      });

      test('increment on a non-counter record throws', () async {
        final table = await fresh();
        await table.put(t, 'name', 'milk');
        expect(() => table.increment(t, 'name', 1), throwsArgumentError);
      });

      test('concurrent increments on two replicas sum after convergence',
          () async {
        final a = await fresh();
        final b = await fresh();
        await a.increment(t, 'qty', 3);
        await b.increment(t, 'qty', 4);

        await syncBoth(a, b);

        expect(await a.value(t, 'qty'), 7);
        expect(await b.value(t, 'qty'), 7);
      });

      test('converged replicas go quiescent', () async {
        final a = await fresh();
        final b = await fresh();
        await a.increment(t, 'qty', 3);
        await b.increment(t, 'qty', 4);
        await syncBoth(a, b);
        await syncBoth(a, b);

        final before = a.maxHlc(t);
        await a.merge(await b.changeset(t));
        expect(a.maxHlc(t), before);
      });
    });

    group('OrSet', () {
      test(
          'a put stores the membership; value resolves sorted and de-duplicated',
          () async {
        final table = await fresh();
        await table.put(t, 'tags', ['milk', 'eggs', 'milk'],
            crdtType: const OrSet());
        expect(await table.value(t, 'tags'), ['eggs', 'milk']);
      });

      test('a put removes elements that left the list', () async {
        final table = await fresh();
        await table.put(t, 'tags', ['milk', 'eggs'], crdtType: const OrSet());
        await table.put(t, 'tags', ['eggs'], crdtType: const OrSet());
        expect(await table.value(t, 'tags'), ['eggs']);
      });

      test('a put with the same membership is a no-op', () async {
        final table = await fresh();
        await table.put(t, 'tags', ['milk'], crdtType: const OrSet());
        final before = table.maxHlc(t);
        await table.put(t, 'tags', ['milk'], crdtType: const OrSet());
        expect(table.maxHlc(t), before);
      });

      test('concurrent add and remove of different elements both take effect',
          () async {
        final a = await fresh();
        final b = await fresh();
        await a.put(t, 'tags', ['milk'], crdtType: const OrSet());
        await syncBoth(a, b);

        // Concurrently: A adds eggs, B removes milk.
        await a.put(t, 'tags', ['milk', 'eggs'], crdtType: const OrSet());
        await b.put(t, 'tags', <String>[], crdtType: const OrSet());
        await syncBoth(a, b);

        expect(await a.value(t, 'tags'), ['eggs']);
        expect(await b.value(t, 'tags'), ['eggs']);
      });

      test('an add wins over a remove that did not observe it', () async {
        final a = await fresh();
        final b = await fresh();
        await a.put(t, 'tags', ['milk'], crdtType: const OrSet());
        await syncBoth(a, b);

        // Concurrently: B removes the milk it observed; A removes and re-adds
        // milk, minting an add tag B never saw.
        await b.put(t, 'tags', <String>[], crdtType: const OrSet());
        await a.put(t, 'tags', <String>[], crdtType: const OrSet());
        await a.put(t, 'tags', ['milk'], crdtType: const OrSet());
        await syncBoth(a, b);

        expect(await a.value(t, 'tags'), ['milk']);
        expect(await b.value(t, 'tags'), ['milk']);
      });

      test('converged replicas go quiescent', () async {
        final a = await fresh();
        final b = await fresh();
        await a.put(t, 'tags', ['milk'], crdtType: const OrSet());
        await b.put(t, 'tags', ['eggs'], crdtType: const OrSet());
        await syncBoth(a, b);
        await syncBoth(a, b);

        final before = a.maxHlc(t);
        await a.merge(await b.changeset(t));
        expect(a.maxHlc(t), before);
      });
    });
  });
}
