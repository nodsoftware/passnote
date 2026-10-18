import 'package:passnote/passnote.dart';
import 'package:test/test.dart';

/// The field paths [s] produces for [doc].
Set<String> _paths(MergeStrategy s, Map<String, dynamic> doc) =>
    {for (final f in s.fields(doc)) f.path};

/// path -> value for [s]'s decomposition of [doc].
Map<String, Object?> _values(MergeStrategy s, Map<String, dynamic> doc) =>
    {for (final f in s.fields(doc)) f.path: f.value};

/// Round-trips [doc] through [s]: `fields()` then `unflatten()`.
Map<String, dynamic> _roundTrip(MergeStrategy s, Map<String, dynamic> doc) => s
    .unflatten([for (final f in s.fields(doc)) (path: f.path, value: f.value)]);

void main() {
  group('ObjectMergeStrategy', () {
    const strategy = ObjectMergeStrategy();

    test('flattens the whole document to a single field', () {
      final doc = {
        'id': 'n1',
        'title': 'A',
        'meta': {'pinned': true}
      };
      final fields = strategy.fields(doc).toList();
      expect(fields, hasLength(1));
      expect(fields.single.path, equals(''));
      expect(fields.single.value, equals(doc));
      expect(fields.single.type, equals(const LwwRegister()));
    });

    test('round-trips a document', () {
      final doc = {
        'id': 'n1',
        'title': 'A',
        'meta': {'pinned': true}
      };
      expect(_roundTrip(strategy, doc), equals(doc));
    });
  });

  group('ShallowMergeStrategy', () {
    const strategy = ShallowMergeStrategy();

    test('gives each top-level field its own entry', () {
      final doc = {'id': 'n1', 'title': 'A', 'content': 'B'};
      expect(_paths(strategy, doc), containsAll(['id', 'title', 'content']));
      expect(_values(strategy, doc)['title'], equals('A'));
    });

    test('types every field last-write-wins', () {
      final doc = {'id': 'n1', 'title': 'A'};
      expect(
        strategy.fields(doc).map((f) => f.type),
        everyElement(equals(const LwwRegister())),
      );
    });

    test('keeps nested objects atomic', () {
      final doc = {
        'id': 'n1',
        'meta': {
          'color': 'red',
          'tags': ['x', 'y']
        },
      };
      expect(
          _values(strategy, doc)['meta'],
          equals({
            'color': 'red',
            'tags': ['x', 'y']
          }));
    });

    test('round-trips a document', () {
      final doc = {'id': 'n1', 'title': 'A', 'content': 'B'};
      expect(_roundTrip(strategy, doc), equals(doc));
    });
  });

  group('DeepMergeStrategy', () {
    const strategy = DeepMergeStrategy();

    test('a key containing the separator is rejected, never restructured', () {
      // Each of these used to corrupt silently in a different way: a dotted
      // key turned into nesting, a scalar/dotted collision threw on READ, a
      // nested value was overwritten, or the dotted key's data vanished
      // depending on map order. All four now fail loudly at the first write.
      const offenders = [
        {'id': 'x', 'a.b': 1},
        {'id': 'x', 'a': 1, 'a.b': 2},
        {
          'id': 'x',
          'a': {'b': 1},
          'a.b': 2
        },
        {'id': 'x', 'a.b': 2, 'a': 1},
      ];
      for (final doc in offenders) {
        expect(() => strategy.fields(doc), throwsArgumentError,
            reason: 'document $doc must be rejected');
      }
    });

    test('a separator-bearing key nested deeper is rejected too', () {
      expect(
        () => strategy.fields({
          'id': 'x',
          'a': {'b.c': 1}
        }),
        throwsArgumentError,
      );
    });

    test('a custom separator moves the constraint with it', () {
      const piped = DeepMergeStrategy(pathSeparator: '|');
      // Dotted keys are fine under a pipe separator...
      final values = _values(piped, {'id': 'x', 'a.b': 1});
      expect(values['a.b'], 1);
      // ...and pipes are the reserved character instead.
      expect(() => piped.fields({'id': 'x', 'a|b': 1}), throwsArgumentError);
    });

    test('unflatten skips a peer row whose path descends through a scalar', () {
      // fields() can never produce these rows, but a synced peer can send
      // them; a poisoned path must degrade to one missing field, never to a
      // throw that kills every read of the collection.
      expect(
        strategy.unflatten([
          (path: 'id', value: 'd1'),
          (path: 'a', value: 1),
          (path: 'a.b', value: 2),
        ]),
        {'id': 'd1', 'a': 1},
        reason: 'the row under an existing scalar is dropped',
      );
      // The other arrival order degrades the other way: the scalar row
      // overwrites the synthesised nesting. Either way, no throw.
      expect(
        strategy.unflatten([
          (path: 'id', value: 'd1'),
          (path: 'a.b', value: 2),
          (path: 'a', value: 1),
        ]),
        {'id': 'd1', 'a': 1},
      );
    });

    test('flattens nested maps into dotted paths', () {
      final doc = {
        'id': 'n1',
        'meta': {
          'color': 'red',
          'author': {'name': 'Ada'}
        },
      };
      final values = _values(strategy, doc);
      expect(values['id'], equals('n1'));
      expect(values['meta.color'], equals('red'));
      expect(values['meta.author.name'], equals('Ada'));
    });

    test('types every leaf last-write-wins', () {
      final doc = {
        'meta': {'color': 'red'}
      };
      expect(
        strategy.fields(doc).map((f) => f.type),
        everyElement(equals(const LwwRegister())),
      );
    });

    test('treats lists as atomic leaves', () {
      final doc = {
        'id': 'n1',
        'tags': ['x', 'y'],
      };
      expect(_values(strategy, doc)['tags'], equals(['x', 'y']));
    });

    test('preserves empty nested objects', () {
      final doc = {'id': 'n1', 'meta': <String, dynamic>{}};
      expect(_roundTrip(strategy, doc), equals(doc));
    });

    test('round-trips a deeply nested document', () {
      final doc = {
        'id': 'n1',
        'meta': {
          'color': 'red',
          'author': {'name': 'Ada', 'verified': true},
        },
        'tags': ['x', 'y'],
      };
      expect(_roundTrip(strategy, doc), equals(doc));
    });

    test('honours a custom path separator', () {
      const sep = DeepMergeStrategy(pathSeparator: '/');
      final doc = {
        'a': {'b': 1},
      };
      expect(_paths(sep, doc).single, equals('a/b'));
      expect(_roundTrip(sep, doc), equals(doc));
    });
  });
}
