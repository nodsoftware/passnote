import 'package:crdt/crdt.dart';

export 'codec.dart' show decodeMessage, encodeMessage, wireVersion;

/// Sealed hierarchy for engine-level protocol messages.
sealed class ProtocolMessage {
  const ProtocolMessage();
}

/// Sent to a peer when a database room is first established.
///
/// The peer responds with a [StateMessage] for each room it also has open.
final class HelloMessage extends ProtocolMessage {
  const HelloMessage({required this.node});

  /// [NodeId] of the sending instance.
  final String node;
}

/// Advertises the sender's per-collection HLC watermarks.
///
/// The receiver replies with a [DeltaMessage] for each collection that has
/// records newer than the advertised watermark.
final class StateMessage extends ProtocolMessage {
  const StateMessage({required this.cols});

  /// Map of collection name → max modified-HLC string (empty = no records).
  final Map<String, String> cols;
}

/// Carries CRDT records for one collection to the peer.
final class DeltaMessage extends ProtocolMessage {
  const DeltaMessage({required this.col, required this.records});

  /// Target collection name.
  final String col;

  /// Records in wire format: each map has `key`, `value`, `is_deleted`, `hlc`
  /// (HLC as ISO-8601 string).
  final List<Map<String, dynamic>> records;
}

/// Requests that the peer initiate a full re-sync back to the sender.
///
/// The receiver replies with a [HelloMessage], which triggers a reciprocal
/// [HelloMessage] → [StateMessage] → [DeltaMessage] exchange so that data
/// the receiver has but the sender is missing flows back.
final class PokeMessage extends ProtocolMessage {
  const PokeMessage();
}

/// Opens a connection: carries the sender's supported wire versions and its
/// device public key.
///
/// Both sides send one on connect and reply once to the first they receive.
/// The receiver negotiates a common version (see `negotiate`); no overlap
/// makes the peer incompatible — observable as a `PeerIncompatible` event —
/// and nothing further is exchanged with it.
final class HandshakeMessage extends ProtocolMessage {
  const HandshakeMessage({
    required this.node,
    required this.versions,
    this.devicePublicKey,
  });

  /// [NodeId] of the sending instance.
  final String node;

  /// The wire versions the sender speaks (see `supportedWireVersions`).
  final List<int> versions;

  /// The sender's encoded `DevicePublicKey`, when it has an identity
  /// configured. Carried for upcoming signed-handshake work; absent otherwise.
  final List<int>? devicePublicKey;
}

/// Carries a random per-session nonce so both peers can derive the same
/// forward-secret ratchet root. Sent on connect (and after a group-key
/// rotation), always under the roster/control cipher — it bootstraps the
/// ratchet, so it is never itself ratcheted.
final class RatchetHelloMessage extends ProtocolMessage {
  const RatchetHelloMessage({
    required this.node,
    required this.nonce,
    required this.keyTag,
  });

  /// [NodeId] of the sending instance.
  final String node;

  /// The sender's 16-byte session nonce.
  final List<int> nonce;

  /// The non-secret tag of the group-key generation the nonce belongs to
  /// (`ratchetKeyTag`). The receiver ignores a nonce whose tag differs from
  /// its own key's, so sessions only ever pair on the same key.
  final List<int> keyTag;
}

/// Shapes decoded delta [records] into a [CrdtChangeset] ready for
/// [Collection.mergeChangeset].
///
/// The binary codec already parses each record's HLC to an [Hlc]; a string
/// (from a hand-built record in a test) is parsed here for convenience.
CrdtChangeset parseDeltaChangeset(
  String colName,
  List<Map<String, dynamic>> records,
) =>
    {
      colName: [
        for (final record in records)
          record['hlc'] is Hlc
              ? record
              : {...record, 'hlc': Hlc.parse(record['hlc'] as String)},
      ],
    };
