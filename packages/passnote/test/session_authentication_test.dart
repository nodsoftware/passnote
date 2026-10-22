// With an identity configured, the passphrase key proves only that a peer
// once joined: every device that ever held it keeps it, revoked ones
// included. These tests pin that such a peer cannot write user data, cannot
// learn which user collections exist, and cannot open a session, so user
// data flows only to and from signed, non-revoked roster members.
// ignore_for_file: implementation_imports
import 'dart:async';

import 'package:crdt/crdt.dart' show Hlc;
import 'package:passnote/engine.dart';
import 'package:passnote/passnote.dart';
import 'package:passnote/src/protocol/messages.dart';
import 'package:test/test.dart';

const int _framePlain = 0x00;
const int _frameRatcheted = 0x01;

class _PuppetTransport implements Transport {
  final _events = StreamController<PeerEvent>.broadcast();
  final _inbound = StreamController<InboundFrame>.broadcast();
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
  Future<List<int>> encrypt(List<int> p) async => [
        0xAC ^ _k,
        0xED ^ _k,
        ...p.map((b) => b ^ _k),
      ];
  @override
  Future<List<int>> decrypt(List<int> c) async {
    if (c.length < 2 || (c[0] ^ _k) != 0xAC || (c[1] ^ _k) != 0xED) {
      throw const CipherAuthError();
    }
    return c.skip(2).map((b) => b ^ _k).toList();
  }
}

/// A signing identity whose signatures are real enough for these tests:
/// `sign` tags the message with the signer's id, `verify` checks the tag.
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
  Future<List<int>> sign(List<int> message) async => [
        ..._pub.signing,
        ...message,
      ];
  @override
  Future<bool> verify(
    List<int> message, {
    required List<int> signature,
    required DevicePublicKey signer,
  }) async {
    final expected = [...signer.signing, ...message];
    if (signature.length != expected.length) return false;
    for (var i = 0; i < expected.length; i++) {
      if (signature[i] != expected[i]) return false;
    }
    return true;
  }

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

final _noteCodec = JsonCodec<Map<String, dynamic>>(
  toMap: (m) => m,
  fromMap: (m) => m,
  idOf: (m) => m['id'] as String,
);

List<int> _passphraseKey(String passphrase) =>
    List<int>.generate(32, (i) => (passphrase.codeUnitAt(i % 4) + i) & 0xff);

