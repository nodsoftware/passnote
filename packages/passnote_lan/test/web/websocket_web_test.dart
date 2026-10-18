@TestOn('browser')
library;

import 'package:passnote/passnote.dart';
import 'package:passnote_lan/passnote_lan.dart';
import 'package:test/test.dart';

void main() {
  test('a browser WebSocketTransport converges with a native peer', () async {
    // The native side runs in a hybrid (VM) isolate: a listening
    // WebSocketTransport that echoes frames back reversed.
    final channel = spawnHybridUri('hybrid_ws_server.dart');
    final port = await channel.stream.first as int;

    final transport = WebSocketTransport(
      connectTo: [Uri.parse('ws://localhost:$port')],
    );
    final connected = transport.events
        .firstWhere((e) => e is PeerConnected)
        .timeout(const Duration(seconds: 10));
    await transport.start(self: 'browser-node', appId: 'wsweb');
    addTearDown(transport.stop);
    expect((await connected as PeerConnected).peer, 'native-node');

    final echoed = transport.inbound.first.timeout(const Duration(seconds: 10));
    await transport.send('native-node', const Frame('room-w', [1, 2, 3]));
    final frame = await echoed;
    expect(frame.from, 'native-node');
    expect(frame.frame.room, 'room-w');
    expect(frame.frame.bytes, [3, 2, 1]);
  });

  test('listening is rejected with a clear error in the browser', () {
    expect(() => WebSocketTransport(listenPort: 0), throwsArgumentError);
  });
}
