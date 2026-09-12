import 'dart:convert';
import 'dart:math';

import 'package:conclave/conclave.dart';
import 'package:conclave/engine.dart';
import 'package:test/test.dart';

/// A deterministic stand-in for a real PAKE. Not secure — it exists to exercise
/// the pairing state machine and [Conclave] wiring. The real SPAKE2 is checked
/// against the RFC 9382 vectors in `conclave_crypto`.
class _FakePake implements Pake {
  @override
  PakeSession start({
    required bool initiator,
    required List<int> secret,
    List<int> initiatorId = const [],
    List<int> responderId = const [],
  }) =>
      _FakeSession(initiator, secret);
}

class _FakeSession implements PakeSession {
  _FakeSession(this._initiator, this._secret)
      : _nonce = List<int>.generate(16, (_) => _rng.nextInt(256));

  static final _rng = Random.secure();
  final bool _initiator;
  final List<int> _secret;
  final List<int> _nonce;

  @override
  List<int> get message => _nonce;

  @override
  PakeResult finish(List<int> peerMessage) {
    if (peerMessage.length != 16) {
      throw const FormatException('bad PAKE message');
    }
    final lo = _initiator ? _nonce : peerMessage;
    final hi = _initiator ? peerMessage : _nonce;
    final shared = _mix([...lo, ...hi, ..._secret]);
    final ci = _mix([...utf8.encode('i'), ...shared]);
    final cr = _mix([...utf8.encode('r'), ...shared]);
    return PakeResult(
      sharedSecret: shared,
      localConfirmation: _initiator ? ci : cr,
      expectedPeerConfirmation: _initiator ? cr : ci,
    );
  }

  static List<int> _mix(List<int> data) {
    var h = 0x811c9dc5;
    final out = <int>[];
    for (var round = 0; round < 32; round++) {
      for (final b in data) {
        h = ((h ^ (b + round)) * 0x01000193) & 0xffffffff;
      }
      out.add(h & 0xff);
      h = ((h << 1) | (h >>> 31)) & 0xffffffff;
    }
    return out;
  }
}

/// Authenticating XOR cipher over a key: a two-byte keyed marker lets `decrypt`
/// fail closed when the wrong key is tried, which is what lets [Database] pick
/// between its roster and data ciphers.
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

final _noteCodec = JsonCodec<Map<String, dynamic>>(
  toMap: (m) => m,
  fromMap: (m) => m,
  idOf: (m) => m['id'] as String,
);

