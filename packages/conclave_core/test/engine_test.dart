import 'dart:async';

import 'package:conclave_core/conclave_core.dart';
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

class _MemKeyStore implements KeyStore {
  final Map<String, List<int>> _keys = {};

  @override
  Future<List<int>?> getKey(String databaseId) async => _keys[databaseId];

  @override
  Future<void> setKey(String databaseId, List<int> key) async =>
      _keys[databaseId] = key;

  @override
  Future<void> clear(String databaseId) async => _keys.remove(databaseId);
}

/// XOR cipher used for tests — intentionally NOT AES to keep tests fast.
class _XorCipher implements Cipher {
  _XorCipher(List<int> key) : _key = key[0];
  final int _key;

  @override
  Future<List<int>> encrypt(List<int> p) async {
    final xored = p.map((b) => b ^ _key).toList();
    return [0xAC ^ _key, 0xED ^ _key, ...xored];
  }

  @override
  Future<List<int>> decrypt(List<int> c) async {
    if (c.length < 2 || (c[0] ^ _key) != 0xAC || (c[1] ^ _key) != 0xED) {
      throw const CipherAuthError();
    }
    return c.skip(2).map((b) => b ^ _key).toList();
  }
}

/// Model used in tests.
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

/// Multi-field model used to exercise field-granular merge strategies.
class _Card {
  _Card({required this.id, required this.title, required this.body});

  final String id;
  final String title;
  final String body;

  _Card copyWith({String? title, String? body}) =>
      _Card(id: id, title: title ?? this.title, body: body ?? this.body);

  static final codec = JsonCodec<_Card>(
    toMap: (c) => {'id': c.id, 'title': c.title, 'body': c.body},
    fromMap: (m) => _Card(
      id: m['id'] as String,
      title: m['title'] as String,
      body: m['body'] as String,
    ),
    idOf: (c) => c.id,
  );
}

/// Builds a minimal [Conclave] for tests.
Future<Conclave> _openConclave(InMemoryBus bus, {String appId = 'test'}) =>
    Conclave.open(
      config: ConclaveConfig(appId: appId, salt: '$appId:v1'),
      store: (_) => _MemStore(),
      keyStore: _MemKeyStore(),
      transport: InMemoryTransport(bus),
      deriveKey: (passphrase, salt) async =>
          List<int>.generate(32, (i) => passphrase.codeUnitAt(i % passphrase.length) ^ i),
      roomTag: (key) => key.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      cipher: _XorCipher.new,
      mnemonicGenerator: (words) => List.generate(words, (i) => 'word$i'),
      idMaskerFactory: (key) => (id) => id,
    );

/// Builds a [Conclave] whose stores persist across reopen calls, keyed by
/// database id, and whose key store and bus are caller-supplied so they too
/// survive a `close()`/reopen cycle.
Future<Conclave> _openPersistentConclave(
  InMemoryBus bus,
  Map<String, _MemStore> stores,
  _MemKeyStore keyStore, {
  String appId = 'test',
}) =>
    Conclave.open(
      config: ConclaveConfig(appId: appId, salt: '$appId:v1'),
      store: (id) => stores.putIfAbsent(id, _MemStore.new),
      keyStore: keyStore,
      transport: InMemoryTransport(bus),
      deriveKey: (passphrase, salt) async => List<int>.generate(
          32, (i) => passphrase.codeUnitAt(i % passphrase.length) ^ i),
      roomTag: (key) =>
          key.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      cipher: _XorCipher.new,
      mnemonicGenerator: (words) => List.generate(words, (i) => 'word$i'),
      idMaskerFactory: (key) => (id) => id,
    );

/// Derives a 32-byte test key from [passphrase] (mirrors the `deriveKey`
/// injected into `_openPersistentConclave`).
List<int> _xorDerive(String passphrase) => List<int>.generate(
      32, (i) => passphrase.codeUnitAt(i % passphrase.length) ^ i);

// ---------------------------------------------------------------------------

