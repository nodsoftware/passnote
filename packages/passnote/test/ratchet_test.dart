import 'package:passnote/passnote.dart';
import 'package:passnote/engine.dart';
import 'package:test/test.dart';

/// Authenticating XOR cipher, keyed so `decrypt` fails closed under the wrong
/// key — required for both the ratchet AEAD and [Database]'s cipher probe.
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
    final body = wrapped.ciphertext.sublist(0, wrapped.ciphertext.length - 16);
    final ks = _ks(_pub.keyExchange, body.length);
    return [for (var i = 0; i < body.length; i++) body[i] ^ ks[i]];
  }

  static List<int> _ks(List<int> seed, int n) =>
      List<int>.generate(n, (i) => seed[i % seed.length] ^ (i & 0xff));
}

final _noteCodec = JsonCodec<Map<String, dynamic>>(
  toMap: (m) => m,
  fromMap: (m) => m,
  idOf: (m) => m['id'] as String,
);

Future<void> _settle() => pumpEventQueue(times: 80);

Cipher _cipherFor(List<int> key) => _XorCipher(key);

void main() {
  group('RatchetSession (unit)', () {
    final root = deriveRatchetRoot(
      groupKey: List<int>.filled(32, 5),
      nonceA: newRatchetNonce(),
      nonceB: newRatchetNonce(),
      nodeA: 'alice',
      nodeB: 'bob',
    );

    RatchetSession low() => RatchetSession.establish(
        root: root, thisNodeIsLow: true, cipherFactory: _cipherFor);
    RatchetSession high() => RatchetSession.establish(
        root: root, thisNodeIsLow: false, cipherFactory: _cipherFor);

    test('a session round-trips messages in order', () async {
      final a = low();
      final b = high();
      final f0 = await a.seal([1, 2, 3]);
      final f1 = await a.seal([4, 5, 6]);
      expect(await b.open(f0), [1, 2, 3]);
      expect(await b.open(f1), [4, 5, 6]);
    });

    test('a frame cannot be reopened once the chain has ratcheted past it',
        () async {
      final a = low();
      final b = high();
      final frames = [
        for (var i = 0; i < 5; i++) await a.seal([i]),
      ];
      // Receive 0, 1, 2 in order.
      for (var i = 0; i < 3; i++) {
        expect(await b.open(frames[i]), [i]);
      }
      // The keys for 0..2 are gone: a replayed / late-captured old frame fails.
      expect(await b.open(frames[0]), isNull);
      expect(await b.open(frames[1]), isNull);
      // The chain still moves forward.
      expect(await b.open(frames[3]), [3]);
    });

    test('a fresh handshake (new nonces) yields an incompatible chain',
        () async {
      final a = low();
      final frame = await a.seal([9, 9, 9]);

      final root2 = deriveRatchetRoot(
        groupKey: List<int>.filled(32, 5),
        nonceA: newRatchetNonce(),
        nonceB: newRatchetNonce(),
        nodeA: 'alice',
        nodeB: 'bob',
      );
      final reconnected = RatchetSession.establish(
          root: root2, thisNodeIsLow: false, cipherFactory: _cipherFor);
      expect(await reconnected.open(frame), isNull);
    });

    test('a slightly reordered frame still opens', () async {
      final a = low();
      final b = high();
      final f0 = await a.seal([0]);
      final f1 = await a.seal([1]);
      final f2 = await a.seal([2]);
      expect(await b.open(f0), [0]);
      expect(await b.open(f2), [2]); // f1 skipped, key stashed
      expect(await b.open(f1), [1]);
    });
  });

  group('over the transport', () {
    Future<Passnote> node(InMemoryBus bus, int seed, KeyStore ks) =>
        passnoteLowLevel(
          config: const PassnoteConfig(
            appId: 'r',
            salt: 'r:v1',
            snapshotInterval: Duration.zero,
          ),
          keyStore: ks,
          transport: InMemoryTransport(bus),
          deriveKey: (_, __) async => List<int>.filled(32, 7),
          roomTag: (_) => 'room',
          cipher: _XorCipher.new,
          mnemonicGenerator: (n) => List.filled(n, 'abandon'),
          validateMnemonic: (_) => true,
          engine: (_, c, __) => MapCrdtTable(c),
          identity: _TestIdentity(seed),
        );

    test('two devices converge over a ratcheting session', () async {
      final bus = InMemoryBus();
      final a = await node(bus, 1, _MemKeyStore());
      final b = await node(bus, 2, _MemKeyStore());
      addTearDown(() async {
        await a.close();
        await b.close();
      });

      final dbA = await a.openDatabase('d', passphrase: 'p');
      await dbA.foundGroup(label: 'A');
      await _settle();
      final dbB = await b.openDatabase('d', passphrase: 'p');
      await dbA.admitDevice(await b.identity.publicKey, label: 'B');
      await a.forceSync();
      await _settle();
      await dbB.refreshDeviceState();
      expect(dbB.deviceState, DeviceState.ready);
      // Let the ratchet handshake (a few extra round trips) settle.
      await a.forceSync();
      await _settle();

      final notesA = dbA.collection<Map<String, dynamic>>('notes', _noteCodec);
      final notesB = dbB.collection<Map<String, dynamic>>('notes', _noteCodec);
      await notesA.put({'id': 'n1', 'v': 'hello'});
      await a.forceSync();
      await _settle();
      expect((await notesB.get('n1'))?['v'], 'hello');
    });

    test('a reconnect starts a fresh chain and still converges', () async {
      final bus = InMemoryBus();
      final aKs = _MemKeyStore();
      final bKs = _MemKeyStore();
      final a = await node(bus, 1, aKs);
      var b = await node(bus, 2, bKs);

      final dbA = await a.openDatabase('d', passphrase: 'p');
      await dbA.foundGroup(label: 'A');
      await _settle();
      final dbB1 = await b.openDatabase('d', passphrase: 'p');
      await dbA.admitDevice(await b.identity.publicKey, label: 'B');
      await a.forceSync();
      await _settle();
      await dbB1.refreshDeviceState();
      expect(dbB1.deviceState, DeviceState.ready);

      final notesA = dbA.collection<Map<String, dynamic>>('notes', _noteCodec);
      await notesA.put({'id': 'x', 'v': 1});
      await a.forceSync();
      await _settle();

      // B disconnects and comes back as a new instance sharing its key store.
      await b.close();
      await _settle();
      b = await node(bus, 2, bKs);
      addTearDown(() async {
        await a.close();
        await b.close();
      });
      final dbB2 = await b.reopenDatabase('d');
      await b.forceSync();
      await _settle();
      await dbB2.refreshDeviceState();
      expect(dbB2.deviceState, DeviceState.ready);

      final notesB2 =
          dbB2.collection<Map<String, dynamic>>('notes', _noteCodec);
      await notesB2.ready;
      await b.forceSync();
      await _settle();
      // Data from before the reconnect is pulled over the fresh chain…
      expect((await notesB2.get('x'))?['v'], 1);
      // …and new data flows over the fresh chain.
      await notesA.put({'id': 'y', 'v': 2});
      await a.forceSync();
      await _settle();
      expect((await notesB2.get('y'))?['v'], 2);
    });
  });
}
