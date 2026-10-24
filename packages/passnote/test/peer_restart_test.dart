// A peer that restarts can come back under the same transport id without
// the transport ever reporting it lost. This side then kept the old
// instance's negotiation and session state, answered nothing, and never
// renegotiated (F-15, found by the Rust port). Each instance now advertises
// a fresh token in its handshake; a token not seen before from a peer resets
// what is held for it, and a replayed older one changes nothing.
// ignore_for_file: implementation_imports
import 'dart:async';

import 'package:passnote/engine.dart';
import 'package:passnote/passnote.dart';
import 'package:passnote/src/protocol/messages.dart';
import 'package:test/test.dart';

class _PuppetTransport implements Transport {
  final _events = StreamController<PeerEvent>.broadcast();
  final _inbound = StreamController<InboundFrame>.broadcast();
  final sent = <(PeerId, Frame)>[];

  @override
  Stream<PeerEvent> get events => _events.stream;
  @override
  Stream<InboundFrame> get inbound => _inbound.stream;
  @override
  Future<void> start({required NodeId self, required String appId}) async {}
  @override
  Future<void> send(PeerId to, Frame frame) async => sent.add((to, frame));
  @override
  Future<void> stop() async {
    await _events.close();
    await _inbound.close();
  }

  void connect(PeerId peer) => _events.add(PeerConnected(peer));
  void deliver(PeerId from, Frame frame) =>
      _inbound.add(InboundFrame(from, frame));
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

final _key = List<int>.generate(32, (i) => i);

void main() {
  test('a peer back under the same id with a new instance is renegotiated',
      () async {
    final transport = _PuppetTransport();
    final passnote = await passnoteLowLevel(
      config: const PassnoteConfig(
        appId: 'pr',
        salt: 'pr:v1',
        snapshotInterval: Duration.zero,
        antiEntropyInterval: Duration.zero,
      ),
      keyStore: _MemKeyStore(),
      transport: transport,
      deriveKey: (_, __) async => _key,
      roomTag: (key) => 'room-${key.take(4).join("-")}',
      cipher: _XorCipher.new,
      mnemonicGenerator: (n) => List.filled(n, 'abandon'),
      validateMnemonic: (_) => true,
      engine: (dbId, collection, _) => MapCrdtTable(collection),
    );
    addTearDown(passnote.close);
    final db = await passnote.openDatabase('d', passphrase: 'p');
    transport.connect('peer');
    await pumpEventQueue(times: 20);

    Future<List<HandshakeMessage>> handshakesSent() async => [
          for (final (to, frame) in transport.sent)
            if (to == 'peer')
              if (decodeMessage(await _XorCipher(_key).decrypt(frame.bytes))
                  case final HandshakeMessage h)
                h,
        ];
    Future<void> handshakeFrom(String instance) async {
      final frame = await _XorCipher(_key).encrypt(encodeMessage(
        HandshakeMessage(
          node: 'peer',
          versions: supportedWireVersions,
          capabilities: ['inst:$instance'],
        ),
      ));
      transport.deliver('peer', Frame(db.room, frame));
      await pumpEventQueue(times: 40);
    }

    await handshakeFrom('0000000000000001');
    final first = await handshakesSent();
    expect(first.last.capabilities.where((c) => c.startsWith('inst:')),
        hasLength(1));

    // The same instance again (a redelivery): nothing to redo.
    await handshakeFrom('0000000000000001');
    expect(await handshakesSent(), hasLength(first.length));

    // A new instance: this side renegotiates and answers it.
    await handshakeFrom('0000000000000002');
    final afterRestart = await handshakesSent();
    expect(afterRestart.length, greaterThan(first.length),
        reason: 'the restarted peer was never answered');

    // A replay of the old instance's handshake changes nothing.
    await handshakeFrom('0000000000000001');
    expect(await handshakesSent(), hasLength(afterRestart.length));
  });
}
