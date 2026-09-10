import 'package:conclave/conclave.dart';
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