void main() {
  late _PuppetTransport transport;
  late Passnote passnote;
  late Database db;
  late Collection<Map<String, dynamic>> notes;
  const peer = 'outsider';
  final key = _passphraseKey('hunter2');
  final control = _XorCipher(key);

  setUp(() async {
    transport = _PuppetTransport();
    passnote = await passnoteLowLevel(
      config: const PassnoteConfig(
        appId: 'sa',
        salt: 'sa:v1',
        snapshotInterval: Duration.zero,
        antiEntropyInterval: Duration.zero,
      ),
      keyStore: _MemKeyStore(),
      transport: transport,
      deriveKey: (passphrase, _) async => _passphraseKey(passphrase),
      roomTag: (key) => 'room-${key.take(4).join("-")}',
      cipher: _XorCipher.new,
      mnemonicGenerator: (n) => List.filled(n, 'abandon'),
      validateMnemonic: (_) => true,
      engine: (dbId, collection, _) => MapCrdtTable(collection),
      identity: _Identity(1),
    );
    db = await passnote.openDatabase('shared', passphrase: 'hunter2');
    expect(db.deviceState, DeviceState.ready);
    notes = db.collection<Map<String, dynamic>>('notes', _noteCodec);
    await notes.put({'id': 'n1', 'text': 'private'});
    transport.connect(peer);
    await pumpEventQueue(times: 40);
  });

  tearDown(() => passnote.close());

  Future<void> deliverPlain(ProtocolMessage msg) async {
    final sealed = await control.encrypt(encodeMessage(msg));
    transport.deliver(peer, Frame(db.room, [_framePlain, ...sealed]));
    await pumpEventQueue(times: 40);
  }

  Future<List<ProtocolMessage>> plainMessagesTo(PeerId to) async => [
        for (final s in transport.sent)
          if (s.to == to && s.frame.bytes.first == _framePlain)
            if (decodeMessage(await control.decrypt(s.frame.bytes.sublist(1)))
                case final msg?)
              msg,
      ];

  test('a user-data delta under the passphrase key is ignored', () async {
    // Shaped exactly like a real delta, dated far ahead so it would win
    // last-write-wins if it were applied at all.
    final hlc = Hlc(DateTime.utc(2999), 0, 'outsider-node').toString();
    await deliverPlain(
      DeltaMessage(
        col: 'notes',
        records: [
          {'key': 'n1', 'value': true, 'is_deleted': false, 'hlc': hlc},
          {
            'key': 'n1\x1F',
            'value': {'id': 'n1', 'text': 'forged'},
            'is_deleted': false,
            'hlc': hlc,
          },
          {'key': 'n2', 'value': true, 'is_deleted': false, 'hlc': hlc},
          {
            'key': 'n2\x1F',
            'value': {'id': 'n2', 'text': 'planted'},
            'is_deleted': false,
            'hlc': hlc,
          },
        ],
      ),
    );
    expect((await notes.get('n1'))?['text'], 'private');
    expect(await notes.get('n2'), isNull);
  });

  test(
    'a reconcile request for user data under the passphrase key is ignored',
    () async {
      final before = transport.sent.length;
      await deliverPlain(
        const ReconcileMessage(col: 'notes', sendRanges: [(null, null)]),
      );
      expect(
        transport.sent.skip(before).where((s) => s.to == peer),
        isEmpty,
        reason: 'the node answered a range request from outside any session',
      );
    },
  );

  test('outside a session, watermarks name the roster only', () async {
    await deliverPlain(const HelloMessage(node: peer));
    final states = (await plainMessagesTo(peer)).whereType<StateMessage>();
    expect(states, isNotEmpty);
    for (final state in states) {
      expect(
        state.cols.keys,
        everyElement(kDeviceCollection),
        reason: 'user collection names leaked outside a session',
      );
    }
  });

  test('an unsigned or non-member hello opens no session', () async {
    await deliverPlain(
      const HandshakeMessage(node: peer, versions: supportedWireVersions),
    );
    final hello =
        (await plainMessagesTo(peer)).whereType<RatchetHelloMessage>().first;
    final outsider = _Identity(99); // never admitted to the roster
    final ephemeral = await RatchetEphemeral.generate();
    // Correctly shaped and signed, by a key the roster does not know.
    final forged = RatchetHelloMessage(
      node: peer,
      to: hello.node,
      deviceId: outsider.deviceId,
      ephemeral: ephemeral.publicKey,
      keyTag: hello.keyTag,
      signature: await outsider.sign([1, 2, 3]),
    );
    await deliverPlain(forged);
    // Claiming a member's id with a signature it cannot make fails too.
    await deliverPlain(
      RatchetHelloMessage(
        node: peer,
        to: hello.node,
        deviceId: passnote.identity.deviceId,
        ephemeral: ephemeral.publicKey,
        keyTag: hello.keyTag,
        signature: List<int>.filled(64, 0),
      ),
    );
    await notes.put({'id': 'n3', 'text': 'after'});
    await pumpEventQueue(times: 40);
    expect(
      transport.sent.where(
        (s) => s.to == peer && s.frame.bytes.first == _frameRatcheted,
      ),
      isEmpty,
      reason: 'a session was established with a peer that is not a member',
    );
    expect(
      (await plainMessagesTo(peer))
          .whereType<DeltaMessage>()
          .where((d) => d.col != kDeviceCollection),
      isEmpty,
      reason: 'user data left the device outside a session',
    );
  });
}
