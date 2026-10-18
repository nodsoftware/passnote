// A ratcheted frame that will not open used to be dropped and forgotten.
//
// That is not a rare case: a peer's RatchetHello is discarded when it lands
// before this device has adopted the group key, which is routine for a device
// that has just paired. The peer, meanwhile, has a session and seals
// everything it sends from then on. The result is one-way sync — frames in
// the other direction go unsealed and arrive fine — with nothing logged and
// no recovery, because the sealing side has no way to notice.
//
// Seen on real hardware: a phone paired with a Mac, the Mac received the
// phone's writes, and the phone received none of the Mac's.
import 'dart:async';
import 'dart:math';

import 'package:passnote/passnote.dart';
import 'package:passnote/engine.dart';
import 'package:test/test.dart';

const int _framePlain = 0x00;
const int _frameRatcheted = 0x01;

/// A transport under the test's control: it records what the node sends and
/// lets the test inject peers and frames.
class _PuppetTransport implements Transport {
  final _events = StreamController<PeerEvent>.broadcast();
  final _inbound = StreamController<InboundFrame>.broadcast();

  /// Every frame the node has sent, in order.
  final List<({PeerId to, Frame frame})> sent = [];

  @override
  Stream<PeerEvent> get events => _events.stream;
  @override
  Stream<InboundFrame> get inbound => _inbound.stream;

  @override
  Future<void> start({required NodeId self, required String appId}) async {}

  @override
  Future<void> send(PeerId to, Frame frame) async =>
      sent.add((to: to, frame: frame));

  @override
  Future<void> stop() async {
    await _events.close();
    await _inbound.close();
  }

  void connect(PeerId peer) => _events.add(PeerConnected(peer));

  void deliver(PeerId from, Frame frame) =>
      _inbound.add(InboundFrame(from, frame));

  /// Frames sent to [peer] that carry the plain marker, which is what the
  /// ratchet nonce exchange uses.
  Iterable<Frame> plainTo(PeerId peer) => sent
      .where((s) => s.to == peer)
      .map((s) => s.frame)
      .where((f) => f.bytes.isNotEmpty && f.bytes.first == _framePlain);
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

void main() {
  test('a ratcheted frame that will not open restarts the ratchet exchange',
      () async {
    final transport = _PuppetTransport();
    final passnote = await passnoteLowLevel(
      config: const PassnoteConfig(
        appId: 'rb',
        salt: 'rb:v1',
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
      identity: _Identity(1),
    );
    addTearDown(passnote.close);

    final db = await passnote.openDatabase('shared', passphrase: 'hunter2');
    if (db.deviceState != DeviceState.ready) await db.foundGroup();

    const peer = 'ghost-peer';
    transport.connect(peer);
    await pumpEventQueue(times: 20);

    // The node greets a new peer, which tells the test which room this
    // database answers on.
    final greeting = transport.plainTo(peer).firstOrNull;
    expect(greeting, isNotNull, reason: 'the node never greeted the peer');
    final room = greeting!.room;

    final before = transport.plainTo(peer).length;

    // A peer that holds a session this node does not seals everything it
    // sends. Nothing here can be opened.
    final garbage = List<int>.generate(64, (_) => Random(7).nextInt(256));
    transport.deliver(peer, Frame(room, [_frameRatcheted, ...garbage]));
    await pumpEventQueue(times: 30);

    expect(
      transport.plainTo(peer).length,
      greaterThan(before),
      reason: 'the node stayed silent after a frame it could not open, so the '
          'peer keeps sealing and every frame it sends is lost',
    );
  });

  test('a frame that will not open is ignored once a session exists', () async {
    // The mirror of the above. With a session in hand an unopenable frame is
    // a stale or replayed one, and tearing the session down for it would
    // break a working pair, so the node must not react.
    final transport = _PuppetTransport();
    final passnote = await passnoteLowLevel(
      config: const PassnoteConfig(
        appId: 'rb',
        salt: 'rb:v1',
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
      identity: _Identity(2),
    );
    addTearDown(passnote.close);

    final db = await passnote.openDatabase('shared', passphrase: 'hunter2');
    if (db.deviceState != DeviceState.ready) await db.foundGroup();

    const peer = 'ghost-peer';
    transport.connect(peer);
    await pumpEventQueue(times: 20);
    final room = transport.plainTo(peer).first.room;

    // One unopenable frame restarts the exchange, and the request is rate
    // limited, so a burst must not produce a request per frame.
    for (var i = 0; i < 5; i++) {
      transport.deliver(peer, Frame(room, [_frameRatcheted, i, i, i, i]));
      await pumpEventQueue(times: 5);
    }

    final requests = transport.plainTo(peer).length;
    expect(
      requests,
      lessThanOrEqualTo(3),
      reason: 'five unopenable frames produced $requests plain frames: the '
          'rate limit is not holding, and a hostile or stuck peer could make '
          'this node flood the link with nonces',
    );
  });

  test('asking again re-sends the same nonce rather than minting one',
      () async {
    // A fresh nonce reads to the peer as "it redid its handshake", so the
    // peer drops its session and mints one back, which reads the same way
    // here. Two devices then establish a session per round without end: a
    // real run produced 13891 of them and both sides went deaf.
    final transport = _PuppetTransport();
    final passnote = await passnoteLowLevel(
      config: const PassnoteConfig(
        appId: 'rb',
        salt: 'rb:v1',
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
      identity: _Identity(3),
    );
    addTearDown(passnote.close);

    final db = await passnote.openDatabase('shared', passphrase: 'hunter2');
    if (db.deviceState != DeviceState.ready) await db.foundGroup();

    const peer = 'ghost-peer';
    transport.connect(peer);
    await pumpEventQueue(times: 20);
    final room = transport.plainTo(peer).first.room;

    transport.deliver(peer, Frame(room, [_frameRatcheted, 1, 2, 3]));
    await pumpEventQueue(times: 30);
    final first = transport.plainTo(peer).last;

    // Past the rate limit, so this is a second genuine request.
    await Future<void>.delayed(const Duration(seconds: 3));
    transport.deliver(peer, Frame(room, [_frameRatcheted, 4, 5, 6]));
    await pumpEventQueue(times: 30);
    final second = transport.plainTo(peer).last;

    expect(
      second.bytes,
      equals(first.bytes),
      reason: 'the second request carried a different nonce, which sets two '
          'devices chasing each other through a new session per round',
    );
  });
}
