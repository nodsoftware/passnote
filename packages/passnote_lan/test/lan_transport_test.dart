@Tags(['integration'])
library;

import 'package:passnote/passnote.dart';
import 'package:passnote_lan/discovery.dart';
import 'package:test/test.dart';

/// Socket-bound loopback test: two [LanTransport]s on the local machine
/// discover each other over mDNS and exchange a frame over WebSocket.
///
/// Tagged `integration` and skipped by the default unit run (see
/// `dart_test.yaml`); run explicitly with:
///
/// ```
/// dart test --run-skipped -t integration packages/passnote_lan
/// ```
void main() {
  test('two transports discover and exchange a frame', () async {
    const appId = 'looptest';
    final a = LanTransport(discoveryInterval: const Duration(seconds: 1));
    final b = LanTransport(discoveryInterval: const Duration(seconds: 1));

    await a.start(self: 'node-a', appId: appId);
    await b.start(self: 'node-b', appId: appId);

    addTearDown(() async {
      await a.stop();
      await b.stop();
    });

    // Wait until 'node-a' (the smaller id, which dials) sees the peer.
    final connected = await a.events
        .firstWhere((e) => e is PeerConnected)
        .timeout(const Duration(seconds: 20));
    expect((connected as PeerConnected).peer, equals('node-b'));

    final received = b.inbound.first.timeout(const Duration(seconds: 10));
    await a.send('node-b', Frame('room-1', [42, 7]));

    final frame = await received;
    expect(frame.from, equals('node-a'));
    expect(frame.frame.room, equals('room-1'));
    expect(frame.frame.bytes, equals([42, 7]));
  }, timeout: const Timeout(Duration(seconds: 40)));
}
