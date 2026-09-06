import 'dart:async';
import 'dart:convert';

import 'package:conclave_core/conclave_core.dart';
import 'package:crdt/crdt.dart' show Hlc;
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Test helpers

class _MemStore implements BlobStore {
  final Map<String, List<int>> _data = {};

  @override
  Future<void> open() async {}

  @override
  Future<List<int>?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, List<int> bytes) async =>
      _data[key] = List.of(bytes);

  @override
  Future<void> delete(String key) async => _data.remove(key);

  @override
  Future<List<String>> keys({String? prefix}) async => prefix == null
      ? _data.keys.toList()
      : _data.keys.where((k) => k.startsWith(prefix)).toList();

  @override
  Future<void> close() async {}
}

/// A simple document model for tests.
class _Doc {
  _Doc(this.id, {this.title, this.count});
  final String id;
  String? title;
  int? count;

  _Doc.fromMap(Map<String, dynamic> m)
      : id = m['id'] as String,
        title = m['title'] as String?,
        count = m['count'] as int?;

  Map<String, dynamic> toMap() => {
        'id': id,
        if (title != null) 'title': title,
        if (count != null) 'count': count,
      };

  static final codec = JsonCodec<_Doc>(
    toMap: (d) => d.toMap(),
    fromMap: (m) => _Doc.fromMap(m),
    idOf: (d) => d.id,
  );

  @override
  bool operator ==(Object other) =>
      other is _Doc &&
      other.id == id &&
      other.title == title &&
      other.count == count;

  @override
  int get hashCode => Object.hash(id, title, count);

  @override
  String toString() => '_Doc($id, title: $title, count: $count)';
}

// ---------------------------------------------------------------------------
// Tests

