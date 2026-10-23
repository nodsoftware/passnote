// A signed ratchet hello verifies forever, so someone who recorded one and
// can make frames arrive under the sender's transport id could replay it to
// tear down the live session (they could not join it: the ephemeral private
// key is gone). A peer mints a fresh ephemeral key per handshake, so a hello
// carrying a key that already served an ended session is a replay and must
// change nothing.
// ignore_for_file: implementation_imports
import 'package:passnote/engine.dart';
import 'package:passnote/passnote.dart';
import 'package:passnote/src/protocol/messages.dart';
import 'package:test/test.dart';

const int _framePlain = 0x00;

class _RecordingBus extends InMemoryBus {
  final log = <(NodeId, NodeId, Frame)>[];
  @override
  void route(NodeId from, NodeId to, Frame frame) {
    log.add((from, to, frame));
    super.route(from, to, frame);
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

/// Signatures that only the signer can make: `sign` prefixes the signer's
/// public signing key, `verify` checks that prefix.
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
  Future<List<int>> sign(List<int> message) async =>
      [..._pub.signing, ...message];
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

final _key = List<int>.generate(32, (i) => i);

Future<Passnote> _node(InMemoryBus bus, int seed) => passnoteLowLevel(
      config: const PassnoteConfig(
        appId: 'rh',
        salt: 'rh:v1',
        snapshotInterval: Duration.zero,
        antiEntropyInterval: Duration.zero,
      ),
      keyStore: _MemKeyStore(),
      transport: InMemoryTransport(bus),
      deriveKey: (_, __) async => _key,
      roomTag: (key) => 'room-${key.take(4).join("-")}',
      cipher: _XorCipher.new,
      mnemonicGenerator: (n) => List.filled(n, 'abandon'),
      validateMnemonic: (_) => true,
      engine: (dbId, collection, _) => MapCrdtTable(collection),
      identity: _Identity(seed),
    );

/// [_XorCipher.decrypt] for [_key], synchronously; empty when it fails.
List<int> _xorOpen(List<int> sealed) {
  final k = _key.fold(0, (a, b) => (a + b) & 0xff);
  if (sealed.length < 2 || (sealed[0] ^ k) != 0xAC || (sealed[1] ^ k) != 0xED) {
    return const [];
  }
  return [for (final b in sealed.skip(2)) b ^ k];
}

/// The ratchet hellos among [frames], decoded.
Future<List<RatchetHelloMessage>> _hellos(Iterable<Frame> frames) async => [
      for (final frame in frames)
        if (frame.bytes.isNotEmpty && frame.bytes.first == _framePlain)
          if (decodeMessage(
                  await _XorCipher(_key).decrypt(frame.bytes.sublist(1)))
              case final RatchetHelloMessage hello)
            hello,
    ];

void main() {
  test('a replayed hello from an ended session changes nothing', () async {
    final bus = _RecordingBus();
    final a = await _node(bus, 1);
    final b = await _node(bus, 2);
    addTearDown(() async {
      await a.close();
      await b.close();
    });
    final dbA = await a.openDatabase('d', passphrase: 'p');
    if (dbA.deviceState != DeviceState.ready) await dbA.foundGroup();
    await pumpEventQueue(times: 50);
    final dbB = await b.openDatabase('d', passphrase: 'p');
    await dbA.admitDevice(await b.identity.publicKey, label: 'B');
    await a.forceSync();
    await pumpEventQueue(times: 200);
    expect(await dbB.refreshDeviceState(), DeviceState.ready);
    await pumpEventQueue(times: 200);

    // Find A's and B's transport ids and A's first hello to B.
    final helloFromA = bus.log.firstWhere((e) =>
        e.$3.bytes.isNotEmpty &&
        e.$3.bytes.first == _framePlain &&
        e.$1 != e.$2);
    final aId = helloFromA.$1;
    final bId = helloFromA.$2;
    final recorded = <Frame>[];
    for (final (from, to, frame) in bus.log) {
      if (from == aId && to == bId) recorded.add(frame);
    }
    final recordedFrame = recorded.firstWhere((f) =>
        f.bytes.isNotEmpty &&
        f.bytes.first == _framePlain &&
        decodeMessage(_xorOpen(f.bytes.sublist(1))) is RatchetHelloMessage);

    // A drops off: B ends the session, and the recorded hello now belongs
    // to an ended one.
    bus.unregister(aId);
    await pumpEventQueue(times: 50);
    Future<int> hellosFromB() async => (await _hellos([
          for (final (from, to, frame) in bus.log)
            if (from == bId && to == aId) frame,
        ]))
            .length;
    final before = await hellosFromB();

    // While the real A is away, someone holding the recording plays it to B
    // under A's transport id.
    bus.route(aId, bId, recordedFrame);
    await pumpEventQueue(times: 200);

    expect(await hellosFromB(), before,
        reason: 'B answered a replayed hello as if A had started a new '
            'handshake, and would pair a session with a key nobody holds');
  });
}
