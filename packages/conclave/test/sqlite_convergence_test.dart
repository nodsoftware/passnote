import 'dart:io';

import 'package:conclave/conclave.dart';
import 'package:conclave/engine.dart';
import 'package:test/test.dart';

/// XOR cipher, fast and deterministic — the wire is not what these tests check.
class _XorCipher implements Cipher {
  _XorCipher(List<int> key) : _key = key[0];
  final int _key;

  @override
  Future<List<int>> encrypt(List<int> p) async =>
      [0xAC ^ _key, 0xED ^ _key, ...p.map((b) => b ^ _key)];

  @override
  Future<List<int>> decrypt(List<int> c) async {
    if (c.length < 2 || (c[0] ^ _key) != 0xAC || (c[1] ^ _key) != 0xED) {
      throw const CipherAuthError();
    }
    return c.skip(2).map((b) => b ^ _key).toList();
  }
}

class _MemKeyStore implements KeyStore {
  final _keys = <String, List<int>>{};
  @override
  Future<List<int>?> getKey(String id) async => _keys[id];
  @override
  Future<void> setKey(String id, List<int> key) async => _keys[id] = key;
  @override
  Future<void> clear(String id) async => _keys.remove(id);
}

class _Note {
  _Note(this.id, this.text);
  final String id;
  final String text;
  static final codec = JsonCodec<_Note>(
    toMap: (n) => {'id': n.id, 'text': n.text},
    fromMap: (m) => _Note(m['id'] as String, m['text'] as String),
    idOf: (n) => n.id,
  );
}

void main() {
  late Directory tmp;
  setUp(
      () => tmp = Directory.systemTemp.createTempSync('conclave_sqlite_conv'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// A node whose collections are backed by SQLite files under [tmp], namespaced
  /// by [label] so two "devices" on the same bus keep separate stores.
  Future<Conclave> openNode(InMemoryBus bus, String label) => Conclave.lowLevel(
        config: const ConclaveConfig(appId: 'test', salt: 'test:v1'),
        keyStore: _MemKeyStore(),
        transport: InMemoryTransport(bus),
        deriveKey: (passphrase, salt) async =>
            List<int>.generate(32, (i) => passphrase.codeUnitAt(0) ^ i),
        roomTag: (key) => 'room',
        cipher: _XorCipher.new,
        mnemonicGenerator: (words) => List.generate(words, (i) => 'word$i'),
        validateMnemonic: (_) => true,
        engine: (dbId, collection, _) =>
            SqliteCrdtTable('${tmp.path}/${label}_${dbId}_$collection.sqlite'),
      );

  const passphrase =
      'one two three four five six seven eight nine ten eleven twelve';

  test('a put on A converges to B (SQLite engine)', () async {
    final bus = InMemoryBus();
    final a = await openNode(bus, 'a');
    final b = await openNode(bus, 'b');
    addTearDown(() async {
      await a.close();
      await b.close();
    });

    final dbA = await a.openDatabase('notes', passphrase: passphrase);
    final dbB = await b.openDatabase('notes', passphrase: passphrase);
    final notesA = dbA.collection<_Note>('notes', _Note.codec);
    final notesB = dbB.collection<_Note>('notes', _Note.codec);

    final synced = notesB.watch().firstWhere((l) => l.isNotEmpty);
    await notesA.put(_Note('n1', 'hello'));

    expect((await synced.timeout(const Duration(seconds: 5))).single.text,
        'hello');
  });

  test('concurrent edits to different docs both survive', () async {
    final bus = InMemoryBus();
    final a = await openNode(bus, 'a');
    final b = await openNode(bus, 'b');
    addTearDown(() async {
      await a.close();
      await b.close();
    });

    final dbA = await a.openDatabase('notes', passphrase: passphrase);
    final dbB = await b.openDatabase('notes', passphrase: passphrase);
    final notesA = dbA.collection<_Note>('notes', _Note.codec);
    final notesB = dbB.collection<_Note>('notes', _Note.codec);

    await notesA.put(_Note('a', 'from A'));
    await notesB.put(_Note('b', 'from B'));

    await Future.wait([
      notesA.watch().firstWhere((l) => l.length == 2),
      notesB.watch().firstWhere((l) => l.length == 2),
    ]).timeout(const Duration(seconds: 5));

    expect((await notesA.all()).map((n) => n.id), containsAll(['a', 'b']));
    expect((await notesB.all()).map((n) => n.id), containsAll(['a', 'b']));
  });

  test('same-key conflict resolves last-write-wins on both nodes', () async {
    final bus = InMemoryBus();
    final a = await openNode(bus, 'a');
    final b = await openNode(bus, 'b');
    addTearDown(() async {
      await a.close();
      await b.close();
    });

    final dbA = await a.openDatabase('notes', passphrase: passphrase);
    final dbB = await b.openDatabase('notes', passphrase: passphrase);
    final notesA = dbA.collection<_Note>('notes', _Note.codec);
    final notesB = dbB.collection<_Note>('notes', _Note.codec);

    await notesA.put(_Note('k', 'first'));
    await notesA.watch().firstWhere((l) => l.isNotEmpty);
    await notesB.watch().firstWhere((l) => l.isNotEmpty);

    // B writes last.
    await notesB.put(_Note('k', 'second'));

    await Future.wait([
      notesA.watch().firstWhere((l) => l.single.text == 'second'),
      notesB.watch().firstWhere((l) => l.single.text == 'second'),
    ]).timeout(const Duration(seconds: 5));
  });

  test('offline edits converge after forceSync', () async {
    final bus = InMemoryBus();
    final a = await openNode(bus, 'a');
    final b = await openNode(bus, 'b');
    addTearDown(() async {
      await a.close();
      await b.close();
    });

    final dbA = await a.openDatabase('notes', passphrase: passphrase);
    final dbB = await b.openDatabase('notes', passphrase: passphrase);
    final notesA = dbA.collection<_Note>('notes', _Note.codec);
    final notesB = dbB.collection<_Note>('notes', _Note.codec);

    // Simulate an outage by pausing delivery on the bus.
    bus.paused = true;
    await notesA.put(_Note('offline', 'written while apart'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await notesB.all(), isEmpty);

    bus.paused = false;
    await dbA.forceSync();
    await notesB
        .watch()
        .firstWhere((l) => l.isNotEmpty)
        .timeout(const Duration(seconds: 5));
    expect((await notesB.all()).single.id, 'offline');
  });

  test('data survives a close and reopen of the same store', () async {
    final bus = InMemoryBus();
    final a = await openNode(bus, 'a');
    final dbA = await a.openDatabase('notes', passphrase: passphrase);
    final notesA = dbA.collection<_Note>('notes', _Note.codec);
    await notesA.put(_Note('persist', 'kept'));
    await a.close();

    final a2 = await openNode(bus, 'a'); // same file paths (label 'a')
    addTearDown(a2.close);
    final dbA2 = await a2.openDatabase('notes', passphrase: passphrase);
    final notesA2 = dbA2.collection<_Note>('notes', _Note.codec);
    await notesA2.ready;
    expect((await notesA2.all()).single.text, 'kept');
  });
}
