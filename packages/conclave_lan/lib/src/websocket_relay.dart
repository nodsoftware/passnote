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
/// ## Deployment warning
///
/// The relay has **no authentication**, and that means more than "anyone may
/// connect": anyone who can reach it can claim any node id that is not
/// connected at that moment. The squatter then receives every envelope
/// addressed to that id — still ciphertext, but the full metadata graph (who
/// talks to the node, frame sizes, timing) — and the real node is refused
/// until the squatter leaves, a denial of service it cannot tell from an
/// outage. An id that is already connected cannot be taken over, and dead
/// connections are reaped by ping so a dropped node can reclaim its id, but
/// pre-claiming is always possible. **Run the relay only on a network you
/// control, or behind an authenticating proxy.** In the same breath: open
/// connections, frame size, node-id length, and time-to-hello are bounded
/// only by [maxClients], [maxFrameBytes], and [helloTimeout] — resource
/// hygiene, not protection.
///
/// This is a reference, not a product: it binds one port, keeps everything in
/// memory, and has no persistence. Run it with
/// `dart run conclave_lan:relay --port 9473`, or host it in-process:
///
/// ```dart
/// final relay = await WebSocketRelay.bind(port: 9473);
/// print('relay on ${relay.port}');
/// ```
class WebSocketRelay {
  WebSocketRelay._(
    this._server,
    this.maxClients,
    this.maxFrameBytes,
    this.helloTimeout,
  ) {
    _server.listen(_handleRequest, onError: (Object _) {});
  }

  /// Binds the relay on [port] (`0` = an ephemeral port).
  ///
  /// [maxClients] bounds **open connections** (not just registered ones — a
  /// socket costs a file descriptor whether or not it ever says hello); a
  /// connection beyond it is closed with [relayFullCode]. A connection that
  /// has not sent its `hello` within [helloTimeout] is evicted, so silent
  /// sockets cannot hold the cap hostage. [maxFrameBytes] bounds one
  /// envelope; a larger one closes its sender with `1009 message too big`.
  /// All of it is hygiene against accidents and floods, not authentication
  /// (see the class docs).
  static Future<WebSocketRelay> bind({
    required int port,
    int maxClients = 256,
    int maxFrameBytes = 4 << 20,
    Duration helloTimeout = const Duration(seconds: 10),
  }) async =>
      WebSocketRelay._(
        await HttpServer.bind(InternetAddress.anyIPv4, port),
        maxClients,
        maxFrameBytes,
        helloTimeout,
      );

  final HttpServer _server;

  /// Maximum simultaneously connected clients.
  final int maxClients;

  /// Maximum size of one relayed envelope in bytes.
  final int maxFrameBytes;

  /// How long a connection may stay open without sending its `hello`.
  final Duration helloTimeout;

  /// Open sockets, registered or not — what [maxClients] actually bounds.
  int _openSockets = 0;

  /// Longest node id accepted in a `hello`.
  static const int _maxNodeIdLength = 128;

  /// Application close code for "relay full" (dart:io only permits reserved
  /// codes or the 3000-4999 range).
  static const int relayFullCode = 4013;

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
    // Remote-fed input: a request that fails mid-handling is dropped, never
    // an unhandled async error.
    try {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      if (_openSockets >= maxClients) {
        // Drain so the close handshake can complete, then refuse.
        socket.listen((_) {}, onError: (Object _) {});
        await socket.close(relayFullCode, 'relay full');
        return;
      }
      _openSockets++;
      var counted = true;
      // Reap dead connections so a dropped node can reclaim its id instead
      // of being locked out by its own ghost.
      socket.pingInterval = const Duration(seconds: 15);
      String? node;
      // A socket that never says hello holds a slot (and a file descriptor)
      // for nothing: evict it. Answering pings is not enough to keep a slot.
      final helloTimer = Timer(helloTimeout, () {
        if (node == null) {
          socket.close(WebSocketStatus.policyViolation, 'no hello');
        }
      });

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
          if (data.length > maxFrameBytes) {
            socket.close(WebSocketStatus.messageTooBig, 'frame too large');
            return;
          }
          final to = _envelopeTo(data);
          if (to == null) return;
          _clients[to]?.add(data);
        },
        onDone: () {
          helloTimer.cancel();
          if (counted) {
            counted = false;
            _openSockets--;
          }
          _unregister(node);
        },
        onError: (Object _) {
          helloTimer.cancel();
          if (counted) {
            counted = false;
            _openSockets--;
          }
          _unregister(node);
        },
      );
    } catch (_) {
      // The requester is gone or sent garbage; there is nobody to answer.
    }
  }

  String? _register(String node, WebSocket socket) {
    // First claim wins: an id that is connected cannot be taken over (see
    // the class docs for what an unauthenticated relay can NOT protect).
    if (node.isEmpty ||
        node.length > _maxNodeIdLength ||
        _clients.containsKey(node)) {
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
