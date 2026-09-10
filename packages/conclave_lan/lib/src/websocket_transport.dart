import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:conclave/conclave.dart';

import 'frame_codec.dart';
import 'ws_socket.dart';
import 'ws_socket_io.dart' if (dart.library.js_interop) 'ws_socket_web.dart'
    as backend;

/// A [Transport] over explicit WebSocket addresses — the path a browser peer
/// (or any peer without mDNS) uses.
///
/// Where `LanTransport` discovers peers by itself, a [WebSocketTransport] is
/// told where to connect: one or more `ws(s)://` URIs in [connectTo], each
/// either another peer's listener or a relay (see `WebSocketRelay`). On native
/// platforms it can also accept inbound connections ([listenPort]); a browser
/// can only dial out.
///
/// One connection can carry many peers: a relay announces every client it
/// hosts, and frames travel in addressed envelopes. A direct peer-to-peer
/// connection is simply the two-party case of the same protocol. Frames stay
/// end-to-end encrypted either way — a relay routes envelopes but can read
/// neither payloads nor anything beyond the public room tag.
///
/// ```dart
/// // A web app connecting to a household relay:
/// Conclave.builder(appId: 'shopping', salt: 'shopping:v1')
///     .transport(() => WebSocketTransport(
///           connectTo: [Uri.parse('wss://relay.example:9473')],
///         ))
///     .open();
/// ```
///
/// Dropped connections are re-dialed with exponential backoff for as long as
/// the transport is started.
class WebSocketTransport implements Transport {
  /// Creates a transport that dials [connectTo] on [start].
  ///
  /// [listenPort] (native only; `0` = an ephemeral port, `null` = no listener)
  /// additionally accepts inbound connections — the side a browser peer dials.
  /// [reconnectBaseDelay] and [reconnectMaxDelay] bound the redial backoff.
  WebSocketTransport({
    this.connectTo = const [],
    this.listenPort,
    Duration reconnectBaseDelay = const Duration(seconds: 2),
    Duration reconnectMaxDelay = const Duration(seconds: 60),
  })  : _reconnectBaseDelay = reconnectBaseDelay,
        _reconnectMaxDelay = reconnectMaxDelay {
    if (listenPort != null && !backend.canServe) {
      throw ArgumentError(
        'listenPort is not supported in the browser; a web peer only dials '
        'out. Configure connectTo: instead.',
      );
    }
  }

  /// The `ws(s)://` addresses this transport dials on [start].
  final List<Uri> connectTo;

  /// The port to accept inbound connections on (native only).
  final int? listenPort;

  final Duration _reconnectBaseDelay;
  final Duration _reconnectMaxDelay;

  final _events = StreamController<PeerEvent>.broadcast();
  final _inbound = StreamController<InboundFrame>.broadcast();

  late NodeId _self;
  bool _started = false;
  WsServerHandle? _server;

  /// The route (connection) each known peer is reachable through.
  final Map<PeerId, WsConnection> _routes = {};

  /// The peers announced per connection, for cleanup when it closes.
  final Map<WsConnection, Set<PeerId>> _peersOf = {};

  /// Redial attempt counts per configured URI.
  final Map<Uri, int> _reconnectAttempts = {};

  /// The port the native listener is bound to, or `null` when not listening.
  /// Available after [start]; useful with `listenPort: 0`.
  int? get boundPort => _server?.port;

  @override
  Stream<PeerEvent> get events => _events.stream;

  @override
  Stream<InboundFrame> get inbound => _inbound.stream;

  @override
  Future<void> start({required NodeId self, required String appId}) async {
    if (_started) throw StateError('WebSocketTransport already started');
    _started = true;
    _self = self;

    final port = listenPort;
    if (port != null) {
      _server = await backend.serveWs(port, _adopt);
    }
    for (final uri in connectTo) {
      unawaited(_dial(uri));
    }
  }

  @override
  Future<void> send(PeerId to, Frame frame) async {
    final route = _routes[to];
    if (route == null) return;
    route.sendBytes(_envelope(_self, to, frame));
  }

