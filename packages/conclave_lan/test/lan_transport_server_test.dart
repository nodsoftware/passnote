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

import 'package:conclave/conclave.dart';
import 'package:conclave_lan/discovery.dart';

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

  Future<void> settle() => pumpEventQueue(times: 40);

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
