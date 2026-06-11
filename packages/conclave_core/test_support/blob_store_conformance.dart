// ignore_for_file: avoid_print

import 'package:conclave_core/conclave_core.dart';
import 'package:test/test.dart';

/// Runs the full [BlobStore] conformance suite against [factory].
///
/// Pass this function a factory that returns a **fresh, unopened** store for
/// each invocation. The suite calls [BlobStore.open] itself.
///
/// ```dart
/// void main() {
///   runBlobStoreConformance(() => SembastStore(
///     namespace: 'test',
///     factory: databaseFactoryMemory,
///   ));
/// }
/// ```
void runBlobStoreConformance(BlobStore Function() factory) {
  late BlobStore store;

  setUp(() async {
    store = factory();
    await store.open();
  });

  tearDown(() async {
    await store.close();
  });

  test('read returns null for missing key', () async {
    expect(await store.read('missing'), isNull);
  });

  test('write then read round-trips bytes', () async {
    final data = [1, 2, 3, 4, 5];
    await store.write('key1', data);
    expect(await store.read('key1'), equals(data));
  });

  test('overwrite replaces previous value', () async {
    await store.write('key1', [1, 2, 3]);
    await store.write('key1', [9, 8, 7]);
    expect(await store.read('key1'), equals([9, 8, 7]));
  });

  test('delete removes a key', () async {
    await store.write('key1', [1]);
    await store.delete('key1');
    expect(await store.read('key1'), isNull);
  });

  test('delete is a no-op for missing key', () async {
    expect(() => store.delete('nonexistent'), returnsNormally);
  });

  test('keys returns all stored keys', () async {
    await store.write('a', [1]);
    await store.write('b', [2]);
    await store.write('c', [3]);
    expect(await store.keys(), unorderedEquals(['a', 'b', 'c']));
  });

  test('keys with prefix filters correctly', () async {
    await store.write('col/doc1', [1]);
    await store.write('col/doc2', [2]);
    await store.write('other/doc3', [3]);
    final result = await store.keys(prefix: 'col/');
    expect(result, unorderedEquals(['col/doc1', 'col/doc2']));
  });

  test('keys returns empty list for empty store', () async {
    expect(await store.keys(), isEmpty);
  });

  test('empty byte list round-trips', () async {
    await store.write('empty', []);
    expect(await store.read('empty'), equals([]));
  });
}
