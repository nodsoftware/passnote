// Passnote 1.0 and 1.1 derived a key from a passphrase with characters
// outside ASCII that matched no other BIP39 implementation. 1.2 derives the
// BIP39 key, and data made under the old one must still open.
@TestOn('vm')
library;

import 'dart:io';

import 'package:passnote/engine.dart';
import 'package:passnote/passnote.dart';
import 'package:test/test.dart';

class _MemKeyStore implements KeyStore {
  final _keys = <String, List<int>>{};
  @override
  Future<List<int>?> getKey(String id) async => _keys[id];
  @override
  Future<void> setKey(String id, List<int> key) async => _keys[id] = key;
  @override
  Future<void> clear(String id) async => _keys.remove(id);
}

class _XorCipher implements Cipher {
  _XorCipher(List<int> key)
      : _k = key.isEmpty ? 0x5A : key.fold(0, (a, b) => (a + b) & 0xff);
  final int _k;
  @override
  Future<List<int>> encrypt(List<int> p) async =>
      [0xAC ^ _k, 0xED ^ _k, ...p.map((b) => b ^ _k)];
  @override
  Future<List<int>> decrypt(List<int> c) async {
    if (c.length < 2 || (c[0] ^ _k) != 0xAC || (c[1] ^ _k) != 0xED) {
      throw const CipherAuthError();
    }
    return c.skip(2).map((b) => b ^ _k).toList();
  }
}

final _codec = JsonCodec<Map<String, dynamic>>(
  toMap: (m) => m,
  fromMap: (m) => m,
  idOf: (m) => m['id'] as String,
);

/// Stand-ins for the two derivations: they agree on ASCII and differ
/// otherwise, like the real ones.
List<int> _kdf(String passphrase, int tweak) {
  final ascii = passphrase.codeUnits.every((c) => c < 0x80);
  final base = passphrase.codeUnits.fold(0, (a, c) => (a * 31 + c) & 0xff);
  return List<int>.generate(32, (i) => (base + i + (ascii ? 0 : tweak)) & 0xff);
}

List<int> _current(String p) => _kdf(p, 1);
List<int> _legacy(String p) => _kdf(p, 2);

void main() {
  late Directory dir;
  late _MemKeyStore keys;
  var legacyCalls = 0;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('passnote_kdf');
    keys = _MemKeyStore();
    legacyCalls = 0;
  });
  tearDown(() => dir.deleteSync(recursive: true));

  /// A 1.2 device when [withLegacy], else one that only knows the 1.1
  /// derivation.
  Future<Passnote> open({bool withLegacy = true, bool preferLegacy = false}) =>
      passnoteLowLevel(
        config: PassnoteConfig(
          appId: 'kd',
          salt: 'kd:v1',
          snapshotInterval: Duration.zero,
          antiEntropyInterval: Duration.zero,
          legacyPassphraseKeys: preferLegacy,
        ),
        keyStore: keys,
        transport: InMemoryTransport(InMemoryBus()),
        deriveKey: (p, _) async => withLegacy ? _current(p) : _legacy(p),
        legacyDeriveKey: withLegacy
            ? (p, _) async {
                legacyCalls++;
                return _legacy(p);
              }
            : null,
        roomTag: (key) => 'room-${key.take(4).join("-")}',
        cipher: _XorCipher.new,
        mnemonicGenerator: (n) => List.filled(n, 'abandon'),
        validateMnemonic: (_) => true,
        engine: (db, collection, key) => SqliteCrdtTable(
          '${dir.path}/$db-$collection.sqlite',
          encryptionKey: key,
        ),
      );

  test('data made by 1.1 under a non-ASCII passphrase opens in 1.2', () async {
    var passnote = await open(withLegacy: false);
    final db = await passnote.openDatabase('d', passphrase: 'Łódź café');
    await db.collection('notes', _codec).put({'id': 'n', 'text': 'kept'});
    await passnote.close();

    passnote = await open();
    addTearDown(passnote.close);
    final again = await passnote.openDatabase('d', passphrase: 'Łódź café');
    expect((await again.collection('notes', _codec).get('n'))?['text'], 'kept');
    // It stays under the key the rest of its group derives.
    expect(await keys.getKey('kd/d'), _legacy('Łódź café'));
  });

  test('a wrong passphrase is still refused', () async {
    var passnote = await open(withLegacy: false);
    await passnote.openDatabase('d', passphrase: 'Łódź café');
    await passnote.close();

    passnote = await open();
    addTearDown(passnote.close);
    expect(() => passnote.openDatabase('d', passphrase: 'Łódź cafè'),
        throwsA(isA<WrongPassphraseException>()));
  });

  test('new data starts under the BIP39 key, or the legacy one by choice',
      () async {
    var passnote = await open();
    await passnote.openDatabase('d', passphrase: 'Łódź café');
    expect(await keys.getKey('kd/d'), _current('Łódź café'));
    await passnote.close();

    passnote = await open(preferLegacy: true);
    addTearDown(passnote.close);
    await passnote.openDatabase('e', passphrase: 'Łódź café');
    expect(await keys.getKey('kd/e'), _legacy('Łódź café'));
  });

  test('an ASCII passphrase derives once', () async {
    final passnote = await open();
    addTearDown(passnote.close);
    await passnote.openDatabase('d', passphrase: 'plain ascii');
    expect(legacyCalls, 0);
  });

  test('a passphrase rotation starts from either key', () async {
    var passnote = await open(withLegacy: false);
    final db = await passnote.openDatabase('d', passphrase: 'Łódź café');
    await db.collection('notes', _codec).put({'id': 'n', 'text': 'kept'});
    await passnote.close();

    passnote = await open();
    await passnote.openDatabase('d', passphrase: 'Łódź café');
    await passnote.rotatePassphrase('d',
        oldPassphrase: 'Łódź café', newPassphrase: 'Kraków');
    expect(await keys.getKey('kd/d'), _current('Kraków'));
    await passnote.close();

    passnote = await open();
    addTearDown(passnote.close);
    final again = await passnote.openDatabase('d', passphrase: 'Kraków');
    expect((await again.collection('notes', _codec).get('n'))?['text'], 'kept');
  });
}
