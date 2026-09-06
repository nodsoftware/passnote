import 'dart:async';

import '../ports/transport.dart';
import 'in_memory_bus.dart';

/// A [Transport] implementation that routes frames through an [InMemoryBus].
///
/// Two [Conclave] instances backed by the same bus synchronise without any
/// sockets. This is the foundation of every engine-level test and is also
/// usable for multi-isolate apps sharing a bus over ports.
class InMemoryTransport implements Transport {
  InMemoryTransport(this._bus);

  final InMemoryBus _bus;
  NodeId? _nodeId;

  final _events = StreamController<PeerEvent>.broadcast();
  final _inbound = StreamController<InboundFrame>.broadcast();

  /// The [NodeId] assigned during [start], or `null` before then.
  NodeId? get nodeId => _nodeId;

  // ---------------------------------------------------------------------------
  // Transport interface

  @override
  Stream<PeerEvent> get events => _events.stream;

  @override
  Stream<InboundFrame> get inbound => _inbound.stream;

  @override
  Future<void> start({required NodeId self, required String appId}) async {
    _nodeId = self;
    _bus.register(this);
  }

  @override
  Future<void> send(PeerId to, Frame frame) async {
    _bus.route(_nodeId!, to, frame);
  }

  @override
  Future<void> stop() async {
    _bus.unregister(_nodeId!);
    await _events.close();
    await _inbound.close();
  }

  // ---------------------------------------------------------------------------
  // Bus-internal injection API

  /// Called by [InMemoryBus] when a new peer appears on the bus.
  void injectPeerConnected(NodeId peer) => _events.add(PeerConnected(peer));

  /// Called by [InMemoryBus] when a peer leaves the bus.
  void injectPeerLost(NodeId peer) => _events.add(PeerLost(peer));

  /// Called by [InMemoryBus] to deliver an inbound frame.
  void injectFrame(NodeId from, Frame frame) =>
      _inbound.add(InboundFrame(from, frame));
}
