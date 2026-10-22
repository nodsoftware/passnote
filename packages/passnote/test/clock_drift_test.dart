// Merging is last-write-wins by hybrid logical clock, so a record stamped far
// in the future would beat every later edit forever. Inbound records beyond
// PassnoteConfig.maxClockDrift are refused, with the rest of their document.
// ignore_for_file: implementation_imports
import 'dart:async';

import 'package:crdt/crdt.dart' show Hlc;
import 'package:passnote/engine.dart';
import 'package:passnote/passnote.dart';
import 'package:passnote/src/protocol/messages.dart';
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

final _noteCodec = JsonCodec<Map<String, dynamic>>(
  toMap: (m) => m,
  fromMap: (m) => m,
  idOf: (m) => m['id'] as String,
);

final _key = List<int>.generate(32, (i) => i);

List<Map<String, dynamic>> _document(String id, String text, DateTime at) {
  final hlc = Hlc(at, 0, 'peer-node');
  return [
    {'key': id, 'value': true, 'is_deleted': false, 'hlc': hlc},
    {
      'key': '$id\x1F',
      'value': {'id': id, 'text': text},
      'is_deleted': false,
      'hlc': hlc,
    },
  ];
}

void main() {
  test('a record beyond the drift bound is refused, a near one accepted',
      () async {
    final transport = _PuppetTransport();
    final passnote = await passnoteLowLevel(
      config: const PassnoteConfig(
        appId: 'cd',
        salt: 'cd:v1',
        snapshotInterval: Duration.zero,
        antiEntropyInterval: Duration.zero,
        maxClockDrift: Duration(minutes: 5),
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
    final notes = db.collection<Map<String, dynamic>>('notes', _noteCodec);
    await notes.ready;
    transport.connect('peer');
    await pumpEventQueue(times: 20);

    final now = DateTime.now().toUtc();
    final frame = await _XorCipher(_key).encrypt(encodeMessage(DeltaMessage(
      col: 'notes',
      records: [
        ..._document(
            'skewed', 'a minute ahead', now.add(const Duration(minutes: 1))),
        ..._document('future', 'year 2999', DateTime.utc(2999)),
      ],
    )));
    transport.deliver('peer', Frame(db.room, frame));
    await pumpEventQueue(times: 40);

    expect((await notes.get('skewed'))?['text'], 'a minute ahead',
        reason: 'ordinary clock skew must still sync');
    expect(await notes.get('future'), isNull,
        reason: 'a far-future record would win last-write-wins forever');
  });
}
