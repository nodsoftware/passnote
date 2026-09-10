import '../crdt/crdt_type.dart';

/// How a [QueryPredicate] compares a field against its value.
enum QueryOp {
  /// The field equals the value (scalars only).
  equals,

  /// The field is greater than the value.
  greaterThan,

  /// The field is less than the value.
  lessThan,

  /// The field equals one of the values in a list.
  isIn,

  /// The field is an [OrSet] that contains the value as an element.
  contains,
}

/// One compiled `where` clause of a collection query: the field [path] it
/// tests, the [op], the [value] to compare against, and the [type] the
/// collection's merge strategy assigns to that path (which selects how the
/// engine reads the stored field — a plain value, a counter total, or set
/// membership).
class QueryPredicate {
  /// Creates a predicate. Validation happens in the query builder; an engine
  /// may assume the combination of [op] and [type] is legal.
  const QueryPredicate({
    required this.path,
    required this.op,
    required this.value,
    required this.type,
  });

  /// The flattened field path this predicate tests.
  final String path;

  /// The comparison to perform.
  final QueryOp op;

  /// The value to compare against. A scalar (`num`, `String`, `bool`, `null`),
  /// or a `List` of scalars for [QueryOp.isIn].
  final Object? value;

  /// The [CrdtType] of the field at [path].
  final CrdtType type;
}

/// A compiled collection query, ready for a `CrdtTable` to execute: the
/// conjunction of [predicates], an optional order, and a keyset page window.
class QuerySpec {
  /// Creates a spec. Built by `CollectionQuery`; validation happens there.
  const QuerySpec({
    required this.predicates,
    this.orderByPath,
    this.orderByType = const LwwRegister(),
    this.descending = false,
    this.limit,
    this.after,
  });

  /// The `where` clauses, combined with AND.
  final List<QueryPredicate> predicates;

  /// The field path to order by, or `null` to order by document id alone.
  /// Documents that lack the field sort together, before every non-null value
  /// (after them when [descending]).
  final String? orderByPath;

  /// The [CrdtType] of the field at [orderByPath].
  final CrdtType orderByType;

  /// Whether the order is reversed. The document-id tiebreak reverses with it,
  /// so pages stay disjoint in either direction.
  final bool descending;

  /// The maximum number of documents to return, or `null` for all.
  final int? limit;

  /// Resume after this position (exclusive) in the query's total order:
  /// keyset pagination. `null` starts from the beginning.
  final QueryCursor? after;
}

/// A position in a query's total order — the sort key of the last row of a
/// page. Opaque to callers: obtain one from a returned page and feed it back
/// to the same query to fetch the next page.
///
/// The total order is `(order-by value, document id)`, so a cursor stays valid
/// across a reopen and points at the same boundary on every converged device.
class QueryCursor {
  /// Creates a cursor. Engines and the query builder construct these; treat
  /// them as opaque elsewhere.
  const QueryCursor({required this.orderValue, required this.docId});

  /// The resolved order-by value of the row, in the engine's comparison form
  /// (`null`, a number, or text). `null` when the query has no `orderBy` or
  /// the document lacks the field.
  final Object? orderValue;

  /// The row's document id, the tiebreak component of the sort key.
  final String docId;
}

/// One row of a query result at the engine level: a matching document id and
/// its resolved order-by value (for building the next [QueryCursor]).
class QueryRow {
  /// Creates a result row.
  const QueryRow({required this.docId, required this.orderValue});

  /// The matching document's id.
  final String docId;

  /// The document's resolved order-by value, `null` when the query has no
  /// `orderBy` or the document lacks the field.
  final Object? orderValue;
}
