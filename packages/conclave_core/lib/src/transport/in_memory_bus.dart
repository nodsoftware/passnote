import '../ports/transport.dart';
import 'in_memory_transport.dart';

/// Routes [Frame]s between [InMemoryTransport] nodes registered on this bus.
///
/// Used in engine tests to simulate a local network without any sockets.
/// Two (or more) [Conclave] instances backed by the same bus will converge
/// exactly as they would over a real LAN transport.
class InMemoryBus {
  final Map<NodeId, InMemoryTransport> _nodes = {};

  /// Registers [transport] on this bus and notifies all existing nodes of the
  /// new peer (and vice-versa).
  void register(InMemoryTransport transport) {
    final id = transport.nodeId!;
    for (final other in _nodes.values) {
      other.injectPeerConnected(id);
      transport.injectPeerConnected(other.nodeId!);
    }
    _nodes[id] = transport;
  }

  /// Removes [id] from the bus and notifies all remaining nodes.
  void unregister(NodeId id) {
    _nodes.remove(id);
    for (final other in _nodes.values) {
      other.injectPeerLost(id);
    }
  }

  /// Delivers [frame] from [from] to the single addressed node [to].
  ///
  /// Mirrors the unicast semantics of the real LAN transport: a frame is
  /// delivered only to its target. Unknown targets are silently dropped.
  void route(NodeId from, NodeId to, Frame frame) {
    _nodes[to]?.injectFrame(from, frame);
  }
}
