# Query and paginate

Filter, sort, and page in the engine, decoding only what you show:

```dart
final page = await items
    .query()
    .where('done', isEqualTo: false)
    .orderBy('createdAt', descending: true)
    .limit(20)
    .page();

// page.items, and:
final next = await items
    .query()
    .where('done', isEqualTo: false)
    .orderBy('createdAt', descending: true)
    .limit(20)
    .startAfter(page.nextCursor!)
    .page();
```

On the disk engine this runs as SQL. Declare `indexedFields: ['done']` when
creating the collection and equality predicates become index searches.

## Operators

`where(path, ...)` takes exactly one operator per call; calls combine with
AND:

- `isEqualTo` (a stored `null` matches `isEqualTo: null`)
- `isGreaterThan` / `isLessThan` (on a `PnCounter` field, compares the total)
- `isIn` (a non-empty list of scalars)
- `contains` (element membership, `OrSet` fields only)

Every clause is checked against the field's CRDT type when you build the
query; a misdirected clause throws `ArgumentError` instead of silently
returning nothing.

## Stable pages

`page()` returns a cursor, not an offset. The order is
`(order-by value, document id)`: total, identical on every converged device,
and stable across a restart. Pages are disjoint and gap-free even while the
data changes, which offset-based paging cannot promise.

## Live results

Watch a query instead of the whole collection:

```dart
items.query().where('done', isEqualTo: false).limit(50).watch().listen(...);
```

A watched query re-emits only when its own result changes, and decodes at most
one page per emission. In Flutter, `CollectionNotifier.query(...)` wraps it.

One constraint: queries need per-field records, so the collection must use a
field-granular merge strategy (`ShallowMergeStrategy`, `DeepMergeStrategy`, or
`SchemaMergeStrategy`; annotated models get this automatically). Querying an
`ObjectMergeStrategy` collection throws.
