import 'package:conclave/conclave.dart';
import 'package:conclave/engine.dart';
import 'package:test/test.dart';

/// Authenticating XOR cipher: the keyed two-byte marker lets `decrypt` fail
/// closed under the wrong key, so [Database] can tell its roster cipher from its
/// (rotating) data cipher.
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

class _MemKeyStore implements KeyStore {
  final _keys = <String, List<int>>{};
  @override
  Future<List<int>?> getKey(String id) async => _keys[id];
  @override
  Future<void> setKey(String id, List<int> key) async => _keys[id] = key;
  @override
  Future<void> clear(String id) async => _keys.remove(id);
}

/// Deterministic [Identity] with real "sealed to one device" semantics.
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

final _noteCodec = JsonCodec<Map<String, dynamic>>(
  toMap: (m) => m,
  fromMap: (m) => m,
  idOf: (m) => m['id'] as String,
);

Future<void> _settle() => pumpEventQueue(times: 40);

void main() {
  Future<Conclave> openNode(InMemoryBus bus, int seed) => Conclave.lowLevel(
        config: const ConclaveConfig(
          appId: 'rev',
          salt: 'rev:v1',
          snapshotInterval: Duration.zero,
        ),
        keyStore: _MemKeyStore(),
        transport: InMemoryTransport(bus),
        deriveKey: (_, __) async => List<int>.filled(32, 42),
        roomTag: (_) => 'room',
        cipher: _XorCipher.new,
        mnemonicGenerator: (n) => List.filled(n, 'abandon'),
        validateMnemonic: (_) => true,
        engine: (dbId, collection, _) => MapCrdtTable(collection),
        identity: _TestIdentity(seed),
      );

  /// A founds, then admits [joiners] directly (skipping the PAKE), and each
  /// joiner syncs the roster to `ready`.
  Future<(Conclave a, List<Conclave> joiners)> ring(
    InMemoryBus bus,
    int joinerCount,
  ) async {
    final a = await openNode(bus, 1);
    final dbA = await a.openDatabase('d', passphrase: 'p');
    if (dbA.deviceState != DeviceState.ready) {
      await dbA.foundGroup(label: 'A');
    }

    final joiners = <Conclave>[];
    for (var i = 0; i < joinerCount; i++) {
      final j = await openNode(bus, 10 + i);
      await _settle();
      await j.openDatabase('d', passphrase: 'p');
      await dbA.admitDevice(await j.identity.publicKey, label: 'J$i');
      await a.forceSync();
      await _settle();
      await j.reopenDatabase('d').then((db) => db.refreshDeviceState());
      joiners.add(j);
    }
    return (a, joiners);
  }

  test('revoke rotates the key: peers converge, the revoked device is frozen',
      () async {
    final bus = InMemoryBus();
    final (a, joiners) = await ring(bus, 2);
    final b = joiners[0];
    final c = joiners[1];
    addTearDown(() async {
      await a.close();
      await b.close();
      await c.close();
    });

    final dbA = await a.reopenDatabase('d');
    final dbB = await b.reopenDatabase('d');
    final dbC = await c.reopenDatabase('d');
    final notesA = dbA.collection<Map<String, dynamic>>('notes', _noteCodec);
    final notesB = dbB.collection<Map<String, dynamic>>('notes', _noteCodec);
    final notesC = dbC.collection<Map<String, dynamic>>('notes', _noteCodec);

    await notesA.put({'id': 'k', 'v': 'before'});
    await a.forceSync();
    await _settle();
    expect((await notesB.get('k'))?['v'], 'before');
    expect((await notesC.get('k'))?['v'], 'before');

    // A revokes C.
    await a.revokeDevice('d', c.identity.deviceId);
    await a.forceSync();
    await _settle();
    await dbB.refreshDeviceState();
    await dbC.refreshDeviceState();

    expect(dbB.deviceState, DeviceState.ready);
    expect(dbC.deviceState, DeviceState.revoked);

    // New data reaches B, not C.
    await notesA.put({'id': 'k', 'v': 'after'});
    await a.forceSync();
    await _settle();
    expect((await notesB.get('k'))?['v'], 'after');
    expect((await notesC.get('k'))?['v'], 'before',
        reason: 'C is on the old key and cannot decrypt new frames');

    // The roster agrees on every non-revoked device.
    final rosterA = {for (final d in await a.devices('d')) d.id: d.revoked};
    final rosterB = {for (final d in await b.devices('d')) d.id: d.revoked};
    expect(rosterA, rosterB);
    expect(rosterA[c.identity.deviceId], isTrue);
    expect(rosterA[a.identity.deviceId], isFalse);
  });

  test('concurrent revocations of different devices converge, both removed',
      () async {
    final bus = InMemoryBus();
    final (a, joiners) = await ring(bus, 3);
    final b = joiners[0];
    final c = joiners[1];
    final d = joiners[2];
    addTearDown(() async {
      for (final n in [a, b, c, d]) {
        await n.close();
      }
    });

    final dbA = await a.reopenDatabase('d');
    final dbB = await b.reopenDatabase('d');

    // Offline: A revokes C, B revokes D at the same time.
    bus.paused = true;
    await a.revokeDevice('d', c.identity.deviceId);
    await b.revokeDevice('d', d.identity.deviceId);
    bus.paused = false;
    await a.forceSync();
    await b.forceSync();
    await _settle();
    await a.forceSync();
    await b.forceSync();
    await _settle();
    await dbA.refreshDeviceState();
    await dbB.refreshDeviceState();

    final rosterA = {for (final e in await a.devices('d')) e.id: e.revoked};
    final rosterB = {for (final e in await b.devices('d')) e.id: e.revoked};
    expect(rosterA, rosterB, reason: 'roster converges');
    expect(rosterA[c.identity.deviceId], isTrue);
    expect(rosterA[d.identity.deviceId], isTrue);
    expect(rosterA[a.identity.deviceId], isFalse);
    expect(rosterA[b.identity.deviceId], isFalse);

    // A and B still share a working group key: data flows between them.
    final notesA = dbA.collection<Map<String, dynamic>>('notes', _noteCodec);
    final notesB = dbB.collection<Map<String, dynamic>>('notes', _noteCodec);
    await notesA.put({'id': 'x', 'v': 'sync'});
    await a.forceSync();
    await _settle();
    expect((await notesB.get('x'))?['v'], 'sync');
    expect(dbA.deviceState, DeviceState.ready);
    expect(dbB.deviceState, DeviceState.ready);
  });

  test('renameDevice propagates', () async {
    final bus = InMemoryBus();
    final (a, joiners) = await ring(bus, 1);
    final b = joiners[0];
    addTearDown(() async {
      await a.close();
      await b.close();
    });

    await a.renameDevice('d', b.identity.deviceId, 'B renamed');
    await a.forceSync();
    await _settle();

    final onB =
        (await b.devices('d')).firstWhere((e) => e.id == b.identity.deviceId);
    expect(onB.label, 'B renamed');
  });
}
