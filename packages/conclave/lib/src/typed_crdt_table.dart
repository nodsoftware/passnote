import 'package:crdt/crdt.dart';

import 'crdt/crdt_type.dart';
import 'crdt/lww_register.dart';
import 'crdt/or_set.dart';
import 'crdt/pn_counter.dart';
import 'id.dart';
import 'ports/crdt_table.dart';
import 'ports/query.dart';

/// The layer that gives [OrSet] and [PnCounter] fields their merge semantics,
/// wrapping any [CrdtTable].
///
/// The inner engine stays a plain last-write-wins record store; this decorator
/// keeps a typed field's *CRDT state* in the record value and translates at the
/// boundary:
///
/// - **Writes.** [put] with an [OrSet] type takes the desired membership (a
///   list) and folds it into the stored state — fresh unique tags for added
///   elements, tombstones for the visible tags of removed ones. [put] with a
///   [PnCounter] type only seeds a new counter (from a starting number);
///   changing an existing counter's value through [put] throws [ArgumentError]
///   — use [increment], which folds a signed delta into this node's
///   sub-counter.
/// - **Reads.** [value] and [liveFields] resolve a typed state back to its
///   logical value: the live elements for a set, `sum(p) - sum(n)` for a
///   counter. Callers never see the internal state.
/// - **Merges.** [merge] intercepts an incoming typed record when a local one
///   exists and combines the two *states* (union of adds and tombstones for a
///   set, element-wise maximum of the sub-counters for a counter) instead of
///   letting the higher HLC win. A merge that adds nothing writes nothing, so
///   converged replicas go quiescent.
///
/// Typed states are self-describing — they carry their type in a reserved
/// `__t` key — so they survive an engine or a peer that does not store the
/// `crdt_type` tag, and [merge] can dispatch without a side table. A document
/// value that is itself a map with a `__t` key holding `'or_set'` or
/// `'pn_counter'` would be misread as a typed state; treat `__t` as a reserved
/// field name.
///
/// [LwwRegister] records (the default) pass through untouched, so an untyped
/// collection behaves exactly as it would on the bare engine.
///
/// [Collection] wraps its engine in this decorator automatically; it is public
/// on the advanced library for engine authors and tests.
final class TypedCrdtTable implements CrdtTable {
  /// Wraps [inner]. Wrapping an already wrapped table is redundant but
  /// harmless — every layer applies the same translation to already canonical
  /// states.
  TypedCrdtTable(CrdtTable inner) : _inner = inner;

  final CrdtTable _inner;

  /// The wrapped engine, for callers that need engine-specific state (tests).
  CrdtTable get inner => _inner;

  @override
  String get nodeId => _inner.nodeId;

  @override
  bool get isPersistent => _inner.isPersistent;

  @override
  Future<void> init() => _inner.init();

  @override
  Future<int> compact(String table, {required Duration horizon}) =>
      _inner.compact(table, horizon: horizon);

  @override
  Future<void> put(
    String table,
    String key,
    Object? value, {
    bool isDeleted = false,
    CrdtType crdtType = const LwwRegister(),
  }) async {
    if (isDeleted) {
      return _inner.put(table, key, value, isDeleted: true, crdtType: crdtType);
    }
    switch (crdtType) {
      case LwwRegister():
        return _inner.put(table, key, value, crdtType: crdtType);
      case OrSet():
        if (value is! List) {
          throw ArgumentError.value(
            value,
            'value',
            'An OrSet field takes its desired membership as a List',
          );
        }
        final current = await _inner.value(table, key);
        final next = orApplyDesired(current, value, () => '$nodeId-${newId()}');
        if (current != null && crdtValueEquals(next, current)) return;
        return _inner.put(table, key, next, crdtType: crdtType);
      case PnCounter():
        if (value is! num) {
          throw ArgumentError.value(
            value,
            'value',
            'A PnCounter field takes a starting number',
          );
        }
        final current = await _inner.value(table, key);
        if (current == null) {
          return _inner.put(table, key, pnApplyDelta(null, nodeId, value),
              crdtType: crdtType);
        }
        if (value == pnResolve(current)) return; // Unchanged: quiescent.
        throw ArgumentError(
          'A PnCounter field cannot be set to a new value; its value is the '
          'sum of every device\'s deltas. Use increment() instead.',
        );
    }
  }

