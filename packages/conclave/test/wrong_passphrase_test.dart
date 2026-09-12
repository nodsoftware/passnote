// Pins openDatabase's wrong-passphrase contract for EVERY configuration:
// the key is validated against local storage before openDatabase returns —
// also without an Identity, where no user collection would otherwise touch a
// disk engine during the open. A wrong passphrase must throw from
// openDatabase itself, store no key, leave the files untouched, and leave no
// broken database registered.
@TestOn('vm')
library;

import 'dart:io';

import 'package:conclave/conclave.dart';
import 'package:conclave/engine.dart';
import 'package:test/test.dart';

class _MemKeyStore implements KeyStore {
  final entries = <String, List<int>>{};
  @override
  Future<List<int>?> getKey(String id) async => entries[id];
  @override
  Future<void> setKey(String id, List<int> key) async => entries[id] = key;
  @override
  Future<void> clear(String id) async => entries.remove(id);
}

final _noteCodec = JsonCodec<Map<String, dynamic>>(
  toMap: (m) => m,
  fromMap: (m) => m,
  idOf: (m) => m['id'] as String,
);

/// Deterministic, passphrase-dependent 32-byte key (the real Argon2id
/// pipeline is pinned by its own vectors; this test is about the open path).
Future<List<int>> _deriveKey(String passphrase, String salt) async =>
    List<int>.generate(
      32,
      (i) => (passphrase.codeUnitAt(i % passphrase.length) * (i + 7)) & 0xff,
    );

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('conclave_wrongpw'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<Conclave> openNode(_MemKeyStore store) => conclaveLowLevel(
        config: const ConclaveConfig(
          appId: 'pw',
          salt: 'pw:v1',
          snapshotInterval: Duration.zero,
        ),
        keyStore: store,
        transport: InMemoryTransport(InMemoryBus()),
        deriveKey: _deriveKey,
        roomTag: (key) => 'room-${key.first}',
        cipher: (_) => _NoopCipher(),
        mnemonicGenerator: (n) => List.filled(n, 'abandon'),
        validateMnemonic: (_) => true,
        // No identity: the configuration where nothing else would force a
        // disk engine open during openDatabase.
        engine: (dbId, collection, key) {
          Directory('${tmp.path}/$dbId').createSync(recursive: true);
          return SqliteCrdtTable(
            '${tmp.path}/$dbId/$collection.sqlite',
            encryptionKey: key,
          );
        },
      );

  test(
      'a wrong passphrase throws from openDatabase itself, stores no key, '
      'and a retry with the right one succeeds', () async {
    // First run: create the database and write something.
    final first = await openNode(_MemKeyStore());
    final db = await first.openDatabase('d', passphrase: 'right horse');
    await db
        .collection<Map<String, dynamic>>('notes', _noteCodec)
        .put({'id': 'k', 'v': 'kept'});
    await first.close();

    // Second run, fresh key store (a new install over the same files).
    final store = _MemKeyStore();
    final second = await openNode(store);
    addTearDown(second.close);

    await expectLater(
      second.openDatabase('d', passphrase: 'wrong horse'),
      throwsA(isA<WrongPassphraseException>()),
      reason: 'openDatabase must validate the key before returning, also '
          'without an Identity configured',
    );
    expect(store.entries, isEmpty,
        reason: 'a key that failed to open anything must not be stored');
    expect(
      tmp
          .listSync(recursive: true)
          .map((e) => e.path)
          .where((p) => p.contains('.corrupt')),
      isEmpty,
      reason: 'a wrong passphrase must not quarantine anything',
    );

    // The failed attempt must not leave a broken database registered: the
    // same instance retried with the right passphrase opens and reads.
    final reopened = await second.openDatabase('d', passphrase: 'right horse');
    final note = await reopened
        .collection<Map<String, dynamic>>('notes', _noteCodec)
        .get('k');
    expect(note?['v'], 'kept');
    expect(store.entries, isNotEmpty,
        reason: 'the proven key is stored for reopenDatabase');
  });
}

/// Identity cipher: at-rest encryption is the engine's job in this test; the
/// wire is unused (no peers).
class _NoopCipher implements Cipher {
  @override
  Future<List<int>> encrypt(List<int> plaintext) async => plaintext;
  @override
  Future<List<int>> decrypt(List<int> ciphertext) async => ciphertext;
}
