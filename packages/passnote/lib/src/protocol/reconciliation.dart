import 'package:crdt/crdt.dart';

import '../ports/crdt_table.dart';

/// The reconciliation capability advertised in the handshake. A peer that
/// negotiated it runs anti-entropy as a range-fingerprint exchange; anyone
/// else gets the full hello/state exchange.
const String reconCapability = 'recon1';

/// One range probe: "here is what I hold in `(from, to]` — do you match?"
class RangeProbe {
  /// Creates a probe. `null` bounds are open ends.
  const RangeProbe({
    required this.from,
    required this.to,
    required this.depth,
    required this.count,
    required this.fingerprint,
  });

  /// Exclusive lower HLC bound, or `null` for the start of time.
  final String? from;

  /// Inclusive upper HLC bound, or `null` for the end of time.
  final String? to;

  /// Split depth so far; the recursion is capped at [Reconciler.maxDepth].
  final int depth;

  /// The sender's record count in the range.
  final int count;

  /// The sender's 16-byte XOR fingerprint of the range.
  final List<int> fingerprint;
}

/// A half-open HLC range whose records the sender wants shipped to it.
class RangeRequest {
  /// Creates a request.
  const RangeRequest({required this.from, required this.to});

  /// Exclusive lower HLC bound, or `null` for the start of time.
  final String? from;

  /// Inclusive upper HLC bound, or `null` for the end of time.
  final String? to;
}

/// What one side does in response to a reconcile message: probe back the
/// still-unresolved subranges, ship its own records for the leaf ranges, and
/// ask for the peer's records there.
class ReconcilePlan {
  /// Creates an empty plan; [Reconciler.handleProbes] fills it.
  ReconcilePlan();

  /// Subranges to probe back at the next depth.
  final List<RangeProbe> replyProbes = [];

  /// Ranges whose records the peer should send us.
  final List<RangeRequest> requestRanges = [];

  /// Ranges whose local records we should send the peer.
  final List<RangeRequest> shipRanges = [];

  /// Whether nothing needs to happen (the probed ranges all matched).
  bool get isEmpty =>
      replyProbes.isEmpty && requestRanges.isEmpty && shipRanges.isEmpty;
}

/// The range-reconciliation state machine, pure over an injected digest
/// function so it unit-tests without an engine.
///
/// The exchange: the initiator probes a whole collection as one range. For
/// each probe, the responder compares fingerprints — a match ends that range;
/// a small (or depth-capped) mismatch becomes a leaf, where the responder
/// ships its records and asks for the peer's; anything else splits at the
/// HLC-time midpoint of the responder's own data and probes back one level
/// deeper. Every message handles a whole level, so a difference is found in
/// O(log n) round trips, and [maxProbesPerReply] keeps a fully divergent pair
/// from exploding the probe count — overflow ranges leaf-ship instead.
class Reconciler {
  /// Creates a reconciler over [digest] (usually `Collection.rangeDigest`).
  Reconciler({
    required this.digest,
    this.leafCount = 32,
    this.maxDepth = 24,
    this.maxProbesPerReply = 64,
  });

  /// Summarises the local records in a half-open HLC range.
  final Future<RangeDigest> Function(String? fromHlc, String? toHlc) digest;

  /// Ranges at or below this many records (on either side) stop splitting and
  /// ship records.
  final int leafCount;

  /// Split depth cap: beyond it a range ships records no matter its size.
  final int maxDepth;

  /// Cap on reply probes per message; overflow ranges leaf-ship instead.
  final int maxProbesPerReply;

  /// The opening probe covering everything this side holds.
  Future<RangeProbe?> initialProbe() async {
    final full = await digest(null, null);
    return RangeProbe(
      from: null,
      to: null,
      depth: 0,
      count: full.count,
      fingerprint: full.fingerprint,
    );
  }

  /// Handles the peer's [probes] and produces this side's plan.
  Future<ReconcilePlan> handleProbes(List<RangeProbe> probes) async {
    final plan = ReconcilePlan();
    for (final probe in probes) {
      final local = await digest(probe.from, probe.to);
      if (local.matches(_asDigest(probe))) continue;

      final leaf = probe.count <= leafCount ||
          local.count <= leafCount ||
          probe.depth >= maxDepth ||
          plan.replyProbes.length + 2 > maxProbesPerReply;
      final mid = leaf ? null : _midpoint(probe, local);
      if (mid == null) {
        // A leaf: both sides exchange the range's records; the CRDT merge
        // dedups anything both already had.
        plan.shipRanges.add(RangeRequest(from: probe.from, to: probe.to));
        plan.requestRanges.add(RangeRequest(from: probe.from, to: probe.to));
        continue;
      }

      final low = await digest(probe.from, mid);
      final high = await digest(mid, probe.to);
      plan.replyProbes
        ..add(RangeProbe(
          from: probe.from,
          to: mid,
          depth: probe.depth + 1,
          count: low.count,
          fingerprint: low.fingerprint,
        ))
        ..add(RangeProbe(
          from: mid,
          to: probe.to,
          depth: probe.depth + 1,
          count: high.count,
          fingerprint: high.fingerprint,
        ));
    }
    return plan;
  }

  static RangeDigest _asDigest(RangeProbe probe) =>
      RangeDigest(count: probe.count, fingerprint: probe.fingerprint);

  /// A split point strictly inside the probed range, bisecting the wall-clock
  /// span of the local data — or `null` when the range cannot be split (all
  /// local records share one instant), which makes it a leaf.
  static String? _midpoint(RangeProbe probe, RangeDigest local) {
    final minHlc = local.minHlc;
    final maxHlc = local.maxHlc;
    if (minHlc == null || maxHlc == null) return null;
    final min = Hlc.parse(minHlc);
    final max = Hlc.parse(maxHlc);
    final minUs = min.dateTime.microsecondsSinceEpoch;
    final maxUs = max.dateTime.microsecondsSinceEpoch;
    if (maxUs <= minUs) return null;
    final mid = Hlc(
      DateTime.fromMicrosecondsSinceEpoch(minUs + (maxUs - minUs) ~/ 2,
          isUtc: true),
      0,
      max.nodeId,
    );
    // Degenerate splits (everything on one side) leaf out instead.
    if (mid <= min || mid >= max) return null;
    return mid.toString();
  }
}