void main() {
  group('Engine convergence', () {
    late InMemoryBus bus;
    late Conclave nodeA;
    late Conclave nodeB;

    setUp(() async {
      bus = InMemoryBus();
      nodeA = await _openConclave(bus);
      nodeB = await _openConclave(bus);
    });

    tearDown(() async {
      await nodeA.close();
      await nodeB.close();
    });

    test('put on A converges to B', () async {
      const passphrase = 'one two three four five six seven eight nine ten eleven twelve';
      final dbA = await nodeA.openDatabase('notes', passphrase: passphrase);
      final dbB = await nodeB.openDatabase('notes', passphrase: passphrase);

      final notesA = dbA.collection<_Note>('notes', _Note.codec);
      final notesB = dbB.collection<_Note>('notes', _Note.codec);

      // Wait for the first item from B's stream (which includes the synced note).
      final bStream = notesB.watch().where((list) => list.isNotEmpty).first;

      await notesA.put(_Note(id: 'n1', text: 'Hello'));

      final bNotes = await bStream.timeout(const Duration(seconds: 5));
      expect(bNotes, hasLength(1));
      expect(bNotes.first.text, equals('Hello'));
    });

    test('concurrent edits both survive on both nodes', () async {
      const passphrase = 'word0 word1 word2 word3 word4 word5 word6 word7 word8 word9 word10 word11';
      final dbA = await nodeA.openDatabase('notes', passphrase: passphrase);
      final dbB = await nodeB.openDatabase('notes', passphrase: passphrase);

      final notesA = dbA.collection<_Note>('notes', _Note.codec);
      final notesB = dbB.collection<_Note>('notes', _Note.codec);

      // Both write different documents.
      await notesA.put(_Note(id: 'na', text: 'From A'));
      await notesB.put(_Note(id: 'nb', text: 'From B'));

      // Both should see 2 notes eventually.
      final aDone = notesA.watch().where((l) => l.length == 2).first;
      final bDone = notesB.watch().where((l) => l.length == 2).first;

      await Future.wait([
        aDone.timeout(const Duration(seconds: 5)),
        bDone.timeout(const Duration(seconds: 5)),
      ]);

      expect(notesA.all.map((n) => n.id), containsAll(['na', 'nb']));
      expect(notesB.all.map((n) => n.id), containsAll(['na', 'nb']));
    });

    test('delete propagates', () async {
      const passphrase = 'word0 word1 word2 word3 word4 word5 word6 word7 word8 word9 word10 word11';
      final dbA = await nodeA.openDatabase('notes', passphrase: passphrase);
      final dbB = await nodeB.openDatabase('notes', passphrase: passphrase);

      final notesA = dbA.collection<_Note>('notes', _Note.codec);
      final notesB = dbB.collection<_Note>('notes', _Note.codec);

      await notesA.put(_Note(id: 'n1', text: 'To delete'));
      await notesB.watch().where((l) => l.isNotEmpty).first
          .timeout(const Duration(seconds: 5));

      await notesA.delete('n1');
      await notesB.watch().where((l) => l.isEmpty).first
          .timeout(const Duration(seconds: 5));

      expect(notesB.get('n1'), isNull);
    });

    test('successive local writes both propagate (delta watermark)', () async {
      const passphrase =
          'word0 word1 word2 word3 word4 word5 word6 word7 word8 word9 word10 word11';
      final dbA = await nodeA.openDatabase('notes', passphrase: passphrase);
      final dbB = await nodeB.openDatabase('notes', passphrase: passphrase);

      final notesA = dbA.collection<_Note>('notes', _Note.codec);
      final notesB = dbB.collection<_Note>('notes', _Note.codec);

      await notesA.put(_Note(id: 'n1', text: 'first'));
      await notesA.put(_Note(id: 'n2', text: 'second'));

      await notesB.watch().where((l) => l.length == 2).first
          .timeout(const Duration(seconds: 5));
      expect(notesB.all.map((n) => n.id), containsAll(['n1', 'n2']));
    });
  });

  group('Field-level merge', () {
    late InMemoryBus bus;
    late Conclave nodeA;
    late Conclave nodeB;

    setUp(() async {
      bus = InMemoryBus();
      nodeA = await _openConclave(bus);
      nodeB = await _openConclave(bus);
    });

    tearDown(() async {
      await nodeA.close();
      await nodeB.close();
    });

    test('object mode loses one of two concurrent field edits', () async {
      const passphrase = 'word0 word1 word2 word3 word4 word5 word6 word7 word8 word9 word10 word11';
      final dbA = await nodeA.openDatabase('cards', passphrase: passphrase);
      final dbB = await nodeB.openDatabase('cards', passphrase: passphrase);

      final cardsA = dbA.collection<_Card>('cards', _Card.codec);
      final cardsB = dbB.collection<_Card>('cards', _Card.codec);

      // Seed a shared card and let both nodes observe it.
      await cardsA.put(_Card(id: 'c1', title: 'Title', body: 'Body'));
      await cardsB.watch().where((l) => l.isNotEmpty).first
          .timeout(const Duration(seconds: 5));

      // Concurrent edits to DIFFERENT fields of the same document.
      await cardsA.put(cardsA.get('c1')!.copyWith(title: 'Edited by A'));
      await cardsB.put(cardsB.get('c1')!.copyWith(body: 'Edited by B'));

      // Let the two writes propagate and converge.
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final a = cardsA.get('c1')!;
      final b = cardsB.get('c1')!;
      // Both nodes converge to the SAME whole-document winner...
      expect(a.title, equals(b.title));
      expect(a.body, equals(b.body));
      // ...but at least one of the two edits is lost (whole-document LWW).
      final lostAnEdit = a.title != 'Edited by A' || a.body != 'Edited by B';
      expect(lostAnEdit, isTrue);
    });

    test('shallow mode keeps concurrent edits to different fields', () async {
      const passphrase = 'word0 word1 word2 word3 word4 word5 word6 word7 word8 word9 word10 word11';
      final dbA = await nodeA.openDatabase('cards', passphrase: passphrase);
      final dbB = await nodeB.openDatabase('cards', passphrase: passphrase);

      const merge = ShallowMergeStrategy();
      final cardsA = dbA.collection<_Card>('cards', _Card.codec, merge: merge);
      final cardsB = dbB.collection<_Card>('cards', _Card.codec, merge: merge);

      await cardsA.put(_Card(id: 'c1', title: 'Title', body: 'Body'));
      await cardsB.watch().where((l) => l.isNotEmpty).first
          .timeout(const Duration(seconds: 5));

      await cardsA.put(cardsA.get('c1')!.copyWith(title: 'Edited by A'));
      await cardsB.put(cardsB.get('c1')!.copyWith(body: 'Edited by B'));

      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Both field edits survive on both nodes.
      for (final cards in [cardsA, cardsB]) {
        final c = cards.get('c1')!;
        expect(c.title, equals('Edited by A'));
        expect(c.body, equals('Edited by B'));
      }
    });

    test('shallow mode keeps a deleted document fully gone, not partial', () async {
      const passphrase = 'word0 word1 word2 word3 word4 word5 word6 word7 word8 word9 word10 word11';
      final dbA = await nodeA.openDatabase('cards', passphrase: passphrase);
      final dbB = await nodeB.openDatabase('cards', passphrase: passphrase);

      const merge = ShallowMergeStrategy();
      final cardsA = dbA.collection<_Card>('cards', _Card.codec, merge: merge);
      final cardsB = dbB.collection<_Card>('cards', _Card.codec, merge: merge);

      await cardsA.put(_Card(id: 'c1', title: 'Title', body: 'Body'));
      await cardsB.watch().where((l) => l.isNotEmpty).first
          .timeout(const Duration(seconds: 5));

      // Delete on A wins the existence register over B's later non-edit.
      await cardsA.delete('c1');
      await cardsB.watch().where((l) => l.isEmpty).first
          .timeout(const Duration(seconds: 5));

      // The document is fully absent on both nodes — never a partial record.
      expect(cardsA.get('c1'), isNull);
      expect(cardsB.get('c1'), isNull);
      expect(cardsA.all, isEmpty);
      expect(cardsB.all, isEmpty);
    });

    test('shallow mode: a later edit revives a concurrently deleted document with all fields', () async {
      const passphrase = 'word0 word1 word2 word3 word4 word5 word6 word7 word8 word9 word10 word11';
      final dbA = await nodeA.openDatabase('cards', passphrase: passphrase);
      final dbB = await nodeB.openDatabase('cards', passphrase: passphrase);

      const merge = ShallowMergeStrategy();
      final cardsA = dbA.collection<_Card>('cards', _Card.codec, merge: merge);
      final cardsB = dbB.collection<_Card>('cards', _Card.codec, merge: merge);

      await cardsA.put(_Card(id: 'c1', title: 'Title', body: 'Body'));
      await cardsB.watch().where((l) => l.isNotEmpty).first
          .timeout(const Duration(seconds: 5));

      // A deletes; B then edits a single field. B's edit refreshes the
      // existence register with a higher HLC, so the document stays alive.
      await cardsA.delete('c1');
      await cardsB.put(cardsB.get('c1')!.copyWith(title: 'Revived'));

      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Both converge to a complete document — never one missing `body`.
      for (final cards in [cardsA, cardsB]) {
        final c = cards.get('c1');
        expect(c, isNotNull);
        expect(c!.title, equals('Revived'));
        expect(c.body, equals('Body'));
      }
    });
  });

  group('Multi-database isolation', () {
    test('different passphrases do not cross-contaminate', () async {
      final bus = InMemoryBus();
      final nodeA = await _openConclave(bus);
      final nodeB = await _openConclave(bus);

      const ppAlpha = 'alpha one two three four five six seven eight nine ten eleven';
      const ppBeta  = 'beta  one two three four five six seven eight nine ten eleven';

      final dbAlphaA = await nodeA.openDatabase('alpha', passphrase: ppAlpha);
      final dbBetaA  = await nodeA.openDatabase('beta',  passphrase: ppBeta);
      final dbBetaB  = await nodeB.openDatabase('beta',  passphrase: ppBeta);

      final notesAlpha = dbAlphaA.collection<_Note>('notes', _Note.codec);
      final notesBetaA = dbBetaA.collection<_Note>('notes', _Note.codec);
      final notesBetaB = dbBetaB.collection<_Note>('notes', _Note.codec);

      await notesAlpha.put(_Note(id: 'secret', text: 'Alpha only'));
      await notesBetaA.put(_Note(id: 'shared', text: 'Beta'));

      // Beta/B should see the Beta note, never the Alpha note.
      await notesBetaB.watch().where((l) => l.isNotEmpty).first
          .timeout(const Duration(seconds: 5));

      expect(notesBetaB.get('shared'), isNotNull);
      expect(notesBetaB.get('secret'), isNull);

      await nodeA.close();
      await nodeB.close();
    });
  });

  group('generatePassphrase', () {
    test('returns correct word count', () async {
      final bus = InMemoryBus();
      final c = await _openConclave(bus);
      expect(c.generatePassphrase(), hasLength(24));
      await c.close();
    });

    test('respects configured word count', () async {
      final bus = InMemoryBus();
      final c = await Conclave.open(
        config: ConclaveConfig(
          appId: 'test',
          salt: 'test:v1',
          passphrasePolicy: const PassphrasePolicy(words: 12),
        ),
        store: (_) => _MemStore(),
        keyStore: _MemKeyStore(),
        transport: InMemoryTransport(bus),
        deriveKey: (p, s) async => List.filled(32, 0),
        roomTag: (_) => 'room',
        cipher: _XorCipher.new,
        mnemonicGenerator: (words) => List.generate(words, (i) => 'w$i'),
        idMaskerFactory: (key) => (id) => id,
      );
      expect(c.generatePassphrase(), hasLength(12));
      await c.close();
    });
  });

  group('Key lifecycle', () {
    test('wrong passphrase does not clobber a valid key', () async {
      final bus = InMemoryBus();
      final stores = <String, _MemStore>{};
      final keyStore = _MemKeyStore();

      const good = 'one two three four five six seven eight nine ten a b';
      const bad = 'zzz two three four five six seven eight nine ten a b';

      // First open writes data with the good key.
      var c = await _openPersistentConclave(bus, stores, keyStore);
      var db = await c.openDatabase('notes', passphrase: good);
      await db.collection<_Note>('notes', _Note.codec)
          .put(_Note(id: 'n1', text: 'secret'));
      await c.close(); // keeps the key

      // Reopen with a WRONG passphrase: must throw and must not overwrite the key.
      c = await _openPersistentConclave(bus, stores, keyStore);
      await expectLater(
        c.openDatabase('notes', passphrase: bad),
        throwsA(isA<WrongPassphraseException>()),
      );

      // Reopen with the CORRECT passphrase still works and sees the data.
      db = await c.openDatabase('notes', passphrase: good);
      final notes = db.collection<_Note>('notes', _Note.codec);
      await notes.watch().where((l) => l.isNotEmpty).first
          .timeout(const Duration(seconds: 5));
      expect(notes.get('n1')?.text, equals('secret'));
      await c.close();
    });

    test('reopenDatabase restores data without a passphrase', () async {
      final bus = InMemoryBus();
      final stores = <String, _MemStore>{};
      final keyStore = _MemKeyStore();
      const pp = 'one two three four five six seven eight nine ten a b';

      var c = await _openPersistentConclave(bus, stores, keyStore);
      var db = await c.openDatabase('notes', passphrase: pp);
      await db.collection<_Note>('notes', _Note.codec)
          .put(_Note(id: 'n1', text: 'hello'));
      await c.close();

      c = await _openPersistentConclave(bus, stores, keyStore);
      db = await c.reopenDatabase('notes'); // no passphrase
      final notes = db.collection<_Note>('notes', _Note.codec);
      await notes.watch().where((l) => l.isNotEmpty).first
          .timeout(const Duration(seconds: 5));
      expect(notes.get('n1')?.text, equals('hello'));
      await c.close();
    });

    test('reopenDatabase throws when no key is stored', () async {
      final bus = InMemoryBus();
      final c = await _openPersistentConclave(
          bus, <String, _MemStore>{}, _MemKeyStore());
      await expectLater(
        c.reopenDatabase('never-opened'),
        throwsStateError,
      );
      await c.close();
    });

    test('forget deletes the key; subsequent reopen fails', () async {
      final bus = InMemoryBus();
      final stores = <String, _MemStore>{};
      final keyStore = _MemKeyStore();
      const pp = 'one two three four five six seven eight nine ten a b';

      final c = await _openPersistentConclave(bus, stores, keyStore);
      await c.openDatabase('notes', passphrase: pp);
      expect(await keyStore.getKey('test/notes'), isNotNull);

      await c.forget('notes');
      expect(await keyStore.getKey('test/notes'), isNull);

      await expectLater(c.reopenDatabase('notes'), throwsStateError);
      await c.close();
    });
  });

  group('rotatePassphrase', () {
    test('re-encrypts data and allows reopen with new passphrase', () async {
      final bus = InMemoryBus();
      final stores = <String, _MemStore>{};
      final keyStore = _MemKeyStore();
      const pp1 =
          'one two three four five six seven eight nine ten eleven twelve';
      const pp2 =
          'two three four five six seven eight nine ten eleven twelve thirteen';

      final c = await _openPersistentConclave(bus, stores, keyStore);
      try {
        // Open with pp1 and write some data.
        var db = await c.openDatabase('notes', passphrase: pp1);
        final col = db.collection('items', _Note.codec);
        await col.put(_Note(id: 'k1', text: 'v1'));
        await col.put(_Note(id: 'k2', text: 'v2'));
        await db.close();

        // Rotate to pp2.
        await c.rotatePassphrase(
          'notes',
          oldPassphrase: pp1,
          newPassphrase: pp2,
        );

        // Reopen with pp2 — must see the data.
        db = await c.openDatabase('notes', passphrase: pp2);
        final col2 = db.collection('items', _Note.codec);
        await col2.ready;
        expect(col2.get('k1')?.text, 'v1');
        expect(col2.get('k2')?.text, 'v2');
        await db.close();
      } finally {
        await c.close();
      }
    });

    test('reopenDatabase works after rotation', () async {
      final bus = InMemoryBus();
      final stores = <String, _MemStore>{};
      final keyStore = _MemKeyStore();
      const pp1 =
          'one two three four five six seven eight nine ten eleven twelve';
      const pp2 =
          'two three four five six seven eight nine ten eleven twelve thirteen';

      final c = await _openPersistentConclave(bus, stores, keyStore);
      try {
        var db = await c.openDatabase('notes', passphrase: pp1);
        final col = db.collection('items', _Note.codec);
        await col.put(_Note(id: 'k1', text: 'v1'));
        await db.close();

        await c.rotatePassphrase(
          'notes',
          oldPassphrase: pp1,
          newPassphrase: pp2,
        );

        // reopenDatabase must pick up the new key from the key store.
        db = await c.reopenDatabase('notes');
        final col2 = db.collection('items', _Note.codec);
        await col2.ready;
        expect(col2.get('k1')?.text, 'v1');
        await db.close();
      } finally {
        await c.close();
      }
    });

    test('throws WrongPassphraseException on wrong old passphrase', () async {
      final bus = InMemoryBus();
      final stores = <String, _MemStore>{};
      final keyStore = _MemKeyStore();
      const pp =
          'one two three four five six seven eight nine ten eleven twelve';

      final c = await _openPersistentConclave(bus, stores, keyStore);
      try {
        var db = await c.openDatabase('notes', passphrase: pp);
        final col = db.collection('items', _Note.codec);
        await col.put(_Note(id: 'k1', text: 'v1'));
        await db.close();

        await expectLater(
          c.rotatePassphrase(
            'notes',
            oldPassphrase:
                'wrong wrong wrong wrong wrong wrong wrong wrong wrong wrong wrong wrong',
            newPassphrase:
                'new new new new new new new new new new new new',
          ),
          throwsA(isA<WrongPassphraseException>()),
        );
      } finally {
        await c.close();
      }
    });

    test('works on a fresh database with no data', () async {
      final bus = InMemoryBus();
      final stores = <String, _MemStore>{};
      final keyStore = _MemKeyStore();
      const pp1 =
          'one two three four five six seven eight nine ten eleven twelve';
      const pp2 =
          'two three four five six seven eight nine ten eleven twelve thirteen';

      final c = await _openPersistentConclave(bus, stores, keyStore);
      try {
        // No data written — just open and close.
        var db = await c.openDatabase('notes', passphrase: pp1);
        await db.close();

        // Rotation on an empty store should be a no-op.
        await c.rotatePassphrase(
          'notes',
          oldPassphrase: pp1,
          newPassphrase: pp2,
        );

        // Should open with the new passphrase.
        db = await c.openDatabase('notes', passphrase: pp2);
        await db.close();
      } finally {
        await c.close();
      }
    });

    test('works when database is still open', () async {
      final bus = InMemoryBus();
      final stores = <String, _MemStore>{};
      final keyStore = _MemKeyStore();
      const pp1 =
          'one two three four five six seven eight nine ten eleven twelve';
      const pp2 =
          'two three four five six seven eight nine ten eleven twelve thirteen';

      final c = await _openPersistentConclave(bus, stores, keyStore);
      try {
        // Open with pp1 and write data, but KEEP it open.
        var db = await c.openDatabase('notes', passphrase: pp1);
        final col = db.collection('items', _Note.codec);
        await col.put(_Note(id: 'k1', text: 'v1'));
        // db is still open here.

        await c.rotatePassphrase(
          'notes',
          oldPassphrase: pp1,
          newPassphrase: pp2,
        );

        // Database was closed during rotation. Reopen with new passphrase.
        db = await c.openDatabase('notes', passphrase: pp2);
        final col2 = db.collection('items', _Note.codec);
        await col2.ready;
        expect(col2.get('k1')?.text, 'v1');
        await db.close();
      } finally {
        await c.close();
      }
    });

    test('old passphrase fails after rotation', () async {
      final bus = InMemoryBus();
      final stores = <String, _MemStore>{};
      final keyStore = _MemKeyStore();
      const pp1 =
          'one two three four five six seven eight nine ten eleven twelve';
      const pp2 =
          'two three four five six seven eight nine ten eleven twelve thirteen';

      final c = await _openPersistentConclave(bus, stores, keyStore);
      try {
        var db = await c.openDatabase('notes', passphrase: pp1);
        final col = db.collection('items', _Note.codec);
        await col.put(_Note(id: 'k1', text: 'v1'));
        await db.close();

        await c.rotatePassphrase(
          'notes',
          oldPassphrase: pp1,
          newPassphrase: pp2,
        );

        // Old passphrase must no longer decrypt the re-encrypted data.
        await expectLater(
          () => c.openDatabase('notes', passphrase: pp1),
          throwsA(isA<WrongPassphraseException>()),
        );
      } finally {
        await c.close();
      }
    });

    test('interrupted rotation is resumable with new passphrase', () async {
      final bus = InMemoryBus();
      final stores = <String, _MemStore>{};
      final keyStore = _MemKeyStore();
      const pp1 =
          'one two three four five six seven eight nine ten eleven twelve';
      const pp2 =
          'two three four five six seven eight nine ten eleven twelve thirteen';

      final c = await _openPersistentConclave(bus, stores, keyStore);
      try {
        // Write two documents so there are at least two blobs.
        var db = await c.openDatabase('notes', passphrase: pp1);
        final col = db.collection('items', _Note.codec);
        await col.put(_Note(id: 'k1', text: 'v1'));
        await col.put(_Note(id: 'k2', text: 'v2'));
        await db.close();

        // Simulate an interrupted rotation: re-encrypt only the first blob.
        final oldKey = await keyStore.getKey('test/notes');
        final newKey = _xorDerive(pp2);
        final oldCipher = _XorCipher(oldKey!);
        final newCipher = _XorCipher(newKey);
        final raw = stores['notes']!;
        final blobKeys = await raw.keys();
        final first = blobKeys.first;
        final encrypted = await raw.read(first);
        if (encrypted != null) {
          final plaintext = await oldCipher.decrypt(encrypted);
          final reEncrypted = await newCipher.encrypt(plaintext);
          await raw.write(first, reEncrypted);
        }
        // Do NOT store the new key — simulate a crash before KeyStore update.
        // Also store rotate_* keys as rotatePassphrase would have done.
        await keyStore.setKey('test/notes.rotate_backup', oldKey);
        await keyStore.setKey('test/notes.rotate_new', newKey);

        // Recovery with the NEW passphrase should complete the rotation.
        db = await c.openDatabase('notes', passphrase: pp2);

        // All data must be intact and readable with the new key.
        final col2 = db.collection('items', _Note.codec);
        await col2.ready;
        expect(col2.get('k1')?.text, 'v1');
        expect(col2.get('k2')?.text, 'v2');
        await db.close();
      } finally {
        await c.close();
      }
    });

    test('interrupted rotation is reversable with old passphrase', () async {
      final bus = InMemoryBus();
      final stores = <String, _MemStore>{};
      final keyStore = _MemKeyStore();

      const pp1 =
          'one two three four five six seven eight nine ten eleven twelve';
      const pp2 =
          'two three four five six seven eight nine ten eleven twelve thirteen';

      final c = await _openPersistentConclave(bus, stores, keyStore);
      try {
        var db = await c.openDatabase('notes', passphrase: pp1);
        final col = db.collection('items', _Note.codec);
        await col.put(_Note(id: 'k1', text: 'v1'));
        await db.close();

        // Simulate interrupted rotation: first blob re-encrypted to new key.
        final oldKey = await keyStore.getKey('test/notes');
        final newKey = _xorDerive(pp2);
        final oldCipher = _XorCipher(oldKey!);
        final newCipher = _XorCipher(newKey);
        final raw = stores['notes']!;
        final blobKeys = await raw.keys();
        final encrypted = await raw.read(blobKeys.first);
        if (encrypted != null) {
          final plaintext = await oldCipher.decrypt(encrypted);
          final reEncrypted = await newCipher.encrypt(plaintext);
          await raw.write(blobKeys.first, reEncrypted);
        }
        await keyStore.setKey('test/notes.rotate_backup', oldKey);
        await keyStore.setKey('test/notes.rotate_new', newKey);

        // Recovery with the OLD passphrase should reverse the rotation.
        db = await c.openDatabase('notes', passphrase: pp1);
        final col2 = db.collection('items', _Note.codec);
        await col2.ready;
        expect(col2.get('k1')?.text, 'v1');
        await db.close();

        // The stored key is the old key, so reopenDatabase also works.
        db = await c.reopenDatabase('notes');
        final col3 = db.collection('items', _Note.codec);
        await col3.ready;
        expect(col3.get('k1')?.text, 'v1');
        await db.close();
      } finally {
        await c.close();
      }
    });

    test('reopenDatabase after interrupted rotation completes forward', () async {
      final bus = InMemoryBus();
      final stores = <String, _MemStore>{};
      final keyStore = _MemKeyStore();

      const pp1 =
          'one two three four five six seven eight nine ten eleven twelve';
      const pp2 =
          'two three four five six seven eight nine ten eleven twelve thirteen';

      final c = await _openPersistentConclave(bus, stores, keyStore);
      Conclave? c2;
      try {
        var db = await c.openDatabase('notes', passphrase: pp1);
        final col = db.collection('items', _Note.codec);
        await col.put(_Note(id: 'k1', text: 'v1'));
        await db.close();

        // Simulate interrupted rotation: first blob re-encrypted to new key.
        final oldKey = await keyStore.getKey('test/notes');
        final newKey = _xorDerive(pp2);
        final oldCipher = _XorCipher(oldKey!);
        final newCipher = _XorCipher(newKey);
        final raw = stores['notes']!;
        final blobKeys = await raw.keys();
        final encrypted = await raw.read(blobKeys.first);
        if (encrypted != null) {
          final plaintext = await oldCipher.decrypt(encrypted);
          final reEncrypted = await newCipher.encrypt(plaintext);
          await raw.write(blobKeys.first, reEncrypted);
        }
        await keyStore.setKey('test/notes.rotate_backup', oldKey);
        await keyStore.setKey('test/notes.rotate_new', newKey);

        // hasPendingRotation should detect the interrupted rotation.
        expect(await c.hasPendingRotation('notes'), isTrue);

        // reopenDatabase (no passphrase) should complete the rotation forward.
        // Simulate an app restart by closing the whole Conclave and opening a
        // fresh one (so _databases is empty and the full reopen path runs).
        await c.close();
        c2 = await _openPersistentConclave(bus, stores, keyStore);

        db = await c2.reopenDatabase('notes');
        final col2 = db.collection('items', _Note.codec);
        await col2.ready;
        expect(col2.get('k1')?.text, 'v1');

        // The stored key is now the new key (rotation completed forward).
        final storedKey = await keyStore.getKey('test/notes');
        expect(storedKey?[0], _xorDerive(pp2)[0]);
        await db.close();

        // hasPendingRotation is now resolved.
        expect(await c2.hasPendingRotation('notes'), isFalse);
      } finally {
        await c.close();
        await c2?.close();
      }
    });

    test('rotatePassphrase skips a corrupt blob without bricking', () async {
      final bus = InMemoryBus();
      final stores = <String, _MemStore>{};
      final keyStore = _MemKeyStore();
      const pp1 =
          'one two three four five six seven eight nine ten eleven twelve';
      const pp2 =
          'two three four five six seven eight nine ten eleven twelve thirteen';

      final c = await _openPersistentConclave(bus, stores, keyStore);
      try {
        var db = await c.openDatabase('notes', passphrase: pp1);
        final col = db.collection('items', _Note.codec);
        await col.put(_Note(id: 'k1', text: 'v1'));
        await col.put(_Note(id: 'k2', text: 'v2'));
        await db.close();

        // Corrupt the second blob (the first blob must be intact for
        // validation to pass).
        final raw = stores['notes']!;
        final blobKeys = await raw.keys();
        if (blobKeys.length > 1) {
          await raw.write(blobKeys.elementAt(1), [0, 0, 0, 0]);
        }

        // Rotation must complete without crashing; the corrupt blob is
        // skipped, the healthy blob is re-encrypted.
        await c.rotatePassphrase(
          'notes',
          oldPassphrase: pp1,
          newPassphrase: pp2,
        );

        db = await c.openDatabase('notes', passphrase: pp2);
        final col2 = db.collection('items', _Note.codec);
        await col2.ready;
        // The document behind the corrupt blob may or may not survive
        // depending on merge strategy, but the rotation must not throw.
        expect(col2.get('k1')?.text, 'v1');
        await db.close();
      } finally {
        await c.close();
      }
    });

    test('rotatePassphrase rejects wrong old passphrase after interruption',
        () async {
      final bus = InMemoryBus();
      final stores = <String, _MemStore>{};
      final keyStore = _MemKeyStore();
      const pp1 =
          'one two three four five six seven eight nine ten eleven twelve';
      const pp2 =
          'two three four five six seven eight nine ten eleven twelve thirteen';
      const wrong =
          'wrong wrong wrong wrong wrong wrong wrong wrong wrong wrong wrong wrong';

      final c = await _openPersistentConclave(bus, stores, keyStore);
      try {
        final db = await c.openDatabase('notes', passphrase: pp1);
        final col = db.collection('items', _Note.codec);
        await col.put(_Note(id: 'k1', text: 'v1'));
        await db.close();

        // Simulate interrupted rotation: first blob re-encrypted to new key.
        final oldKey = await keyStore.getKey('test/notes');
        final newKey = _xorDerive(pp2);
        final oldCipher = _XorCipher(oldKey!);
        final newCipher = _XorCipher(newKey);
        final raw = stores['notes']!;
        final blobKeys = await raw.keys();
        final encrypted = await raw.read(blobKeys.first);
        if (encrypted != null) {
          final plaintext = await oldCipher.decrypt(encrypted);
          final reEncrypted = await newCipher.encrypt(plaintext);
          await raw.write(blobKeys.first, reEncrypted);
        }
        await keyStore.setKey('test/notes.rotate_backup', oldKey);
        await keyStore.setKey('test/notes.rotate_new', newKey);

        // Calling rotatePassphrase with a wrong old passphrase must fail even
        // though the first blob happens to be decryptable with the new key.
        await expectLater(
          () => c.rotatePassphrase(
            'notes',
            oldPassphrase: wrong,
            newPassphrase: pp2,
          ),
          throwsA(isA<WrongPassphraseException>()),
        );
      } finally {
        await c.close();
      }
    });

    test('peers converge after both rotate', () async {
      final bus = InMemoryBus();
      final storesA = <String, _MemStore>{};
      final storesB = <String, _MemStore>{};
      final keyStoreA = _MemKeyStore();
      final keyStoreB = _MemKeyStore();
      const pp1 =
          'one two three four five six seven eight nine ten eleven twelve';
      const pp2 =
          'two three four five six seven eight nine ten eleven twelve thirteen';

      final nodeA = await _openPersistentConclave(
        bus, storesA, keyStoreA,
        appId: 'converge',
      );
      final nodeB = await _openPersistentConclave(
        bus, storesB, keyStoreB,
        appId: 'converge',
      );
      try {
        // Both open with pp1 and sync.
        var dbA = await nodeA.openDatabase('notes', passphrase: pp1);
        var dbB = await nodeB.openDatabase('notes', passphrase: pp1);
        final colA = dbA.collection('items', _Note.codec);
        final colB = dbB.collection('items', _Note.codec);
        await colA.put(_Note(id: 'k1', text: 'from A before'));
        await colB.watch().where((l) => l.isNotEmpty).first
            .timeout(const Duration(seconds: 5));
        await dbA.close();
        await dbB.close();

        // Both rotate to pp2.
        await nodeA.rotatePassphrase(
          'notes',
          oldPassphrase: pp1,
          newPassphrase: pp2,
        );
        await nodeB.rotatePassphrase(
          'notes',
          oldPassphrase: pp1,
          newPassphrase: pp2,
        );

        // Reopen both with pp2 and verify convergence.
        dbA = await nodeA.openDatabase('notes', passphrase: pp2);
        dbB = await nodeB.openDatabase('notes', passphrase: pp2);
        final colA2 = dbA.collection('items', _Note.codec);
        final colB2 = dbB.collection('items', _Note.codec);
        await colA2.ready;
        await colB2.ready;
        expect(colA2.get('k1')?.text, 'from A before');
        expect(colB2.get('k1')?.text, 'from A before');

        // A makes a change after rotation; B must receive it.
        await colA2.put(_Note(id: 'k2', text: 'from A after'));
        await colB2.watch().where((l) => l.length >= 2).first
            .timeout(const Duration(seconds: 5));
        expect(colB2.get('k2')?.text, 'from A after');
        await dbA.close();
        await dbB.close();
      } finally {
        await nodeA.close();
        await nodeB.close();
      }
    });
  });

  group('Collection.length', () {
    test('zero on a fresh collection', () async {
      final bus = InMemoryBus();
      final c = await _openConclave(bus);
      var db = await c.openDatabase(
          'notes', passphrase: 'one two three four five six seven eight nine ten eleven twelve');
      final notes = db.collection<_Note>('notes', _Note.codec);
      await notes.ready;
      expect(notes.length, equals(0));
      await c.close();
    });

    test('increases after put', () async {
      final bus = InMemoryBus();
      final c = await _openConclave(bus);
      var db = await c.openDatabase(
          'notes', passphrase: 'one two three four five six seven eight nine ten eleven twelve');
      final notes = db.collection<_Note>('notes', _Note.codec);
      await notes.ready;
      await notes.put(_Note(id: 'n1', text: 'a'));
      expect(notes.length, equals(1));
      await notes.put(_Note(id: 'n2', text: 'b'));
      expect(notes.length, equals(2));
      await c.close();
    });

    test('decreases after delete', () async {
      final bus = InMemoryBus();
      final c = await _openConclave(bus);
      var db = await c.openDatabase(
          'notes', passphrase: 'one two three four five six seven eight nine ten eleven twelve');
      final notes = db.collection<_Note>('notes', _Note.codec);
      await notes.ready;
      await notes.put(_Note(id: 'n1', text: 'a'));
      await notes.put(_Note(id: 'n2', text: 'b'));
      expect(notes.length, equals(2));
      await notes.delete('n1');
      expect(notes.length, equals(1));
      await c.close();
    });

    test('matches all.length', () async {
      final bus = InMemoryBus();
      final c = await _openConclave(bus);
      var db = await c.openDatabase(
          'notes', passphrase: 'one two three four five six seven eight nine ten eleven twelve');
      final notes = db.collection<_Note>('notes', _Note.codec);
      await notes.ready;
      expect(notes.length, equals(notes.all.length));
      await notes.put(_Note(id: 'n1', text: 'a'));
      expect(notes.length, equals(notes.all.length));
      await notes.put(_Note(id: 'n2', text: 'b'));
      expect(notes.length, equals(notes.all.length));
      await notes.delete('n1');
      expect(notes.length, equals(notes.all.length));
      await c.close();
    });

    test('survives restore', () async {
      final bus = InMemoryBus();
      final stores = <String, _MemStore>{};
      final keyStore = _MemKeyStore();
      const pp = 'one two three four five six seven eight nine ten a b';

      var c = await _openPersistentConclave(bus, stores, keyStore);
      var db = await c.openDatabase('notes', passphrase: pp);
      var notes = db.collection<_Note>('notes', _Note.codec);
      await notes.ready;
      await notes.put(_Note(id: 'n1', text: 'a'));
      await notes.put(_Note(id: 'n2', text: 'b'));
      expect(notes.length, equals(2));
      await c.close();

      c = await _openPersistentConclave(bus, stores, keyStore);
      db = await c.reopenDatabase('notes');
      notes = db.collection<_Note>('notes', _Note.codec);
      await notes.ready;
      expect(notes.length, equals(2));
      await c.close();
    });
  });

  group('Inbound rate limiting', () {
    test('normal frame rate is not throttled', () async {
      final bus = InMemoryBus();
      final nodeA = await _openConclave(bus);
      final nodeB = await _openConclave(bus);
      const pp = 'one two three four five six seven eight nine ten eleven twelve';

      final dbA = await nodeA.openDatabase('notes', passphrase: pp);
      final dbB = await nodeB.openDatabase('notes', passphrase: pp);
      final colA = dbA.collection<_Note>('notes', _Note.codec);
      final colB = dbB.collection<_Note>('notes', _Note.codec);

      await colA.put(_Note(id: 'n1', text: 'a'));
      await colA.put(_Note(id: 'n2', text: 'b'));

      await colB.watch().where((l) => l.length == 2).first
          .timeout(const Duration(seconds: 5));
      expect(colB.all, hasLength(2));

      await nodeA.close();
      await nodeB.close();
    });

    test('excessive inbound frames from a peer are silently dropped', () async {
      final bus = InMemoryBus();
      final transportB = InMemoryTransport(bus);
      final nodeB = await Conclave.open(
        config: ConclaveConfig(
          appId: 'test',
          salt: 'test:v1',
          maxInboundFramesPerSecond: 5,
        ),
        store: (_) => _MemStore(),
        keyStore: _MemKeyStore(),
        transport: transportB,
        deriveKey: (p, s) async =>
            List<int>.generate(32, (i) => p.codeUnitAt(i % p.length) ^ i),
        roomTag: (k) =>
            k.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        cipher: _XorCipher.new,
        mnemonicGenerator: (words) => List.generate(words, (i) => 'w$i'),
        idMaskerFactory: (key) => (id) => id,
      );
      final nodeA = await _openConclave(bus);
      const pp = 'one two three four five six seven eight nine ten eleven twelve';

      final dbA = await nodeA.openDatabase('notes', passphrase: pp);
      final dbB = await nodeB.openDatabase('notes', passphrase: pp);
      final colA = dbA.collection<_Note>('notes', _Note.codec);
      final colB = dbB.collection<_Note>('notes', _Note.codec);

      // Watch B for the burst writes before they happen.
      final burstDone = colB.watch().where((l) => l.length >= 20).first;

      // Send many rapid writes — more than the 5 fps limit allows.
      for (int i = 0; i < 20; i++) {
        await colA.put(_Note(id: 'n$i', text: '$i'));
      }

      // B should NOT receive all 20 (many are rate-limited).  Use a short
      // timeout so the test does not hang if they did all arrive.
      await expectLater(
        burstDone.timeout(const Duration(milliseconds: 300)),
        throwsA(isA<TimeoutException>()),
      );

      // After the rate window expires a new write gets through.
      await Future<void>.delayed(const Duration(seconds: 2));
      await colA.put(_Note(id: 'last', text: 'last'));
      await colB.watch().where((l) => l.any((n) => n.id == 'last')).first
          .timeout(const Duration(seconds: 5));
      expect(colB.get('last')?.text, equals('last'));

      await nodeA.close();
      await nodeB.close();
    });

    test('a noisy peer does not starve other peers', () async {
      final bus = InMemoryBus();
      final transportC = InMemoryTransport(bus);
      final nodeC = await Conclave.open(
        config: ConclaveConfig(
          appId: 'test',
          salt: 'test:v1',
          maxInboundFramesPerSecond: 5,
        ),
        store: (_) => _MemStore(),
        keyStore: _MemKeyStore(),
        transport: transportC,
        deriveKey: (p, s) async =>
            List<int>.generate(32, (i) => p.codeUnitAt(i % p.length) ^ i),
        roomTag: (k) =>
            k.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        cipher: _XorCipher.new,
        mnemonicGenerator: (words) => List.generate(words, (i) => 'w$i'),
        idMaskerFactory: (key) => (id) => id,
      );
      final nodeA = await _openConclave(bus);
      final nodeB = await _openConclave(bus);
      const pp = 'one two three four five six seven eight nine ten eleven twelve';

      final dbA = await nodeA.openDatabase('notes', passphrase: pp);
      final dbB = await nodeB.openDatabase('notes', passphrase: pp);
      final dbC = await nodeC.openDatabase('notes', passphrase: pp);
      final colA = dbA.collection<_Note>('notes', _Note.codec);
      final colB = dbB.collection<_Note>('notes', _Note.codec);
      final colC = dbC.collection<_Note>('notes', _Note.codec);

      // Watch B and C before the burst.
      final bDone = colB.watch().where((l) => l.length == 20).first;
      final cBurst = colC.watch().where((l) => l.length >= 20).first;

      // A floods the bus with rapid writes.
      for (int i = 0; i < 20; i++) {
        await colA.put(_Note(id: 'n$i', text: '$i'));
      }

      // B (normal, no limit) gets all 20.
      await bDone.timeout(const Duration(seconds: 5));
      expect(colB.all, hasLength(20));

      // C (rate-limited) does NOT get all 20 within the rate window.
      await expectLater(
        cBurst.timeout(const Duration(milliseconds: 300)),
        throwsA(isA<TimeoutException>()),
      );

      await nodeA.close();
      await nodeB.close();
      await nodeC.close();
    });
  });

  group('forceSync recovery', () {
    test('recovers data lost during rate limiting', () async {
      final bus = InMemoryBus();
      final transportB = InMemoryTransport(bus);
      final nodeB = await Conclave.open(
        config: ConclaveConfig(
          appId: 'test',
          salt: 'test:v1',
          maxInboundFramesPerSecond: 5,
        ),
        store: (_) => _MemStore(),
        keyStore: _MemKeyStore(),
        transport: transportB,
        deriveKey: (p, s) async =>
            List<int>.generate(32, (i) => p.codeUnitAt(i % p.length) ^ i),
        roomTag: (k) =>
            k.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        cipher: _XorCipher.new,
        mnemonicGenerator: (words) => List.generate(words, (i) => 'w$i'),
        idMaskerFactory: (key) => (id) => id,
      );
      final nodeA = await _openConclave(bus);
      const pp = 'one two three four five six seven eight nine ten eleven twelve';

      final dbA = await nodeA.openDatabase('notes', passphrase: pp);
      final dbB = await nodeB.openDatabase('notes', passphrase: pp);
      final colA = dbA.collection<_Note>('notes', _Note.codec);
      final colB = dbB.collection<_Note>('notes', _Note.codec);

      // Watch B for the burst.
      final burstDone = colB.watch().where((l) => l.length >= 20).first;

      // A floods — most deltas get rate-limited on B.
      for (int i = 0; i < 20; i++) {
        await colA.put(_Note(id: 'n$i', text: '$i'));
      }

      // Confirm B is missing data.
      await expectLater(
        burstDone.timeout(const Duration(milliseconds: 300)),
        throwsA(isA<TimeoutException>()),
      );
      final countBefore = colB.all.length;
      expect(countBefore, lessThan(10));

      // Let the rate window expire, then force sync from A.
      await Future<void>.delayed(const Duration(seconds: 2));
      await nodeA.forceSync();

      // B now receives all 20.
      await colB.watch().where((l) => l.length == 20).first
          .timeout(const Duration(seconds: 5));
      expect(colB.all, hasLength(20));

      await nodeA.close();
      await nodeB.close();
    });

    test('forceSync pulls data the caller was missing', () async {
      // Only nodeA is rate-limited. B writes while A's inbound is restricted;
      // A then calls forceSync and receives the missing data via SyncRequest.
      final bus = InMemoryBus();
      final transportA = InMemoryTransport(bus);
      final nodeA = await Conclave.open(
        config: ConclaveConfig(
          appId: 'test',
          salt: 'test:v1',
          maxInboundFramesPerSecond: 5,
        ),
        store: (_) => _MemStore(),
        keyStore: _MemKeyStore(),
        transport: transportA,
        deriveKey: (p, s) async =>
            List<int>.generate(32, (i) => p.codeUnitAt(i % p.length) ^ i),
        roomTag: (k) =>
            k.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        cipher: _XorCipher.new,
        mnemonicGenerator: (words) => List.generate(words, (i) => 'w$i'),
        idMaskerFactory: (key) => (id) => id,
      );
      final nodeB = await _openConclave(bus);
      const pp = 'one two three four five six seven eight nine ten eleven twelve';

      final dbA = await nodeA.openDatabase('notes', passphrase: pp);
      final dbB = await nodeB.openDatabase('notes', passphrase: pp);
      final colA = dbA.collection<_Note>('notes', _Note.codec);
      final colB = dbB.collection<_Note>('notes', _Note.codec);

      // A writes 5 docs — B receives all 5 (normal sync, no rate limit on B).
      for (int i = 0; i < 5; i++) {
        await colA.put(_Note(id: 'n$i', text: 'a$i'));
      }
      await colB.watch().where((l) => l.length == 5).first
          .timeout(const Duration(seconds: 5));

      // B writes 15 more docs rapidly — A's 5 fps limit drops some.
      for (int i = 5; i < 20; i++) {
        await colB.put(_Note(id: 'n$i', text: 'b$i'));
      }

      // Confirm A does NOT have all 20.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(colA.all.length, lessThan(20));

      // Let the rate window expire, then force sync from A.
      await Future<void>.delayed(const Duration(seconds: 2));
      await nodeA.forceSync();

      // A receives the missing docs via the Poke → Hello back exchange.
      await colA.watch().where((l) => l.length == 20).first
          .timeout(const Duration(seconds: 5));
      expect(colA.all, hasLength(20));
      // B has everything too.
      expect(colB.all, hasLength(20));

      await nodeA.close();
      await nodeB.close();
    });
  });

  group('Conflict observer', () {
    late InMemoryBus bus;
    late Conclave nodeA;
    late Conclave nodeB;

    setUp(() async {
      bus = InMemoryBus();
      nodeA = await _openConclave(bus);
      nodeB = await _openConclave(bus);
    });

    tearDown(() async {
      await nodeA.close();
      await nodeB.close();
    });

    test('fires when remote edit overwrites an existing document', () async {
      const pp = 'one two three four five six seven eight nine ten eleven twelve';
      final dbA = await nodeA.openDatabase('notes', passphrase: pp);
      final dbB = await nodeB.openDatabase('notes', passphrase: pp);

      final notesA = dbA.collection<_Note>('notes', _Note.codec);
      dbB.collection<_Note>('notes', _Note.codec);

      // Use a dedicated collection on a third node for observer testing.
      final bus = InMemoryBus();
      final nodeC = await _openConclave(bus);
      final dbC = await nodeC.openDatabase('notes', passphrase: pp);
      final conflicts = <String>[];
      final notesC = dbC.collection<_Note>('notes', _Note.codec,
        onRemoteConflict: (id) => conflicts.add(id),
      );
      await notesC.ready;

      // Seed A with a document, then copy the entire changeset to C.
      await notesA.put(_Note(id: 'n1', text: 'Hello'));
      final seed = notesA.getChangeset();
      await notesC.mergeChangeset(seed);
      expect(conflicts, isEmpty);

      // Update the same document on A, then copy the full changeset to C.
      // HLC timestamps on the second write are newer, so the merge will
      // overwrite C's version — and since n1 already exists locally, the
      // conflict observer fires.
      await notesA.put(_Note(id: 'n1', text: 'World'));
      final update = notesA.getChangeset();
      await notesC.mergeChangeset(update);

      expect(conflicts, contains('n1'));

      await nodeC.close();
    });

    test('does not fire when the document did not exist locally', () async {
      const pp = 'one two three four five six seven eight nine ten eleven twelve';
      final dbA = await nodeA.openDatabase('notes', passphrase: pp);
      final dbB = await nodeB.openDatabase('notes', passphrase: pp);

      final conflicts = <String>[];
      final notesA = dbA.collection<_Note>('notes', _Note.codec);
      final notesB = dbB.collection<_Note>('notes', _Note.codec,
        onRemoteConflict: (id) => conflicts.add(id),
      );

      // A writes two documents; B has never seen either.
      await notesA.put(_Note(id: 'n1', text: 'a'));
      await notesA.put(_Note(id: 'n2', text: 'b'));
      await notesB.watch().where((l) => l.length == 2).first
          .timeout(const Duration(seconds: 5));

      // Neither existed locally on B before the merge, so no conflicts.
      expect(conflicts, isEmpty);
    });
  });
}