  @override
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    await _server?.close();
    _server = null;
    for (final connection in _peersOf.keys.toList()) {
      await connection.close();
    }
    _routes.clear();
    _peersOf.clear();
    await _events.close();
    await _inbound.close();
  }

  // ---------------------------------------------------------------------------
  // Dialing

  Future<void> _dial(Uri uri) async {
    if (!_started) return;
    try {
      final connection = await backend.connectWs(uri);
      _reconnectAttempts.remove(uri);
      _adopt(connection, redialUri: uri);
    } catch (_) {
      _scheduleRedial(uri);
    }
  }

  void _scheduleRedial(Uri uri) {
    if (!_started) return;
    final attempt = (_reconnectAttempts[uri] ?? 0) + 1;
    _reconnectAttempts[uri] = attempt;
    final delayMs = _reconnectBaseDelay.inMilliseconds * (1 << (attempt - 1));
    final delay = Duration(
      milliseconds: delayMs.clamp(0, _reconnectMaxDelay.inMilliseconds),
    );
    Timer(delay, () {
      if (_started) unawaited(_dial(uri));
    });
  }

  // ---------------------------------------------------------------------------
  // Connection handling (both dialed and accepted)

  void _adopt(WsConnection connection, {Uri? redialUri}) {
    _peersOf[connection] = {};
    connection.sendText('hello $_self');

    connection.messages.listen(
      (message) {
        if (message is String) {
          _control(connection, message);
        } else if (message is List<int>) {
          _routedFrame(message);
        }
      },
      onDone: () => _dropConnection(connection, redialUri),
      onError: (Object _) => _dropConnection(connection, redialUri),
    );
  }

  void _control(WsConnection connection, String line) {
    final space = line.indexOf(' ');
    if (space < 0) return;
    final verb = line.substring(0, space);
    final node = line.substring(space + 1);
    if (node.isEmpty || node == _self) return;
    switch (verb) {
      case 'hello' || 'join':
        if (_routes.containsKey(node)) return; // First route wins.
        _routes[node] = connection;
        _peersOf[connection]?.add(node);
        _events.add(PeerConnected(node));
      case 'left':
        if (_peersOf[connection]?.remove(node) ?? false) {
          _routes.remove(node);
          _events.add(PeerLost(node));
        }
    }
  }

  void _routedFrame(List<int> bytes) {
    final envelope = _decodeEnvelope(bytes);
    if (envelope == null) return;
    final (from, to, frame) = envelope;
    // Not ours (a relay mis-route, or a peer racing a topology change).
    if (to != _self) return;
    if (!_inbound.isClosed) _inbound.add(InboundFrame(from, frame));
  }

  void _dropConnection(WsConnection connection, Uri? redialUri) {
    final peers = _peersOf.remove(connection) ?? const {};
    for (final peer in peers) {
      _routes.remove(peer);
      if (!_events.isClosed) _events.add(PeerLost(peer));
    }
    if (redialUri != null && _started) _scheduleRedial(redialUri);
  }

  // ---------------------------------------------------------------------------
  // Envelope: [2B fromLen][from][2B toLen][to][FrameCodec frame]

  static Uint8List _envelope(NodeId from, PeerId to, Frame frame) {
    final fromBytes = utf8.encode(from);
    final toBytes = utf8.encode(to);
    final out = BytesBuilder(copy: false)
      ..addByte((fromBytes.length >> 8) & 0xff)
      ..addByte(fromBytes.length & 0xff)
      ..add(fromBytes)
      ..addByte((toBytes.length >> 8) & 0xff)
      ..addByte(toBytes.length & 0xff)
      ..add(toBytes)
      ..add(FrameCodec.encode(frame));
    return out.toBytes();
  }

  static (String, String, Frame)? _decodeEnvelope(List<int> bytes) {
    try {
      var pos = 0;
      String readString() {
        final length = (bytes[pos] << 8) | bytes[pos + 1];
        pos += 2;
        final value = utf8.decode(bytes.sublist(pos, pos + length));
        pos += length;
        return value;
      }

      final from = readString();
      final to = readString();
      final frame = FrameCodec.decode(bytes.sublist(pos));
      if (frame == null) return null;
      return (from, to, frame);
    } catch (_) {
      return null; // Malformed envelope: drop, never throw.
    }
  }
}
