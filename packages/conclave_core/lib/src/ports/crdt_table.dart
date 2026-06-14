import 'package:crdt/crdt.dart';

/// CRDT record store: the persistence and merge layer beneath [Collection].
///
/// A [CrdtTable] stores a set of records, each identified by a string key and
/// carrying an opaque value, a tombstone flag (`isDeleted`), and a Hybrid
/// Logical Clock (HLC) timestamp. The HLC ordering is the sole source of
/// truth for conflict resolution: when two peers hold different values for the
/// same key, the record with the higher HLC wins on merge — last-write-wins.
///
/// ## Tombstones
///
/// Deleting a record never removes it from storage: [put] with
/// `isDeleted: true` soft-deletes the record by setting its tombstone flag.
/// Tombstones are included in [changeset] output so that peers receive and
/// apply deletes, not just writes. A compaction pass (see [Collection.compact],
/// Task 02) may physically remove tombstones that are old enough to be safe.
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
/// The default [MapCrdtTable] satisfies all of the above by delegating to the
/// `crdt` package's `MapCrdt`. Swap it for a disk-backed implementation to
/// bound memory use on large or long-lived collections.
abstract interface class CrdtTable {
  /// Writes or tombstones the record identified by [table]/[key].
  ///
  /// Setting [isDeleted] to `true` tombstones the record (soft-delete); the
  /// record remains in the table and is included in changesets so peers can
  /// observe the deletion.
  Future<void> put(
    String table,
    String key,
    Object? value, {
    bool isDeleted = false,
  });

  /// Returns the live value for [key] in [table], or `null` if absent or
  /// tombstoned.
  Object? value(String table, String key);

  /// Returns all live (non-tombstoned) records in [table] whose key starts
  /// with [prefix], as a flat map of key → value.
  ///
  /// Pass an empty prefix to scan the full table (used by [Collection.all]
  /// and [Collection.length]). Pass a document-id prefix (e.g.
  /// `"$id\x1F"`) to narrow the read to a single document's field records —
  /// a disk-backed adapter can use this to avoid loading the whole table.
  Map<String, Object?> liveFields(String table, String prefix);

  /// Returns records in [table] in [CrdtChangeset] format.
  ///
  /// When [sinceHlc] is non-null, only records modified after that HLC string
  /// are returned. Pass `null` (the default) for the full table, including
  /// tombstones — required for persistence and sync.
  CrdtChangeset changeset(String table, {String? sinceHlc});

  /// The highest HLC seen in [table] as a string, or the empty string when
  /// the table is empty.
  String maxHlc(String table);

  /// Merges a [CrdtChangeset] received from a peer or loaded from storage.
  Future<void> merge(CrdtChangeset changeset);

  /// A broadcast stream that emits whenever any record in [table] changes.
  Stream<void> watch(String table);
}
