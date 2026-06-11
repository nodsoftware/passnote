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
  Future<List<int>> encrypt(List<int> p) async => p.map((b) => b ^ _key).toList();

  @override
  Future<List<int>> decrypt(List<int> c) async => c.map((b) => b ^ _key).toList();
}

/// Model used in tests.
class _Note {
  _Note({required this.id, required this.text});

  final String id;
  final String text;

  static final codec = JsonCodec<_Note>(
    toJson: (n) => {'id': n.id, 'text': n.text},
    fromJson: (m) => _Note(id: m['id'] as String, text: m['text'] as String),
    id: (n) => n.id,
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
}
