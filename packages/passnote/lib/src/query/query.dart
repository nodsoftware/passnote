part of '../collection.dart';

/// An immutable, typed query over a [Collection], built by chaining [where],
/// [orderBy], [limit], and [startAfter], and executed with [get] or [page].
///
/// Every clause validates at build time against the collection's
/// [MergeStrategy]: the operators must fit the field's [CrdtType] (`contains`
/// needs an [OrSet], comparisons need an orderable field), so a misdirected
/// query throws [ArgumentError] instead of silently returning nothing.
///
/// Execution runs in the storage engine — on the SQLite engine as SQL, using
/// the indexes declared via `indexedFields` — and only the matching documents
/// are decoded. Results are ordered by `(order-by value, document id)`;
/// documents that lack the order-by field sort first (last when descending).
/// That order is total and engine-independent, which makes [page] safe for
/// infinite scroll: pages are disjoint and gap-free, and a cursor points at
/// the same boundary after a reopen and on every converged device.
///
/// ```dart
/// final page = await items
///     .query()
///     .where('done', isEqualTo: false)
///     .orderBy('createdAt', descending: true)
///     .limit(20)
///     .page();
/// // Later: .startAfter(page.nextCursor!) for the next page.
/// ```
class CollectionQuery<T> {
  CollectionQuery._(
    this._collection,
    this._predicates,
    this._orderByPath,
    this._descending,
    this._limit,
    this._after,
  );

  final Collection<T> _collection;
  final List<QueryPredicate> _predicates;
  final String? _orderByPath;
  final bool _descending;
  final int? _limit;
  final QueryCursor? _after;

  /// The sentinel that distinguishes "parameter not given" from an explicit
  /// `null` argument (querying for a stored null is legal).
  static const Object _unset = Object();

  CollectionQuery<T> _with({
    List<QueryPredicate>? predicates,
    String? orderByPath,
    bool? descending,
    int? limit,
    QueryCursor? after,
  }) =>
      CollectionQuery._(
        _collection,
        predicates ?? _predicates,
        orderByPath ?? _orderByPath,
        descending ?? _descending,
        limit ?? _limit,
        after ?? _after,
      );

  /// Adds one comparison on the field at [path]; clauses combine with AND.
  ///
  /// Pass exactly one operator per call:
  ///
  /// - [isEqualTo] — the field equals a scalar (`null` matches a stored null).
  /// - [isGreaterThan] / [isLessThan] — the field exceeds / is below a
  ///   non-null scalar. On a [PnCounter] field the comparison is against the
  ///   counter's total.
  /// - [isIn] — the field equals one of a non-empty list of scalars.
  /// - [contains] — the [OrSet] field at [path] contains the scalar as an
  ///   element. Only valid on a set field.
  ///
  /// A document without the field never matches. Throws [ArgumentError] when
  /// the operator does not fit the field's [CrdtType], the value is not a
  /// scalar (`num`, `String`, `bool`, `null`), or more or fewer than one
  /// operator is given.
  CollectionQuery<T> where(
    String path, {
    Object? isEqualTo = _unset,
    Object? isGreaterThan = _unset,
    Object? isLessThan = _unset,
    List<Object?>? isIn,
    Object? contains = _unset,
  }) {
    _validatePath(path);
    final type = _collection._merge.typeAt(path);
    final given = <(QueryOp, Object?)>[
      if (!identical(isEqualTo, _unset)) (QueryOp.equals, isEqualTo),
      if (!identical(isGreaterThan, _unset))
        (QueryOp.greaterThan, isGreaterThan),
      if (!identical(isLessThan, _unset)) (QueryOp.lessThan, isLessThan),
      if (isIn != null) (QueryOp.isIn, isIn),
      if (!identical(contains, _unset)) (QueryOp.contains, contains),
    ];
    if (given.length != 1) {
      throw ArgumentError(
        'where("$path") takes exactly one operator; got ${given.length}.',
      );
    }
    final (op, value) = given.single;

    switch (type) {
      case OrSet():
        if (op != QueryOp.contains) {
          throw ArgumentError(
            'Field "$path" is an OrSet; the only operator a set supports is '
            'contains.',
          );
        }
      case LwwRegister() || PnCounter():
        if (op == QueryOp.contains) {
          throw ArgumentError(
            'contains queries set membership, and field "$path" is not an '
            'OrSet.',
          );
        }
    }
    switch (op) {
      case QueryOp.isIn:
        final values = value as List;
        if (values.isEmpty) {
          throw ArgumentError('isIn on "$path" needs a non-empty list.');
        }
        values.forEach(_validateScalar);
      case QueryOp.greaterThan || QueryOp.lessThan:
        if (value == null) {
          throw ArgumentError(
            'Ordered comparison on "$path" against null never matches; '
            'pass a non-null scalar.',
          );
        }
        _validateScalar(value);
      case QueryOp.equals || QueryOp.contains:
        _validateScalar(value);
    }

    return _with(predicates: [
      ..._predicates,
      QueryPredicate(path: path, op: op, value: value, type: type),
    ]);
  }

