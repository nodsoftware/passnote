import 'dart:io';

import 'package:conclave/conclave.dart';
import 'package:conclave/engine.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../test_support/corrupting_file.dart';

/// XOR cipher — the wire format is not what these tests check.
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

/// Fails the test unless [path] is unreadable (open throws, or `quick_check`
/// does not return `ok`).
void _expectUnreadable(String path) {
  try {
    final db = sqlite3.open(path);
    final result = db.select('PRAGMA quick_check');
    db.dispose();
    expect(
      result.first.values.first,
      isNot('ok'),
      reason: 'file at $path should have been corrupted',
    );
  } on SqliteException {
    // Corrupt enough that the open itself failed — also fine.
  }
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('conclave_crash'));
  tearDown(() => tmp.deleteSync(recursive: true));

  const passphrase =
      'one two three four five six seven eight nine ten eleven twelve';

  Future<Conclave> openNode(InMemoryBus bus, String label) => Conclave.lowLevel(
        config: const ConclaveConfig(
          appId: 'test',
          salt: 'test:v1',
          snapshotInterval: Duration.zero,
        ),
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

  test('a corrupt collection file is quarantined and re-synced from a peer',
      () async {
    final bus = InMemoryBus();
    final a = await openNode(bus, 'a');
    final b = await openNode(bus, 'b');

    final dbA = await a.openDatabase('notes', passphrase: passphrase);
    final dbB = await b.openDatabase('notes', passphrase: passphrase);
    dbA.collection<_Note>('notes', _Note.codec);
    final notesB = dbB.collection<_Note>('notes', _Note.codec);

    await dbA.collection<_Note>('notes', _Note.codec).put(_Note('n1', 'hello'));
    await notesB
        .watch()
        .firstWhere((l) => l.isNotEmpty)
        .timeout(const Duration(seconds: 5));
    await a.close();

    final file = '${tmp.path}/a_notes_notes.sqlite';
    corruptDatabaseFile(file);
    _expectUnreadable(file);

    // Reopen node A over the same files and the same bus (B is still up).
    final a2 = await openNode(bus, 'a');
    addTearDown(() async {
      await a2.close();
      await b.close();
    });
    final events = <ConclaveEvent>[];
    a2.events.listen(events.add);

    final dbA2 = await a2.openDatabase('notes', passphrase: passphrase);
    final notesA2 = dbA2.collection<_Note>('notes', _Note.codec);
    await notesA2.ready;

    // The reset store pulled the record back from the peer.
    await notesA2
        .watch()
        .firstWhere((l) => l.isNotEmpty)
        .timeout(const Duration(seconds: 5));
    expect((await notesA2.all()).single.text, 'hello');

    final recovered = events.whereType<StoreRecovered>().single;
    expect(recovered.source, CrdtRecoverySource.reset);
    expect(recovered.collection, 'notes');
    expect(recovered.databaseId, 'notes');
    expect(File(recovered.quarantinePath).existsSync(), isTrue);
  });

  test('with no peer, the snapshot restores the last consistent state',
      () async {
    final path = '${tmp.path}/snap.sqlite';
    final t1 = await SqliteCrdtTable.open(path);
    await t1.put('c', 'k1', 'v1');
    await t1.put('c', 'k2', 'v2');
    t1.snapshotNow();
    await t1.put('c', 'k3', 'written after the snapshot');
    await t1.close();

    expect(File('$path.snapshot').existsSync(), isTrue);
    corruptDatabaseFile(path);
    _expectUnreadable(path);

    final t2 = SqliteCrdtTable(path);
    await t2.init();
    addTearDown(t2.close);

    expect(t2.recovery, isNotNull);
    expect(t2.recovery!.source, CrdtRecoverySource.snapshot);
    expect(await t2.value('c', 'k1'), 'v1');
    expect(await t2.value('c', 'k2'), 'v2');
    expect(await t2.value('c', 'k3'), isNull);
    expect(File(t2.recovery!.quarantinePath).existsSync(), isTrue);
  });

  test('an interrupted transaction leaves the store openable and consistent',
      () async {
    final path = '${tmp.path}/txn.sqlite';
    final t1 = await SqliteCrdtTable.open(path);
    await t1.put('c', 'committed', 'yes');
    await t1.close();

    // Crash mid-transaction: BEGIN + INSERT, then drop the connection with no
    // COMMIT so SQLite rolls the write back.
    final raw = sqlite3.open(path);
    raw.execute('BEGIN');
    raw.execute(
      "INSERT INTO crdt_records "
      "(collection, key, value, is_deleted, hlc, hlc_key) "
      "VALUES ('c', 'phantom', '\"nope\"', 0, 'z', 'z')",
    );
    raw.dispose();

    final t2 = await SqliteCrdtTable.open(path);
    addTearDown(t2.close);

    expect(t2.recovery, isNull, reason: 'a rollback is not corruption');
    expect(await t2.value('c', 'committed'), 'yes');
    expect(await t2.value('c', 'phantom'), isNull);
  });

  group('an interrupted migration is never left half-applied', () {
    test('a rolled-back migration reopens at the old version and completes',
        () async {
      final path = '${tmp.path}/mig_rollback.sqlite';

      // Crash mid-migration: create a table but never bump user_version or
      // commit.
      final raw = sqlite3.open(path);
      raw.execute('BEGIN');
      raw.execute(
        'CREATE TABLE crdt_records ('
        'collection TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL, '
        'is_deleted INTEGER NOT NULL DEFAULT 0, hlc TEXT NOT NULL, '
        'hlc_key TEXT NOT NULL, PRIMARY KEY (collection, key))',
      );
      raw.dispose();

      // Before the engine sees it: old version, and the object is gone.
      final check = sqlite3.open(path);
      expect(
        check.select('PRAGMA user_version').first['user_version'],
        0,
      );
      expect(
        check.select(
          "SELECT name FROM sqlite_master "
          "WHERE type = 'table' AND name = 'crdt_records'",
        ),
        isEmpty,
      );
      check.dispose();

      final t = await SqliteCrdtTable.open(path);
      addTearDown(t.close);
      expect(t.recovery, isNull);
      await t.put('c', 'k', 'v');
      expect(await t.value('c', 'k'), 'v');

      final after = sqlite3.open(path);
      expect(
        after.select('PRAGMA user_version').first['user_version'],
        2,
      );
      after.dispose();
    });

    test('an already-migrated store reopens without re-migrating', () async {
      final path = '${tmp.path}/mig_done.sqlite';
      final t1 = await SqliteCrdtTable.open(path);
      await t1.put('c', 'k', 'v');
      await t1.close();

      final check = sqlite3.open(path);
      expect(
        check.select('PRAGMA user_version').first['user_version'],
        2,
      );
      check.dispose();

      final t2 = await SqliteCrdtTable.open(path);
      addTearDown(t2.close);
      expect(await t2.value('c', 'k'), 'v');
    });
  });
}
