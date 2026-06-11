import 'dart:convert';

import 'package:crdt/crdt.dart';

/// Wire protocol version tag included in every frame.
const int _wireVersion = 1;

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

// ---------------------------------------------------------------------------
// Serialisation helpers

/// Encodes a [ProtocolMessage] to a JSON byte payload.
List<int> encodeMessage(ProtocolMessage msg) {
  final json = switch (msg) {
    HelloMessage(:final node) => {
        'v': _wireVersion,
        'type': 'hello',
        'node': node,
      },
    StateMessage(:final cols) => {
        'v': _wireVersion,
        'type': 'state',
        'cols': cols,
      },
    DeltaMessage(:final col, :final records) => {
        'v': _wireVersion,
        'type': 'delta',
        'col': col,
        'records': records.map(_encodeRecord).toList(),
      },
  };
  return utf8.encode(jsonEncode(json));
}

/// Decodes a JSON byte payload into a [ProtocolMessage], or returns `null` for
/// unknown or malformed payloads (forward-compatibility).
ProtocolMessage? decodeMessage(List<int> bytes) {
  final Map<String, dynamic> json;
  try {
    json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }

  return switch (json['type'] as String?) {
    'hello' => HelloMessage(node: json['node'] as String),
    'state' => StateMessage(
        cols: (json['cols'] as Map<String, dynamic>).cast<String, String>(),
      ),
    'delta' => DeltaMessage(
        col: json['col'] as String,
        records: (json['records'] as List).cast<Map<String, dynamic>>(),
      ),
    _ => null,
  };
}

/// Converts [Hlc] objects to strings for wire transport.
Map<String, dynamic> _encodeRecord(Map<String, Object?> record) => {
      ...record,
      'hlc': (record['hlc'] as Hlc).toString(),
    };

/// Parses the HLC strings in [records] back to [Hlc] objects, returning a
/// [CrdtChangeset] ready for [Collection.mergeChangeset].
CrdtChangeset parseDeltaChangeset(
  String colName,
  List<Map<String, dynamic>> records,
) =>
    parseCrdtChangeset({colName: records});