  /// Orders the results by the field at [path] (then by document id, as a
  /// tiebreak). Documents without the field sort first — last when
  /// [descending].
  ///
  /// At most one order per query. Ordering by an [OrSet] field throws
  /// [ArgumentError]: a set has no single comparable value. On a [PnCounter]
  /// field the order is by the counter's total. Without [orderBy], results
  /// are ordered by document id.
  CollectionQuery<T> orderBy(String path, {bool descending = false}) {
    _validatePath(path);
    if (_orderByPath != null) {
      throw ArgumentError(
        'orderBy is already set to "$_orderByPath"; a query has one order.',
      );
    }
    if (_collection._merge.typeAt(path) is OrSet) {
      throw ArgumentError(
        'Cannot orderBy "$path": an OrSet has no single comparable value.',
      );
    }
    return _with(orderByPath: path, descending: descending);
  }

  /// Caps the number of returned documents at [n] (which must be positive).
  CollectionQuery<T> limit(int n) {
    if (n <= 0) throw ArgumentError.value(n, 'n', 'must be positive');
    return _with(limit: n);
  }

  /// Resumes after [cursor], the position handed back by a previous [page] of
  /// the same query (same predicates and order).
  CollectionQuery<T> startAfter(QueryCursor cursor) => _with(after: cursor);

  /// Runs the query and returns the matching documents.
  Future<List<T>> get() async => (await page()).items;

  /// Runs the query and returns the matching documents plus the cursor for
  /// the next page.
  ///
  /// [QueryPage.nextCursor] is `null` when this page ends the result set (it
  /// returned fewer documents than [limit], or the query has no limit).
  Future<QueryPage<T>> page() async {
    _requireFieldRows();
    await _collection._ready;
    // Through the write chain, so a page never holds a half-written document.
    final (rows, fieldsByDoc) = await _collection._serializedRead(_fetch);
    final items = _decode(rows, fieldsByDoc);
    final last = rows.isNotEmpty ? rows.last : null;
    final nextCursor = (_limit != null && rows.length == _limit && last != null)
        ? QueryCursor(orderValue: last.orderValue, docId: last.docId)
        : null;
    return QueryPage._(items, nextCursor);
  }

  /// Watches the query: emits its result after the initial load, then again
  /// whenever a change — local or synced — alters the result's contents or
  /// order.
  ///
  /// Cost per change is bounded by the query, not the collection: each engine
  /// change signal re-runs the (indexed, windowed) query and re-reads at most
  /// the result's documents; decoding happens only when the result actually
  /// changed, so at most [limit] documents are decoded per emission. A change
  /// that leaves the result identical emits nothing — [Collection.watch], by
  /// contrast, decodes and emits the whole collection on every change.
  ///
  /// The cursor window ([startAfter]) is honoured, so one stream can watch one
  /// page. The stream completes when the database is closed.
  Stream<List<T>> watch() {
    _requireFieldRows();
    List<String>? lastFingerprint;
    var running = false;
    var dirty = false;
    return _collection._watchStream((controller) async {
      // Coalesce bursts: one recompute at a time, and a signal that arrives
      // mid-recompute queues exactly one more.
      if (running) {
        dirty = true;
        return;
      }
      running = true;
      try {
        do {
          dirty = false;
          // Sample through the write chain: a put writes a document's field
          // records one at a time, each firing a change event, and an
          // unserialised read between two of them would see (and decode) a
          // half-written document.
          late (List<QueryRow>, Map<String, Map<String, Object?>>) sample;
          await _collection._serialize(() async => sample = await _fetch());
          final (rows, fieldsByDoc) = sample;
          final fingerprint = _fingerprint(rows, fieldsByDoc);
          if (_sameFingerprint(lastFingerprint, fingerprint)) continue;
          lastFingerprint = fingerprint;
          final items = _decode(rows, fieldsByDoc);
          if (!controller.isClosed) controller.add(items);
        } while (dirty);
      } finally {
        running = false;
      }
    });
  }

