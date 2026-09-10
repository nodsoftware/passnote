import 'dart:async';

import 'package:conclave/conclave.dart';
import 'package:test/test.dart';

class _Task {
  _Task(this.id, this.title, this.done, this.priority);

  final String id;
  final String title;
  final bool done;
  final num priority;

  static final codec = JsonCodec<_Task>(
    toMap: (t) =>
        {'id': t.id, 'title': t.title, 'done': t.done, 'priority': t.priority},
    fromMap: (m) => _Task(
      m['id'] as String,
      m['title'] as String,
      m['done'] as bool,
      m['priority'] as num,
    ),
    idOf: (t) => t.id,
  );
}

/// Counts decodes, so a test can assert a watched query never decodes more
/// than its page.
class _CountingCodec<T> implements Codec<T> {
  _CountingCodec(this._inner);
  final Codec<T> _inner;
  int decodes = 0;

  @override
  Map<String, dynamic> toMap(T value) => _inner.toMap(value);

  @override
  T fromMap(Map<String, dynamic> map) {
    decodes++;
    return _inner.fromMap(map);
  }

  @override
  String idOf(T value) => _inner.idOf(value);
}

/// Lets pending engine events and watch refreshes settle.
Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

_Task _task(String id, {bool done = false, num priority = 0}) =>
    _Task(id, 'task $id', done, priority);

void main() {
  Collection<_Task> open({Codec<_Task>? codec}) => Collection.create<_Task>(
        'tasks',
        codec ?? _Task.codec,
        merge: const ShallowMergeStrategy(),
      );

  test('emits after the initial load, then on page-affecting changes',
      () async {
    final col = open();
    final emissions = <List<_Task>>[];
    final sub = col.query().orderBy('priority').limit(2).watch().listen(
          emissions.add,
        );
    addTearDown(sub.cancel);

    await _settle();
    expect(emissions, hasLength(1));
    expect(emissions.single, isEmpty, reason: 'initial snapshot of empty set');

    await col.put(_task('a', priority: 1));
    await _settle();
    expect(emissions.last.map((t) => t.id), equals(['a']));

    // A new document that enters the page emits again.
    await col.put(_task('b', priority: 0));
    await _settle();
    expect(emissions.last.map((t) => t.id), equals(['b', 'a']));
  });

  test('a change entirely outside the watched page emits nothing', () async {
    final col = open();
    for (var i = 0; i < 4; i++) {
      await col.put(_task('t$i', priority: i));
    }

    final emissions = <List<_Task>>[];
    final sub = col.query().orderBy('priority').limit(2).watch().listen(
          emissions.add,
        );
    addTearDown(sub.cancel);
    await _settle();
    expect(emissions.last.map((t) => t.id), equals(['t0', 't1']));
    final before = emissions.length;

    // Beyond the page: sorts after t1, so the page is untouched.
    await col.put(_task('t9', priority: 9));
    await _settle();
    expect(emissions.length, equals(before),
        reason: 'an unchanged page is suppressed, not re-emitted');

    // Inside the page: a smaller priority takes the first slot.
    await col.put(_task('t-first', priority: -1));
    await _settle();
    expect(emissions.last.map((t) => t.id), equals(['t-first', 't0']));
  });

  test('an in-place edit to a page document emits the new contents', () async {
    final col = open();
    await col.put(_task('a', priority: 1));

    final emissions = <List<_Task>>[];
    final sub = col.query().where('done', isEqualTo: false).watch().listen(
          emissions.add,
        );
    addTearDown(sub.cancel);
    await _settle();
    expect(emissions.last.single.title, 'task a');

    await col.put(_Task('a', 'renamed', false, 1));
    await _settle();
    expect(emissions.last.single.title, 'renamed');

    // Leaving the result set (done flips) emits the shrunken page.
    await col.put(_Task('a', 'renamed', true, 1));
    await _settle();
    expect(emissions.last, isEmpty);
  });

  test('decodes at most the page per emission under a burst of writes',
      () async {
    final codec = _CountingCodec<_Task>(_Task.codec);
    final col = open(codec: codec);

    var emissions = 0;
    final sub = col
        .query()
        .where('done', isEqualTo: false)
        .orderBy('priority')
        .limit(5)
        .watch()
        .listen((_) => emissions++);
    addTearDown(sub.cancel);
    await _settle();

    codec.decodes = 0;
    emissions = 0;
    for (var i = 0; i < 40; i++) {
      await col.put(_task('t$i', priority: i));
    }
    await _settle();

    expect(emissions, greaterThan(0));
    expect(codec.decodes, lessThanOrEqualTo(emissions * 5),
        reason: 'a watched query decodes at most limit docs per emission, '
            'never the whole collection');
  });

  test('the watched page matches the one-shot query order', () async {
    final col = open();
    for (var i = 0; i < 6; i++) {
      await col.put(_task('t$i', priority: 5 - i));
    }

    final first = Completer<List<_Task>>();
    final sub = col
        .query()
        .orderBy('priority', descending: true)
        .limit(4)
        .watch()
        .listen((items) {
      if (!first.isCompleted) first.complete(items);
    });
    addTearDown(sub.cancel);

    final watched = await first.future.timeout(const Duration(seconds: 5));
    final oneShot =
        await col.query().orderBy('priority', descending: true).limit(4).get();
    expect(watched.map((t) => t.id), equals(oneShot.map((t) => t.id)));
  });

  test('a watched query stream completes on dispose', () async {
    final col = open();
    final done = Completer<void>();
    final sub = col.query().limit(1).watch().listen((_) {});
    sub.onDone(done.complete);
    await _settle();

    await col.dispose();
    await done.future.timeout(const Duration(seconds: 5));
  });

  test('watching an ObjectMergeStrategy collection throws at build time', () {
    final col = Collection.create<_Task>('tasks', _Task.codec);
    expect(() => col.query().watch(), throwsArgumentError);
  });
}
