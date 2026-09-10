import 'dart:convert';

import 'package:conclave/conclave.dart';
import 'package:test/test.dart';

import 'src/task_model.dart';

// Runs against the checked-in output of this package's own builder (see
// build.yaml): the fixtures in test/src/ are generated, compiled, and
// exercised for real. `melos run generate` refreshes them; CI fails on drift.
void main() {
  final task = Task(
    id: 't1',
    title: 'Buy milk',
    done: true,
    qty: 3,
    tags: const ['dairy', 'urgent'],
    priority: 2,
    scores: const {'freshness': 0.9},
  );

  test('the generated codec round-trips a document', () {
    final decoded = Task.codec.fromMap(Task.codec.toMap(task));
    expect(Task.codec.toMap(decoded), Task.codec.toMap(task));
  });

  test('@DocumentId drives idOf', () {
    expect(Task.codec.idOf(task), 't1');
  });

  test('the generated schema carries exactly the @Crdt annotations', () {
    expect(Task.schema, {'qty': const PnCounter(), 'tags': const OrSet()});
  });

  test('unannotated fields default to LwwRegister', () {
    expect(Task.merge.typeAt('title'), const LwwRegister());
    expect(Task.merge.typeAt('done'), const LwwRegister());
    expect(Task.merge.typeAt('qty'), const PnCounter());
    expect(Task.merge.typeAt('tags'), const OrSet());
  });

  test('the merge strategy decomposes per field with the schema types', () {
    final specs = Task.merge.fields(Task.codec.toMap(task)).toList();
    final byPath = {for (final s in specs) s.path: s.type};
    expect(byPath['qty'], const PnCounter());
    expect(byPath['tags'], const OrSet());
    expect(byPath['title'], const LwwRegister());
  });

  test('constructor defaults fill fields a stored document lacks', () {
    final decoded = Task.codec.fromMap({'id': 't2', 'title': 'Old doc'});
    expect(decoded.done, isFalse);
    expect(decoded.qty, 0);
    expect(decoded.tags, isEmpty);
    expect(decoded.priority, isNull);
    expect(decoded.scores, isEmpty);
  });

  test('a JSON round-trip survives, including integral doubles', () {
    // jsonDecode hands back plain Lists/Maps and may return an integral
    // number as int; the generated fromMap must convert, not cast.
    final wire = jsonDecode(jsonEncode({
      ...Task.codec.toMap(task),
      'scores': {'freshness': 1},
    })) as Map<String, dynamic>;
    final decoded = Task.codec.fromMap(wire);
    expect(decoded.scores, {'freshness': 1.0});
    expect(decoded.tags, ['dairy', 'urgent']);
    expect(decoded.priority, 2);
  });

  test('a positional constructor gets its arguments in order', () {
    const note = Note('n1', 'hello');
    final decoded = Note.codec.fromMap(Note.codec.toMap(note));
    expect(Note.codec.idOf(decoded), 'n1');
    expect(decoded.text, 'hello');
  });
}
