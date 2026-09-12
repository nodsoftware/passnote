import 'dart:async';
import 'dart:io';

import 'package:conclave/conclave.dart';
import 'package:mdns_dart/mdns_dart.dart';

import 'frame_codec.dart';

/// A LAN [Transport] that discovers same-app peers over mDNS / DNS-SD and
/// exchanges frames over WebSocket connections.
///
/// Discovery advertises a service of type `_conclave-<appId>._tcp` carrying a
/// `node` TXT entry (this instance's [NodeId]) and the port of its WebSocket
/// server. Peers browse the same type, then dial each other's WebSocket. To
/// avoid two connections between the same pair, only the node with the
/// lexicographically smaller id dials; the larger id accepts the inbound
/// connection.
///
/// The WebSocket layer is covered by the default unit run; mDNS discovery is
/// socket-bound and covered by the tagged loopback integration test.
class LanTransport implements Transport {
  /// Creates a transport.
  ///
  /// [discoveryInterval] controls how often the network is re-browsed for new
  /// peers. [reconnectBaseDelay] and [reconnectMaxDelay] bound the exponential
  /// backoff used when re-dialing a dropped peer.
  LanTransport({
    Duration discoveryInterval = const Duration(seconds: 5),
    Duration reconnectBaseDelay = const Duration(seconds: 2),
    Duration reconnectMaxDelay = const Duration(seconds: 60),
  })  : _discoveryInterval = discoveryInterval,
        _reconnectBaseDelay = reconnectBaseDelay,
        _reconnectMaxDelay = reconnectMaxDelay;

  final Duration _discoveryInterval;
  final Duration _reconnectBaseDelay;
  final Duration _reconnectMaxDelay;

  final _events = StreamController<PeerEvent>.broadcast();
  final _inbound = StreamController<InboundFrame>.broadcast();

  late NodeId _self;
  late String _serviceType;

  HttpServer? _wsServer;
  MDNSServer? _mdnsServer;
  Timer? _discoveryTimer;
  bool _started = false;
  bool _discoveryUnavailableEmitted = false;

  /// Active connections keyed by remote [PeerId] (their [NodeId]).
  final Map<PeerId, WebSocket> _connections = {};

  /// Peers we are currently dialing, to avoid duplicate concurrent dials.
  final Set<PeerId> _dialing = {};

  /// Reconnect attempt counts per peer for exponential backoff.
  final Map<PeerId, int> _reconnectAttempts = {};

  @override
  Stream<PeerEvent> get events => _events.stream;

  @override
  Stream<InboundFrame> get inbound => _inbound.stream;

  /// The local port the WebSocket server is bound to, or `null` before
  /// [start]. Diagnostics and tests; peers learn it over mDNS.
  int? get port => _wsServer?.port;

  @override
  Future<void> start({required NodeId self, required String appId}) async {
    if (_started) throw StateError('LanTransport already started');
    _started = true;
    _self = self;
    _serviceType = '_conclave-$appId._tcp';

    // 1. WebSocket server on an ephemeral port. Remote-fed input: a request
    // that fails mid-handling is dropped, never an unhandled async error.
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _wsServer = server;
    server.listen(_handleHttpRequest, onError: (Object _) {});

    // 2. Advertise this node over mDNS. A platform that refuses multicast (a
    // missing entitlement or local-network permission) must not crash the
    // app: the transport stays up without discovery — the failure mode the
    // platform-setup guide documents — and a [DiscoveryUnavailable] event
    // tells the app why no peers will appear.
    await _advertise(self, server.port);

    // 3. Browse for peers immediately and on an interval. Only the mDNS
    // query itself runs guarded (see [_discover]); dialing and socket
    // handling keep normal error propagation, like the accepting side.
    unawaited(_browse());
    _discoveryTimer =
        Timer.periodic(_discoveryInterval, (_) => unawaited(_browse()));
  }

