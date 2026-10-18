// At-rest encryption is a headline claim: these tests prove it holds on the
// bytes actually written to disk, and that the engine fails closed instead of
// silently storing plaintext (the workspace pubspec builds package:sqlite3
// from the SQLCipher source via `hooks.user_defines`).
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:passnote/engine.dart';
import 'package:sqlite3/sqlite3.dart' show sqlite3;
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUpAll(() => tmp = Directory.systemTemp.createTempSync('passnote_enc'));
  tearDownAll(() => tmp.deleteSync(recursive: true));

  var counter = 0;
  String freshPath() => '${tmp.path}/db_${counter++}.sqlite';

  final key = List<int>.filled(32, 7);
  final wrongKey = List<int>.filled(32, 8);

  test('the workspace links a SQLCipher build (the tests below depend on it)',
      () {
    final db = sqlite3.open(':memory:');
    addTearDown(db.close);
    expect(db.select('PRAGMA cipher_version'), isNotEmpty,
        reason: 'package:sqlite3 must be built from the SQLCipher source '
            '(hooks.user_defines in the workspace pubspec)');
  });

  test('the failure message teaches the actual fix', () {
    // The one error whose whole job is to explain the remedy must name the
    // mechanism that exists: the hooks stanza in the app root pubspec.
    final message = const SqlCipherUnavailableException().toString();
    expect(message, contains('user_defines'));
    expect(message, contains('source: sqlcipher'));
    expect(message, contains('root'));
  });

  test('an encrypted database holds no plaintext on disk', () async {
    final path = freshPath();
    final table = await SqliteCrdtTable.open(path, encryptionKey: key);
    await table.put('items', 'k', 'TOP-SECRET-VALUE');
    await table.close();

    final bytes = File(path).readAsBytesSync();
    final header = latin1.decode(bytes.take(16).toList());
    expect(header, isNot(startsWith('SQLite format 3')),
        reason: 'a SQLCipher file has an encrypted header');
    expect(latin1.decode(bytes, allowInvalid: true),
        isNot(contains('TOP-SECRET-VALUE')),
        reason: 'stored values must not appear in plaintext on disk');
  });

  test('a wrong key throws WrongPassphraseException and quarantines nothing',
      () async {
    final path = freshPath();
    final table = await SqliteCrdtTable.open(path, encryptionKey: key);
    await table.put('items', 'k', 'survives');
    await table.close();

    await expectLater(
      SqliteCrdtTable.open(path, encryptionKey: wrongKey),
      throwsA(isA<WrongPassphraseException>()),
    );

    // The file was not moved aside or replaced: the directory holds no
    // quarantine sibling and the right key still opens the original data.
    final siblings = tmp
        .listSync()
        .map((e) => e.path)
        .where((p) => p.startsWith(path) && p != path)
        .where((p) => !p.endsWith('-wal') && !p.endsWith('-shm'))
        .toList();
    expect(siblings, isEmpty,
        reason: 'a wrong passphrase must not quarantine the database');

    final reopened = await SqliteCrdtTable.open(path, encryptionKey: key);
    addTearDown(reopened.close);
    expect(await reopened.value('items', 'k'), 'survives');
  });

  test('header damage with a healthy snapshot recovers instead of throwing',
      () async {
    // NOTADB is ambiguous: wrong key or damaged header. The snapshot carries
    // the same key (VACUUM INTO inherits it), so a snapshot that opens under
    // the key proves the key right and arbitrates toward recovery.
    final path = freshPath();
    final table = await SqliteCrdtTable.open(path, encryptionKey: key);
    await table.put('items', 'k', 'snapshotted');
    table.snapshotNow();
    await table.close();

    final file = File(path);
    final bytes = file.readAsBytesSync();
    for (var i = 0; i < 32; i++) {
      bytes[i] = 0;
    }
    file.writeAsBytesSync(bytes);

    final recovered = await SqliteCrdtTable.open(path, encryptionKey: key);
    addTearDown(recovered.close);
    expect(recovered.recovery?.source, CrdtRecoverySource.snapshot);
    expect(await recovered.value('items', 'k'), 'snapshotted');
  });

  test('header damage without a snapshot resolves to WrongPassphraseException',
      () async {
    // With nothing to arbitrate, the ambiguity resolves conservatively: the
    // file is reported mis-keyed and left in place, never quarantined.
    final path = freshPath();
    final table = await SqliteCrdtTable.open(path, encryptionKey: key);
    await table.put('items', 'k', 'v');
    await table.close();

    final file = File(path);
    final bytes = file.readAsBytesSync();
    for (var i = 0; i < 32; i++) {
      bytes[i] = 0;
    }
    file.writeAsBytesSync(bytes);

    await expectLater(
      SqliteCrdtTable.open(path, encryptionKey: key),
      throwsA(isA<WrongPassphraseException>()),
    );
    expect(File(path).existsSync(), isTrue,
        reason: 'the ambiguous file is preserved for manual recovery');
  });

  test('opening an encrypted file without a key does not leak data', () async {
    final path = freshPath();
    final table = await SqliteCrdtTable.open(path, encryptionKey: key);
    await table.put('items', 'k', 'TOP-SECRET-VALUE');
    await table.close();

    // Without the key the file is unreadable; the engine treats it as an
    // unreadable store (quarantine + reset), and no plaintext surfaces.
    final unkeyed = await SqliteCrdtTable.open(path);
    addTearDown(unkeyed.close);
    expect(await unkeyed.value('items', 'k'), isNull);
    expect(unkeyed.recovery, isNotNull,
        reason: 'the unreadable store was rebuilt, not decrypted');
  });
}
