// A key rotation re-keys the stores that are open. A store on disk that was
// not open at the time (an app that opens collections lazily) is left under
// the earlier key, and used to refuse the current key for good. It must
// open, and be brought up to date, the next time it is used.
@TestOn('vm')
library;

import 'dart:async';
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

class _Identity implements Identity {
  _Identity(int seed)
      : _pub = DevicePublicKey(
          keyExchange:
              List<int>.generate(32, (i) => (seed * 31 + i * 7) & 0xff),
          signing: List<int>.generate(32, (i) => (seed * 13 + i * 5) & 0xff),
        );

  final DevicePublicKey _pub;

  @override
  Future<DevicePublicKey> get publicKey async => _pub;
  @override
  String get deviceId => fingerprintOf(_pub);
  @override
  String fingerprintOf(DevicePublicKey publicKey) {
    var acc = 0;
    for (final b in publicKey.keyExchange) {
      acc = (acc * 31 + b) & 0x7fffffff;
    }
    return 'D${acc.toRadixString(16).padLeft(15, '0')}'.substring(0, 16);
  }

  @override
  Future<List<int>> sign(List<int> message) async =>
      [..._pub.signing, ...message];
  @override
  Future<bool> verify(
    List<int> message, {
    required List<int> signature,
    required DevicePublicKey signer,
  }) async {
    final expected = [...signer.signing, ...message];
    if (signature.length != expected.length) return false;
    for (var i = 0; i < expected.length; i++) {
      if (signature[i] != expected[i]) return false;
    }
    return true;
  }

  @override
  Future<WrappedKey> wrapFor(DevicePublicKey peer, List<int> key) async =>
      WrappedKey(
        ephemeralPublicKey: List<int>.of(peer.keyExchange),
        nonce: List<int>.filled(12, 0),
        ciphertext: [...key, ...List<int>.filled(16, 0xAA)],
      );
  @override
  Future<List<int>> unwrap(WrappedKey wrapped) async =>
      wrapped.ciphertext.sublist(0, wrapped.ciphertext.length - 16);
}

final _codec = JsonCodec<Map<String, dynamic>>(
  toMap: (m) => m,
  fromMap: (m) => m,
  idOf: (m) => m['id'] as String,
);

void main() {
  late Directory dir;
  late _MemKeyStore keys;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('passnote_rotation');
    keys = _MemKeyStore();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<Passnote> open({Identity? identity}) => passnoteLowLevel(
        config: const PassnoteConfig(
          appId: 'rk',
          salt: 'rk:v1',
          snapshotInterval: Duration.zero,
          antiEntropyInterval: Duration.zero,
        ),
        keyStore: keys,
        transport: InMemoryTransport(InMemoryBus()),
        deriveKey: (passphrase, _) async => List<int>.generate(
            32, (i) => (passphrase.codeUnitAt(0) + i) & 0xff),
        roomTag: (key) => 'room-${key.take(4).join("-")}',
        cipher: _XorCipher.new,
        mnemonicGenerator: (n) => List.filled(n, 'abandon'),
        validateMnemonic: (_) => true,
        engine: (db, collection, key) => SqliteCrdtTable(
          '${dir.path}/$db-$collection.sqlite',
          encryptionKey: key,
        ),
        identity: identity,
      );

  test('a collection not open during a revocation opens afterwards', () async {
    final me = _Identity(1);
    var passnote = await open(identity: me);
    final db = await passnote.openDatabase('d', passphrase: 'p');
    expect(db.deviceState, DeviceState.ready);
    await db.collection('notes', _codec).put({'id': 'n', 'text': 'kept'});
    final other = _Identity(2);
    await db.admitDevice(await other.publicKey, label: 'other');
    await passnote.close();

    // Revoke with `notes` closed: the group key rotates without it.
    passnote = await open(identity: me);
    await passnote.reopenDatabase('d');
    await passnote.revokeDevice('d', other.deviceId);
    await passnote.close();

    passnote = await open(identity: me);
    addTearDown(passnote.close);
    final again = await passnote.reopenDatabase('d');
    final notes = again.collection('notes', _codec);
    expect((await notes.get('n'))?['text'], 'kept');
    await notes.put({'id': 'n2', 'text': 'written after'});
    await passnote.close();

    // Brought up to date: it now opens under the current key directly.
    passnote = await open(identity: me);
    final last = await passnote.reopenDatabase('d');
    expect((await last.collection('notes', _codec).get('n2'))?['text'],
        'written after');
  });

  test('a collection not open during a passphrase rotation opens afterwards',
      () async {
    var passnote = await open();
    final db = await passnote.openDatabase('d', passphrase: 'old');
    await db.collection('notes', _codec).put({'id': 'n', 'text': 'kept'});
    await passnote.close();

    passnote = await open();
    await passnote.openDatabase('d', passphrase: 'old');
    await passnote.rotatePassphrase('d',
        oldPassphrase: 'old', newPassphrase: 'new');
    await passnote.close();

    passnote = await open();
    addTearDown(passnote.close);
    final again = await passnote.openDatabase('d', passphrase: 'new');
    expect((await again.collection('notes', _codec).get('n'))?['text'], 'kept');
  });
}
