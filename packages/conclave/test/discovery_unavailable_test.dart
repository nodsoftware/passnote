// Pins the discovery-unavailable signal path: a transport that reports
// [DiscoveryUnavailable] (multicast refused by the OS) surfaces to the app as
// [PeerDiscoveryUnavailable] on [Conclave.events], so "discovery is blocked"
// is distinguishable from "no peers nearby".
import 'dart:async';

import 'package:conclave/conclave.dart';
import 'package:conclave/engine.dart';
import 'package:test/test.dart';

class _MemKeyStore implements KeyStore {
  final _keys = <String, List<int>>{};
  @override
  Future<List<int>?> getKey(String id) async => _keys[id];
  @override
  Future<void> setKey(String id, List<int> key) async => _keys[id] = key;
  @override
  Future<void> clear(String id) async => _keys.remove(id);
}

class _NoopCipher implements Cipher {
  @override
  Future<List<int>> encrypt(List<int> plaintext) async => plaintext;
  @override
  Future<List<int>> decrypt(List<int> ciphertext) async => ciphertext;
}

/// A transport whose platform refuses discovery: it reports
/// [DiscoveryUnavailable] the way the LAN transport does when the OS denies
/// multicast (asynchronously, sometime after start).
class _NoDiscoveryTransport implements Transport {
  final _events = StreamController<PeerEvent>.broadcast();
  final _inbound = StreamController<InboundFrame>.broadcast();

  void reportRefusal() => _events.add(const DiscoveryUnavailable(
        reason: 'multicast advertisement was refused',
      ));

  void reportRestored() => _events.add(const DiscoveryRestored());

  /// Reports a refusal during [start], the way the LAN transport does: its
  /// responder binds inside `start`, so the event is emitted before
  /// `conclaveLowLevel` has returned and before any caller can subscribe.
  bool refuseOnStart = false;

  @override
  Stream<PeerEvent> get events => _events.stream;
  @override
  Stream<InboundFrame> get inbound => _inbound.stream;

  @override
  Future<void> start({required NodeId self, required String appId}) async {
    if (refuseOnStart) reportRefusal();
  }

  @override
  Future<void> send(PeerId to, Frame frame) async {}

  @override
  Future<void> stop() async {
    await _events.close();
    await _inbound.close();
  }
}

Future<Conclave> openNode(Transport transport) => conclaveLowLevel(
      config: const ConclaveConfig(appId: 'du', salt: 'du:v1'),
      keyStore: _MemKeyStore(),
      transport: transport,
      deriveKey: (_, __) async => List<int>.filled(32, 1),
      roomTag: (_) => 'room',
      cipher: (_) => _NoopCipher(),
      mnemonicGenerator: (n) => List.filled(n, 'abandon'),
      validateMnemonic: (_) => true,
      engine: (dbId, collection, _) => MapCrdtTable(collection),
    );

void main() {
  test('DiscoveryUnavailable surfaces as PeerDiscoveryUnavailable', () async {
    final transport = _NoDiscoveryTransport();
    final conclave = await openNode(transport);
    addTearDown(conclave.close);
    final seen = <ConclaveEvent>[];
    conclave.events.listen(seen.add);

    transport.reportRefusal();
    await pumpEventQueue(times: 10);

    final discovery = seen.whereType<PeerDiscoveryUnavailable>();
    expect(discovery, hasLength(1));
    expect(discovery.single.reason, contains('multicast'));
  });

  test(
      'a refusal during start is readable afterwards, though no listener '
      'could have seen the event', () async {
    final transport = _NoDiscoveryTransport()..refuseOnStart = true;
    final conclave = await openNode(transport);
    addTearDown(conclave.close);

    // Nobody could subscribe while `start` ran, so the event reached nobody.
    final seen = <ConclaveEvent>[];
    conclave.events.listen(seen.add);
    await pumpEventQueue(times: 10);
    expect(seen, isEmpty, reason: 'the event fired before anyone could listen');

    // The state behind it is still there to read.
    expect(conclave.discoveryUnavailableReason, contains('multicast'));
  });

  test('discovery recovering is reported and clears the reason', () async {
    final transport = _NoDiscoveryTransport();
    final conclave = await openNode(transport);
    addTearDown(conclave.close);
    final seen = <ConclaveEvent>[];
    conclave.events.listen(seen.add);

    transport.reportRefusal();
    await pumpEventQueue(times: 10);
    expect(conclave.discoveryUnavailableReason, isNotNull);

    transport.reportRestored();
    await pumpEventQueue(times: 10);

    expect(seen.whereType<PeerDiscoveryRestored>(), hasLength(1));
    expect(conclave.discoveryUnavailableReason, isNull,
        reason: 'the warning an app raised must come down again');
  });
}
