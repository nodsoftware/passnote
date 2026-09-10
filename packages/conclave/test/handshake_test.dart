import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:conclave/conclave.dart';
import 'package:conclave/engine.dart' show negotiate, supportedWireVersions;
import 'package:test/test.dart';

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

final _codec = JsonCodec<Map<String, dynamic>>(
  toMap: (m) => m,
  fromMap: (m) => m,
  idOf: (m) => m['id'] as String,
);

const _passphrase = 'w0 w1 w2 w3 w4 w5 w6 w7 w8 w9 w10 w11';

Future<void> _settle() => pumpEventQueue(times: 40);

void main() {
  group('negotiate', () {
    test('picks the highest common version', () {
      expect(negotiate([1, 2, 3], [2, 3, 4]), 3);
      expect(negotiate([3, 1, 2], [4, 2]), 2);
    });

    test('single common value', () {
      expect(negotiate([2], [2]), 2);
      expect(negotiate([1, 2], [2, 9]), 2);
    });

    test('no overlap is null', () {
      expect(negotiate([1], [2]), isNull);
      expect(negotiate([2, 3], [4, 5]), isNull);
      expect(negotiate([], [2]), isNull);
      expect(negotiate([2], []), isNull);
      expect(negotiate([], []), isNull);
    });

    test('this build advertises the binary protocol', () {
      expect(supportedWireVersions, [2]);
    });
  });

  Future<Conclave> openNode(
    InMemoryBus bus, {
    List<int>? versions,
    int? identitySeed,
  }) =>
      Conclave.lowLevel(
        config: const ConclaveConfig(appId: 'hs', salt: 'hs:v1'),
        keyStore: _MemKeyStore(),
        transport: InMemoryTransport(bus),
        deriveKey: (p, _) async =>
            List<int>.generate(32, (i) => p.codeUnitAt(i % p.length)),
        roomTag: (_) => 'room',
        cipher: _XorCipher.new,
        mnemonicGenerator: (n) => List.generate(n, (i) => 'word$i'),
        validateMnemonic: (_) => true,
        engine: (dbId, collection, _) => MapCrdtTable(collection),
        identity: identitySeed == null ? null : _TestIdentity(identitySeed),
        pake: identitySeed == null ? null : _FakePake(),
        wireVersions: versions ?? supportedWireVersions,
      );

  test('peers with a common version complete the handshake and sync', () async {
    final bus = InMemoryBus();
    final a = await openNode(bus);
    // A future build advertising {2, 3} still talks 2 with this one.
    final b = await openNode(bus, versions: [2, 3]);
    addTearDown(() async {
      await a.close();
      await b.close();
    });

    final dbA = await a.openDatabase('d', passphrase: _passphrase);
    final dbB = await b.openDatabase('d', passphrase: _passphrase);
    final colA = dbA.collection<Map<String, dynamic>>('notes', _codec);
    final colB = dbB.collection<Map<String, dynamic>>('notes', _codec);

    await colA.put({'id': 'x', 'v': 'hello'});
    await colB
        .watch()
        .firstWhere((l) => l.isNotEmpty)
        .timeout(const Duration(seconds: 5));
    expect((await colB.get('x'))?['v'], 'hello');
  });

  test('no common version: PeerIncompatible, no sync, no crash', () async {
    final bus = InMemoryBus();
    final a = await openNode(bus);
    final b = await openNode(bus, versions: [3]); // From the future.
    addTearDown(() async {
      await a.close();
      await b.close();
    });

    final incompatibleOnA = Completer<PeerIncompatible>();
    a.events.listen((e) {
      if (e is PeerIncompatible && !incompatibleOnA.isCompleted) {
        incompatibleOnA.complete(e);
      }
    });

    final dbA = await a.openDatabase('d', passphrase: _passphrase);
    final dbB = await b.openDatabase('d', passphrase: _passphrase);
    final colA = dbA.collection<Map<String, dynamic>>('notes', _codec);
    final colB = dbB.collection<Map<String, dynamic>>('notes', _codec);

    await colA.put({'id': 'x', 'v': 'unreachable'});
    final event =
        await incompatibleOnA.future.timeout(const Duration(seconds: 5));
    expect(event.localVersions, [2]);
    expect(event.remoteVersions, [3]);

    // Nothing syncs in either direction, and nothing crashes or loops.
    await a.forceSync();
    await b.forceSync();
    await _settle();
    expect(await colB.get('x'), isNull);
    await colB.put({'id': 'y', 'v': 'also unreachable'});
    await _settle();
    expect(await colA.get('y'), isNull);
  });

  test('a mixed group syncs among the compatible members only', () async {
    final bus = InMemoryBus();
    final a = await openNode(bus);
    final b = await openNode(bus);
    final future = await openNode(bus, versions: [7]);
    addTearDown(() async {
      await a.close();
      await b.close();
      await future.close();
    });

    final dbA = await a.openDatabase('d', passphrase: _passphrase);
    final dbB = await b.openDatabase('d', passphrase: _passphrase);
    final dbF = await future.openDatabase('d', passphrase: _passphrase);
    final colA = dbA.collection<Map<String, dynamic>>('notes', _codec);
    final colB = dbB.collection<Map<String, dynamic>>('notes', _codec);
    final colF = dbF.collection<Map<String, dynamic>>('notes', _codec);

    await colA.put({'id': 'x', 'v': 'shared'});
    await colB
        .watch()
        .firstWhere((l) => l.isNotEmpty)
        .timeout(const Duration(seconds: 5));
    expect((await colB.get('x'))?['v'], 'shared');
    expect(await colF.get('x'), isNull);
  });

  test(
      'the ratchet runs inside the handshake: identity nodes converge with '
      'forward-secret sessions', () async {
    // With identities configured, user deltas travel ratcheted once the
    // post-negotiation nonce exchange completes; convergence proves the whole
    // chain (handshake -> negotiation -> ratchet -> sync) works in order.
    final bus = InMemoryBus();
    final a = await openNode(bus, identitySeed: 1);
    final b = await openNode(bus, identitySeed: 2);
    addTearDown(() async {
      await a.close();
      await b.close();
    });

    final dbA = await a.openDatabase('d', passphrase: _passphrase);

    // Pairing (task 18) also runs over the connect path: startPairing founds
    // the group, B joins via the PAKE rendezvous, then syncs through the
    // negotiated session.
    final code = await a.startPairing('d');
    expect(dbA.deviceState, DeviceState.ready);
    final dbB = await b.pairWith('d', code);
    expect(dbB.deviceState, DeviceState.ready);

    final colA = dbA.collection<Map<String, dynamic>>('notes', _codec);
    final colB = dbB.collection<Map<String, dynamic>>('notes', _codec);
    await colA.put({'id': 'x', 'v': 'ratcheted'});
    await a.forceSync();
    await _settle();
    expect((await colB.get('x'))?['v'], 'ratcheted');
  });
}
