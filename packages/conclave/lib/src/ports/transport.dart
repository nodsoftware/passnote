/// A unique, stable identifier for this app instance within the transport.
typedef NodeId = String;

/// Identifies a remote peer.
typedef PeerId = String;

/// Base type for transport events: peer lifecycle and discovery state.
sealed class PeerEvent {
  const PeerEvent();
}

/// Emitted when a new peer connects.
final class PeerConnected extends PeerEvent {
  /// Creates the event.
  const PeerConnected(this.peer);

  /// The peer that connected.
  final PeerId peer;
}

/// Emitted when a peer disconnects or becomes unreachable.
final class PeerLost extends PeerEvent {
  /// Creates the event.
  const PeerLost(this.peer);

  /// The peer that was lost.
  final PeerId peer;
}

/// Emitted (at most once per [Transport.start]) when the transport determines
/// its peer-discovery mechanism is unavailable on this platform — for
/// example, the OS refused the multicast sockets mDNS needs because a
/// permission or entitlement is missing.
///
/// The transport itself stays up and connections that arrive by other means
/// still work; only automatic discovery is out. Surface this to the user:
/// without it, "discovery is blocked" is indistinguishable from "no peers
/// nearby". See the platform-setup guide for the per-OS declarations.
final class DiscoveryUnavailable extends PeerEvent {
  /// Creates the event.
  const DiscoveryUnavailable({required this.reason});

  /// A short human-readable description of what was refused.
  final String reason;
}

/// Peer discovery works again after a [DiscoveryUnavailable].
///
/// Discovery can come back without a restart: a permission granted while the
/// app runs, or a network that starts carrying multicast again. An app that
/// warned the user on [DiscoveryUnavailable] takes the warning down here.
final class DiscoveryRestored extends PeerEvent {
  /// Creates the event.
  const DiscoveryRestored();
}

/// A tagged binary payload routed by [room].
///
/// [room] is a public, non-reversible hash of a database key used only for
/// multiplexing; possessing the room tag is never sufficient to decrypt the
/// payload.
class Frame {
  /// Creates a frame.
  const Frame(this.room, this.bytes);

  /// Public discovery tag for the target database.
  final String room;

  /// Encrypted payload bytes.
  final List<int> bytes;
}

/// A [Frame] received from [from].
class InboundFrame {
  /// Creates a received frame.
  const InboundFrame(this.from, this.frame);

  /// The peer that sent this frame.
  final PeerId from;

  /// The received frame.
  final Frame frame;
}

/// Discovers same-app nodes and moves opaque frames between them.
///
/// The transport is room-blind: it delivers frames without interpreting their
/// content. Room-based routing and decryption happen in the engine layer.
abstract interface class Transport {
  /// Stream of peer connection and disconnection events.
  Stream<PeerEvent> get events;

  /// Stream of frames received from remote peers.
  Stream<InboundFrame> get inbound;

  /// Starts the transport, advertising [self] under [appId].
  Future<void> start({required NodeId self, required String appId});

  /// Sends [frame] to the peer identified by [to].
  Future<void> send(PeerId to, Frame frame);

  /// Stops the transport, closing all active connections.
  Future<void> stop();
}
