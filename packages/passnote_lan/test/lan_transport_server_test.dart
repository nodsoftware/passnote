// The socket layer of [LanTransport] without mDNS: the WebSocket server, the
// node-id handshake, frame delivery in both directions, duplicate-connection
// handling, and disconnect events. Discovery itself is covered by the tagged
// loopback integration test; everything here runs on any machine, including
// one whose OS blocks multicast (where start() must degrade quietly instead
// of crashing the app).
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:passnote/passnote.dart';
import 'package:passnote_lan/discovery.dart';

import 'package:test/test.dart';

void main() {
  late LanTransport transport;
  late List<PeerEvent> events;

  setUp(() async {
    transport = LanTransport(discoveryInterval: const Duration(hours: 1));
    events = [];
    await transport.start(self: 'server-node', appId: 'srvtest');
    transport.events.listen(events.add);
  });

  tearDown(() => transport.stop());

  Future<WebSocket> connectAs(String nodeId) async {
    final ws = await WebSocket.connect('ws://127.0.0.1:${transport.port}');
    ws.add(nodeId);
    return ws;
  }

  // Real sockets need real time: a fixed number of event-loop turns is not
  // enough when the suite's files run in parallel on a loaded machine.
  Future<void> settle() async {
    await pumpEventQueue(times: 40);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await pumpEventQueue(times: 40);
  }

  test('start survives a platform without multicast and binds its server',
      () async {
    // On a machine that refuses multicast sockets this start() already
    // proved the degrade path; on one that allows them it proves the happy
    // path. Either way the socket layer is up.
    expect(transport.port, isNotNull);
  });

  test('an accepted socket announces the server node id first', () async {
    final ws = await WebSocket.connect('ws://127.0.0.1:${transport.port}');
    addTearDown(ws.close);
    expect(await ws.first, 'server-node');
  });

  test('the client handshake binds the peer and frames flow both ways',
      () async {
    final received = <Frame>[];
    final inbound = <InboundFrame>[];
    transport.inbound.listen(inbound.add);

    final ws = await connectAs('client-node');
    addTearDown(ws.close);
    ws.listen((data) {
      if (data is List<int>) {
        final frame = FrameCodec.decode(data);
        if (frame != null) received.add(frame);
      }
    });
    await settle();
    expect(events.whereType<PeerConnected>().map((e) => e.peer),
        contains('client-node'));

    // Server → client.
    await transport.send('client-node', Frame('room-1', [1, 2, 3]));
    await settle();
    expect(received, hasLength(1));
    expect(received.single.room, 'room-1');
    expect(received.single.bytes, [1, 2, 3]);

    // Client → server.
    ws.add(FrameCodec.encode(Frame('room-2', [9])));
    await settle();
    expect(inbound, hasLength(1));
    expect(inbound.single.from, 'client-node');
    expect(inbound.single.frame.room, 'room-2');

    // Garbage binary is dropped, never thrown.
    ws.add(const <int>[0xff]);
    await settle();
    expect(inbound, hasLength(1));
  });

  test('a duplicate connection for the same peer is closed, first one kept',
      () async {
    final first = await connectAs('client-node');
    addTearDown(first.close);
    await settle();

    final second = await connectAs('client-node');
    second.listen((_) {});
    await second.done.timeout(const Duration(seconds: 5));

    expect(events.whereType<PeerConnected>(), hasLength(1),
        reason: 'one logical peer, one PeerConnected');
    // The first connection still carries frames.
    await transport.send('client-node', Frame('r', [5]));
    expect(await first.any((d) => d is List<int>), isTrue);
  });

  group('inbound limits', () {
    Future<LanTransport> serve({
      int maxInboundConnections = 64,
      Duration helloTimeout = const Duration(seconds: 10),
      int maxFrameBytes = 4 << 20,
    }) async {
      final server = LanTransport(
        discoveryInterval: const Duration(hours: 1),
        maxInboundConnections: maxInboundConnections,
        helloTimeout: helloTimeout,
        maxFrameBytes: maxFrameBytes,
      );
      await server.start(self: 'limited-node', appId: 'srvlimits');
      addTearDown(server.stop);
      return server;
    }

    test('a socket that never names itself is evicted', () async {
      final server =
          await serve(helloTimeout: const Duration(milliseconds: 200));
      final silent = await WebSocket.connect('ws://127.0.0.1:${server.port}');
      await _closed(silent);
    });

    test('an oversize message closes its socket', () async {
      final server = await serve(maxFrameBytes: 64);
      final flooder = await WebSocket.connect('ws://127.0.0.1:${server.port}');
      final closed = _closed(flooder);
      flooder.add('flooder');
      flooder.add(List<int>.filled(128, 7));
      await closed;
      expect(flooder.closeCode, WebSocketStatus.messageTooBig);
    });

    test('an absurd node id is refused', () async {
      final server = await serve();
      final ws = await WebSocket.connect('ws://127.0.0.1:${server.port}');
      final closed = _closed(ws);
      ws.add('x' * 1000);
      await closed;
      expect(ws.closeCode, WebSocketStatus.policyViolation);
    });

    test('connections beyond the cap are refused', () async {
      final server = await serve(maxInboundConnections: 1);
      final first = await WebSocket.connect('ws://127.0.0.1:${server.port}');
      addTearDown(first.close);
      first.listen((_) {});
      first.add('first');
      await expectLater(
        WebSocket.connect('ws://127.0.0.1:${server.port}'),
        throwsA(isA<WebSocketException>()),
      );
    });
  });

  test('a disconnect emits PeerLost and send becomes a no-op', () async {
    final ws = await connectAs('client-node');
    await settle();
    await ws.close();
    await settle();
    expect(events.whereType<PeerLost>().map((e) => e.peer),
        contains('client-node'));
    // No connection: send drops silently.
    await transport.send('client-node', Frame('r', [1]));
  });

  test('a plain HTTP request is answered 400, not upgraded', () async {
    final client = HttpClient();
    addTearDown(client.close);
    final request = await client.get('127.0.0.1', transport.port!, '/anything');
    final response = await request.close();
    expect(response.statusCode, HttpStatus.badRequest);
  });

  test('a malformed upgrade request is dropped and the server keeps serving',
      () async {
    // Upgrade headers but no Sec-WebSocket-Key: passes isUpgradeRequest,
    // makes WebSocketTransformer.upgrade throw. Remote-fed input, so the
    // handler must fail closed instead of leaking an unhandled async error.
    final raw = await Socket.connect('127.0.0.1', transport.port!);
    raw.write('GET / HTTP/1.1\r\n'
        'Host: 127.0.0.1\r\n'
        'Connection: Upgrade\r\n'
        'Upgrade: websocket\r\n'
        '\r\n');
    await raw.flush();
    await settle();
    raw.destroy();

    // The transport survives: a well-formed client still connects.
    final ws = await connectAs('client-node');
    addTearDown(ws.close);
    await settle();
    expect(events.whereType<PeerConnected>().map((e) => e.peer),
        contains('client-node'));
  });

  test('multicast refusal surfaces DiscoveryUnavailable, at most once',
      () async {
    // Only exercisable where the OS actually refuses multicast (for example
    // a macOS terminal without local-network permission); where multicast
    // works, discovery is available and there is nothing to emit.
    final own = LanTransport(
      discoveryInterval: const Duration(milliseconds: 200),
    );
    final ownEvents = <PeerEvent>[];
    own.events.listen(ownEvents.add);
    await own.start(self: 'du-node', appId: 'dutest');
    addTearDown(own.stop);

    // Give the advertise attempt and a few browse rounds time to run.
    await Future<void>.delayed(const Duration(seconds: 1));
    final unavailable = ownEvents.whereType<DiscoveryUnavailable>().toList();
    if (unavailable.isEmpty) {
      markTestSkipped('multicast is available here; refusal not exercised');
      return;
    }
    expect(unavailable, hasLength(1),
        reason: 'the event is emitted at most once per transport lifetime, '
            'however many advertise and browse attempts fail');
    expect(unavailable.single.reason, contains('multicast'));
  });
}

/// Completes when the server closes [ws] (listens to it to drive the close
/// handshake).
Future<void> _closed(WebSocket ws) {
  final done = Completer<void>();
  ws.listen((_) {}, onDone: done.complete, onError: (Object _) {});
  return done.future.timeout(const Duration(seconds: 5));
}