void main() {
  Future<Conclave> openNode(InMemoryBus bus, int seed, {Pake? pake}) =>
      conclaveLowLevel(
        config: const ConclaveConfig(
          appId: 'pair',
          salt: 'pair:v1',
          snapshotInterval: Duration.zero,
        ),
        keyStore: _MemKeyStore(),
        transport: InMemoryTransport(bus),
        // Derived key varies with the passphrase so the roster key A shares with
        // B is meaningful; the pairing box/rendezvous use fixed salts.
        deriveKey: (passphrase, salt) async => List<int>.generate(
            32, (i) => (passphrase.hashCode ^ salt.hashCode ^ i) & 0xff),
        roomTag: (key) => 'room-${key.take(4).join("-")}',
        cipher: _XorCipher.new,
        mnemonicGenerator: (n) => List.filled(n, 'abandon'),
        validateMnemonic: (_) => true,
        engine: (dbId, collection, _) => MapCrdtTable(collection),
        identity: _TestIdentity(seed),
        pake: pake ?? _FakePake(),
      );

  test('two devices pair with a correct code and converge on user data',
      () async {
    final bus = InMemoryBus();
    final a = await openNode(bus, 1);
    addTearDown(a.close);
    final b = await openNode(bus, 2);
    addTearDown(b.close);

    final dbA = await a.openDatabase('shared', passphrase: 'hunter2');
    expect(dbA.deviceState, DeviceState.needsPairing,
        reason: 'A has a peer at open, so it does not auto-found');

    final code = await a.startPairing('shared', joinerLabel: "B's phone");
    expect(code.digits, matches(RegExp(r'^\d{9}$')));

    final dbB = await b.pairWith('shared', PairingCode.parse(code.display));
    expect(dbB.deviceState, DeviceState.ready);
    expect(dbA.deviceState, DeviceState.ready);

    final roster = {for (final d in await dbA.listDevices()) d.deviceId};
    expect(roster, containsAll([a.identity.deviceId, b.identity.deviceId]));

    // User data now flows both ways over the shared group key.
    final notesA = dbA.collection<Map<String, dynamic>>('notes', _noteCodec);
    final notesB = dbB.collection<Map<String, dynamic>>('notes', _noteCodec);
    await notesA.put({'id': 'n1', 'text': 'from A'});
    await notesA
        .watch()
        .firstWhere((_) => true)
        .timeout(const Duration(seconds: 2));
    await b.forceSync();
    await pumpEventQueue();
    expect((await notesB.get('n1'))?['text'], 'from A');
  });

  test(
      'a device that founded a rival group offline recovers with forget '
      'then pairWith', () async {
    final lan = InMemoryBus();
    final offline = InMemoryBus();

    // A founds the real group and writes data.
    final a = await openNode(lan, 1);
    addTearDown(a.close);
    final dbA = await a.openDatabase('shared', passphrase: 'hunter2');
    if (dbA.deviceState != DeviceState.ready) await dbA.foundGroup();
    final notesA = dbA.collection<Map<String, dynamic>>('notes', _noteCodec);
    await notesA.put({'id': 'n1', 'text': 'the real group'});

    // B's device state persists across its two sessions (key store, roster
    // pins, and stored records), like an app restarting.
    final bStore = _MemKeyStore();
    final bEngines = <String, MapCrdtTable>{};
    Future<Conclave> openB(InMemoryBus bus) => conclaveLowLevel(
          config: const ConclaveConfig(
            appId: 'pair',
            salt: 'pair:v1',
            snapshotInterval: Duration.zero,
          ),
          keyStore: bStore,
          transport: InMemoryTransport(bus),
          deriveKey: (passphrase, salt) async => List<int>.generate(
              32, (i) => (passphrase.hashCode ^ salt.hashCode ^ i) & 0xff),
          roomTag: (key) => 'room-${key.take(4).join("-")}',
          cipher: _XorCipher.new,
          mnemonicGenerator: (n) => List.filled(n, 'abandon'),
          validateMnemonic: (_) => true,
          engine: (dbId, collection, _) => bEngines.putIfAbsent(
              '$dbId/$collection', () => MapCrdtTable(collection)),
          identity: _TestIdentity(2),
          pake: _FakePake(),
        );

    // Session 1, offline: no peer is connected at open, so B founds a RIVAL
    // group — ready, encrypted, and wrong.
    var b = await openB(offline);
    final rival = await b.openDatabase('shared', passphrase: 'hunter2');
    expect(rival.deviceState, DeviceState.ready,
        reason: 'offline open auto-founds: this is the trap');
    await b.close();

    // Session 2, back on the real network: the rival persisted, and its
    // pinned founder keeps it a rival — syncing does not merge groups.
    b = await openB(lan);
    addTearDown(b.close);
    await b.reopenDatabase('shared');

    // The documented way out: forget the rival (drops its key and roster
    // pins), delete its local data (the disk engine's files; here the
    // in-memory stores), then join the real group by code.
    await b.forget('shared');
    bEngines.clear();

    final code = await a.startPairing('shared', joinerLabel: 'B again');
    final dbB = await b.pairWith('shared', PairingCode.parse(code.display));
    expect(dbB.deviceState, DeviceState.ready);
    final notesB = dbB.collection<Map<String, dynamic>>('notes', _noteCodec);
    Map<String, dynamic>? note;
    for (var i = 0; i < 100 && note == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      note = await notesB.get('n1');
    }
    expect(note?['text'], 'the real group',
        reason: "after forget + pairWith, B is in the founder's group");
  });

  test('a joiner receives data written before it paired, unprompted', () async {
    final bus = InMemoryBus();
    final a = await openNode(bus, 1);
    addTearDown(a.close);

    // A is alone when it opens, so it founds the group and writes data.
    final dbA = await a.openDatabase('shared', passphrase: 'hunter2');
    final notesA = dbA.collection<Map<String, dynamic>>('notes', _noteCodec);
    await notesA.put({'id': 'n1', 'text': 'written before B existed'});

    final b = await openNode(bus, 2);
    addTearDown(b.close);
    final code = await a.startPairing('shared', joinerLabel: "B's phone");
    final dbB = await b.pairWith('shared', PairingCode.parse(code.display));
    expect(dbB.deviceState, DeviceState.ready);

    // No forceSync: the joiner asks for the collection it just opened, which
    // the sponsor's handshake could not have named.
    final notesB = dbB.collection<Map<String, dynamic>>('notes', _noteCodec);
    await notesB
        .watch()
        .firstWhere((all) => all.isNotEmpty)
        .timeout(const Duration(seconds: 5));
    expect((await notesB.get('n1'))?['text'], 'written before B existed');
  });

  test('a wrong code is rejected without exposing the group key', () async {
    final bus = InMemoryBus();
    final a = await openNode(bus, 1);
    addTearDown(a.close);
    final b = await openNode(bus, 2);
    addTearDown(b.close);

    await a.openDatabase('shared', passphrase: 'hunter2');
    await a.startPairing('shared');

    await expectLater(
      b.pairWith('shared', PairingCode.parse('000 000 000')),
      throwsA(isA<PairingRejected>()),
    );
    expect(
      () => b.reopenDatabase('shared'),
      throwsStateError,
      reason: 'no key was stored for B',
    );
  });

  test('repeated wrong codes exhaust the sponsor and disarm the code',
      () async {
    final bus = InMemoryBus();
    final a = await openNode(bus, 1);
    addTearDown(a.close);
    await a.openDatabase('shared', passphrase: 'hunter2');
    final realCode = await a.startPairing('shared');

    for (var i = 0; i < 3; i++) {
      final b = await openNode(bus, 10 + i);
      await expectLater(
        b.pairWith('shared', PairingCode.parse('111 111 111')),
        throwsA(isA<PairingRejected>()),
      );
      await b.close();
    }

    // The code is now dead even though it is the correct one.
    final b = await openNode(bus, 99);
    addTearDown(b.close);
    await expectLater(
      b.pairWith('shared', realCode),
      throwsA(anyOf(isA<PairingRejected>(), isA<PairingTimeout>())),
    );
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('the pairing code is nine digits and parses back from its display form',
      () {
    final code = PairingCode.generate();
    expect(code.digits, hasLength(9));
    expect(code.display, matches(RegExp(r'^\d{3} \d{3} \d{3}$')));
    expect(PairingCode.parse(code.display).digits, code.digits);
    expect(PairingCode.parse('12-34-56-789').digits, '123456789');
    expect(() => PairingCode.parse('12345'), throwsFormatException);
  });
}
