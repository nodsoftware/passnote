import 'package:crdt/crdt.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'dart:convert' show utf8;

import '../crdt/crdt_type.dart';
import 'query.dart';

/// CRDT record store: the persistence and merge layer beneath [Collection].
///
/// A [CrdtTable] stores a set of records, each identified by a string key and
/// carrying an opaque value, a tombstone flag (`isDeleted`), a Hybrid Logical
/// Clock (HLC) timestamp, and a [CrdtType]. At this layer every record merges
/// last-write-wins: when two peers hold different values for the same key the
/// record with the higher HLC wins on merge. The richer [CrdtType] merge rules
/// ([OrSet], [PnCounter]) are layered on top by `TypedCrdtTable`, which wraps
/// any implementation of this port — an engine only records the type and treats
/// the value as opaque.
///
/// ## Tombstones
///
/// Deleting a record never removes it from storage: [put] with
/// `isDeleted: true` soft-deletes the record by setting its tombstone flag.
/// Tombstones are included in [changeset] output so that peers receive and
/// apply deletes, not just writes. A compaction pass ([Collection.compact])
/// may physically remove tombstones that are old enough to be safe.
///
/// ## Changesets and sync
///
/// [changeset] returns a serialisable snapshot of all records (or those
/// modified after a given HLC), which is the wire format used by the sync
/// protocol. [merge] applies an incoming changeset, advancing the local HLC
/// and calling [watch] listeners when any record changes.
///
/// ## Implementor contract
///
/// - **Causality:** [merge] must advance the local canonical HLC to at least
///   the maximum HLC seen in the incoming changeset before writing any record,
///   so a local [put] that follows a merge is always causally later.
/// - **Idempotency:** merging the same changeset twice must be a no-op
///   (the HLC comparison in merge makes this automatic).
/// - **Watch:** [watch] must return a broadcast stream; missing events while
///   there are no listeners is acceptable, but no event must be emitted after
///   [merge] or [put] returns without the record being durably stored.
///
/// ## Persistence
///
/// Set [isPersistent] to `true` in implementations that own their own
/// durability (e.g. a disk-backed engine that writes synchronously on every
/// mutation). [Collection] skips its own `_restore` and `_persistDocuments`
/// steps for persistent tables, delegating lifecycle to [init] and [compact]
/// instead.
///
/// ## Async reads
///
/// Read methods ([value], [liveFields], [changeset]) are async so a
/// disk-backed engine can load data on demand without keeping every value in
/// memory. [liveKeys] is sync and returns only metadata (key + tombstone flag),
/// enabling operations such as [Collection.length] without I/O.
///
/// The default [MapCrdtTable] satisfies all of the above by delegating to the
/// `crdt` package's `MapCrdt`. Swap it for a disk-backed implementation to
/// bound memory use on large or long-lived collections.
abstract interface class CrdtTable {
  /// The identifier of this replica, as stamped into the node component of the
  /// HLCs this table generates.
  ///
  /// A persistent engine must keep it stable across restarts — the typed merge
  /// layer keys each node's counter contributions by it. The in-memory
  /// [MapCrdtTable] generates a fresh one per instance, which is fine for its
  /// tests-only lifetime. For a persistent engine, must be readable once [init]
  /// has run.
  String get nodeId;

  /// Whether this table owns its own durability.
  ///
  /// When true, [Collection] will not call [init] during startup (and will
  /// skip its internal `_persistDocuments` step after mutations).
  bool get isPersistent => false;

  /// Initializes the table from storage (called by [Collection] during
  /// startup when [isPersistent] is true).
  ///
  /// The default implementation is a no-op. Override to load an index, warm a
  /// cache, or set up internal state from the backing store. Must be called
  /// exactly once before any other method.
  Future<void> init() async {}

  /// Permanently removes tombstoned records whose wall-clock time is older
  /// than [horizon] and returns the number of reclaimed records.
  ///
  /// Defaults to throwing [UnsupportedError]. Override for engines that
  /// support in-place compaction.
  Future<int> compact(String table, {required Duration horizon}) async =>
      throw UnsupportedError(
        '$runtimeType does not support in-place compaction; '
        'use Collection.compact for a rebuild-based approach.',
      );

  /// Writes or tombstones the record identified by [table]/[key].
  ///
  /// Setting [isDeleted] to `true` tombstones the record (soft-delete); the
  /// record remains in the table and is included in changesets so peers can
  /// observe the deletion.
  ///
  /// [crdtType] is the merge rule recorded for this record. It defaults to
  /// [LwwRegister] (last-write-wins). An engine stores the tag and treats the
  /// value as opaque — the type-aware merge itself happens in `TypedCrdtTable`,
  /// above this port. An in-memory engine that cannot store the type may ignore
  /// it (typed values are self-describing); a persistent engine must record it.
  Future<void> put(
    String table,
    String key,
    Object? value, {
    bool isDeleted = false,
    CrdtType crdtType = const LwwRegister(),
  });

