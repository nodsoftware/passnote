// Rotating the passphrase: the roster and control key change, the group key
// and the data do not, and a rotation that dies halfway finishes itself on the
// next open.

import 'dart:convert';

import 'package:passnote/passnote.dart';
import 'package:passnote/engine.dart';
import 'package:test/test.dart';

/// A store that behaves like a disk-backed one in the ways this file cares
/// about: it keeps its rows between opens, and it refuses to open under a key
/// that did not write it.
class _KeyedTable extends MapCrdtTable {
  _KeyedTable(super.name, List<int> key) : storedKey = List.of(key);

  /// The key the "file" is encrypted under.
  List<int> storedKey;

  /// The key the caller is opening with.
  List<int>? attempted;

  /// Makes the next [rekey] die, standing in for a process that is killed
  /// halfway through a rotation.
  bool failRekey = false;

  /// A disk-backed store, as far as the layers above are concerned: that is
  /// what makes [Collection] call [init], and so what makes a wrong key
  /// surface at open time the way SQLCipher makes it surface.
  @override
  bool get isPersistent => true;

  @override
  Future<void> init() async {
    if (!_sameKey(attempted ?? const [], storedKey)) {
      throw const WrongPassphraseException();
    }
    await super.init();
  }

  @override
  Future<void> rekey(List<int> newKey) async {
    if (failRekey) throw StateError('killed mid-rotation');
    storedKey = List.of(newKey);
  }

  @override
  Future<void> close() async {}
}

/// Every store on this "device", surviving close and reopen.
class _Disk {
  final tables = <String, _KeyedTable>{};

  _KeyedTable open(String databaseId, String collection, List<int> key) {
    final table = tables.putIfAbsent(
      '$databaseId/$collection',
      () => _KeyedTable(collection, key),
    );
    table.attempted = key;
    return table;
  }

  /// The roster store, which is what a passphrase actually protects.
  _KeyedTable get roster => tables.entries
      .firstWhere((entry) => entry.key.endsWith(kDeviceCollection))
      .value;
}

class _MemKeyStore implements KeyStore {
  final keys = <String, List<int>>{};
  @override
  Future<List<int>?> getKey(String id) async => keys[id];
  @override
  Future<void> setKey(String id, List<int> key) async => keys[id] = key;
  @override
  Future<void> clear(String id) async => keys.remove(id);
}

/// Authenticating XOR cipher: a keyed marker lets decrypt fail closed.
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

class _TestIdentity implements Identity {
  _TestIdentity(int seed)
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
  Future<List<int>> sign(List<int> message) async => message;

  @override
  Future<bool> verify(
    List<int> message, {
    required List<int> signature,
    required DevicePublicKey signer,
  }) async =>
      true;

  @override
  Future<WrappedKey> wrapFor(DevicePublicKey peer, List<int> key) async {
    final ks = _ks(peer.keyExchange, key.length);
    return WrappedKey(
      ephemeralPublicKey: List<int>.of(peer.keyExchange),
      nonce: List<int>.filled(12, 0),
      ciphertext: [
        for (var i = 0; i < key.length; i++) key[i] ^ ks[i],
        ...List<int>.filled(16, 0xAA),
      ],
    );
  }

  @override
  Future<List<int>> unwrap(WrappedKey wrapped) async {
    if (!_eq(wrapped.ephemeralPublicKey, _pub.keyExchange)) {
      throw StateError('not sealed to this device');
    }
    final body = wrapped.ciphertext.sublist(0, wrapped.ciphertext.length - 16);
    final ks = _ks(_pub.keyExchange, body.length);
    return [for (var i = 0; i < body.length; i++) body[i] ^ ks[i]];
  }

