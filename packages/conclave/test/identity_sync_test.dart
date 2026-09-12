import 'package:conclave/conclave.dart';
import 'package:conclave/engine.dart';
import 'package:test/test.dart';

/// Pass-through cipher: these tests check roster sync and group-key resolution,
/// not the wire format.
class _PlainCipher implements Cipher {
  @override
  Future<List<int>> encrypt(List<int> plaintext) async => plaintext;
  @override
  Future<List<int>> decrypt(List<int> ciphertext) async => ciphertext;
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

/// A deterministic [Identity] with real "sealed to one device" semantics: any
/// party can [wrapFor] a peer given its public key, but only the device whose
/// public key matches can [unwrap]. The seal is a XOR keystream — enough to
/// prove the plumbing without pulling in `conclave_crypto`.
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
    final ks = _keystream(peer.keyExchange, key.length);
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
    final mine = _pub.keyExchange;
    if (!_sameBytes(wrapped.ephemeralPublicKey, mine)) {
      throw StateError('wrapped key was not sealed to this device');
    }
    final body = wrapped.ciphertext.sublist(0, wrapped.ciphertext.length - 16);
    final ks = _keystream(mine, body.length);
    return [for (var i = 0; i < body.length; i++) body[i] ^ ks[i]];
  }

  static List<int> _keystream(List<int> seed, int n) =>
      List<int>.generate(n, (i) => seed[i % seed.length] ^ (i & 0xff));

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

final _noteCodec = JsonCodec<Map<String, dynamic>>(
  toMap: (m) => m,
  fromMap: (m) => m,
  idOf: (m) => m['id'] as String,
);

const _baseKey = <int>[9, 9, 9]; // stand-in passphrase-derived key

