import 'dart:async';

import 'package:conclave_core/conclave_core.dart';
import 'package:crdt/crdt.dart' show CrdtChangeset, Hlc;
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Test helpers

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

/// Wraps a codec and counts how many documents are actually decoded, so a test
/// can assert that a paginated/indexed read does not decode the whole
/// collection.
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

/// Wraps a [CrdtTable] and counts engine reads, so a test can assert that a
/// query does not re-scan the table once per matched id.
class _CountingTable implements CrdtTable {
  _CountingTable(this._inner);
  final CrdtTable _inner;
  int liveFieldsCalls = 0;
  int valueCalls = 0;

  @override
  Future<Map<String, Object?>> liveFields(String table, String prefix) {
    liveFieldsCalls++;
    return _inner.liveFields(table, prefix);
  }

  @override
  Future<Object?> value(String table, String key) {
    valueCalls++;
    return _inner.value(table, key);
  }

  @override
  Future<void> put(String table, String key, Object? value,
          {bool isDeleted = false}) =>
      _inner.put(table, key, value, isDeleted: isDeleted);

  @override
  Future<CrdtChangeset> changeset(String table, {String? sinceHlc}) =>
      _inner.changeset(table, sinceHlc: sinceHlc);

  @override
  String maxHlc(String table) => _inner.maxHlc(table);

  @override
  Future<void> merge(CrdtChangeset changeset) => _inner.merge(changeset);

  @override
  bool get isPersistent => false;

  @override
  Future<void> init() async {}

  @override
  Future<int> compact(String table, {required Duration horizon}) async =>
      throw UnsupportedError('not used in tests');

  @override
  Stream<void> watch(String table) => _inner.watch(table);

  @override
  Set<String> liveKeys(String table, String prefix) =>
      _inner.liveKeys(table, prefix);

  @override
  Future<void> close() => _inner.close();

  @override
  Future<void> rekey(List<int> newKey) => _inner.rekey(newKey);

  @override
  Stream<CrdtRecovery> get recoveries => _inner.recoveries;
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
      title: (m['title'] ?? '') as String,
      body: (m['body'] ?? '') as String,
    ),
    idOf: (c) => c.id,
  );
}