  /// Starts the mDNS responder. Never throws: the mDNS library sends packets
  /// from fire-and-forget futures, so multicast refusal can surface as an
  /// asynchronous error long after the awaited calls return — the responder
  /// therefore lives in its own guarded zone, scoped to mDNS alone, and a
  /// refusal degrades to "no advertisement" plus a [DiscoveryUnavailable]
  /// event.
  Future<void> _advertise(NodeId self, int wsPort) {
    final done = Completer<void>();
    runZonedGuarded(
      () async {
        try {
          final service = await MDNSService.create(
            instance: self,
            service: _serviceType,
            port: wsPort,
            txt: ['node=$self', 'port=$wsPort'],
          );
          final mdns = MDNSServer(MDNSServerConfig(zone: service));
          await mdns.start();
          _mdnsServer = mdns;
        } catch (_) {
          _noteDiscoveryUnavailable('multicast advertisement was refused');
        }
        if (!done.isCompleted) done.complete();
      },
      (_, __) {
        _noteDiscoveryUnavailable('multicast advertisement was refused');
        if (!done.isCompleted) done.complete();
      },
    );
    return done.future;
  }

  /// Emits [DiscoveryUnavailable] once per transport lifetime.
  void _noteDiscoveryUnavailable(String reason) {
    if (_discoveryUnavailableEmitted) return;
    _discoveryUnavailableEmitted = true;
    if (!_events.isClosed) {
      _events.add(DiscoveryUnavailable(reason: reason));
    }
  }

  @override
  Future<void> send(PeerId to, Frame frame) async {
    final conn = _connections[to];
    if (conn == null) return;
    conn.add(FrameCodec.encode(frame));
  }

  @override
  Future<void> stop() async {
    if (!_started) return;
    _started = false;

    _discoveryTimer?.cancel();
    _discoveryTimer = null;

    for (final conn in _connections.values) {
      await conn.close();
    }
    _connections.clear();
    _dialing.clear();
    _reconnectAttempts.clear();

    await _mdnsServer?.stop();
    _mdnsServer = null;
    await _wsServer?.close(force: true);
    _wsServer = null;

    await _events.close();
    await _inbound.close();
  }

  // ---------------------------------------------------------------------------
  // Inbound (server side)

  Future<void> _handleHttpRequest(HttpRequest request) async {
    // Fail closed on remote-fed input: `onError` on the server subscription
    // does not catch a throw from inside this async callback (a malformed
    // upgrade, a connection dying mid-handshake), so the whole handler is
    // guarded and a failing request is simply dropped.
    try {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      _registerSocket(socket, dialedPeer: null);
    } catch (_) {
      // The requester is gone or sent garbage; there is nobody to answer.
    }
  }

  // ---------------------------------------------------------------------------
  // Discovery + outbound (client side)

  Future<void> _browse() async {
    if (!_started) return;
    final entries = await _discover();
    // Unavailable this round; the next tick retries in case the permission
    // arrived. Dialing below runs in the caller's zone.
    if (entries == null) return;
    for (final entry in entries) {
      final txt = MDNSService.parseTXTRecords(entry.infoFields);
      final node = txt['node'];
      final address = entry.primaryAddress;
      if (node == null || node == _self || address == null) continue;
      // Only the smaller id dials, so a pair forms exactly one connection.
      if (_self.compareTo(node) >= 0) continue;
      if (_connections.containsKey(node) || _dialing.contains(node)) continue;
      unawaited(_dial(node, address, entry.port));
    }
  }

  /// Whether to ask for `SO_REUSEPORT` when binding the mDNS socket.
  ///
  /// Dart implements `reusePort` only on macOS and iOS; everywhere else the
  /// runtime rejects the bind outright with
  /// ``Dart Socket ERROR: `reusePort` not supported on this platform``. On
  /// Apple platforms it is what lets the browse socket share UDP 5353 with the
  /// OS's own mDNS responder, so it is worth asking for there and nowhere
  /// else. `reuseAddress` (always on) covers the rest.
  static final bool _reusePort = Platform.isMacOS || Platform.isIOS;

