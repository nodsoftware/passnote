// A joining device calls `pairWith` the moment it opens, which on a real
// network is seconds before mDNS has found anybody. Every other pairing test
// runs over a bus where both nodes are already connected when pairing starts,
// so the joiner's peer set is never empty and this case never arises.
//
// It arose on hardware: the joiner's hello was sent to an empty peer set,
// reached nobody, was never re-sent, and the join timed out after 20 seconds
// against a sponsor that had been armed and waiting the whole time.
import 'dart:async';

import 'package:conclave/conclave.dart';
import 'package:conclave/engine.dart';
import 'package:test/test.dart';

/// Wraps a transport and withholds [PeerConnected] until [release], so a node
/// can be opened, and pairing started, while it still believes it is alone.
class _LateConnectTransport implements Transport {
  _LateConnectTransport(this._inner);

  final Transport _inner;
  final _events = StreamController<PeerEvent>.broadcast();
  final _held = <PeerEvent>[];
  bool _released = false;

  @override
  Stream<PeerEvent> get events => _events.stream;

  @override
  Stream<InboundFrame> get inbound => _inner.inbound;

  @override
  Future<void> start({required NodeId self, required String appId}) async {
    // Subscribed before the inner transport starts: registering on the bus
    // announces existing peers immediately, and those are exactly the events
    // being held back.
    _inner.events.listen((event) {
      if (!_released && event is PeerConnected) {
        _held.add(event);
        return;
      }
      if (!_events.isClosed) _events.add(event);
    });
    await _inner.start(self: self, appId: appId);
  }

  /// Lets the withheld peers through, as discovery finding them would.
  void release() {
    _released = true;
    for (final event in _held) {
      if (!_events.isClosed) _events.add(event);
    }
    _held.clear();
  }

  @override
  Future<void> send(PeerId to, Frame frame) => _inner.send(to, frame);

  @override
  Future<void> stop() async {
    await _inner.stop();
    await _events.close();
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

class _Pake implements Pake {
  @override
  PakeSession start({
    required bool initiator,
    required List<int> secret,
    List<int> initiatorId = const [],
    List<int> responderId = const [],
  }) =>
      _Session(initiator, secret);
}

class _Session implements PakeSession {
  _Session(this._initiator, this._secret);
  final bool _initiator;
  final List<int> _secret;

  @override
  List<int> get message => List<int>.filled(16, _initiator ? 1 : 2);

  @override
  PakeResult finish(List<int> peerMessage) {
    if (peerMessage.length != 16) {
      throw const FormatException('bad PAKE message');
    }
    final shared = [
      for (var i = 0; i < 16; i++) (_secret[i % _secret.length] + i) & 0xff,
    ];
    final ci = [0x01, ...shared];
    final cr = [0x02, ...shared];
    return PakeResult(
      sharedSecret: shared,
      localConfirmation: _initiator ? ci : cr,
      expectedPeerConfirmation: _initiator ? cr : ci,
    );
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
  Future<List<int>> sign(List<int> message) async => message;

  @override
  Future<bool> verify(
    List<int> message, {
    required List<int> signature,
    required DevicePublicKey signer,
  }) async =>
      true;

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
  Future<Conclave> openNode(int seed, Transport transport) => conclaveLowLevel(
        config: const ConclaveConfig(
          appId: 'pair',
          salt: 'pair:v1',
          snapshotInterval: Duration.zero,
        ),
        keyStore: _MemKeyStore(),
        transport: transport,
        deriveKey: (passphrase, salt) async => List<int>.generate(
            32, (i) => (passphrase.hashCode ^ salt.hashCode ^ i) & 0xff),
        roomTag: (key) => 'room-${key.take(4).join("-")}',
        cipher: _XorCipher.new,
        mnemonicGenerator: (n) => List.filled(n, 'abandon'),
        validateMnemonic: (_) => true,
        engine: (dbId, collection, _) => MapCrdtTable(collection),
        identity: _Identity(seed),
        pake: _Pake(),
      );

  test('a joiner that pairs before discovery finds the sponsor still pairs',
      () async {
    final bus = InMemoryBus();

    final sponsor = await openNode(1, InMemoryTransport(bus));
    addTearDown(sponsor.close);

    final late = _LateConnectTransport(InMemoryTransport(bus));
    final joiner = await openNode(2, late);
    addTearDown(joiner.close);

    final dbSponsor =
        await sponsor.openDatabase('shared', passphrase: 'hunter2');
    if (dbSponsor.deviceState != DeviceState.ready) {
      await dbSponsor.foundGroup();
    }
    final code = await sponsor.startPairing('shared');

    // The joiner cannot see anybody yet: this is the state a real device is in
    // the instant it opens, and the hello has nowhere to go.
    final joining = joiner.pairWith('shared', PairingCode.parse(code.digits));

    // Discovery finds the sponsor a moment later, as mDNS would.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    late.release();

    final dbJoiner = await joining.timeout(
      const Duration(seconds: 10),
      onTimeout: () => fail(
        'the joiner never paired: its hello was sent to an empty peer set '
        'and never re-sent once the sponsor appeared',
      ),
    );

    expect(dbJoiner.deviceState, DeviceState.ready);
    expect(dbSponsor.deviceState, DeviceState.ready);

    final roster = {for (final d in await dbSponsor.listDevices()) d.deviceId};
    expect(
      roster,
      containsAll([sponsor.identity.deviceId, joiner.identity.deviceId]),
    );

    // And the group key really is shared: data flows over it.
    final notes = dbSponsor.collection<Map<String, dynamic>>('notes', _codec);
    final theirs = dbJoiner.collection<Map<String, dynamic>>('notes', _codec);
    await notes.put({'id': 'n1', 'text': 'from the sponsor'});
    await joiner.forceSync();
    await pumpEventQueue();
    expect((await theirs.get('n1'))?['text'], 'from the sponsor');
  });

  test(
      'a device that opens its collections before any peer connects still '
      'receives what the group already holds', () async {
    // A device that has just paired holds nothing, and everything the group
    // already wrote predates it. Getting that history is not the joiner
    // asking for it — no forceSync here — but the handshake naming the
    // collections each side holds, and the delta exchange that follows.
    final bus = InMemoryBus();

    final founder = await openNode(1, InMemoryTransport(bus));
    addTearDown(founder.close);
    final dbFounder =
        await founder.openDatabase('shared', passphrase: 'hunter2');
    if (dbFounder.deviceState != DeviceState.ready) {
      await dbFounder.foundGroup();
    }
    final theirs = dbFounder.collection<Map<String, dynamic>>('notes', _codec);
    await theirs.put({'id': 'n1', 'text': 'written before they arrived'});

    // The joiner pairs, then opens its collections while still alone.
    final late = _LateConnectTransport(InMemoryTransport(bus));
    final joiner = await openNode(2, late);
    addTearDown(joiner.close);
    final code = await founder.startPairing('shared');
    final joining = joiner.pairWith('shared', PairingCode.parse(code.digits));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    late.release();
    final dbJoiner = await joining.timeout(const Duration(seconds: 10));

    final mine = dbJoiner.collection<Map<String, dynamic>>('notes', _codec);
    await mine.ready;

    // No forceSync: the poke round is what has to deliver this.
    for (var i = 0; i < 40 && (await mine.get('n1')) == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await pumpEventQueue();
    }

    expect(
      (await mine.get('n1'))?['text'],
      'written before they arrived',
      reason: 'a freshly paired device never received what the group already '
          'held, so pairing succeeded and the data never followed',
    );
  });
}