  /// Returns the live value for [key] in [table], or `null` if absent or
  /// tombstoned.
  Future<Object?> value(String table, String key);

  /// The stored HLC string of the record at [table]/[key] — tombstoned or
  /// live — or `null` when no record exists.
  ///
  /// Lets the sync layer tell a record that will actually change local state
  /// (incoming HLC newer) from a redelivery of something already held.
  Future<String?> recordHlc(String table, String key);

  /// Returns all live (non-tombstoned) records in [table] whose key starts
  /// with [prefix], as a flat map of key → value.
  ///
  /// Pass an empty prefix to scan the full table (used by [Collection.all]
  /// and [Collection.all]). Pass a document-id prefix (e.g.
  /// `"$id\x1F"`) to narrow the read to a single document's field records —
  /// a disk-backed adapter can use this to avoid loading the whole table.
  Future<Map<String, Object?>> liveFields(String table, String prefix);

  /// The live field rows of the given documents, grouped by document id and
  /// keyed by bare field path (the portion of the record key after the
  /// `"$docId\x1F"` separator). Existence registers are not included; a
  /// document with no live field rows is absent from the result.
  ///
  /// This is the materialisation read for point lookups and query pages: an
  /// indexed engine must serve it without scanning the whole table, and a
  /// scanning engine must serve the whole batch in one scan — never one scan
  /// per document.
  Future<Map<String, Map<String, Object?>>> docFields(
      String table, Iterable<String> docIds);

  /// All live (non-tombstoned) keys in [table] whose key starts with
  /// [prefix].
  ///
  /// Like [liveFields] but without values — returns only metadata so
  /// operations such as [Collection.length] can avoid I/O. Must be safe to
  /// call synchronously after [init].
  Set<String> liveKeys(String table, String prefix);

  /// Returns the ids of the live documents in [table] that satisfy [spec], in
  /// the spec's total order — `(order-by value, document id)` — windowed by its
  /// limit and cursor.
  ///
  /// A document is live when its existence register (the separator-free key)
  /// is live. Predicates evaluate against the *resolved* value of a field row
  /// (a counter's total, a set's membership), so a typed state stored at rest
  /// matches the same way on every engine. The comparison order across value
  /// kinds is fixed: missing/null, then numbers, then text (non-scalar values
  /// compare as their JSON encoding) — every engine must produce the same
  /// order, so keyset pages line up across engines and devices.
  Future<List<QueryRow>> queryDocIds(String table, QuerySpec spec);

  /// Prepares an index for equality lookups on [fieldPath] in [table], so a
  /// `QueryOp.equals` predicate on that path does not scan the table.
  ///
  /// Idempotent. An engine without secondary indexes (the in-memory
  /// [MapCrdtTable]) treats this as a no-op and answers queries by scanning.
  Future<void> ensureQueryIndex(String table, String fieldPath);

  /// Returns records in [table] in [CrdtChangeset] format.
  ///
  /// When [sinceHlc] is non-null, only records modified after that HLC string
  /// are returned; when [untilHlc] is non-null, only records at or before it.
  /// Both bounds are parsed and compared as HLCs, never as raw strings. Pass
  /// neither (the default) for the full table, including tombstones — required
  /// for persistence and sync; the bounded form serves range reconciliation's
  /// leaf fetches.
  Future<CrdtChangeset> changeset(
    String table, {
    String? sinceHlc,
    String? untilHlc,
  });

  /// Summarises the records of [table] whose HLC lies in the half-open range
  /// `(fromHlc, toHlc]` (a `null` bound is open): how many there are, the XOR
  /// fingerprint of their identities, and the range's lowest and highest HLCs.
  ///
  /// Tombstoned records are included — a deletion is state that must
  /// reconcile. Two replicas whose digests match over a range hold the same
  /// record versions there (see [RangeDigestBuilder] for the identity). Must
  /// stream: memory per call is O(1), not O(range).
  Future<RangeDigest> rangeDigest(String table,
      {String? fromHlc, String? toHlc});

  /// The highest HLC seen in [table] as a string, or the empty string when
  /// the table is empty.
  String maxHlc(String table);

  /// Merges a [CrdtChangeset] received from a peer or loaded from storage.
  Future<void> merge(CrdtChangeset changeset);

  /// A broadcast stream that emits whenever any record in [table] changes.
  Stream<void> watch(String table);

  /// Releases resources (a disk-backed engine closes its file). The default is
  /// a no-op. Called by [Collection.dispose].
  Future<void> close() async {}