  /// One mDNS browse, inside a guarded zone scoped to the query alone: the
  /// mDNS library sends from fire-and-forget futures, so multicast refusal
  /// surfaces as asynchronous errors that must not reach the app. Returns
  /// `null` when discovery is unavailable (also noted as an event).
  Future<List<ServiceEntry>?> _discover() {
    final done = Completer<List<ServiceEntry>?>();
    runZonedGuarded(
      () async {
        try {
          final entries = await MDNSClient.discover(
            _serviceType,
            timeout: const Duration(seconds: 2),
            reusePort: _reusePort,
          );
          if (!done.isCompleted) done.complete(entries);
        } catch (_) {
          _noteDiscoveryUnavailable('multicast browse was refused');
          if (!done.isCompleted) done.complete(null);
        }
      },
      (_, __) {
        _noteDiscoveryUnavailable('multicast browse was refused');
        if (!done.isCompleted) done.complete(null);
      },
    );
    return done.future;
  }

  Future<void> _dial(PeerId peer, InternetAddress address, int port) async {
    if (!_started || _connections.containsKey(peer)) return;
    _dialing.add(peer);
    try {
      final socket = await WebSocket.connect('ws://${address.address}:$port');
      _reconnectAttempts.remove(peer);
      _registerSocket(socket, dialedPeer: peer);
    } catch (_) {
      _scheduleReconnect(peer, address, port);
    } finally {
      _dialing.remove(peer);
    }
  }

  void _scheduleReconnect(PeerId peer, InternetAddress address, int port) {
    if (!_started) return;
    final attempt = (_reconnectAttempts[peer] ?? 0) + 1;
    _reconnectAttempts[peer] = attempt;
    final delayMs = _reconnectBaseDelay.inMilliseconds * (1 << (attempt - 1));
    final delay = Duration(
      milliseconds: delayMs.clamp(0, _reconnectMaxDelay.inMilliseconds),
    );
    Timer(delay, () {
      if (_started && !_connections.containsKey(peer)) {
        unawaited(_dial(peer, address, port));
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Shared connection handling

  /// Wires up [socket]. For dialed sockets [dialedPeer] is the known remote
  /// node id; for accepted sockets it is `null` and learned from the handshake.
  void _registerSocket(WebSocket socket, {required PeerId? dialedPeer}) {
    // Heartbeat: dart:io closes the socket if pongs stop arriving.
    socket.pingInterval = const Duration(seconds: 15);

    // Always announce ourselves first so the peer learns our node id.
    socket.add(_self);

    PeerId? peer = dialedPeer;
    if (peer != null) _bindPeer(peer, socket);

    socket.listen(
      (data) {
        if (peer == null) {
          // First text message is the handshake carrying the peer's node id.
          if (data is String) {
            peer = data;
            _bindPeer(peer!, socket);
          }
          return;
        }
        if (data is List<int>) {
          final frame = FrameCodec.decode(data);
          if (frame != null) {
            _inbound.add(InboundFrame(peer!, frame));
          }
        }
      },
      onDone: () => _unbindPeer(peer, socket),
      onError: (_) => _unbindPeer(peer, socket),
      cancelOnError: true,
    );
  }

  void _bindPeer(PeerId peer, WebSocket socket) {
    // A handshake completing while stop() tears things down must not touch
    // the closed controller (the same guard _unbindPeer carries).
    if (!_started || _events.isClosed) {
      unawaited(socket.close());
      return;
    }
    final existing = _connections[peer];
    if (identical(existing, socket)) return;
    if (existing != null) {
      // Duplicate connection to the same peer — keep the first, drop this one.
      unawaited(socket.close());
      return;
    }
    _connections[peer] = socket;
    _events.add(PeerConnected(peer));
  }

  void _unbindPeer(PeerId? peer, WebSocket socket) {
    if (peer == null) return;
    if (!identical(_connections[peer], socket)) return;
    _connections.remove(peer);
    if (_started && !_events.isClosed) {
      _events.add(PeerLost(peer));
    }
  }
}