void main() {
  /// Records the key each collection's engine was built with, so a test can
  /// assert user collections use the group key, not [_baseKey].
  late Map<String, List<int>> engineKeys;

  Future<Conclave> openNode(InMemoryBus bus, int seed) => conclaveLowLevel(
        config: const ConclaveConfig(
          appId: 'test',
          salt: 'test:v1',
          snapshotInterval: Duration.zero,
        ),
        keyStore: _MemKeyStore(),
        transport: InMemoryTransport(bus),
        deriveKey: (_, __) async => _baseKey,
        roomTag: (_) => 'room',
        cipher: (_) => _PlainCipher(),
        mnemonicGenerator: (words) => List.filled(words, 'abandon'),
        validateMnemonic: (_) => true,
        engine: (dbId, collection, key) {
          engineKeys['$dbId/$collection'] = key;
          return MapCrdtTable(collection);
        },
        identity: _TestIdentity(seed),
      );

  setUp(() => engineKeys = {});

  test('user code cannot open the reserved device collection', () async {
    final a = await openNode(InMemoryBus(), 1);
    addTearDown(a.close);
    final db = await a.openDatabase('d', passphrase: 'p');

    expect(
      () => db.collection<Map<String, dynamic>>(kDeviceCollection, _noteCodec),
      throwsArgumentError,
    );
  });

  test('a lone first device founds the group key on open', () async {
    final a = await openNode(InMemoryBus(), 1);
    addTearDown(a.close);
    final db = await a.openDatabase('d', passphrase: 'p');

    expect(db.deviceState, DeviceState.ready);
    final devices = await db.listDevices();
    expect(devices, hasLength(1));
    expect(devices.single.deviceId, a.identity.deviceId);

    // A user collection is encrypted with the group key, not the base key.
    await db.collection<Map<String, dynamic>>('notes', _noteCodec).ready;
    expect(engineKeys['d/notes'], isNot(_baseKey));
    expect(engineKeys['d/__conclave_devices'], _baseKey);
  });

  test('a second device opens in needs-pairing state, then unwraps on admit',
      () async {
    final bus = InMemoryBus();
    final a = await openNode(bus, 1);
    final dbA = await a.openDatabase('d', passphrase: 'p');
    addTearDown(a.close);

    final b = await openNode(bus, 2);
    addTearDown(b.close);
    await pumpEventQueue();
    final dbB = await b.openDatabase('d', passphrase: 'p');

    expect(dbB.deviceState, DeviceState.needsPairing);

    // A admits B; the wrap syncs; B re-resolves and holds the group key.
    await dbA.admitDevice(await b.identity.publicKey, label: "B's laptop");
    await a.forceSync();
    await pumpEventQueue();
    expect(await dbB.refreshDeviceState(), DeviceState.ready);

    // Both devices' user collections end up on the same group key.
    await dbA.collection<Map<String, dynamic>>('notes', _noteCodec).ready;
    await dbB.collection<Map<String, dynamic>>('notes', _noteCodec).ready;
    expect(engineKeys['d/notes'], isNot(_baseKey));
  });

  test('opening a user collection before pairing throws at the call site',
      () async {
    final bus = InMemoryBus();
    final a = await openNode(bus, 1);
    await a.openDatabase('d', passphrase: 'p');
    addTearDown(a.close);

    final b = await openNode(bus, 2);
    addTearDown(b.close);
    await pumpEventQueue();
    final dbB = await b.openDatabase('d', passphrase: 'p'); // no throw

    // Membership is a precondition checked synchronously: the failure is
    // catchable with an ordinary try/catch where the collection is created,
    // not later on its async reads.
    expect(
      () => dbB.collection<Map<String, dynamic>>('notes', _noteCodec),
      throwsStateError,
    );
  });

  test('concurrent roster edits on two devices converge', () async {
    final bus = InMemoryBus();
    final a = await openNode(bus, 1);
    final dbA = await a.openDatabase('d', passphrase: 'p');
    addTearDown(a.close);

    final b = await openNode(bus, 2);
    addTearDown(b.close);
    await pumpEventQueue();
    final dbB = await b.openDatabase('d', passphrase: 'p');

    await dbA.admitDevice(await b.identity.publicKey, label: 'B');
    await a.forceSync();
    await pumpEventQueue();
    expect(await dbB.refreshDeviceState(), DeviceState.ready);

    // Offline: A admits C, B admits D at the same time.
    bus.paused = true;
    await dbA.admitDevice(await _TestIdentity(3).publicKey, label: 'C');
    await dbB.admitDevice(await _TestIdentity(4).publicKey, label: 'D');
    bus.paused = false;
    await a.forceSync();
    await b.forceSync();
    await pumpEventQueue();

    final rosterA = {for (final d in await dbA.listDevices()) d.deviceId};
    final rosterB = {for (final d in await dbB.listDevices()) d.deviceId};
    expect(rosterA, rosterB);
    expect(
      rosterA,
      containsAll([
        a.identity.deviceId,
        b.identity.deviceId,
        _TestIdentity(3).deviceId,
        _TestIdentity(4).deviceId,
      ]),
    );
  });

  test('a revoked flag propagates to the revoked device', () async {
    final bus = InMemoryBus();
    final a = await openNode(bus, 1);
    final dbA = await a.openDatabase('d', passphrase: 'p');
    addTearDown(a.close);

    final b = await openNode(bus, 2);
    addTearDown(b.close);
    await pumpEventQueue();
    final dbB = await b.openDatabase('d', passphrase: 'p');

    await dbA.admitDevice(await b.identity.publicKey, label: 'B');
    await a.forceSync();
    await pumpEventQueue();
    expect(await dbB.refreshDeviceState(), DeviceState.ready);

    await dbA.revokeDevice(b.identity.deviceId);
    await a.forceSync();
    await pumpEventQueue();

    expect(await dbB.refreshDeviceState(), DeviceState.revoked);
    final bRecord = (await dbB.listDevices())
        .firstWhere((d) => d.deviceId == b.identity.deviceId);
    expect(bRecord.revoked, isTrue);
  });
}