  static List<int> _ks(List<int> seed, int n) =>
      List<int>.generate(n, (i) => seed[i % seed.length] ^ (i & 0xff));
  static bool _eq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

bool _sameKey(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

const _old = 'the old words';
const _new = 'the new words';

/// One device, rebuilt on every "launch" over the same disk and key store.
// ignore: library_private_types_in_public_api — a test helper, not an API.
Future<Passnote> launch(_Disk disk, _MemKeyStore store, InMemoryBus bus) =>
    passnoteLowLevel(
      config: const PassnoteConfig(
        appId: 'rot',
        salt: 'rot:v1',
        passphrasePolicy:
            PassphrasePolicy(strictness: PassphraseStrictness.reject),
      ),
      keyStore: store,
      transport: InMemoryTransport(bus),
      deriveKey: (passphrase, salt) async =>
          List<int>.generate(32, (i) => (passphrase.hashCode ^ i) & 0xff),
      roomTag: (key) => 'room-${key.take(4).join("-")}',
      cipher: _XorCipher.new,
      mnemonicGenerator: (n) => List.filled(n, 'abandon'),
      validateMnemonic: (phrase) => phrase != 'not a mnemonic',
      engine: disk.open,
      identity: _TestIdentity(1),
    );

void main() {
  late _Disk disk;
  late _MemKeyStore store;
  late InMemoryBus bus;

  setUp(() {
    disk = _Disk();
    store = _MemKeyStore();
    bus = InMemoryBus();
  });

  /// Opens the database, rotates it to [_new], and closes it again.
  Future<void> rotate(Passnote node) => node.rotatePassphrase(
        'db',
        oldPassphrase: _old,
        newPassphrase: _new,
      );

  /// A one-document collection, enough to prove data outlives a rotation.
  Collection<String> notesOf(Database db) => db.collection<String>(
        'notes',
        JsonCodec(
          toMap: (note) => {'id': 'n', 'v': note},
          fromMap: (map) => map['v'] as String,
          idOf: (_) => 'n',
        ),
      );

  test('the new words open it, and the data is all still there', () async {
    final node = await launch(disk, store, bus);
    final db = await node.openDatabase('db', passphrase: _old);
    await notesOf(db).put('written before the rotation');

    await rotate(node);

    // Still usable immediately: the handles the app is holding keep working,
    // because the stores were re-keyed rather than replaced.
    expect(await notesOf(db).get('n'), 'written before the rotation');
    expect(db.deviceState, DeviceState.ready);
    await node.close();

    // And after a restart, under the new words.
    final again = await launch(disk, store, bus);
    addTearDown(again.close);
    final reopened = await again.openDatabase('db', passphrase: _new);
    expect(reopened.deviceState, DeviceState.ready,
        reason: 'the group key is not derived from the passphrase');
    expect(await notesOf(reopened).get('n'), 'written before the rotation');
  });

  test('the old words are refused once they are no longer the words', () async {
    final node = await launch(disk, store, bus);
    await node.openDatabase('db', passphrase: _old);
    await rotate(node);
    await node.close();

    final again = await launch(disk, store, bus);
    addTearDown(again.close);
    await expectLater(
      again.openDatabase('db', passphrase: _old),
      throwsA(isA<WrongPassphraseException>()),
    );
  });

  test('a wrong current passphrase changes nothing', () async {
    final node = await launch(disk, store, bus);
    addTearDown(node.close);
    await node.openDatabase('db', passphrase: _old);
    final keyBefore = List.of(disk.roster.storedKey);

    await expectLater(
      node.rotatePassphrase('db',
          oldPassphrase: 'some other words', newPassphrase: _new),
      throwsA(isA<WrongPassphraseException>()),
    );

    expect(disk.roster.storedKey, keyBefore);
    expect(await node.hasPendingRotation('db'), isFalse);
  });

  test('a new phrase the policy rejects changes nothing', () async {
    final node = await launch(disk, store, bus);
    addTearDown(node.close);
    await node.openDatabase('db', passphrase: _old);
    final keyBefore = List.of(disk.roster.storedKey);

    await expectLater(
      node.rotatePassphrase('db',
          oldPassphrase: _old, newPassphrase: 'not a mnemonic'),
      throwsA(isA<WeakPassphraseException>()),
    );

    expect(disk.roster.storedKey, keyBefore);
    expect(await node.hasPendingRotation('db'), isFalse);
  });

  test('rotating to the same words is a no-op', () async {
    final node = await launch(disk, store, bus);
    addTearDown(node.close);
    final db = await node.openDatabase('db', passphrase: _old);
    final room = db.room;

    await node.rotatePassphrase('db', oldPassphrase: _old, newPassphrase: _old);

    expect(db.room, room);
    expect(await node.hasPendingRotation('db'), isFalse);
  });

  test('the discovery room moves with the passphrase', () async {
    final node = await launch(disk, store, bus);
    addTearDown(node.close);
    final db = await node.openDatabase('db', passphrase: _old);
    final before = db.room;

    await rotate(node);

    // A rotated device speaks in a different room, which is exactly why every
    // other device has to be rotated or paired again.
    expect(db.room, isNot(before));
  });

  test('a rotation killed mid-way finishes itself on the next open', () async {
    final node = await launch(disk, store, bus);
    await node.openDatabase('db', passphrase: _old);
    disk.roster.failRekey = true;

    await expectLater(rotate(node), throwsA(isA<StateError>()));
    expect(await node.hasPendingRotation('db'), isTrue,
        reason: 'the journal outlives the crash');
    await node.close();

    // The machine comes back. Nothing asks the user anything.
    disk.roster.failRekey = false;
    final again = await launch(disk, store, bus);
    addTearDown(again.close);
    expect(await again.hasPendingRotation('db'), isTrue);

    final reopened = await again.openDatabase('db', passphrase: _new);
    expect(reopened.deviceState, DeviceState.ready);
    expect(await again.hasPendingRotation('db'), isFalse);
  });

  test('a rotation killed after the stores were re-encrypted also finishes',
      () async {
    final node = await launch(disk, store, bus);
    await node.openDatabase('db', passphrase: _old);

    // Stand in for a kill between the re-encryption and the promotion: the
    // store is on the new key, the key store still points at the old one.
    final newKey = List<int>.generate(32, (i) => (_new.hashCode ^ i) & 0xff);
    await store.setKey(
      'rot/db#rotating',
      utf8.encode(jsonEncode({
        'v': 1,
        'key': base64Encode(newKey),
        'collections': [kDeviceCollection],
      })),
    );
    await disk.roster.rekey(newKey);
    await node.close();

    final again = await launch(disk, store, bus);
    addTearDown(again.close);
    final reopened = await again.openDatabase('db', passphrase: _new);

    expect(reopened.deviceState, DeviceState.ready);
    expect(await again.hasPendingRotation('db'), isFalse);
    expect(await store.getKey('rot/db'), newKey);
  });

  test('reopening without a passphrase also finishes an interrupted rotation',
      () async {
    final node = await launch(disk, store, bus);
    await node.openDatabase('db', passphrase: _old);
    disk.roster.failRekey = true;
    await expectLater(rotate(node), throwsA(isA<StateError>()));
    await node.close();

    disk.roster.failRekey = false;
    final again = await launch(disk, store, bus);
    addTearDown(again.close);

    // reopenDatabase takes no passphrase at all, so it has to be the one that
    // sorts this out — this is the cold-start path every app uses.
    final reopened = await again.reopenDatabase('db');
    expect(reopened.deviceState, DeviceState.ready);
    expect(await again.hasPendingRotation('db'), isFalse);
  });

  test('a rotation cannot be finished while the database is open', () async {
    final node = await launch(disk, store, bus);
    addTearDown(node.close);
    await node.openDatabase('db', passphrase: _old);
    await store.setKey(
        'rot/db#rotating',
        utf8.encode(jsonEncode({
          'v': 1,
          'key': base64Encode(List<int>.filled(32, 7)),
          'collections': [kDeviceCollection],
        })));

    await expectLater(
      node.resumePendingRotation('db'),
      throwsA(isA<StateError>()),
    );
  });
}