/// Builds a minimal [Conclave] for tests.
Future<Conclave> _openConclave(InMemoryBus bus, {String appId = 'test'}) =>
    Conclave.lowLevel(
      config: ConclaveConfig(appId: appId, salt: '$appId:v1'),
      keyStore: _MemKeyStore(),
      transport: InMemoryTransport(bus),
      deriveKey: (passphrase, salt) async => List<int>.generate(
          32, (i) => passphrase.codeUnitAt(i % passphrase.length) ^ i),
      roomTag: (key) =>
          key.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      cipher: _XorCipher.new,
      mnemonicGenerator: (words) => List.generate(words, (i) => 'word$i'),
      validateMnemonic: (_) => true,
      engine: (_, col, __) => MapCrdtTable(col),
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
      const passphrase =
          'one two three four five six seven eight nine ten eleven twelve';
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
      const passphrase =
          'word0 word1 word2 word3 word4 word5 word6 word7 word8 word9 word10 word11';
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

      expect((await notesA.all()).map((n) => n.id), containsAll(['na', 'nb']));
      expect((await notesB.all()).map((n) => n.id), containsAll(['na', 'nb']));
    });

    test('delete propagates', () async {
      const passphrase =
          'word0 word1 word2 word3 word4 word5 word6 word7 word8 word9 word10 word11';
      final dbA = await nodeA.openDatabase('notes', passphrase: passphrase);
      final dbB = await nodeB.openDatabase('notes', passphrase: passphrase);

      final notesA = dbA.collection<_Note>('notes', _Note.codec);
      final notesB = dbB.collection<_Note>('notes', _Note.codec);

      await notesA.put(_Note(id: 'n1', text: 'To delete'));
      await notesB
          .watch()
          .where((l) => l.isNotEmpty)
          .first
          .timeout(const Duration(seconds: 5));

      await notesA.delete('n1');
      await notesB
          .watch()
          .where((l) => l.isEmpty)
          .first
          .timeout(const Duration(seconds: 5));

      expect(await notesB.get('n1'), isNull);
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

      await notesB
          .watch()
          .where((l) => l.length == 2)
          .first
          .timeout(const Duration(seconds: 5));
      expect((await notesB.all()).map((n) => n.id), containsAll(['n1', 'n2']));
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
      const passphrase =
          'word0 word1 word2 word3 word4 word5 word6 word7 word8 word9 word10 word11';
      final dbA = await nodeA.openDatabase('cards', passphrase: passphrase);
      final dbB = await nodeB.openDatabase('cards', passphrase: passphrase);

      final cardsA = dbA.collection<_Card>('cards', _Card.codec);
      final cardsB = dbB.collection<_Card>('cards', _Card.codec);

      // Seed a shared card and let both nodes observe it.
      await cardsA.put(_Card(id: 'c1', title: 'Title', body: 'Body'));
      await cardsB
          .watch()
          .where((l) => l.isNotEmpty)
          .first
          .timeout(const Duration(seconds: 5));

      // Concurrent edits to DIFFERENT fields of the same document.
      await cardsA
          .put((await cardsA.get('c1'))!.copyWith(title: 'Edited by A'));
      await cardsB.put((await cardsB.get('c1'))!.copyWith(body: 'Edited by B'));

      // Let the two writes propagate and converge.
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final a = (await cardsA.get('c1'))!;
      final b = (await cardsB.get('c1'))!;
      // Both nodes converge to the SAME whole-document winner...
      expect(a.title, equals(b.title));
      expect(a.body, equals(b.body));
      // ...but at least one of the two edits is lost (whole-document LWW).
      final lostAnEdit = a.title != 'Edited by A' || a.body != 'Edited by B';
      expect(lostAnEdit, isTrue);
    });

    test('shallow mode keeps concurrent edits to different fields', () async {
      const passphrase =
          'word0 word1 word2 word3 word4 word5 word6 word7 word8 word9 word10 word11';
      final dbA = await nodeA.openDatabase('cards', passphrase: passphrase);
      final dbB = await nodeB.openDatabase('cards', passphrase: passphrase);

      const merge = ShallowMergeStrategy();
      final cardsA = dbA.collection<_Card>('cards', _Card.codec, merge: merge);
      final cardsB = dbB.collection<_Card>('cards', _Card.codec, merge: merge);

      await cardsA.put(_Card(id: 'c1', title: 'Title', body: 'Body'));
      await cardsB
          .watch()
          .where((l) => l.isNotEmpty)
          .first
          .timeout(const Duration(seconds: 5));

      await cardsA
          .put((await cardsA.get('c1'))!.copyWith(title: 'Edited by A'));
      await cardsB.put((await cardsB.get('c1'))!.copyWith(body: 'Edited by B'));

      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Both field edits survive on both nodes.
      for (final cards in [cardsA, cardsB]) {
        final c = (await cards.get('c1'))!;
        expect(c.title, equals('Edited by A'));
        expect(c.body, equals('Edited by B'));
      }
    });

    test('shallow mode keeps a deleted document fully gone, not partial',
        () async {
      const passphrase =
          'word0 word1 word2 word3 word4 word5 word6 word7 word8 word9 word10 word11';
      final dbA = await nodeA.openDatabase('cards', passphrase: passphrase);
      final dbB = await nodeB.openDatabase('cards', passphrase: passphrase);

      const merge = ShallowMergeStrategy();
      final cardsA = dbA.collection<_Card>('cards', _Card.codec, merge: merge);
      final cardsB = dbB.collection<_Card>('cards', _Card.codec, merge: merge);

      await cardsA.put(_Card(id: 'c1', title: 'Title', body: 'Body'));
      await cardsB
          .watch()
          .where((l) => l.isNotEmpty)
          .first
          .timeout(const Duration(seconds: 5));

      // Delete on A wins the existence register over B's later non-edit.
      await cardsA.delete('c1');
      await cardsB
          .watch()
          .where((l) => l.isEmpty)
          .first
          .timeout(const Duration(seconds: 5));

      // The document is fully absent on both nodes — never a partial record.
      expect(await cardsA.get('c1'), isNull);
      expect(await cardsB.get('c1'), isNull);
      expect(await cardsA.all(), isEmpty);
      expect(await cardsB.all(), isEmpty);
    });

    test(
        'shallow mode: a later edit revives a concurrently deleted document with all fields',
        () async {
      const passphrase =
          'word0 word1 word2 word3 word4 word5 word6 word7 word8 word9 word10 word11';
      final dbA = await nodeA.openDatabase('cards', passphrase: passphrase);
      final dbB = await nodeB.openDatabase('cards', passphrase: passphrase);

      const merge = ShallowMergeStrategy();
      final cardsA = dbA.collection<_Card>('cards', _Card.codec, merge: merge);
      final cardsB = dbB.collection<_Card>('cards', _Card.codec, merge: merge);

      await cardsA.put(_Card(id: 'c1', title: 'Title', body: 'Body'));
      await cardsB
          .watch()
          .where((l) => l.isNotEmpty)
          .first
          .timeout(const Duration(seconds: 5));

      // A deletes; B then edits a single field. B's edit refreshes the
      // existence register with a higher HLC, so the document stays alive.
      await cardsA.delete('c1');
      await cardsB.put((await cardsB.get('c1'))!.copyWith(title: 'Revived'));

      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Both converge to a complete document — never one missing `body`.
      for (final cards in [cardsA, cardsB]) {
        final c = await cards.get('c1');
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

      const ppAlpha =
          'alpha one two three four five six seven eight nine ten eleven';
      const ppBeta =
          'beta  one two three four five six seven eight nine ten eleven';

      final dbAlphaA = await nodeA.openDatabase('alpha', passphrase: ppAlpha);
      final dbBetaA = await nodeA.openDatabase('beta', passphrase: ppBeta);
      final dbBetaB = await nodeB.openDatabase('beta', passphrase: ppBeta);

      final notesAlpha = dbAlphaA.collection<_Note>('notes', _Note.codec);
      final notesBetaA = dbBetaA.collection<_Note>('notes', _Note.codec);
      final notesBetaB = dbBetaB.collection<_Note>('notes', _Note.codec);

      await notesAlpha.put(_Note(id: 'secret', text: 'Alpha only'));
      await notesBetaA.put(_Note(id: 'shared', text: 'Beta'));

      // Beta/B should see the Beta note, never the Alpha note.
      await notesBetaB
          .watch()
          .where((l) => l.isNotEmpty)
          .first
          .timeout(const Duration(seconds: 5));

      expect(await notesBetaB.get('shared'), isNotNull);
      expect(await notesBetaB.get('secret'), isNull);

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
      final c = await Conclave.lowLevel(
        config: ConclaveConfig(
          appId: 'test',
          salt: 'test:v1',
          passphrasePolicy: const PassphrasePolicy(words: 12),
        ),
        keyStore: _MemKeyStore(),
        transport: InMemoryTransport(bus),
        deriveKey: (p, s) async => List.filled(32, 0),
        roomTag: (_) => 'room',
        cipher: _XorCipher.new,
        mnemonicGenerator: (words) => List.generate(words, (i) => 'w$i'),
        validateMnemonic: (_) => true,
        engine: (_, col, __) => MapCrdtTable(col),
      );
      expect(c.generatePassphrase(), hasLength(12));
      await c.close();
    });
  });

  group('Key lifecycle', () {
    test('reopenDatabase throws when no key is stored', () async {
      final bus = InMemoryBus();
      final c = await _openConclave(bus);
      await expectLater(
        c.reopenDatabase('never-opened'),
        throwsStateError,
      );
      await c.close();
    });

    test('forget deletes the key; subsequent reopen fails', () async {
      final bus = InMemoryBus();
      const pp = 'one two three four five six seven eight nine ten a b';

      final c = await _openConclave(bus);
      await c.openDatabase('notes', passphrase: pp);
      // reopen works while the key is stored.
      await c.reopenDatabase('notes');

      await c.forget('notes');

      // With the key gone, reopen has nothing to restore.
      await expectLater(c.reopenDatabase('notes'), throwsStateError);
      await c.close();
    });
  });

  group('Passphrase strictness', () {
    test('reject policy throws WeakPassphraseException for weak passphrase',
        () async {
      final bus = InMemoryBus();
      final c = await Conclave.lowLevel(
        config: ConclaveConfig(
          appId: 'strict',
          salt: 'strict:v1',
          passphrasePolicy:
              const PassphrasePolicy(strictness: PassphraseStrictness.reject),
        ),
        keyStore: _MemKeyStore(),
        transport: InMemoryTransport(bus),
        deriveKey: (p, s) async =>
            List<int>.generate(32, (i) => p.codeUnitAt(i % p.length) ^ i),
        roomTag: (_) => 'room',
        cipher: _XorCipher.new,
        mnemonicGenerator: (words) => List.generate(words, (i) => 'w$i'),
        validateMnemonic: (_) => false,
        engine: (_, col, __) => MapCrdtTable(col),
      );
      await expectLater(
        c.openDatabase('notes', passphrase: 'password'),
        throwsA(isA<WeakPassphraseException>()),
      );
      await c.close();
    });

    test('reject policy accepts a valid mnemonic', () async {
      final bus = InMemoryBus();
      final keyStore = _MemKeyStore();
      final c = await Conclave.lowLevel(
        config: ConclaveConfig(
          appId: 'strict',
          salt: 'strict:v1',
          passphrasePolicy:
              const PassphrasePolicy(strictness: PassphraseStrictness.reject),
        ),
        keyStore: keyStore,
        transport: InMemoryTransport(bus),
        deriveKey: (p, s) async =>
            List<int>.generate(32, (i) => p.codeUnitAt(i % p.length) ^ i),
        roomTag: (_) => 'room',
        cipher: _XorCipher.new,
        mnemonicGenerator: (words) => List.generate(words, (i) => 'w$i'),
        validateMnemonic: (_) => true,
        engine: (_, col, __) => MapCrdtTable(col),
      );
      const mnemonic =
          'one two three four five six seven eight nine ten eleven twelve';
      await c.openDatabase('notes', passphrase: mnemonic);
      expect(await keyStore.getKey('strict/notes'), isNotNull);
      await c.close();
    });

    test('warn policy (default) accepts weak passphrase (back-compat)',
        () async {
      final bus = InMemoryBus();
      final keyStore = _MemKeyStore();
      final c = await Conclave.lowLevel(
        config: ConclaveConfig(
          appId: 'lax',
          salt: 'lax:v1',
        ),
        keyStore: keyStore,
        transport: InMemoryTransport(bus),
        deriveKey: (p, s) async =>
            List<int>.generate(32, (i) => p.codeUnitAt(i % p.length) ^ i),
        roomTag: (_) => 'room',
        cipher: _XorCipher.new,
        mnemonicGenerator: (words) => List.generate(words, (i) => 'w$i'),
        validateMnemonic: (_) => false,
        engine: (_, col, __) => MapCrdtTable(col),
      );
      await c.openDatabase('notes', passphrase: 'password');
      expect(await keyStore.getKey('lax/notes'), isNotNull);
      await c.close();
    });

    test(
        'WeakPassphraseException is thrown before any key is written to KeyStore',
        () async {
      final bus = InMemoryBus();
      final keyStore = _MemKeyStore();
      final c = await Conclave.lowLevel(
        config: ConclaveConfig(
          appId: 'strict',
          salt: 'strict:v1',
          passphrasePolicy:
              const PassphrasePolicy(strictness: PassphraseStrictness.reject),
        ),
        keyStore: keyStore,
        transport: InMemoryTransport(bus),
        deriveKey: (p, s) async =>
            List<int>.generate(32, (i) => p.codeUnitAt(i % p.length) ^ i),
        roomTag: (_) => 'room',
        cipher: _XorCipher.new,
        mnemonicGenerator: (words) => List.generate(words, (i) => 'w$i'),
        validateMnemonic: (_) => false,
        engine: (_, col, __) => MapCrdtTable(col),
      );
      await expectLater(
        c.openDatabase('notes', passphrase: 'weak'),
        throwsA(isA<WeakPassphraseException>()),
      );
      // No key should have been stored.
      expect(await keyStore.getKey('strict/notes'), isNull);
      await c.close();
    });
  });

  group('Collection.length', () {
    test('zero on a fresh collection', () async {
      final bus = InMemoryBus();
      final c = await _openConclave(bus);
      final db = await c.openDatabase('notes',
          passphrase:
              'one two three four five six seven eight nine ten eleven twelve');
      final notes = db.collection<_Note>('notes', _Note.codec);
      await notes.ready;
      expect(notes.length, equals(0));
      await c.close();
    });

    test('increases after put', () async {
      final bus = InMemoryBus();
      final c = await _openConclave(bus);
      final db = await c.openDatabase('notes',
          passphrase:
              'one two three four five six seven eight nine ten eleven twelve');
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
      final db = await c.openDatabase('notes',
          passphrase:
              'one two three four five six seven eight nine ten eleven twelve');
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
      final db = await c.openDatabase('notes',
          passphrase:
              'one two three four five six seven eight nine ten eleven twelve');
      final notes = db.collection<_Note>('notes', _Note.codec);
      await notes.ready;
      expect(notes.length, equals((await notes.all()).length));
      await notes.put(_Note(id: 'n1', text: 'a'));
      expect(notes.length, equals((await notes.all()).length));
      await notes.put(_Note(id: 'n2', text: 'b'));
      expect(notes.length, equals((await notes.all()).length));
      await notes.delete('n1');
      expect(notes.length, equals((await notes.all()).length));
      await c.close();
    });
  });

  group('Collection pagination', () {
    test('all(limit: 10) returns exactly 10 docs from 100', () async {
      final col = Collection.create<_Note>('notes', _Note.codec);
      await col.ready;

      for (int i = 0; i < 100; i++) {
        await col.put(_Note(id: 'n$i', text: 'text$i'));
      }

      expect(await col.all(limit: 10), hasLength(10));
      expect(
          (await col.all(limit: 10)).map((n) => n.id),
          equals([
            for (int i = 0; i < 10; i++) 'n$i',
          ]));
    });

    test('all(offset: 95) returns the last 5 docs', () async {
      final col = Collection.create<_Note>('notes', _Note.codec);
      await col.ready;

      for (int i = 0; i < 100; i++) {
        await col.put(_Note(id: 'n$i', text: 'text$i'));
      }

      expect(await col.all(offset: 95), hasLength(5));
      expect(
          (await col.all(offset: 95)).map((n) => n.id),
          equals([
            for (int i = 95; i < 100; i++) 'n$i',
          ]));
    });

    test('all(offset: 100) returns empty on a collection of 100', () async {
      final col = Collection.create<_Note>('notes', _Note.codec);
      await col.ready;

      for (int i = 0; i < 100; i++) {
        await col.put(_Note(id: 'n$i', text: 'text$i'));
      }

      expect(await col.all(offset: 100), isEmpty);
    });

    test('all() with no args still returns everything', () async {
      final col = Collection.create<_Note>('notes', _Note.codec);
      await col.ready;

      for (int i = 0; i < 100; i++) {
        await col.put(_Note(id: 'n$i', text: 'text$i'));
      }

      expect(await col.all(), hasLength(100));
    });

    test('where with limit stops after N matches', () async {
      final col = Collection.create<_Note>('notes', _Note.codec);
      await col.ready;

      for (int i = 0; i < 100; i++) {
        final text = i.isEven ? 'even' : 'odd';
        await col.put(_Note(id: 'n$i', text: text));
      }

      final result = await col.where((n) => n.text == 'even', limit: 3);
      expect(result, hasLength(3));
      expect(result.map((n) => n.id), equals(['n0', 'n2', 'n4']));
    });

    test('where with skip + limit returns correct page', () async {
      final col = Collection.create<_Note>('notes', _Note.codec);
      await col.ready;

      for (int i = 0; i < 100; i++) {
        final text = i.isEven ? 'even' : 'odd';
        await col.put(_Note(id: 'n$i', text: text));
      }

      // Skip first 10 even docs, take 3.
      final result =
          await col.where((n) => n.text == 'even', offset: 10, limit: 3);
      expect(result, hasLength(3));
      expect(result.map((n) => n.id), equals(['n20', 'n22', 'n24']));
    });

    test('where with offset only does not crash', () async {
      final col = Collection.create<_Note>('notes', _Note.codec);
      await col.ready;

      for (int i = 0; i < 10; i++) {
        await col.put(_Note(id: 'n$i', text: i.isEven ? 'even' : 'odd'));
      }

      // offset without limit: skip first 3 even docs, return the rest.
      final result =
          (await col.where((n) => n.text == 'even', offset: 3)).toList();
      expect(result, hasLength(2));
      expect(result.map((n) => n.id), equals(['n6', 'n8']));
    });

    test('where without pagination behaves like all().where', () async {
      final col = Collection.create<_Note>('notes', _Note.codec);
      await col.ready;

      for (int i = 0; i < 10; i++) {
        final text = i.isEven ? 'even' : 'odd';
        await col.put(_Note(id: 'n$i', text: text));
      }

      expect(
        (await col.where((n) => n.text == 'even')).map((n) => n.id),
        orderedEquals(
            (await col.all()).where((n) => n.text == 'even').map((n) => n.id)),
      );
    });
  });

  group('Secondary indexes (4b)', () {
    // Index granularity matches the merge strategy's flattened field paths.
    // ShallowMergeStrategy exposes top-level fields (text, status, …);
    // ObjectMergeStrategy only exposes '' (the whole doc), so these tests
    // use ShallowMergeStrategy for per-field indexing.
    final merge = const ShallowMergeStrategy();

    test('findBy returns matching documents', () async {
      final col = Collection.create<_Note>(
        'notes',
        _Note.codec,
        merge: merge,
        indexedFields: ['text'],
      );
      await col.ready;

      await col.put(_Note(id: 'a', text: 'done'));
      await col.put(_Note(id: 'b', text: 'pending'));
      await col.put(_Note(id: 'c', text: 'done'));

      expect((await col.findBy('text', 'done')).map((n) => n.id),
          unorderedEquals(['a', 'c']));
      expect((await col.findBy('text', 'pending')).map((n) => n.id),
          equals(['b']));
    });

    test('findBy returns empty for unmatched value', () async {
      final col = Collection.create<_Note>(
        'notes',
        _Note.codec,
        merge: merge,
        indexedFields: ['text'],
      );
      await col.ready;

      await col.put(_Note(id: 'a', text: 'done'));

      expect(await col.findBy('text', 'missing'), isEmpty);
    });

    test('findBy on undeclared field throws', () async {
      final col = Collection.create<_Note>(
        'notes',
        _Note.codec,
        merge: merge,
        indexedFields: ['text'],
      );
      await col.ready;

      expect(
        () async => await col.findBy('nonexistent', 'x'),
        throwsArgumentError,
      );
    });

    test('index survives put that changes an indexed field', () async {
      final col = Collection.create<_Note>(
        'notes',
        _Note.codec,
        merge: merge,
        indexedFields: ['text'],
      );
      await col.ready;

      await col.put(_Note(id: 'a', text: 'pending'));
      await col.put(_Note(id: 'a', text: 'done'));

      expect(await col.findBy('text', 'pending'), isEmpty);
      expect(
          (await col.findBy('text', 'done')).map((n) => n.id), equals(['a']));
    });

    test('index reflects delete', () async {
      final col = Collection.create<_Note>(
        'notes',
        _Note.codec,
        merge: merge,
        indexedFields: ['text'],
      );
      await col.ready;

      await col.put(_Note(id: 'a', text: 'done'));
      await col.delete('a');

      expect(await col.findBy('text', 'done'), isEmpty);
    });

    test('index reflects concurrent edit through mergeChangeset', () async {
      // Node A creates a doc with status 'pending'.
      final colA = Collection.create<_Note>(
        'notes',
        _Note.codec,
        merge: merge,
        indexedFields: ['text'],
      );
      await colA.ready;
      await colA.put(_Note(id: 'a', text: 'pending'));

      // Node B receives the changeset and indexes it.
      final colB = Collection.create<_Note>(
        'notes',
        _Note.codec,
        merge: merge,
        indexedFields: ['text'],
      );
      await colB.ready;
      await colB.mergeChangeset(await colA.getChangeset());

      expect((await colB.findBy('text', 'pending')).map((n) => n.id),
          equals(['a']));

      // Node B edits the doc's text.
      await colB.put(_Note(id: 'a', text: 'done'));

      expect(await colB.findBy('text', 'pending'), isEmpty);
      expect(
          (await colB.findBy('text', 'done')).map((n) => n.id), equals(['a']));
    });

    test('findBy supports limit and offset', () async {
      final col = Collection.create<_Note>(
        'notes',
        _Note.codec,
        merge: merge,
        indexedFields: ['text'],
      );
      await col.ready;

      for (int i = 0; i < 10; i++) {
        await col.put(_Note(id: 'n$i', text: 'even'));
      }

      expect(await col.findBy('text', 'even', limit: 3), hasLength(3));
      expect(await col.findBy('text', 'even', offset: 8), hasLength(2));
      expect(await col.findBy('text', 'even', offset: 10), isEmpty);
    });

    test('no-index collection works unchanged', () async {
      final col = Collection.create<_Note>(
        'notes',
        _Note.codec,
        merge: merge,
      );
      await col.ready;

      await col.put(_Note(id: 'a', text: 'hello'));
      expect((await col.get('a'))?.text, equals('hello'));
      expect(await col.all(), hasLength(1));
    });

    test('declaring indexedFields with ObjectMergeStrategy throws', () {
      // The default ObjectMergeStrategy flattens each document to a single
      // record (key ''), so per-field index paths would never be populated.
      // This must fail loudly at construction rather than silently returning
      // empty results from findBy.
      expect(
        () => Collection.create<_Note>(
          'notes',
          _Note.codec,
          indexedFields: ['text'],
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  // The point of the feature: an indexed/paginated read must not decode the
  // whole collection, and must not re-scan the engine once per matched id.
  group('Query cost', () {
    test('findBy decodes only matching documents, not the whole collection',
        () async {
      final codec = _CountingCodec(_Note.codec);
      final col = Collection.create<_Note>(
        'notes',
        codec,
        merge: const ShallowMergeStrategy(),
        indexedFields: ['text'],
      );
      await col.ready;

      for (int i = 0; i < 100; i++) {
        await col.put(_Note(id: 'n$i', text: i % 20 == 0 ? 'hit' : 'miss'));
      }

      codec.decodes = 0;
      final hits = (await col.findBy('text', 'hit')).toList();
      expect(hits, hasLength(5));
      // Only the 5 matches are decoded — not all 100. The old O(matches·n)
      // implementation decoded one doc per match too, but via get(); the win
      // here is over `where`, which would decode all 100.
      expect(codec.decodes, equals(5));
    });

    test('findBy scans the engine once, not once per matched id', () async {
      final table = _CountingTable(MapCrdtTable('notes'));
      final col = Collection.create<_Note>(
        'notes',
        _Note.codec,
        merge: const ShallowMergeStrategy(),
        indexedFields: ['text'],
        engine: () => table,
      );
      await col.ready;

      for (int i = 0; i < 50; i++) {
        await col.put(_Note(id: 'n$i', text: 'hit'));
      }

      table.liveFieldsCalls = 0;
      final hits = (await col.findBy('text', 'hit')).toList();
      expect(hits, hasLength(50));
      // Regression guard for the O(matches·n) bug: a single scan, not 50.
      expect(table.liveFieldsCalls, equals(1));
    });

    test('all(limit: N) decodes only the page', () async {
      final codec = _CountingCodec(_Note.codec);
      final col = Collection.create<_Note>('notes', codec);
      await col.ready;

      for (int i = 0; i < 100; i++) {
        await col.put(_Note(id: 'n$i', text: 'text$i'));
      }

      codec.decodes = 0;
      expect(await col.all(limit: 10), hasLength(10));
      expect(codec.decodes, equals(10));
    });

    test('where(limit: N) stops decoding after N matches', () async {
      final codec = _CountingCodec(_Note.codec);
      final col = Collection.create<_Note>('notes', codec);
      await col.ready;

      // All documents match, so the generator must stop at exactly `limit`.
      for (int i = 0; i < 100; i++) {
        await col.put(_Note(id: 'n$i', text: 'same'));
      }

      codec.decodes = 0;
      expect((await col.where((n) => n.text == 'same', limit: 3)).toList(),
          hasLength(3));
      expect(codec.decodes, equals(3));
    });
  });

  group('Inbound rate limiting', () {
    test('normal frame rate is not throttled', () async {
      final bus = InMemoryBus();
      final nodeA = await _openConclave(bus);
      final nodeB = await _openConclave(bus);
      const pp =
          'one two three four five six seven eight nine ten eleven twelve';

      final dbA = await nodeA.openDatabase('notes', passphrase: pp);
      final dbB = await nodeB.openDatabase('notes', passphrase: pp);
      final colA = dbA.collection<_Note>('notes', _Note.codec);
      final colB = dbB.collection<_Note>('notes', _Note.codec);

      await colA.put(_Note(id: 'n1', text: 'a'));
      await colA.put(_Note(id: 'n2', text: 'b'));

      await colB
          .watch()
          .where((l) => l.length == 2)
          .first
          .timeout(const Duration(seconds: 5));
      expect(await colB.all(), hasLength(2));

      await nodeA.close();
      await nodeB.close();
    });

    test('excessive inbound frames from a peer are silently dropped', () async {
      final bus = InMemoryBus();
      final transportB = InMemoryTransport(bus);
      final nodeB = await Conclave.lowLevel(
        config: ConclaveConfig(
          appId: 'test',
          salt: 'test:v1',
          maxInboundFramesPerSecond: 5,
        ),
        keyStore: _MemKeyStore(),
        transport: transportB,
        deriveKey: (p, s) async =>
            List<int>.generate(32, (i) => p.codeUnitAt(i % p.length) ^ i),
        roomTag: (k) =>
            k.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        cipher: _XorCipher.new,
        mnemonicGenerator: (words) => List.generate(words, (i) => 'w$i'),
        validateMnemonic: (_) => true,
        engine: (_, col, __) => MapCrdtTable(col),
      );
      final nodeA = await _openConclave(bus);
      const pp =
          'one two three four five six seven eight nine ten eleven twelve';

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
      await colB
          .watch()
          .where((l) => l.any((n) => n.id == 'last'))
          .first
          .timeout(const Duration(seconds: 5));
      expect((await colB.get('last'))?.text, equals('last'));

      await nodeA.close();
      await nodeB.close();
    });

    test('a noisy peer does not starve other peers', () async {
      final bus = InMemoryBus();
      final transportC = InMemoryTransport(bus);
      final nodeC = await Conclave.lowLevel(
        config: ConclaveConfig(
          appId: 'test',
          salt: 'test:v1',
          maxInboundFramesPerSecond: 5,
        ),
        keyStore: _MemKeyStore(),
        transport: transportC,
        deriveKey: (p, s) async =>
            List<int>.generate(32, (i) => p.codeUnitAt(i % p.length) ^ i),
        roomTag: (k) =>
            k.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        cipher: _XorCipher.new,
        mnemonicGenerator: (words) => List.generate(words, (i) => 'w$i'),
        validateMnemonic: (_) => true,
        engine: (_, col, __) => MapCrdtTable(col),
      );
      final nodeA = await _openConclave(bus);
      final nodeB = await _openConclave(bus);
      const pp =
          'one two three four five six seven eight nine ten eleven twelve';

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
      expect(await colB.all(), hasLength(20));

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
      final nodeB = await Conclave.lowLevel(
        config: ConclaveConfig(
          appId: 'test',
          salt: 'test:v1',
          maxInboundFramesPerSecond: 5,
        ),
        keyStore: _MemKeyStore(),
        transport: transportB,
        deriveKey: (p, s) async =>
            List<int>.generate(32, (i) => p.codeUnitAt(i % p.length) ^ i),
        roomTag: (k) =>
            k.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        cipher: _XorCipher.new,
        mnemonicGenerator: (words) => List.generate(words, (i) => 'w$i'),
        validateMnemonic: (_) => true,
        engine: (_, col, __) => MapCrdtTable(col),
      );
      final nodeA = await _openConclave(bus);
      const pp =
          'one two three four five six seven eight nine ten eleven twelve';

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
      final countBefore = (await colB.all()).length;
      expect(countBefore, lessThan(10));

      // Let the rate window expire, then force sync from A.
      await Future<void>.delayed(const Duration(seconds: 2));
      await nodeA.forceSync();

      // B now receives all 20.
      await colB
          .watch()
          .where((l) => l.length == 20)
          .first
          .timeout(const Duration(seconds: 5));
      expect(await colB.all(), hasLength(20));

      await nodeA.close();
      await nodeB.close();
    });

    test('forceSync pulls data the caller was missing', () async {
      // Only nodeA is rate-limited. B writes while A's inbound is restricted;
      // A then calls forceSync and receives the missing data via SyncRequest.
      final bus = InMemoryBus();
      final transportA = InMemoryTransport(bus);
      final nodeA = await Conclave.lowLevel(
        config: ConclaveConfig(
          appId: 'test',
          salt: 'test:v1',
          maxInboundFramesPerSecond: 5,
        ),
        keyStore: _MemKeyStore(),
        transport: transportA,
        deriveKey: (p, s) async =>
            List<int>.generate(32, (i) => p.codeUnitAt(i % p.length) ^ i),
        roomTag: (k) =>
            k.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        cipher: _XorCipher.new,
        mnemonicGenerator: (words) => List.generate(words, (i) => 'w$i'),
        validateMnemonic: (_) => true,
        engine: (_, col, __) => MapCrdtTable(col),
      );
      final nodeB = await _openConclave(bus);
      const pp =
          'one two three four five six seven eight nine ten eleven twelve';

      final dbA = await nodeA.openDatabase('notes', passphrase: pp);
      final dbB = await nodeB.openDatabase('notes', passphrase: pp);
      final colA = dbA.collection<_Note>('notes', _Note.codec);
      final colB = dbB.collection<_Note>('notes', _Note.codec);

      // A writes 5 docs — B receives all 5 (normal sync, no rate limit on B).
      for (int i = 0; i < 5; i++) {
        await colA.put(_Note(id: 'n$i', text: 'a$i'));
      }
      await colB
          .watch()
          .where((l) => l.length == 5)
          .first
          .timeout(const Duration(seconds: 5));

      // B writes 15 more docs rapidly — A's 5 fps limit drops some.
      for (int i = 5; i < 20; i++) {
        await colB.put(_Note(id: 'n$i', text: 'b$i'));
      }

      // Confirm A does NOT have all 20.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect((await colA.all()).length, lessThan(20));

      // Let the rate window expire, then force sync from A.
      await Future<void>.delayed(const Duration(seconds: 2));
      await nodeA.forceSync();

      // A receives the missing docs via the Poke → Hello back exchange.
      await colA
          .watch()
          .where((l) => l.length == 20)
          .first
          .timeout(const Duration(seconds: 5));
      expect(await colA.all(), hasLength(20));
      // B has everything too.
      expect(await colB.all(), hasLength(20));

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
      const pp =
          'one two three four five six seven eight nine ten eleven twelve';
      final dbA = await nodeA.openDatabase('notes', passphrase: pp);
      final dbB = await nodeB.openDatabase('notes', passphrase: pp);

      final notesA = dbA.collection<_Note>('notes', _Note.codec);
      dbB.collection<_Note>('notes', _Note.codec);

      // Use a dedicated collection on a third node for observer testing.
      final bus = InMemoryBus();
      final nodeC = await _openConclave(bus);
      final dbC = await nodeC.openDatabase('notes', passphrase: pp);
      final conflicts = <String>[];
      final notesC = dbC.collection<_Note>(
        'notes',
        _Note.codec,
        onRemoteConflict: (id) => conflicts.add(id),
      );
      await notesC.ready;

      // Seed A with a document, then copy the entire changeset to C.
      await notesA.put(_Note(id: 'n1', text: 'Hello'));
      final seed = await notesA.getChangeset();
      await notesC.mergeChangeset(seed);
      expect(conflicts, isEmpty);

      // Update the same document on A, then copy the full changeset to C.
      // HLC timestamps on the second write are newer, so the merge will
      // overwrite C's version — and since n1 already exists locally, the
      // conflict observer fires.
      await notesA.put(_Note(id: 'n1', text: 'World'));
      final update = await notesA.getChangeset();
      await notesC.mergeChangeset(update);

      expect(conflicts, contains('n1'));

      await nodeC.close();
    });

    test('does not fire when the document did not exist locally', () async {
      const pp =
          'one two three four five six seven eight nine ten eleven twelve';
      final dbA = await nodeA.openDatabase('notes', passphrase: pp);
      final dbB = await nodeB.openDatabase('notes', passphrase: pp);

      final conflicts = <String>[];
      final notesA = dbA.collection<_Note>('notes', _Note.codec);
      final notesB = dbB.collection<_Note>(
        'notes',
        _Note.codec,
        onRemoteConflict: (id) => conflicts.add(id),
      );

      // A writes two documents; B has never seen either.
      await notesA.put(_Note(id: 'n1', text: 'a'));
      await notesA.put(_Note(id: 'n2', text: 'b'));
      await notesB
          .watch()
          .where((l) => l.length == 2)
          .first
          .timeout(const Duration(seconds: 5));

      // Neither existed locally on B before the merge, so no conflicts.
      expect(conflicts, isEmpty);
    });
  });

  group('Compaction', () {
    /// Builds a minimal test environment and returns the collection.
    Future<Collection<_Note>> withCol() async {
      final bus = InMemoryBus();
      final c = await _openConclave(bus);
      final db = await c.openDatabase(
        'test',
        passphrase:
            'one two three four five six seven eight nine ten eleven twelve',
      );
      final col = db.collection<_Note>('notes', _Note.codec);
      await col.ready;
      return col;
    }

    /// Injects records directly via [Collection.mergeChangeset].
    /// The changeset key is the collection's name ([Collection.name]).
    Future<void> inject(
      Collection<_Note> col,
      Iterable<Map<String, Object?>> records,
    ) =>
        col.mergeChangeset({col.name: records.toList()});

    /// Version of [inject] for non-_Note collections.
    Future<void> injectCard(
      Collection<_Card> col,
      Iterable<Map<String, Object?>> records,
    ) =>
        col.mergeChangeset({col.name: records.toList()});

    test('empty collection returns 0', () async {
      final col = await withCol();
      expect(await col.compact(horizon: const Duration(days: 1)), 0);
    });

    test('only live docs returns 0', () async {
      final col = await withCol();
      await col.put(_Note(id: 'n1', text: 'a'));
      expect(await col.compact(horizon: const Duration(days: 1)), 0);
      expect(col.length, 1);
    });

    test('young tombstones are not reclaimed', () async {
      final col = await withCol();
      await col.put(_Note(id: 'n1', text: 'a'));
      await col.delete('n1');
      expect(await col.compact(horizon: const Duration(days: 30)), 0);
    });

    test('old tombstones are reclaimed', () async {
      final col = await withCol();
      final old = Hlc(DateTime.utc(2020, 1, 1), 0, 'test');
      await inject(col, [
        {'key': 'dead', 'value': null, 'is_deleted': true, 'hlc': old},
        {'key': 'dead\x1F', 'value': null, 'is_deleted': true, 'hlc': old},
      ]);
      await col.put(_Note(id: 'n1', text: 'a'));
      expect(col.length, 1);
      expect(
        await col.compact(horizon: const Duration(days: 1)),
        greaterThan(0),
      );
      expect(col.length, 1);
    });

    test('reclaimed count is precise and idempotent', () async {
      final col = await withCol();
      final old = Hlc(DateTime.utc(2020, 1, 1), 0, 'test');
      await inject(col, [
        {'key': 'd1', 'value': null, 'is_deleted': true, 'hlc': old},
        {'key': 'd1\x1F', 'value': null, 'is_deleted': true, 'hlc': old},
      ]);
      expect(await col.compact(horizon: const Duration(days: 1)), 2);
      expect(await col.compact(horizon: const Duration(days: 1)), 0);
    });

    test('watcher survives compaction', () async {
      final col = await withCol();
      final seen = <int>[];
      col.watch().listen((docs) => seen.add(docs.length));

      // 1. Initial snapshot of empty collection.
      await col.ready;
      await Future<void>.delayed(Duration.zero);
      expect(seen, contains(0));
      seen.clear();

      // 2. Inject old tombstones — watcher fires.
      final old = Hlc(DateTime.utc(2020, 1, 1), 0, 'test');
      await inject(col, [
        {'key': 'dead', 'value': null, 'is_deleted': true, 'hlc': old},
        {'key': 'dead\x1F', 'value': null, 'is_deleted': true, 'hlc': old},
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(seen, contains(0));
      seen.clear();

      // 3. Compact — watcher fires a fresh snapshot.
      await col.compact(horizon: const Duration(days: 1));
      await Future<void>.delayed(Duration.zero);
      expect(seen, contains(0));
      seen.clear();

      // 4. Put after compact — watcher still fires.
      await col.put(_Note(id: 'n1', text: 'hi'));
      await Future<void>.delayed(Duration.zero);
      expect(seen, contains(1));
    });

    test('field tombstones are reclaimed', () async {
      final bus = InMemoryBus();
      final c = await _openConclave(bus);
      final db = await c.openDatabase(
        'test',
        passphrase:
            'one two three four five six seven eight nine ten eleven twelve',
      );
      final col = db.collection<_Card>(
        'cards',
        _Card.codec,
        merge: ShallowMergeStrategy(),
      );
      await col.ready;

      // Seed a doc with backdated HLCs on both title and body fields.
      final docHlc = Hlc(DateTime.utc(2020, 1, 1), 0, 'test');
      await injectCard(col, [
        {'key': 'c1', 'value': true, 'is_deleted': false, 'hlc': docHlc},
        {'key': 'c1\x1Fid', 'value': 'c1', 'is_deleted': false, 'hlc': docHlc},
        {
          'key': 'c1\x1Ftitle',
          'value': 'hello',
          'is_deleted': false,
          'hlc': docHlc
        },
        {
          'key': 'c1\x1Fbody',
          'value': 'world',
          'is_deleted': false,
          'hlc': docHlc
        },
      ]);
      expect(col.length, 1);

      // Tombstone the title field with a newer HLC.
      final tombHlc = Hlc(DateTime.utc(2020, 6, 1), 0, 'test');
      await injectCard(col, [
        {
          'key': 'c1\x1Ftitle',
          'value': null,
          'is_deleted': true,
          'hlc': tombHlc
        },
      ]);

      // Compact reclaims the old field tombstone for title (Jun 2020 tombstone
      // beyond the 365-day horizon). The original title value (Jan 2020) was
      // overwritten by the tombstone at merge time and is gone — after compact,
      // the field is simply absent.
      final reclaimed = await col.compact(horizon: const Duration(days: 365));
      expect(reclaimed, greaterThan(0));
      // Doc is still alive with the body field intact.
      expect(col.length, 1);
      expect((await col.get('c1'))?.title, '');
      expect((await col.get('c1'))?.body, 'world');
      await c.close();
    });

    test('convergence after compaction (peer already had tombstone)', () async {
      // A peer that already observed the delete will re-sync the tombstone
      // after compact, keeping the doc deleted — no surprise resurrection.
      final col = await withCol();
      final old = Hlc(DateTime.utc(2020, 1, 1), 0, 'test');
      await inject(col, [
        {'key': 'dead', 'value': null, 'is_deleted': true, 'hlc': old},
        {'key': 'dead\x1F', 'value': null, 'is_deleted': true, 'hlc': old},
      ]);
      expect(col.length, 0);

      // Compact removes the tombstone.
      await col.compact(horizon: const Duration(days: 1));
      expect(col.length, 0);

      // Peer re-syncs its copy of the tombstone — it's new to the empty
      // engine so it's accepted again. Doc stays deleted.
      await inject(col, [
        {'key': 'dead', 'value': null, 'is_deleted': true, 'hlc': old},
        {'key': 'dead\x1F', 'value': null, 'is_deleted': true, 'hlc': old},
      ]);
      expect(col.length, 0);
    });

    test('resurrection after compaction works', () async {
      final col = await withCol();
      final docHlc = Hlc(DateTime.utc(2020, 1, 1), 0, 'test');
      final tombHlc = Hlc(DateTime.utc(2020, 6, 1), 0, 'test');
      // Doc created.
      await inject(col, [
        {'key': 'n1', 'value': true, 'is_deleted': false, 'hlc': docHlc},
        {
          'key': 'n1\x1F',
          'value': {'id': 'n1', 'text': 'hello'},
          'is_deleted': false,
          'hlc': docHlc
        },
      ]);
      expect(col.length, 1);
      // Tombstone with higher HLC wins.
      await inject(col, [
        {'key': 'n1', 'value': null, 'is_deleted': true, 'hlc': tombHlc},
        {'key': 'n1\x1F', 'value': null, 'is_deleted': true, 'hlc': tombHlc},
      ]);
      expect(col.length, 0);
      // Compact removes the tombstone.
      await col.compact(horizon: const Duration(days: 365));
      expect(col.length, 0);
      // Peer re-syncs its pre-tombstone doc — without the tombstone it wins.
      await inject(col, [
        {'key': 'n1', 'value': true, 'is_deleted': false, 'hlc': docHlc},
        {
          'key': 'n1\x1F',
          'value': {'id': 'n1', 'text': 'hello'},
          'is_deleted': false,
          'hlc': docHlc
        },
      ]);
      expect(col.length, 1);
      expect((await col.get('n1'))?.text, 'hello');
    });

    test('Database.compact fans out to all collections', () async {
      final bus = InMemoryBus();
      final c = await _openConclave(bus);
      final db = await c.openDatabase(
        'test',
        passphrase:
            'one two three four five six seven eight nine ten eleven twelve',
      );
      final colA = db.collection<_Note>('a', _Note.codec);
      final colB = db.collection<_Note>('b', _Note.codec);
      await colA.ready;
      await colB.ready;

      final old = Hlc(DateTime.utc(2020, 1, 1), 0, 'test');
      await colA.mergeChangeset({
        'a': [
          {'key': 'd1', 'value': null, 'is_deleted': true, 'hlc': old},
          {'key': 'd1\x1F', 'value': null, 'is_deleted': true, 'hlc': old},
        ],
      });
      await colB.mergeChangeset({
        'b': [
          {'key': 'd2', 'value': null, 'is_deleted': true, 'hlc': old},
          {'key': 'd2\x1F', 'value': null, 'is_deleted': true, 'hlc': old},
        ],
      });

      final total = await db.compact(horizon: const Duration(days: 1));
      expect(total, 4);
      await c.close();
    });
  });
}
