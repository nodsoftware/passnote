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

/// Carries a random per-session nonce so both peers can derive the same
/// forward-secret ratchet root. Sent on connect (and after a group-key
/// rotation), always under the roster/control cipher — it bootstraps the
/// ratchet, so it is never itself ratcheted.
final class RatchetHelloMessage extends ProtocolMessage {
  const RatchetHelloMessage({required this.node, required this.nonce});

  /// [NodeId] of the sending instance.
  final String node;

  /// The sender's 16-byte session nonce.
  final List<int> nonce;
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
