// The inbound rate limit bounds how many frames a peer may send per second,
// not how long they take to handle. A peer whose frames arrive faster than
// they are handled (large frames, a slow device) must not be able to queue
// memory without limit, whether or not it holds a key.
import 'dart:async';

import 'package:passnote/engine.dart';
import 'package:passnote/passnote.dart';
import 'package:test/test.dart';

class _PuppetTransport implements Transport {
  final _events = StreamController<PeerEvent>.broadcast();
  final _inbound = StreamController<InboundFrame>.broadcast();

  @override
  Stream<PeerEvent> get events => _events.stream;
  @override
  Stream<InboundFrame> get inbound => _inbound.stream;
  @override
  Future<void> start({required NodeId self, required String appId}) async {}
  @override
  Future<void> send(PeerId to, Frame frame) async {}
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

/// A cipher whose decryption waits on [gate]: handling is as slow as the
/// test wants, and [decrypts] counts the frames that were handled at all.
class _GatedCipher implements Cipher {
  _GatedCipher(this.gate);

  final Future<void> gate;
  int decrypts = 0;

  @override
  Future<List<int>> encrypt(List<int> plaintext) async => plaintext;

  @override
  Future<List<int>> decrypt(List<int> ciphertext) async {
    decrypts++;
    await gate;
    throw const CipherAuthError();
  }
}

void main() {
  test('a peer cannot queue more than a bounded number of bytes', () async {
    final transport = _PuppetTransport();
    final gate = Completer<void>();
    final cipher = _GatedCipher(gate.future);
    final passnote = await passnoteLowLevel(
      config: const PassnoteConfig(
        appId: 'bl',
        salt: 'bl:v1',
        snapshotInterval: Duration.zero,
        antiEntropyInterval: Duration.zero,
        maxInboundFramesPerSecond: 100000,
      ),
      keyStore: _MemKeyStore(),
      transport: transport,
      deriveKey: (_, __) async => List<int>.filled(32, 1),
      roomTag: (key) => 'room-${key.first}',
      cipher: (_) => cipher,
      mnemonicGenerator: (n) => List.filled(n, 'abandon'),
      validateMnemonic: (_) => true,
      engine: (dbId, collection, _) => MapCrdtTable(collection),
    );
    addTearDown(passnote.close);
    final db = await passnote.openDatabase('d', passphrase: 'p');
    transport.connect('flooder');
    await pumpEventQueue();

    // 200 MiB in 1 MiB frames, all arriving while the first frame is still
    // being handled: far beyond the 32 MiB a peer may have waiting.
    final big = List<int>.filled(1 << 20, 7);
    for (var i = 0; i < 200; i++) {
      transport.deliver('flooder', Frame(db.room, big));
    }
    await pumpEventQueue(times: 50);
    gate.complete();
    await pumpEventQueue(times: 500);

    expect(cipher.decrypts, lessThanOrEqualTo(32),
        reason: 'every frame of the burst was queued for handling');
    expect(cipher.decrypts, greaterThan(0));

    // Once the backlog has drained, the peer is served again.
    final before = cipher.decrypts;
    transport.deliver('flooder', Frame(db.room, const [1, 2, 3]));
    await pumpEventQueue(times: 50);
    expect(cipher.decrypts, before + 1);
  });
}
