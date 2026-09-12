import 'lww_register.dart';

/// State and merge rules for a [PnCounter] field — a positive/negative counter
/// whose value is the sum of every replica's signed contributions, so
/// concurrent increments on different devices all count.
///
/// The stored representation is a pair of per-node sub-counters:
///
/// ```json
/// {"__t": "pn_counter", "p": {"<node>": 3}, "n": {"<node>": 1}}
/// ```
///
/// The value is `sum(p) - sum(n)`. Each node only ever raises its own entry
/// (increments raise `p[node]`, decrements raise `n[node]`), so a merge is the
/// element-wise maximum of both maps — commutative, associative, idempotent.

/// The `crdt_type` tag for a PN-Counter, persisted on the row and on the wire.
const String pnCounterTag = 'pn_counter';

/// An empty counter state (value 0).
Map<String, Object?> pnEmpty() => {
      crdtTypeKey: pnCounterTag,
      'p': <String, Object?>{},
      'n': <String, Object?>{},
    };

/// The logical value of [state]: `sum(p) - sum(n)`. A value that is not a
/// PN-Counter state resolves to `0`.
num pnResolve(Object? state) {
  final s = _normalise(state);
  num total = 0;
  for (final v in (s['p'] as Map).values) {
    total += v as num;
  }
  for (final v in (s['n'] as Map).values) {
    total -= v as num;
  }
  return total;
}

/// Returns [state] with [by] folded into [node]'s contribution: a positive
/// [by] raises `p[node]`, a negative [by] raises `n[node]` by its magnitude.
Map<String, Object?> pnApplyDelta(Object? state, String node, num by) {
  final s = _normalise(state);
  if (by == 0) return s;
  final side = by > 0 ? 'p' : 'n';
  final magnitude = by.abs();
  final counts = Map<String, Object?>.from(s[side] as Map);
  counts[node] = ((counts[node] as num?) ?? 0) + magnitude;
  s[side] = counts;
  return s;
}

/// Merges two counter states by taking the element-wise maximum of their `p`
/// and `n` maps.
Map<String, Object?> pnMerge(Object? a, Object? b) {
  final sa = _normalise(a);
  final sb = _normalise(b);
  return {
    crdtTypeKey: pnCounterTag,
    'p': _maxMerge(sa['p'] as Map, sb['p'] as Map),
    'n': _maxMerge(sa['n'] as Map, sb['n'] as Map),
  };
}

/// Coerces [state] into a well-formed counter state. Fail-safe on the whole
/// shape AND on every inner value: a state that is not a counter degrades to
/// empty, a `p`/`n` that is not a map degrades to empty, and an entry whose
/// key is not a `String` or whose count is not a `num` is dropped (absent is
/// 0). The value reaches this code from a synced peer, so it must never be
/// trusted enough to throw on — a poisoned row would otherwise make every
/// read of its collection fail.
Map<String, Object?> _normalise(Object? state) {
  if (state is! Map || state[crdtTypeKey] != pnCounterTag) return pnEmpty();
  return {
    crdtTypeKey: pnCounterTag,
    'p': _counts(state['p']),
    'n': _counts(state['n']),
  };
}

Map<String, Object?> _counts(Object? side) => {
      if (side is Map)
        for (final entry in side.entries)
          if (entry.key is String && entry.value is num)
            entry.key as String: entry.value,
    };

Map<String, Object?> _maxMerge(Map a, Map b) {
  final out = <String, Object?>{};
  for (final key in {...a.keys, ...b.keys}) {
    final av = (a[key] as num?) ?? 0;
    final bv = (b[key] as num?) ?? 0;
    out[key as String] = av > bv ? av : bv;
  }
  return out;
}
