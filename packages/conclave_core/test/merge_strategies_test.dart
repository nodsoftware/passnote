import 'package:conclave_core/conclave_core.dart';
import 'package:test/test.dart';

void main() {
  group('ObjectMergeStrategy', () {
    const strategy = ObjectMergeStrategy();

    test('flattens the whole document to a single field', () {
      final doc = {
        'id': 'n1',
        'title': 'A',
        'meta': {'pinned': true}
      };
      final fields = strategy.flatten(doc);
      expect(fields, hasLength(1));
      expect(fields.values.single, equals(doc));
    });

    test('round-trips a document', () {
      final doc = {
        'id': 'n1',
        'title': 'A',
        'meta': {'pinned': true}
      };
      expect(strategy.unflatten(strategy.flatten(doc)), equals(doc));
    });
  });

  group('ShallowMergeStrategy', () {
    const strategy = ShallowMergeStrategy();

    test('gives each top-level field its own entry', () {
      final doc = {'id': 'n1', 'title': 'A', 'content': 'B'};
      final fields = strategy.flatten(doc);
      expect(fields.keys, containsAll(['id', 'title', 'content']));
      expect(fields['title'], equals('A'));
    });

    test('keeps nested objects atomic', () {
      final doc = {
        'id': 'n1',
        'meta': {
          'color': 'red',
          'tags': ['x', 'y']
        },
      };
      final fields = strategy.flatten(doc);
      expect(
          fields['meta'],
          equals({
            'color': 'red',
            'tags': ['x', 'y']
          }));
    });

    test('round-trips a document', () {
      final doc = {'id': 'n1', 'title': 'A', 'content': 'B'};
      expect(strategy.unflatten(strategy.flatten(doc)), equals(doc));
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
      final fields = strategy.flatten(doc);
      expect(fields['id'], equals('n1'));
      expect(fields['meta.color'], equals('red'));
      expect(fields['meta.author.name'], equals('Ada'));
    });

    test('treats lists as atomic leaves', () {
      final doc = {
        'id': 'n1',
        'tags': ['x', 'y'],
      };
      final fields = strategy.flatten(doc);
      expect(fields['tags'], equals(['x', 'y']));
    });

    test('preserves empty nested objects', () {
      final doc = {'id': 'n1', 'meta': <String, dynamic>{}};
      final fields = strategy.flatten(doc);
      expect(strategy.unflatten(fields), equals(doc));
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
      expect(strategy.unflatten(strategy.flatten(doc)), equals(doc));
    });

    test('honours a custom path separator', () {
      const sep = DeepMergeStrategy(pathSeparator: '/');
      final doc = {
        'a': {'b': 1},
      };
      expect(sep.flatten(doc).keys.single, equals('a/b'));
      expect(sep.unflatten(sep.flatten(doc)), equals(doc));
    });
  });
}