void main() {
  group('LazyCrdtTable via Collection', () {
    late _MemStore store;

    setUp(() {
      store = _MemStore();
    });

    Collection<_Doc> openCol({
      MergeStrategy merge = const ShallowMergeStrategy(),
      List<String> indexedFields = const [],
    }) {
      return Collection.create<_Doc>(
        'test',
        _Doc.codec,
        store,
        merge: merge,
        table: LazyCrdtTable('test', store),
        indexedFields: indexedFields,
      );
    }

    test('put and get a document', () async {
      final col = openCol();
      await col.ready;
      await col.put(_Doc('a', title: 'hello', count: 1));
      final doc = await col.get('a');
      expect(doc, equals(_Doc('a', title: 'hello', count: 1)));
    });

    test('all returns live documents', () async {
      final col = openCol();
      await col.ready;
      await col.put(_Doc('a', title: 'alpha'));
      await col.put(_Doc('b', title: 'beta'));
      expect(col.length, 2);
      expect(await col.all(), hasLength(2));
    });

    test('delete tombstones without removing blob', () async {
      final col = openCol();
      await col.ready;
      await col.put(_Doc('a', title: 'hello'));
      await col.delete('a');
      expect(await col.get('a'), isNull);
      expect(col.length, 0);

      // The per-document blob still exists (tombstone retained).
      final blobKeys = await store.keys(prefix: 'test/d/');
      expect(blobKeys, hasLength(1));
    });

    test('get returns null for absent key', () async {
      final col = openCol();
      await col.ready;
      expect(await col.get('nonexistent'), isNull);
    });

    test('length is 0 on empty collection', () async {
      final col = openCol();
      await col.ready;
      expect(col.length, 0);
    });

    test('data survives reopen (same store, new engine)', () async {
      final col1 = openCol();
      await col1.ready;
      await col1.put(_Doc('a', title: 'hello'));
      await col1.put(_Doc('b', title: 'world'));

      // Open a new collection on the same store.
      final col2 = openCol();
      await col2.ready;
      expect(col2.length, 2);
      expect(await col2.get('a'), equals(_Doc('a', title: 'hello')));
      expect(await col2.get('b'), equals(_Doc('b', title: 'world')));
    });

    test('blob count = document count, not record count', () async {
      final col = openCol(merge: ShallowMergeStrategy());
      await col.ready;
      await col.put(_Doc('a', title: 'hello', count: 42));

      final blobKeys = await store.keys(prefix: 'test/d/');
      expect(blobKeys, hasLength(1));

      final blob = await store.read(blobKeys.first);
      expect(blob, isNotNull);
      final parsed = Map<String, Map<String, dynamic>>.from(
        jsonDecode(String.fromCharCodes(blob!)) as Map,
      );
      // The blob should contain the existence register + field records.
      expect(parsed.keys, contains('a'));
      expect(parsed.keys, contains('a\x1Ftitle'));
      expect(parsed.keys, contains('a\x1Fcount'));
      expect(parsed['a']?['v'], isTrue); // existence register is true
      expect(parsed['a\x1Ftitle']?['v'], 'hello');
      expect(parsed['a\x1Fcount']?['v'], 42);
    });

    test('mergeChangeset converges two collections', () async {
      final colA = openCol();
      final colB = openCol();
      await Future.wait([colA.ready, colB.ready]);

      await colA.put(_Doc('a', title: 'from A'));
      final changeset = await colA.getChangeset();

      await colB.mergeChangeset(changeset);
      expect(await colB.get('a'), equals(_Doc('a', title: 'from A')));
    });

    test('mergeChangeset handles concurrent edits', () async {
      final colA = openCol();
      final colB = openCol();
      await Future.wait([colA.ready, colB.ready]);

      await colA.put(_Doc('x', count: 1));
      await colB.put(_Doc('x', count: 2));

      // Peer A sends to B; B's version wins (same HLC counter + node tie-break).
      await colB.mergeChangeset(await colA.getChangeset());
      // B should have count=2 (its own edit is later by canonical time).
      expect((await colB.get('x'))!.count, 2);
    });

    test('watch emits after put and merge', () async {
      final col = openCol();
      await col.ready;

      final emitted = <List<_Doc>>[];
      col.watch().listen(emitted.add);

      // Give the stream listener time to attach.
      await Future<void>.delayed(Duration.zero);

      await col.put(_Doc('a', title: 'first'));
      await Future<void>.delayed(Duration.zero);
      expect(emitted.length, greaterThanOrEqualTo(1));
    });

    /// Injects [records] via [Collection.mergeChangeset] so we can supply
    /// backdated HLC values the model object normally wouldn't produce.
    Future<void> inject(
      Collection<_Doc> col,
      Iterable<Map<String, Object?>> records,
    ) =>
        col.mergeChangeset({col.name: records.toList()});

    test('compact removes old tombstones', () async {
      final col = openCol();
      await col.ready;

      await col.put(_Doc('b', title: 'still-alive'));

      // Inject an old tombstone (HLC dated 2020).
      final old = Hlc(DateTime.utc(2020, 1, 1), 0, 'test');
      await inject(col, [
        {'key': 'a', 'value': null, 'is_deleted': true, 'hlc': old},
        {'key': 'a\x1F', 'value': null, 'is_deleted': true, 'hlc': old},
      ]);

      expect(col.length, 1, reason: 'only b is alive');
      final reclaimed = await col.compact(horizon: const Duration(days: 1));
      expect(reclaimed, greaterThan(0));
      expect(col.length, 1);
      expect(await col.get('b'), equals(_Doc('b', title: 'still-alive')));
    });

    test('compact reclaims field tombstones', () async {
      final col = openCol(merge: ShallowMergeStrategy());
      await col.ready;

      await col.put(_Doc('a', title: 'hello'));
      // Inject old field tombstone for 'count'.
      final old = Hlc(DateTime.utc(2020, 1, 1), 0, 'test');
      await inject(col, [
        {'key': 'a\x1Fcount', 'value': null, 'is_deleted': true, 'hlc': old},
      ]);

      final reclaimed = await col.compact(horizon: const Duration(days: 1));
      expect(reclaimed, greaterThan(0));
      expect(await col.get('a'), equals(_Doc('a', title: 'hello')));
    });

    test('reopen after data survives blob format round-trip', () async {
      final col1 = openCol();
      await col1.ready;
      await col1.put(_Doc('x', title: 'round', count: 7));
      await col1.put(_Doc('y', title: 'trip'));

      // Reopen with a fresh engine.
      final col2 = openCol();
      await col2.ready;
      expect(col2.length, 2);
      expect(await col2.get('x'), equals(_Doc('x', title: 'round', count: 7)));
      expect(await col2.get('y'), equals(_Doc('y', title: 'trip')));

      // Verify the blob store format matches _persistDocuments.
      final raw = await store.read('test/d/x');
      expect(raw, isNotNull);
      final decoded = String.fromCharCodes(raw!);
      // Should contain the expected fields.
      expect(decoded, contains('"v":'));
      expect(decoded, contains('"d":'));
      expect(decoded, contains('"h":'));
    });

    test('secondary index works with lazy engine', () async {
      final col = openCol(
        merge: ShallowMergeStrategy(),
        indexedFields: ['title'],
      );
      await col.ready;

      await col.put(_Doc('a', title: 'same'));
      await col.put(_Doc('b', title: 'same'));
      await col.put(_Doc('c', title: 'unique'));

      expect(await col.findBy('title', 'same'), hasLength(2));
      expect(await col.findBy('title', 'unique'), hasLength(1));
      expect(await col.findBy('title', 'missing'), isEmpty);
    });

    test('large collection does not overflow (smoke test)', () async {
      final col = openCol();
      await col.ready;

      // Insert 500 documents.
      for (var i = 0; i < 500; i++) {
        await col.put(_Doc('doc$i', title: 'title$i', count: i));
      }
      expect(col.length, 500);

      // Read them all back.
      final all = await col.all();
      expect(all, hasLength(500));

      // Delete half.
      for (var i = 0; i < 250; i++) {
        await col.delete('doc$i');
      }
      expect(col.length, 250);
    });
  });
}
