import 'dart:convert';

import '../crdt/crdt_type.dart';
import '../crdt/or_set.dart';
import '../crdt/pn_counter.dart';
import '../ports/query.dart';

/// Evaluates a [QuerySpec] by scanning a table's live rows in Dart.
///
/// This is the query path for engines without secondary indexes (the in-memory
/// `MapCrdtTable`). Its semantics — predicate matching, the comparison order
/// across value kinds, keyset windowing — deliberately mirror the SQL the
/// SQLite engine generates, so a query returns identical pages on either
/// engine: missing/null sorts first, then numbers, then text, with non-scalar
/// values comparing as their JSON encoding and booleans comparing as 0/1.
///
/// [liveRows] is the table's full live map (key → raw stored value), with
/// document ids and field paths joined by [separator] and existence registers
/// stored under the bare document id.
List<QueryRow> evaluateQueryByScan({
  required Map<String, Object?> liveRows,
  required QuerySpec spec,
  required String separator,
}) {
  // Group live rows into alive doc ids and per-document raw field maps.
  final alive = <String>{};
  final fields = <String, Map<String, Object?>>{};
  for (final entry in liveRows.entries) {
    final sep = entry.key.indexOf(separator);
    if (sep < 0) {
      alive.add(entry.key);
    } else {
      final id = entry.key.substring(0, sep);
      (fields[id] ??= {})[entry.key.substring(sep + 1)] = entry.value;
    }
  }

  final rows = <QueryRow>[];
  docs:
  for (final id in alive) {
    final doc = fields[id] ?? const {};
    for (final p in spec.predicates) {
      if (!_matches(doc[p.path], doc.containsKey(p.path), p)) continue docs;
    }
    final orderPath = spec.orderByPath;
    rows.add(QueryRow(
      docId: id,
      orderValue: orderPath == null
          ? null
          : _resolveComparable(doc[orderPath], spec.orderByType),
    ));
  }

  final sign = spec.descending ? -1 : 1;
  int compareToCursor(QueryRow r, Object? orderValue, String docId) {
    final byOrder = compareQueryValues(r.orderValue, orderValue);
    return sign * (byOrder != 0 ? byOrder : compareCodePoints(r.docId, docId));
  }

  rows.sort((a, b) => compareToCursor(a, b.orderValue, b.docId));

  var windowed = rows;
  final after = spec.after;
  if (after != null) {
    windowed = [
      for (final r in windowed)
        if (compareToCursor(r, after.orderValue, after.docId) > 0) r,
    ];
  }
  final limit = spec.limit;
  if (limit != null && windowed.length > limit) {
    windowed = windowed.sublist(0, limit);
  }
  return windowed;
}

/// Whether a field's raw stored value ([raw], present when [exists]) satisfies
/// predicate [p].
bool _matches(Object? raw, bool exists, QueryPredicate p) {
  if (!exists) return false; // Every operator requires the field row.
  switch (p.op) {
    case QueryOp.contains:
      final target = _normalise(p.value);
      return orResolve(raw).any((e) => _equal(_normalise(e), target));
    case QueryOp.equals:
      return _equal(_resolveComparable(raw, p.type), _normalise(p.value));
    case QueryOp.isIn:
      final field = _resolveComparable(raw, p.type);
      return (p.value as List)
          .any((candidate) => _equal(field, _normalise(candidate)));
    case QueryOp.greaterThan:
      // SQL comparison with NULL is never true.
      final field = _resolveComparable(raw, p.type);
      if (field == null) return false;
      return compareQueryValues(field, _normalise(p.value)) > 0;
    case QueryOp.lessThan:
      final field = _resolveComparable(raw, p.type);
      if (field == null) return false;
      return compareQueryValues(field, _normalise(p.value)) < 0;
  }
}

/// Equality in the shared comparison domain. Two nulls are equal (a stored
/// JSON null matches `isEqualTo: null`, like SQL `IS`); values of different
/// kinds never are.
bool _equal(Object? a, Object? b) =>
    _rank(a) == _rank(b) && compareQueryValues(a, b) == 0;

/// The resolved, comparable form of a stored field value: a counter state
/// becomes its total, anything else its plain value normalised by
/// [_normalise]. (Set membership never reaches here; `contains` resolves the
/// state itself.)
Object? _resolveComparable(Object? raw, CrdtType type) => switch (type) {
      PnCounter() => pnResolve(raw),
      _ => _normalise(raw),
    };

/// Normalises a plain value into the comparison domain shared with SQLite's
/// `json_extract`: booleans become 0/1, non-scalar values become their JSON
/// text, numbers and strings pass through.
Object? _normalise(Object? value) => switch (value) {
      null => null,
      final bool b => b ? 1 : 0,
      final num n => n,
      final String s => s,
      _ => jsonEncode(value),
    };

/// Total order over normalised values, mirroring SQLite's storage-class order:
/// null, then numeric, then text.
int compareQueryValues(Object? a, Object? b) {
  final byRank = _rank(a).compareTo(_rank(b));
  if (byRank != 0) return byRank;
  if (a is num && b is num) return a.compareTo(b);
  if (a is String && b is String) return compareCodePoints(a, b);
  return 0; // Both null.
}

/// Orders [a] and [b] by Unicode code point, as SQLite orders UTF-8 text.
///
/// [String.compareTo] orders by UTF-16 code unit instead, which puts a
/// character above U+FFFF (stored as a surrogate pair, 0xD800-0xDFFF) before
/// one in U+E000-U+FFFF; the two engines would then page differently.
int compareCodePoints(String a, String b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    final x = a.codeUnitAt(i);
    final y = b.codeUnitAt(i);
    if (x == y) continue;
    // Surrogates (0xD800-0xDFFF) are above every BMP code point below them
    // and below every one above them (0xE000-0xFFFF).
    return _codePointRank(x).compareTo(_codePointRank(y));
  }
  return a.length.compareTo(b.length);
}

int _codePointRank(int unit) => unit >= 0xD800 && unit <= 0xDFFF
    ? unit + 0x2000
    : (unit >= 0xE000 ? unit - 0x800 : unit);

int _rank(Object? v) => switch (v) { null => 0, num _ => 1, _ => 2 };
