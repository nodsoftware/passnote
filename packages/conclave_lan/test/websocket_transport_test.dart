@TestOn('vm')
library;

import 'dart:async';

import 'package:conclave/conclave.dart';
import 'package:conclave_lan/conclave_lan.dart';
import 'package:conclave_lan/relay.dart';
import 'package:test/test.dart';

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

class _MemKeyStore implements KeyStore {
  final _keys = <String, List<int>>{};
  @override
  Future<List<int>?> getKey(String id) async => _keys[id];
  @override
  Future<void> setKey(String id, List<int> key) async => _keys[id] = key;
  @override
  Future<void> clear(String id) async => _keys.remove(id);
}

final _codec = JsonCodec<Map<String, dynamic>>(
  toMap: (m) => m,
  fromMap: (m) => m,
  idOf: (m) => m['id'] as String,
);

void main() {
  group('direct connection', () {
    test('two peers exchange frames over a local listener', () async {
      final server = WebSocketTransport(listenPort: 0);
      await server.start(self: 'server-node', appId: 'ws');
      addTearDown(server.stop);

      final client = WebSocketTransport(
        connectTo: [Uri.parse('ws://127.0.0.1:${server.boundPort}')],
      );
      final serverSeesClient = server.events
          .firstWhere((e) => e is PeerConnected)
          .timeout(const Duration(seconds: 5));
      final clientSeesServer = client.events
          .firstWhere((e) => e is PeerConnected)
          .timeout(const Duration(seconds: 5));
      await client.start(self: 'client-node', appId: 'ws');
      addTearDown(client.stop);

      expect((await serverSeesClient).peer, 'client-node');
      expect((await clientSeesServer).peer, 'server-node');

      final atServer = server.inbound.first.timeout(const Duration(seconds: 5));
      await client.send('server-node', const Frame('room-1', [1, 2, 3]));
      final received = await atServer;
      expect(received.from, 'client-node');
      expect(received.frame.room, 'room-1');
      expect(received.frame.bytes, [1, 2, 3]);

      // And the other direction.
      final atClient = client.inbound.first.timeout(const Duration(seconds: 5));
      await server.send('client-node', const Frame('room-1', [9]));
      expect((await atClient).frame.bytes, [9]);
    });

    test('a frame addressed to an unknown peer is a silent no-op', () async {
      final transport = WebSocketTransport(listenPort: 0);
      await transport.start(self: 'lonely', appId: 'ws');
      addTearDown(transport.stop);
      await transport.send('nobody', const Frame('room', [1]));
    });
  });

  group('relay', () {
    test('forwards frames between clients and announces joins and leaves',
        () async {
      final relay = await WebSocketRelay.bind(port: 0);
      addTearDown(relay.close);
      final uri = Uri.parse('ws://127.0.0.1:${relay.port}');

      final a = WebSocketTransport(connectTo: [uri]);
      final b = WebSocketTransport(connectTo: [uri]);
      final aSeesB = a.events
          .firstWhere((e) => e is PeerConnected && e.peer == 'node-b')
          .timeout(const Duration(seconds: 5));
      await a.start(self: 'node-a', appId: 'ws');
      await b.start(self: 'node-b', appId: 'ws');
      addTearDown(a.stop);

      await aSeesB;
      final atB = b.inbound.first.timeout(const Duration(seconds: 5));
      await a.send('node-b', const Frame('room-x', [42]));
      final received = await atB;
      expect(received.from, 'node-a');
      expect(received.frame.room, 'room-x');
      expect(received.frame.bytes, [42]);

      // A leave is announced to the survivors.
      final aLosesB = a.events
          .firstWhere((e) => e is PeerLost && e.peer == 'node-b')
          .timeout(const Duration(seconds: 5));
      await b.stop();
      await aLosesB;
    });

    test('two Conclave nodes converge through the relay', () async {
      final relay = await WebSocketRelay.bind(port: 0);
      addTearDown(relay.close);
      final uri = Uri.parse('ws://127.0.0.1:${relay.port}');

      Future<Conclave> openNode() => Conclave.lowLevel(
            config: const ConclaveConfig(appId: 'wsr', salt: 'wsr:v1'),
            keyStore: _MemKeyStore(),
            transport: WebSocketTransport(connectTo: [uri]),
            deriveKey: (p, _) async =>
                List<int>.generate(32, (i) => p.codeUnitAt(i % p.length)),
            roomTag: (_) => 'room',
            cipher: _XorCipher.new,
            mnemonicGenerator: (n) => List.generate(n, (i) => 'word$i'),
            validateMnemonic: (_) => true,
            engine: (dbId, collection, _) => MapCrdtTable(collection),
          );

      final a = await openNode();
      final b = await openNode();
      addTearDown(() async {
        await a.close();
        await b.close();
      });

      const passphrase = 'w0 w1 w2 w3 w4 w5 w6 w7 w8 w9 w10 w11';
      final dbA = await a.openDatabase('d', passphrase: passphrase);
      final dbB = await b.openDatabase('d', passphrase: passphrase);
      final colA = dbA.collection<Map<String, dynamic>>('notes', _codec);
      final colB = dbB.collection<Map<String, dynamic>>('notes', _codec);

      await colA.put({'id': 'x', 'v': 'through the relay'});
      await colB
          .watch()
          .firstWhere((l) => l.isNotEmpty)
          .timeout(const Duration(seconds: 10));
      expect((await colB.get('x'))?['v'], 'through the relay');
    });
  });
}