  /// Re-encrypts the store at rest under [newKey], keeping all data.
  ///
  /// Called when the group key rotates (device revocation). In-memory engines
  /// hold no at-rest key, so the default is a no-op; a SQLCipher-backed engine
  /// runs `PRAGMA rekey`.
  Future<void> rekey(List<int> newKey) async {}

  /// Emits once if [init] found the local store unreadable and rebuilt it
  /// (from an on-disk snapshot, or empty).
  ///
  /// In-memory engines never emit. The default is an empty stream. A broadcast
  /// stream so a late subscriber is safe; [Conclave] listens on it to surface
  /// a [StoreRecovered] event and trigger a re-sync.
  Stream<CrdtRecovery> get recoveries => const Stream<CrdtRecovery>.empty();
}

/// The summary of one HLC range of a table, as [CrdtTable.rangeDigest]
/// returns it: the input to range-based set reconciliation.
class RangeDigest {
  /// Creates a digest. Engines build these via [RangeDigestBuilder].
  const RangeDigest({
    required this.count,
    required this.fingerprint,
    this.minHlc,
    this.maxHlc,
  });

  /// An empty range: zero records, the zero fingerprint.
  static final RangeDigest empty = RangeDigest(
    count: 0,
    fingerprint: List<int>.unmodifiable(List<int>.filled(16, 0)),
  );

  /// Number of records in the range.
  final int count;

  /// XOR of every record's identity hash ([RangeDigestBuilder.add]).
  /// 16 bytes; all zero for an empty range.
  final List<int> fingerprint;

  /// The lowest record HLC in the range, or `null` when empty.
  final String? minHlc;

  /// The highest record HLC in the range, or `null` when empty.
  final String? maxHlc;

  /// Whether [other] summarises the same record set (same count and
  /// fingerprint).
  bool matches(RangeDigest other) {
    if (count != other.count) return false;
    for (var i = 0; i < fingerprint.length; i++) {
      if (fingerprint[i] != other.fingerprint[i]) return false;
    }
    return true;
  }
}

/// Streams records into a [RangeDigest]: an engine calls [add] once per
/// record in the range (any order) and takes [build].
///
/// A record's identity is its `(key, hlc)` pair — the HLC changes whenever
/// the value does, so equal pairs mean equal record versions. The fingerprint
/// is the XOR of the first 16 bytes of `SHA-256(key ‖ 0x00 ‖ hlc)`:
/// order-independent, so ranges can be summarised in one streaming pass and
/// split without re-hashing.
class RangeDigestBuilder {
  final List<int> _xor = List<int>.filled(16, 0);
  int _count = 0;
  Hlc? _min;
  Hlc? _max;

  /// Folds one record into the digest.
  void add(String key, Hlc hlc) {
    final hash = sha256.convert(
        [...utf8.encode(key), 0x00, ...utf8.encode(hlc.toString())]).bytes;
    for (var i = 0; i < 16; i++) {
      _xor[i] ^= hash[i];
    }
    _count++;
    if (_min == null || hlc < _min!) _min = hlc;
    if (_max == null || hlc > _max!) _max = hlc;
  }

  /// The accumulated digest.
  RangeDigest build() => RangeDigest(
        count: _count,
        fingerprint: List<int>.unmodifiable(_xor),
        minHlc: _min?.toString(),
        maxHlc: _max?.toString(),
      );
}

/// How a [CrdtTable] rebuilt its local store after finding it unreadable.
enum CrdtRecoverySource {
  /// The most recent on-disk snapshot was restored. Records written since that
  /// snapshot are gone but return on the next sync with a peer.
  snapshot,

  /// No usable snapshot existed; the store was reset to empty and must
  /// re-sync from a peer to get its data back.
  reset,
}

/// What [CrdtTable.recoveries] reports when [CrdtTable.init] rebuilds an
/// unreadable local store.
class CrdtRecovery {
  /// Creates the report.
  const CrdtRecovery({required this.source, required this.quarantinePath});

  /// Whether the store was restored from a snapshot or reset to empty.
  final CrdtRecoverySource source;

  /// Where the unreadable file was moved, kept for inspection.
  final String quarantinePath;
}

/// A [CrdtTable] that keeps periodic on-disk snapshots as a peerless recovery
/// fallback.
///
/// [Conclave] sets [snapshotInterval] from [ConclaveConfig.snapshotInterval]
/// before it calls [CrdtTable.init].
abstract interface class SnapshotCapable {
  /// How often to write a snapshot of the store. [Duration.zero] disables
  /// snapshots. Set before [CrdtTable.init]; later changes may not take effect.
  set snapshotInterval(Duration value);
}
