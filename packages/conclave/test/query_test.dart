import 'dart:io';

import 'package:conclave/conclave.dart';
import 'package:conclave/engine.dart';
import 'package:test/test.dart';

/// A task exercising every queryable shape: an untyped bool and text, a
/// nullable number, an OrSet list, and a PnCounter.
class _Task {
  _Task(this.id, this.title, this.done, this.priority, this.tags, this.qty);

  final String id;
  final String title;
  final bool done;
  final num? priority;
  final List<String> tags;
  final num qty;

  static final codec = JsonCodec<_Task>(
    toMap: (t) => {
      'id': t.id,
      'title': t.title,
      'done': t.done,
      'priority': t.priority,
      'tags': t.tags,
      'qty': t.qty,
    },
    fromMap: (m) => _Task(
      m['id'] as String,
      m['title'] as String,
      m['done'] as bool,
      m['priority'] as num?,
      (m['tags'] as List).cast<String>(),
      m['qty'] as num,
    ),
    idOf: (t) => t.id,
  );
}

const _schema = SchemaMergeStrategy({'tags': OrSet(), 'qty': PnCounter()});

void main() {
  late Directory tmp;
  setUpAll(() => tmp = Directory.systemTemp.createTempSync('conclave_query'));
  tearDownAll(() => tmp.deleteSync(recursive: true));
  var counter = 0;
  String freshPath() => '${tmp.path}/db_${counter++}.sqlite';

  /// A collection on a SQLite file, so reopening [path] resumes the same data.
  Future<Collection<_Task>> openSqlite(String path) async {
    final col = Collection.create<_Task>(
      'tasks',
      _Task.codec,
      merge: _schema,
      indexedFields: ['done'],
      engine: () => SqliteCrdtTable(path),
    );
    await col.ready;
    addTearDown(col.dispose);
    return col;
  }

  Future<Collection<_Task>> openInMemory() async {
    final col = Collection.create<_Task>('tasks', _Task.codec, merge: _schema);
    await col.ready;
    return col;
  }

  _Task task(String id,
          {bool done = false,
          num? priority,
          List<String>? tags,
          num qty = 0}) =>
      _Task(id, 'task $id', done, priority, tags ?? const [], qty);

  group('engine behaviour (both engines)', () {
    for (final (label, open) in [
      ('SQLite', (String p) => openSqlite(p)),
      ('in-memory', (String p) => openInMemory()),
    ]) {
      group(label, () {
        test('equality, comparison, and AND of clauses', () async {
          final col = await open(freshPath());
          await col.put(task('a', done: true, priority: 1));
          await col.put(task('b', done: false, priority: 5));
          await col.put(task('c', done: false, priority: 9));

          expect(
              (await col.query().where('done', isEqualTo: false).get())
                  .map((t) => t.id),
              unorderedEquals(['b', 'c']));
          expect(
              (await col
                      .query()
                      .where('done', isEqualTo: false)
                      .where('priority', isGreaterThan: 6)
                      .get())
                  .map((t) => t.id),
              equals(['c']));
          expect(
              (await col.query().where('priority', isLessThan: 2).get())
                  .map((t) => t.id),
              equals(['a']));
          expect(
              (await col.query().where('priority', isIn: [1, 9]).get())
                  .map((t) => t.id),
              unorderedEquals(['a', 'c']));
        });

        test('contains matches OrSet membership, not the stored state',
            () async {
          final col = await open(freshPath());
          await col.put(task('a', tags: ['urgent', 'home']));
          await col.put(task('b', tags: ['work']));
          await col.put(task('c'));

          expect(
              (await col.query().where('tags', contains: 'urgent').get())
                  .map((t) => t.id),
              equals(['a']));
          expect(
              (await col.query().where('tags', contains: 'work').get())
                  .map((t) => t.id),
              equals(['b']));
          expect(
              await col.query().where('tags', contains: 'nope').get(), isEmpty);
        });

        test('numeric comparison targets a PnCounter total', () async {
          final col = await open(freshPath());
          await col.put(task('a'));
          await col.put(task('b'));
          await col.increment('a', 'qty', by: 3);
          await col.increment('b', 'qty', by: 10);
          await col.increment('b', 'qty', by: -2);

          expect(
              (await col.query().where('qty', isGreaterThan: 5).get())
                  .map((t) => t.id),
              equals(['b']));
          expect(
              (await col.query().where('qty', isEqualTo: 3).get())
                  .map((t) => t.id),
              equals(['a']));
        });

        test('orderBy sorts, missing field first, and descending flips',
            () async {
          final col = await open(freshPath());
          await col.put(task('a', priority: 5));
          await col.put(task('b', priority: 1));
          await col.put(task('c')); // priority null: sorts first ascending.

          expect((await col.query().orderBy('priority').get()).map((t) => t.id),
              equals(['c', 'b', 'a']));
          expect(
              (await col.query().orderBy('priority', descending: true).get())
                  .map((t) => t.id),
              equals(['a', 'b', 'c']));
        });

        test(
            'keyset pages are disjoint and gap-free, including null order '
            'values', () async {
          final col = await open(freshPath());
          for (var i = 0; i < 9; i++) {
            await col.put(task('t$i', priority: i < 3 ? null : i));
          }

          for (final descending in [false, true]) {
            final seen = <String>[];
            QueryCursor? cursor;
            do {
              var q = col
                  .query()
                  .orderBy('priority', descending: descending)
                  .limit(2);
              if (cursor != null) q = q.startAfter(cursor);
              final page = await q.page();
              for (final t in page.items) {
                expect(seen, isNot(contains(t.id)),
                    reason: 'pages must be disjoint (descending=$descending)');
                seen.add(t.id);
              }
              cursor = page.nextCursor;
            } while (cursor != null);
            expect(seen, hasLength(9),
                reason: 'pages must be gap-free (descending=$descending)');
          }
        });
      });
    }
  });

  test('the two engines return identical pages', () async {
    final sqlite = await openSqlite(freshPath());
    final memory = await openInMemory();
    for (final col in [sqlite, memory]) {
      for (var i = 0; i < 7; i++) {
        await col.put(task('t$i',
            done: i.isEven, priority: i < 2 ? null : 10 - i, tags: ['g$i']));
      }
    }

    for (final col in [sqlite, memory]) {
      expect(
          (await col
                  .query()
                  .where('done', isEqualTo: true)
                  .orderBy('priority')
                  .limit(2)
                  .get())
              .map((t) => t.id)
              .toList(),
          equals(['t0', 't6']),
          reason: 'null priority first, then ascending');
    }
  });

  test(
      'the two engines split an order-value tie at a page boundary '
      'identically, both directions', () async {
    // Duplicated priorities arranged so every page boundary falls INSIDE a
    // tie: the cursor must disambiguate by document id, and both engines
    // must agree on where each page ends. This is the trickiest branch of
    // the compiled keyset window (`ord = cursor AND did > cursor.docId`).
    final sqlite = await openSqlite(freshPath());
    final memory = await openInMemory();
    for (final col in [sqlite, memory]) {
      for (var i = 0; i < 6; i++) {
        await col.put(task('t$i', priority: i < 3 ? 1 : 2));
      }
    }

    for (final descending in [false, true]) {
      final expected = descending
          ? ['t5', 't4', 't3', 't2', 't1', 't0']
          : ['t0', 't1', 't2', 't3', 't4', 't5'];
      final perEngine = <List<String>>[];
      for (final col in [sqlite, memory]) {
        final pages = <List<String>>[];
        QueryCursor? cursor;
        do {
          var q =
              col.query().orderBy('priority', descending: descending).limit(2);
          if (cursor != null) q = q.startAfter(cursor);
          final page = await q.page();
          pages.add([for (final t in page.items) t.id]);
          cursor = page.nextCursor;
        } while (cursor != null);
        expect(pages.expand((p) => p), equals(expected),
            reason: 'ties order by document id (descending=$descending)');
        expect(pages.every((p) => p.length <= 2), isTrue);
        perEngine.add(pages.expand((p) => p).toList());
      }
      expect(perEngine[0], equals(perEngine[1]),
          reason: 'both engines agree page by page (descending=$descending)');
    }
  });

  test('a cursor survives a close and reopen of the same store', () async {
    final path = freshPath();
    var col = await openSqlite(path);
    for (var i = 0; i < 6; i++) {
      await col.put(task('t$i', priority: i));
    }

    final first = await col.query().orderBy('priority').limit(2).page();
    expect(first.items.map((t) => t.id), equals(['t0', 't1']));
    await col.dispose();

    col = await openSqlite(path);
    final second = await col
        .query()
        .orderBy('priority')
        .limit(2)
        .startAfter(first.nextCursor!)
        .page();
    expect(second.items.map((t) => t.id), equals(['t2', 't3']));
  });

  test('two converged devices return identical pages', () async {
    final a = await openSqlite(freshPath());
    final b = await openSqlite(freshPath());
    await a.put(task('x', priority: 2, tags: ['home']));
    await a.put(task('y', priority: 2, tags: ['work']));
    await b.put(task('z', priority: 1));
    await b.mergeChangeset(await a.getChangeset());
    await a.mergeChangeset(await b.getChangeset());

    Future<List<String>> ids(Collection<_Task> col) async =>
        [for (final t in await col.query().orderBy('priority').get()) t.id];

    final onA = await ids(a);
    expect(onA, equals(['z', 'x', 'y']), reason: 'priority, then doc id');
    expect(await ids(b), equals(onA));
  });

  test('an equality predicate on a declared index path searches the index',
      () async {
    final engine = SqliteCrdtTable(freshPath());
    await engine.init();
    addTearDown(engine.close);
    await engine.ensureQueryIndex('tasks', 'done');
    final typed = TypedCrdtTable(engine);
    for (var i = 0; i < 20; i++) {
      await typed.put('tasks', 't$i', true);
      await typed.put('tasks', 't$i\x1Fdone', i.isEven);
    }

    const spec = QuerySpec(predicates: [
      QueryPredicate(
        path: 'done',
        op: QueryOp.equals,
        value: false,
        type: LwwRegister(),
      ),
    ]);
    final plan = engine.explainQuery('tasks', spec);
    expect(plan, contains('cq_tasks_done'),
        reason: 'the declared index must serve the predicate:\n$plan');
    expect(plan, isNot(contains('SCAN crdt_records')),
        reason: 'no full-table scan:\n$plan');
    // And the plan is not just cosmetic: the query returns the right rows.
    final rows = await typed.queryDocIds('tasks', spec);
    expect(rows.map((r) => r.docId),
        unorderedEquals([for (var i = 1; i < 20; i += 2) 't$i']));
  });

  group('build-time validation', () {
    late Collection<_Task> col;
    setUp(() async => col = await openInMemory());

    test('operators must fit the field type', () {
      expect(
          () => col.query().where('tags', isEqualTo: 'x'), throwsArgumentError);
      expect(() => col.query().where('tags', isGreaterThan: 1),
          throwsArgumentError);
      expect(
          () => col.query().where('title', contains: 'x'), throwsArgumentError);
      expect(() => col.query().where('qty', contains: 1), throwsArgumentError);
      expect(() => col.query().orderBy('tags'), throwsArgumentError);
    });

    test('values must be scalars and operators well-formed', () {
      expect(() => col.query().where('title', isEqualTo: ['a']),
          throwsArgumentError);
      expect(() => col.query().where('title'), throwsArgumentError);
      expect(() => col.query().where('title', isEqualTo: 'a', isLessThan: 'b'),
          throwsArgumentError);
      expect(() => col.query().where('qty', isGreaterThan: null),
          throwsArgumentError);
      expect(() => col.query().where('title', isIn: []), throwsArgumentError);
      expect(() => col.query().limit(0), throwsArgumentError);
      expect(() => col.query().where('bad\x1Fpath', isEqualTo: 1),
          throwsArgumentError);
      expect(() => col.query().orderBy('a').orderBy('b'), throwsArgumentError);
    });

    test('isEqualTo null is a real query, not a missing operator', () async {
      await col.put(task('a', priority: null));
      await col.put(task('b', priority: 4));
      expect(
          (await col.query().where('priority', isEqualTo: null).get())
              .map((t) => t.id),
          equals(['a']));
    });
  });
}
