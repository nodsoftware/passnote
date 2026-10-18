import 'package:passnote/passnote.dart';
import 'package:passnote/engine.dart';
import 'package:test/test.dart';

/// Authenticating XOR cipher: the keyed two-byte marker lets `decrypt` fail
/// closed under the wrong key, so [Database] can tell its roster cipher from
/// its (rotating) data cipher.
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

/// The deterministic test stand-in for the phrase → keypair derivation: the
/// same phrase always yields the same identity.
Future<Identity> _recoveryIdentity(String phrase, String salt) async {
  var acc = salt.length;
  for (final u in phrase.codeUnits) {
    acc = (acc * 33 + u) & 0xffff;
  }
  return _TestIdentity(0x4000 + acc);
}

final _noteCodec = JsonCodec<Map<String, dynamic>>(
  toMap: (m) => m,
  fromMap: (m) => m,
  idOf: (m) => m['id'] as String,
);

const _passphrase = 'w0 w1 w2 w3 w4 w5 w6 w7 w8 w9 w10 w11';

void main() {
  Future<Passnote> openNode(
    InMemoryBus bus,
    int seed, {
    bool recoveryEnabled = true,
    bool withFactory = true,
  }) =>
      passnoteLowLevel(
        config: PassnoteConfig(
          appId: 'rec',
          salt: 'rec:v1',
          snapshotInterval: Duration.zero,
          recoveryEnabled: recoveryEnabled,
        ),
        keyStore: _MemKeyStore(),
        transport: InMemoryTransport(bus),
        deriveKey: (p, _) async =>
            List<int>.generate(32, (i) => p.codeUnitAt(i % p.length)),
        roomTag: (_) => 'room',
        cipher: _XorCipher.new,
        mnemonicGenerator: (n) => List.generate(n, (i) => 'word$i'),
        validateMnemonic: (p) => p.split(' ').length == 24,
        engine: (dbId, collection, _) => MapCrdtTable(collection),
        identity: _TestIdentity(seed),
        recoveryIdentity: withFactory ? _recoveryIdentity : null,
      );

  test('a fresh install recovers with the phrase and converges', () async {
    final bus = InMemoryBus();
    final a = await openNode(bus, 1);
    addTearDown(a.close);

    final dbA = await a.openDatabase('home', passphrase: _passphrase);
    expect(dbA.deviceState, DeviceState.ready, reason: 'founded alone');
    await dbA
        .collection<Map<String, dynamic>>('notes', _noteCodec)
        .put({'id': 'n1', 'text': 'kept'});

    final words = await a.enableRecovery('home');
    expect(words, hasLength(24));

    // A fresh device that was never paired: only the phrase (and the
    // passphrase) travel to it.
    final b = await openNode(bus, 2);
    addTearDown(b.close);
    final dbB = await b.recoverFrom(
      'home',
      words.join(' '),
      passphrase: _passphrase,
    );
    expect(dbB.deviceState, DeviceState.ready);

    final notesB = dbB.collection<Map<String, dynamic>>('notes', _noteCodec);
    var docs = await notesB.all();
    for (var i = 0; i < 100 && docs.isEmpty; i++) {
      await dbB.forceSync();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      docs = await notesB.all();
    }
    expect(docs.single['text'], 'kept');

    // The recovered device is now an ordinary roster member on both sides.
    await dbA.forceSync();
    await pumpEventQueue(times: 40);
    final labels = (await dbA.devices()).map((d) => d.label);
    expect(labels, contains('recovered device'));
    expect(labels, contains('recovery phrase'));
  });

  test('recovery APIs throw when the app did not opt in', () async {
    final bus = InMemoryBus();
    final a = await openNode(bus, 3, recoveryEnabled: false);
    addTearDown(a.close);
    await a.openDatabase('home', passphrase: _passphrase);

    expect(() => a.enableRecovery('home'), throwsStateError);
    expect(
      () => a.recoverFrom('home2', 'any phrase', passphrase: _passphrase),
      throwsStateError,
    );
  });

  test('recovery APIs throw when no derivation is installed', () async {
    final bus = InMemoryBus();
    final a = await openNode(bus, 4, withFactory: false);
    addTearDown(a.close);
    await a.openDatabase('home', passphrase: _passphrase);

    expect(() => a.enableRecovery('home'), throwsStateError);
  });

  test('an invalid phrase is rejected before touching the network', () async {
    final bus = InMemoryBus();
    final a = await openNode(bus, 5);
    addTearDown(a.close);

    expect(
      () => a.recoverFrom('home', 'too short', passphrase: _passphrase),
      throwsArgumentError,
    );
  });

  test('a revoked recovery phrase can no longer recover', () async {
    final bus = InMemoryBus();
    final a = await openNode(bus, 6);
    addTearDown(a.close);
    final dbA = await a.openDatabase('home', passphrase: _passphrase);
    final words = await a.enableRecovery('home');

    // Withdraw the phrase like any device.
    final recovery =
        (await dbA.devices()).singleWhere((d) => d.label == 'recovery phrase');
    await a.revokeDevice('home', recovery.id);

    final b = await openNode(bus, 7);
    addTearDown(b.close);
    await expectLater(
      b.recoverFrom('home', words.join(' '), passphrase: _passphrase),
      throwsStateError,
    );
  });
}
