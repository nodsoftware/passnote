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
  bool _advertiseOk = true;
  bool _browseOk = true;

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
          final mdns = MDNSServer(
            MDNSServerConfig(zone: service, reusePort: _reusePort),
          );
          await mdns.start();
          _mdnsServer = mdns;
          _noteDiscovery(advertise: true);
        } catch (_) {
          _noteDiscovery(advertise: false);
        }
        if (!done.isCompleted) done.complete();
      },
      (_, __) {
        // The responder sends on both address families too. Once it is up, a
        // failing send on one of them is not a refused advertisement.
        if (_mdnsServer == null) _noteDiscovery(advertise: false);
        if (!done.isCompleted) done.complete();
      },
    );
    return done.future;
  }

  /// Records that advertising, or one browse round, failed or succeeded, and
  /// emits an event when that changes whether discovery works at all.
  ///
  /// Discovery needs both halves: a responder so peers can find this node, and
  /// a browse so this node can find them. Either one down is reported, and
  /// only both being up clears it again.
  ///
  /// Transitions are what get emitted, never each failing round: a permanently
  /// refused browse retries every [_discoveryInterval] and must not turn into
  /// an endless stream of identical events. Equally, the first failure must
  /// not latch forever — a later failure after a recovery is news again.
  void _noteDiscovery({bool? advertise, bool? browse}) {
    final was = _advertiseOk && _browseOk;
    if (advertise != null) _advertiseOk = advertise;
    if (browse != null) _browseOk = browse;
    final now = _advertiseOk && _browseOk;
    if (was == now || _events.isClosed) return;
    if (now) {
      _events.add(const DiscoveryRestored());
    } else {
      _events.add(DiscoveryUnavailable(
        reason: _advertiseOk
            ? 'multicast browse was refused'
            : 'multicast advertisement was refused',
      ));
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
    // A browse takes seconds, so [stop] can land while one is in flight: by
    // here the streams are closed and the connections torn down, and dialing
    // a peer now would reopen what stop just closed.
    if (!_started) return;
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

  /// Whether to ask for `SO_REUSEPORT` when binding an mDNS socket.
  ///
  /// Apple platforms run their own mDNS responder, which already holds UDP
  /// 5353. Sharing that port needs `SO_REUSEPORT`; `reuseAddress` alone is not
  /// enough, and a bind without it fails with
  /// `Address already in use, errno = 48`. Both mDNS sockets — the responder
  /// that advertises this node and the client that browses for peers — bind
  /// 5353, so both ask for it here.
  ///
  /// Android rejects the option outright: the runtime refuses the bind with
  /// ``Dart Socket ERROR: `reusePort` not supported on this platform``, which
  /// kills discovery on a platform that has no competing responder and does
  /// not need the option at all. Linux implements it, but nothing there
  /// contends for 5353, so `reuseAddress` is enough and this stays Apple-only.
  static final bool _reusePort = Platform.isMacOS || Platform.isIOS;

  /// One mDNS browse, inside a guarded zone scoped to the query alone: the
  /// mDNS library sends from fire-and-forget futures, so multicast refusal
  /// surfaces as asynchronous errors that must not reach the app. Returns
  /// `null` when discovery is unavailable (also noted as an event).
  ///
  /// The library queries both address families. A host that routes one of them
  /// and not the other — an IPv4-only LAN is the common case — fails those
  /// sends with `No route to host` while the other family answers normally, so
  /// an asynchronous send failure alone says nothing about whether discovery
  /// works. It used to count anyway whenever the browse also came back
  /// empty — meant as a proxy for "and nothing else explains the empty
  /// result", but wrong on exactly the browsing device with no peers to
  /// find yet: browse there is *always* empty, on every single-address-
  /// family LAN (common — plenty of home networks route only IPv4), turning
  /// every retry into a false "multicast browse was refused" for a device
  /// that was never actually refused anything (found by a real device
  /// stuck showing that banner indefinitely while alone on its network).
  /// [_isRefusal] now does what the empty-results check was standing in
  /// for: separates an actual permission refusal from an unreachable
  /// address family, so only the former counts.
  Future<List<ServiceEntry>?> _discover() {
    final done = Completer<List<ServiceEntry>?>();
    var refused = false;
    runZonedGuarded(
      () async {
        try {
          final entries = await MDNSClient.discover(
            _serviceType,
            timeout: const Duration(seconds: 2),
            reusePort: _reusePort,
          );
          if (entries.isEmpty && refused) {
            _noteDiscovery(browse: false);
            if (!done.isCompleted) done.complete(null);
            return;
          }
          _noteDiscovery(browse: true);
          if (!done.isCompleted) done.complete(entries);
        } catch (error) {
          if (_isRefusal(error)) refused = true;
          _noteDiscovery(browse: !refused);
          if (!done.isCompleted) done.complete(null);
        }
      },
      (error, __) {
        // Swallowed so it never reaches the app, and recorded rather than
        // acted on: aborting here would discard the results the working
        // address family is about to deliver.
        if (_isRefusal(error)) refused = true;
      },
    );
    return done.future;
  }

  /// Whether [error] is the OS actually denying multicast — permission
  /// revoked, no multicast lock held — as opposed to an address family
  /// simply having no route on this network, which is routine and would
  /// otherwise be misreported as a refusal on every retry for as long as a
  /// device has no peers to find (see [_discover]'s doc comment). Dart's
  /// `SocketException.osError` carries the platform errno; matched by
  /// message rather than by numeric code because BSD/Darwin's
  /// `ENETUNREACH`/`EHOSTUNREACH` values differ from Linux/Android's, while
  /// `dart:io` renders both consistently in `OSError.message`.
  static bool _isRefusal(Object error) {
    if (error is! SocketException) return false;
    final message = (error.osError?.message ?? error.message).toLowerCase();
    if (message.contains('permission') || message.contains('not permitted')) {
      return true;
    }
    if (message.contains('unreachable') || message.contains('no route')) {
      return false;
    }
    // An error shape neither list recognizes: treat as a refusal rather
    // than silently swallowing an unfamiliar failure mode.
    return true;
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
