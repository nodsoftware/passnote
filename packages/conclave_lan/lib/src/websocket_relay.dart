import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A reference frame relay for `WebSocketTransport` peers that cannot reach
/// each other directly (typically: browsers, or devices on different
/// networks).
///
/// Every client connects with a WebSocket, announces itself (`hello <node>`),
/// learns about the other clients (`join` / `left` lines), and exchanges
/// addressed binary envelopes; the relay routes each envelope to its `to`
/// node. **The relay is not trusted with data**: payloads are end-to-end
/// encrypted by Conclave before they reach the transport, so the relay sees
/// only node ids, public room tags, and ciphertext.
///
/// This is a reference, not a product: it binds one port, keeps everything in
/// memory, and has no authentication or persistence. Run it with
/// `dart run conclave_lan:relay --port 9473`, or host it in-process:
///
/// ```dart
/// final relay = await WebSocketRelay.bind(port: 9473);
/// print('relay on ${relay.port}');
/// ```
class WebSocketRelay {
  WebSocketRelay._(this._server) {
    _server.listen(_handleRequest);
  }

  /// Binds the relay on [port] (`0` = an ephemeral port).
  static Future<WebSocketRelay> bind({required int port}) async =>
      WebSocketRelay._(await HttpServer.bind(InternetAddress.anyIPv4, port));

  final HttpServer _server;

  /// Connected clients by node id.
  final Map<String, WebSocket> _clients = {};

  /// The port the relay is listening on.
  int get port => _server.port;

  /// The node ids currently connected.
  Iterable<String> get connectedNodes => _clients.keys;

  /// Stops the relay and disconnects every client.
  Future<void> close() async {
    for (final socket in _clients.values.toList()) {
      await socket.close();
    }
    _clients.clear();
    await _server.close(force: true);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }
    final socket = await WebSocketTransformer.upgrade(request);
    String? node;

    socket.listen(
      (data) {
        if (data is String) {
          // The only client-to-relay control line is the initial hello.
          if (node == null && data.startsWith('hello ')) {
            node = _register(data.substring('hello '.length), socket);
          }
          return;
        }
        if (node == null || data is! List<int>) return;
        final to = _envelopeTo(data);
        if (to == null) return;
        _clients[to]?.add(data);
      },
      onDone: () => _unregister(node),
      onError: (Object _) => _unregister(node),
    );
  }

  String? _register(String node, WebSocket socket) {
    if (node.isEmpty || _clients.containsKey(node)) {
      socket.close(WebSocketStatus.policyViolation, 'node id taken');
      return null;
    }
    // Introduce the newcomer and the room to each other.
    for (final entry in _clients.entries) {
      entry.value.add('join $node');
      socket.add('join ${entry.key}');
    }
    _clients[node] = socket;
    return node;
  }

  void _unregister(String? node) {
    if (node == null) return;
    if (_clients.remove(node) == null) return;
    for (final socket in _clients.values) {
      socket.add('left $node');
    }
  }

  /// Reads the `to` node id out of a `WebSocketTransport` envelope
  /// (`[2B fromLen][from][2B toLen][to][frame]`) without touching the frame.
  static String? _envelopeTo(List<int> bytes) {
    try {
      final fromLength = (bytes[0] << 8) | bytes[1];
      final toStart = 2 + fromLength + 2;
      final toLength = (bytes[toStart - 2] << 8) | bytes[toStart - 1];
      return utf8.decode(bytes.sublist(toStart, toStart + toLength));
    } catch (_) {
      return null; // Malformed: drop.
    }
  }
}