  /// Runs the compiled query and the batched materialisation read: the
  /// matching rows in order, and the raw resolved fields of their documents.
  ///
  /// One batched read materialises the whole result: decode cost scales with
  /// the page, and a scanning engine walks its table once, not once per hit.
  Future<(List<QueryRow>, Map<String, Map<String, Object?>>)> _fetch() async {
    final c = _collection;
    final spec = QuerySpec(
      predicates: _predicates,
      orderByPath: _orderByPath,
      orderByType: _orderByPath == null
          ? const LwwRegister()
          : c._merge.typeAt(_orderByPath),
      descending: _descending,
      limit: _limit,
      after: _after,
    );
    final rows = await c._engine.queryDocIds(c._name, spec);
    final fieldsByDoc =
        await c._engine.docFields(c._name, [for (final row in rows) row.docId]);
    return (rows, fieldsByDoc);
  }

  List<T> _decode(
      List<QueryRow> rows, Map<String, Map<String, Object?>> fieldsByDoc) {
    final c = _collection;
    return [
      for (final row in rows)
        if (fieldsByDoc[row.docId] case final fields? when fields.isNotEmpty)
          c._codec.fromMap(c._merge.unflatten(Collection._rows(fields))),
    ];
  }

  /// A canonical, order-sensitive summary of a fetched result — one string
  /// per row, from the raw (undecoded) fields — used by [watch] to skip
  /// emissions when nothing the query can see has changed.
  static List<String> _fingerprint(
      List<QueryRow> rows, Map<String, Map<String, Object?>> fieldsByDoc) {
    return [
      for (final row in rows)
        '${row.docId}\x1F${jsonEncode([
              for (final path
                  in (fieldsByDoc[row.docId] ?? const {}).keys.toList()..sort())
                [path, fieldsByDoc[row.docId]![path]],
            ])}',
    ];
  }

  static bool _sameFingerprint(List<String>? a, List<String> b) {
    if (a == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Queries need per-field records; [ObjectMergeStrategy] produces none.
  void _requireFieldRows() {
    if (_collection._merge is ObjectMergeStrategy) {
      throw ArgumentError(
        'Collection "${_collection._name}" uses ObjectMergeStrategy, which '
        'stores each document as a single record with no field rows to query. '
        'Use ShallowMergeStrategy, DeepMergeStrategy, or SchemaMergeStrategy.',
      );
    }
  }

  /// Rejects paths that cannot be a flattened field path: the reserved unit
  /// separator, or any other control character (which would also corrupt the
  /// SQL literals the engine builds identifiers from).
  static void _validatePath(String path) {
    if (path.isEmpty ||
        path.codeUnits.any((u) => u < 0x20) ||
        path.contains('\x7F')) {
      throw ArgumentError.value(
        path,
        'path',
        'A field path is non-empty and contains no control characters',
      );
    }
  }

  /// Rejects predicate values outside the comparable domain.
  static void _validateScalar(Object? value) {
    if (value is! num? && value is! String && value is! bool) {
      throw ArgumentError.value(
        value,
        'value',
        'Query values are scalars: num, String, bool, or null',
      );
    }
  }
}

/// One page of query results: the decoded [items] and, when the result set
/// continues past them, the [nextCursor] to fetch the following page with
/// [CollectionQuery.startAfter].
class QueryPage<T> {
  QueryPage._(this.items, this.nextCursor);

  /// The documents of this page, in the query's order.
  final List<T> items;

  /// The position after the last row of this page, or `null` when this page
  /// ends the result set.
  final QueryCursor? nextCursor;
}