  /// Folds a signed [by] into this node's sub-counter of the [PnCounter]
  /// record at [table]/[key], creating the counter (at `0 + by`) if the record
  /// does not exist yet.
  ///
  /// Throws [ArgumentError] if the record exists but is not a counter.
  Future<void> increment(String table, String key, num by) async {
    final current = await _inner.value(table, key);
    if (current != null && storedCrdtTag(current) != pnCounterTag) {
      throw ArgumentError(
        'Field "$key" is not a PnCounter; only counter fields can be '
        'incremented.',
      );
    }
    if (current != null && by == 0) return; // Nothing to fold in.
    await _inner.put(table, key, pnApplyDelta(current, nodeId, by),
        crdtType: const PnCounter());
  }

  @override
  Future<Object?> value(String table, String key) async =>
      _resolve(await _inner.value(table, key));

  @override
  Future<String?> recordHlc(String table, String key) =>
      _inner.recordHlc(table, key);

  @override
  Future<Map<String, Object?>> liveFields(String table, String prefix) async {
    final raw = await _inner.liveFields(table, prefix);
    return {for (final e in raw.entries) e.key: _resolve(e.value)};
  }

  @override
  Future<Map<String, Map<String, Object?>>> docFields(
      String table, Iterable<String> docIds) async {
    final raw = await _inner.docFields(table, docIds);
    return {
      for (final doc in raw.entries)
        doc.key: {
          for (final f in doc.value.entries) f.key: _resolve(f.value),
        },
    };
  }

  @override
  Set<String> liveKeys(String table, String prefix) =>
      _inner.liveKeys(table, prefix);

  @override
  Future<List<QueryRow>> queryDocIds(String table, QuerySpec spec) =>
      // Engines evaluate predicates over resolved values themselves (a SQL
      // engine cannot round-trip rows through Dart), so nothing to translate.
      _inner.queryDocIds(table, spec);

  @override
  Future<void> ensureQueryIndex(String table, String fieldPath) =>
      _inner.ensureQueryIndex(table, fieldPath);

  @override
  Future<CrdtChangeset> changeset(
    String table, {
    String? sinceHlc,
    String? untilHlc,
  }) =>
      // Raw states travel on the wire: the receiving side needs the full state
      // (tags, tombstones, sub-counters) to merge, not the resolved value.
      _inner.changeset(table, sinceHlc: sinceHlc, untilHlc: untilHlc);

  @override
  Future<RangeDigest> rangeDigest(
    String table, {
    String? fromHlc,
    String? toHlc,
  }) =>
      _inner.rangeDigest(table, fromHlc: fromHlc, toHlc: toHlc);

  @override
  String maxHlc(String table) => _inner.maxHlc(table);

  @override
  Future<void> merge(CrdtChangeset changeset) async {
    // Typed records that must be combined with local state, held back from the
    // inner (last-write-wins) merge and written as fresh local records after
    // it. States are read before the inner merge runs; the sets are disjoint
    // by key, so ordering does not matter.
    final rewrites = <({String table, String key, Object? merged})>[];
    final passthrough = <String, List<CrdtRecord>>{};

    for (final entry in changeset.entries) {
      final table = entry.key;
      final kept = <CrdtRecord>[];
      for (final record in entry.value) {
        final value = record['value'];
        final tag = storedCrdtTag(value);
        final incoming = switch (tag) {
          orSetTag || pnCounterTag when record['is_deleted'] != true => value,
          _ => null,
        };
        if (incoming == null) {
          kept.add(record);
          continue;
        }
        final key = record['key'] as String;
        final local = await _inner.value(table, key);
        if (local == null) {
          // No live local state: apply as a plain record, keeping the
          // incoming HLC so a repeated merge stays a no-op.
          kept.add(record);
          continue;
        }
        final merged = tag == orSetTag
            ? orMerge(local, incoming)
            : pnMerge(local, incoming);
        if (crdtValueEquals(merged, local)) continue; // Nothing new.
        rewrites.add((table: table, key: key, merged: merged));
      }
      if (kept.isNotEmpty) passthrough[table] = kept;
    }

    if (passthrough.isNotEmpty) await _inner.merge(passthrough);
    for (final rewrite in rewrites) {
      await _inner.put(
        rewrite.table,
        rewrite.key,
        rewrite.merged,
        crdtType: crdtTypeFromTag(storedCrdtTag(rewrite.merged)),
      );
    }
  }

  @override
  Stream<void> watch(String table) => _inner.watch(table);

  @override
  Future<void> close() => _inner.close();

  @override
  Future<void> rekey(List<int> newKey) => _inner.rekey(newKey);

  @override
  Stream<CrdtRecovery> get recoveries => _inner.recoveries;

  /// Translates a stored value to its logical one: live elements for a set
  /// state, the summed total for a counter state, anything else unchanged.
  static Object? _resolve(Object? stored) => switch (storedCrdtTag(stored)) {
        orSetTag => orResolve(stored),
        pnCounterTag => pnResolve(stored),
        _ => stored,
      };
}
