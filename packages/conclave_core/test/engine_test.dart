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
      clock: SystemHlcClock.new,
      deriveKey: (passphrase, salt) async =>
          List<int>.generate(32, (i) => passphrase.codeUnitAt(i % passphrase.length) ^ i),
      roomTag: (key) => key.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      cipher: _XorCipher.new,
      mnemonicGenerator: (words) => List.generate(words, (i) => 'word$i'),
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
      clock: SystemHlcClock.new,
      deriveKey: (passphrase, salt) async => List<int>.generate(
          32, (i) => passphrase.codeUnitAt(i % passphrase.length) ^ i),
      roomTag: (key) =>
          key.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      cipher: _XorCipher.new,
      mnemonicGenerator: (words) => List.generate(words, (i) => 'word$i'),
    );

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
          passphrase: const PassphrasePolicy(words: 12),
        ),
        store: (_) => _MemStore(),
        keyStore: _MemKeyStore(),
        transport: InMemoryTransport(bus),
        clock: SystemHlcClock.new,
        deriveKey: (p, s) async => List.filled(32, 0),
        roomTag: (_) => 'room',
        cipher: _XorCipher.new,
        mnemonicGenerator: (words) => List.generate(words, (i) => 'w$i'),
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
}
