/// A unique, stable identifier for this app instance within the transport.
typedef NodeId = String;

/// Identifies a remote peer.
typedef PeerId = String;

/// Base type for peer-lifecycle events.
sealed class PeerEvent {
  const PeerEvent(this.peer);

  /// The peer this event concerns.
  final PeerId peer;
}

/// Emitted when a new peer connects.
final class PeerConnected extends PeerEvent {
  const PeerConnected(super.peer);
}

/// Emitted when a peer disconnects or becomes unreachable.
final class PeerLost extends PeerEvent {
  const PeerLost(super.peer);
}

/// A tagged binary payload routed by [room].
///
/// [room] is a public, non-reversible hash of a database key used only for
/// multiplexing; possessing the room tag is never sufficient to decrypt the
/// payload.
class Frame {
  const Frame(this.room, this.bytes);

  /// Public discovery tag for the target database.
  final String room;

  /// Encrypted payload bytes.
  final List<int> bytes;
}

/// A [Frame] received from [from].
class InboundFrame {
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
