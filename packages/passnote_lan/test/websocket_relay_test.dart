// The reference relay's admission rules: first claim on a node id wins (an id
// in use cannot be taken over), oversize frames close their sender, and the
// client cap holds. What no unauthenticated relay can prevent — pre-claiming
// an id whose owner is offline — is documented on the class instead.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:passnote_lan/relay.dart';
import 'package:test/test.dart';

/// A `WebSocketTransport` envelope: `[2B fromLen][from][2B toLen][to][frame]`.
List<int> envelope(String from, String to, List<int> frame) {
  final fromBytes = utf8.encode(from);
  final toBytes = utf8.encode(to);
  return [
    (fromBytes.length >> 8) & 0xff,
    fromBytes.length & 0xff,
    ...fromBytes,
    (toBytes.length >> 8) & 0xff,
    toBytes.length & 0xff,
    ...toBytes,
    ...frame,
  ];
}

Future<WebSocket> join(int port, String node) async {
  final ws = await WebSocket.connect('ws://127.0.0.1:$port');
  ws.add('hello $node');
  return ws;
}

// Real sockets need real time: a fixed number of event-loop turns is not
// enough when the suite's files run in parallel on a loaded machine.
Future<void> settle() async {
  await pumpEventQueue(times: 40);
  await Future<void>.delayed(const Duration(milliseconds: 100));
  await pumpEventQueue(times: 40);
}

void main() {
  test('an id in use cannot be taken over; the holder keeps its traffic',
      () async {
    final relay = await WebSocketRelay.bind(port: 0);
    addTearDown(relay.close);

    final alice = await join(relay.port, 'alice');
    final aliceInbox = <List<int>>[];
    alice.listen((d) {
      if (d is List<int>) aliceInbox.add(d);
    });
    await settle();
    expect(relay.connectedNodes, contains('alice'));

    // The attacker claims alice's id while she is connected.
    final attacker = await join(relay.port, 'alice');
    attacker.listen((_) {});
    await attacker.done.timeout(const Duration(seconds: 5));
    expect(attacker.closeCode, WebSocketStatus.policyViolation);

    // Bob's envelope still reaches the real alice.
    final bob = await join(relay.port, 'bob');
    addTearDown(bob.close);
    await settle();
    bob.add(envelope('bob', 'alice', [1, 2, 3]));
    await settle();
    expect(aliceInbox, hasLength(1));
    await alice.close();
  });

  test('an oversize frame closes its sender; the relay keeps serving',
      () async {
    final relay = await WebSocketRelay.bind(port: 0, maxFrameBytes: 64);
    addTearDown(relay.close);

    final flooder = await join(relay.port, 'flooder');
    flooder.listen((_) {});
    await settle();
    flooder.add(envelope('flooder', 'anyone', List.filled(128, 7)));
    await flooder.done.timeout(const Duration(seconds: 5));
    expect(flooder.closeCode, WebSocketStatus.messageTooBig);

    // Two well-behaved clients still exchange frames. Waited on, not pumped
    // for: real sockets need real time, and a fixed number of event-loop
    // turns was not always enough under a loaded test run.
    final a = await join(relay.port, 'a');
    final b = await join(relay.port, 'b');
    addTearDown(a.close);
    addTearDown(b.close);
    final bFrame =
        b.firstWhere((d) => d is List<int>).timeout(const Duration(seconds: 5));
    await settle();
    a.add(envelope('a', 'b', [9]));
    expect(await bFrame, envelope('a', 'b', [9]));
  });

  test('a client cannot send in another client\'s name', () async {
    final relay = await WebSocketRelay.bind(port: 0);
    addTearDown(relay.close);

    final a = await join(relay.port, 'a');
    final b = await join(relay.port, 'b');
    final mallory = await join(relay.port, 'mallory');
    addTearDown(a.close);
    addTearDown(b.close);
    addTearDown(mallory.close);
    a.listen((_) {});
    mallory.listen((_) {});
    final bInbox = <List<int>>[];
    final bGotOne = Completer<void>();
    b.listen((d) {
      if (d is List<int>) {
        bInbox.add(d);
        if (!bGotOne.isCompleted) bGotOne.complete();
      }
    });
    await settle();

    // Claiming to be 'a' is dropped; the same frame in its own name is not.
    mallory.add(envelope('a', 'b', [1]));
    mallory.add(envelope('mallory', 'b', [2]));
    await bGotOne.future.timeout(const Duration(seconds: 5));
    await settle();
    expect(bInbox, [
      envelope('mallory', 'b', [2])
    ]);
  });

  test('the client cap refuses connections beyond it', () async {
    final relay = await WebSocketRelay.bind(port: 0, maxClients: 1);
    addTearDown(relay.close);

    final first = await join(relay.port, 'one');
    addTearDown(first.close);
    first.listen((_) {});
    // Wait for the registration itself: the hello travels over a real
    // socket, so pumping the event queue alone can race it.
    for (var i = 0; i < 100 && !relay.connectedNodes.contains('one'); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(relay.connectedNodes, contains('one'));

    final second = await WebSocket.connect('ws://127.0.0.1:${relay.port}');
    // Await the stream's close, not `done`: this client never wrote, so its
    // sink side (which `done` tracks) only settles on its own close.
    final closed = Completer<void>();
    second.listen((_) {}, onDone: closed.complete);
    await closed.future.timeout(const Duration(seconds: 5));
    expect(second.closeCode, WebSocketRelay.relayFullCode);
    await second.close();
  });

  test('silent connections count against the cap', () async {
    // Sockets that upgrade but never say hello each cost a file descriptor;
    // the cap must bound OPEN connections, not registrations.
    final relay = await WebSocketRelay.bind(
      port: 0,
      maxClients: 3,
      helloTimeout: const Duration(minutes: 1),
    );
    addTearDown(relay.close);

    final silent = <WebSocket>[];
    for (var i = 0; i < 3; i++) {
      final ws = await WebSocket.connect('ws://127.0.0.1:${relay.port}');
      ws.listen((_) {});
      addTearDown(ws.close);
      silent.add(ws);
    }
    await settle();

    final refused = await WebSocket.connect('ws://127.0.0.1:${relay.port}');
    final closed = Completer<void>();
    refused.listen((_) {}, onDone: closed.complete);
    await closed.future.timeout(const Duration(seconds: 5));
    expect(refused.closeCode, WebSocketRelay.relayFullCode,
        reason: 'three silent sockets fill a cap of three');
  });

  test('a connection that never says hello is evicted, freeing its slot',
      () async {
    final relay = await WebSocketRelay.bind(
      port: 0,
      maxClients: 1,
      helloTimeout: const Duration(milliseconds: 200),
    );
    addTearDown(relay.close);

    final squatter = await WebSocket.connect('ws://127.0.0.1:${relay.port}');
    final evicted = Completer<void>();
    squatter.listen((_) {}, onDone: evicted.complete);
    await evicted.future.timeout(const Duration(seconds: 5));
    expect(squatter.closeCode, WebSocketStatus.policyViolation);

    // The slot is free again: a real client registers.
    final real = await join(relay.port, 'real');
    addTearDown(real.close);
    real.listen((_) {});
    for (var i = 0; i < 100 && !relay.connectedNodes.contains('real'); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(relay.connectedNodes, contains('real'));
  });

  test('an absurd node id is refused', () async {
    final relay = await WebSocketRelay.bind(port: 0);
    addTearDown(relay.close);
    final ws = await join(relay.port, 'x' * 500);
    ws.listen((_) {});
    await ws.done.timeout(const Duration(seconds: 5));
    expect(ws.closeCode, WebSocketStatus.policyViolation);
  });
}
