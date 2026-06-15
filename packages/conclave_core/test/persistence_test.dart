import 'dart:convert';

import 'package:conclave_core/conclave_core.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Test helpers

class _MemStore implements BlobStore {
  final Map<String, List<int>> data = {};

  @override
  Future<void> open() async {}

  @override
  Future<List<int>?> read(String key) async => data[key];

  @override
  Future<void> write(String key, List<int> bytes) async =>
      data[key] = List.of(bytes);

  @override
  Future<void> delete(String key) async => data.remove(key);

  @override
  Future<List<String>> keys({String? prefix}) async => prefix == null
      ? data.keys.toList()
      : data.keys.where((k) => k.startsWith(prefix)).toList();

  @override
  Future<void> close() async {}
}

/// Wraps a [_MemStore] and counts [write] calls.
class _SpyStore extends _MemStore {
  int writeCount = 0;

  @override
  Future<void> write(String key, List<int> bytes) async {
    writeCount++;
    return super.write(key, bytes);
  }
}

class _Note {
  _Note({required this.id, required this.text});

  final String id;
  final String text;

  static final codec = JsonCodec<_Note>(
    toMap: (n) => {'id': n.id, 'text': n.text},
    fromMap: (m) => _Note(id: m['id'] as String, text: m['text'] as String),
    idOf: (n) => n.id,
  );
}

// ---------------------------------------------------------------------------

void main() {
  group('Per-document persistence', () {
    test('1. a single put writes exactly one blob, not N+1', () async {
      final store = _SpyStore();
      final col = Collection.create<_Note>('notes', _Note.codec, store);
      await col.ready;

      // Write 100 initial docs.
      for (int i = 0; i < 100; i++) {
        await col.put(_Note(id: 'n$i', text: 'text$i'));
      }

      final countBefore = store.writeCount;

      // One additional put must trigger exactly one write.
      await col.put(_Note(id: 'new', text: 'hello'));

      expect(store.writeCount - countBefore, equals(1));
    });

    test('2. round-trip: documents survive close and reopen', () async {
      final store = _MemStore();

      // Write some documents.
      final col1 = Collection.create<_Note>('notes', _Note.codec, store);
      await col1.ready;
      await col1.put(_Note(id: 'a', text: 'alpha'));
      await col1.put(_Note(id: 'b', text: 'beta'));

      // Simulate reopen by creating a new Collection over the same store.
      final col2 = Collection.create<_Note>('notes', _Note.codec, store);
      await col2.ready;

      expect(col2.get('a')?.text, equals('alpha'));
      expect(col2.get('b')?.text, equals('beta'));
      expect(col2.all(), hasLength(2));
    });

    test('3. delete retains a tombstone blob (not a hard delete)', () async {
      final store = _MemStore();
      final col = Collection.create<_Note>('notes', _Note.codec, store);
      await col.ready;

      await col.put(_Note(id: 'doc1', text: 'hello'));
      await col.delete('doc1');

      // The blob must still exist in the store (tombstone retained).
      final blobKeys = await store.keys(prefix: 'notes/d/');
      expect(blobKeys, isNotEmpty);

      // The collection correctly reports the document as absent.
      expect(col.get('doc1'), isNull);
      expect(col.all(), isEmpty);

      // The stored blob contains the tombstoned existence register.
      final bytes = store.data[blobKeys.first]!;
      final raw = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      // The bare-id entry is deleted.
      final existenceEntry = raw['doc1'] as Map<String, dynamic>?;
      expect(existenceEntry, isNotNull);
      expect(existenceEntry!['d'], isTrue);
    });

    test('4. mergeChangeset writes only touched documents', () async {
      final store = _SpyStore();
      final colA = Collection.create<_Note>('notes', _Note.codec, store);
      await colA.ready;

      // Seed 100 docs.
      for (int i = 0; i < 100; i++) {
        await colA.put(_Note(id: 'n$i', text: 'v$i'));
      }

      // Build a changeset that touches only 2 documents.
      final delta = colA.getChangeset();
      final allRecords = delta['notes']!;
      final touched = {'n0', 'n1'};
      final twoDocRecords = allRecords
          .where((r) {
            final key = r['key'] as String;
            final sep = key.indexOf('\x1F');
            final id = sep < 0 ? key : key.substring(0, sep);
            return touched.contains(id);
          })
          .map((r) => Map<String, Object?>.from(r))
          .toList();
      final changeset = {'notes': twoDocRecords};

      // A second collection over a clean store receives the merge.
      final store2 = _SpyStore();
      final colB = Collection.create<_Note>('notes', _Note.codec, store2);
      await colB.ready;

      final writesBefore = store2.writeCount;
      await colB.mergeChangeset(changeset);

      // Exactly 2 blobs written (one per touched document).
      expect(store2.writeCount - writesBefore, equals(2));
    });

    test('5. key masker hides doc ids; data still round-trips', () async {
      final rawStore = _MemStore();
      const docId = 'secret-document-id';

      // A simple test masker so we can easily verify the raw id is absent.
      String testMasker(String id) => 'masked${id.hashCode.abs()}';

      final col = Collection.create<_Note>(
        'notes',
        _Note.codec,
        rawStore,
        idMasker: testMasker,
      );
      await col.ready;
      await col.put(_Note(id: docId, text: 'sensitive'));

      // The raw store must not contain the plaintext doc id in any key.
      final storedKeys = await rawStore.keys();
      for (final k in storedKeys) {
        expect(k, isNot(contains(docId)),
            reason: 'plaintext doc id leaked into storage key "$k"');
      }

      // Data still round-trips correctly.
      expect(col.get(docId)?.text, equals('sensitive'));

      // Reopen with the same masker and verify the data is still readable.
      final col2 = Collection.create<_Note>(
        'notes',
        _Note.codec,
        rawStore,
        idMasker: testMasker,
      );
      await col2.ready;
      expect(col2.get(docId)?.text, equals('sensitive'));
    });
  });
}
