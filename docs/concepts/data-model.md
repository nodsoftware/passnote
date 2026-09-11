# Collections

A `Collection<T>` is a typed, queryable set of documents inside a database. Each
document is identified by a stable string id. How two devices reconcile
concurrent edits to the *same* document is configurable per collection — see
[Merge strategies](#merge-strategies).

## Obtaining a collection

Collections are created (or re-opened) by name on a database. Pass a `Codec<T>`
that knows how to (de)serialise the document and extract its id:

```dart
final items = db.collection<Item>('items', itemCodec);
```

Re-requesting the same name returns the same collection instance.

## Codecs

A `Codec<T>` is the bridge between your type and the JSON map stored in the
CRDT. For JSON-friendly models, use `JsonCodec`:

```dart
final itemCodec = JsonCodec<Item>(
  toMap: (i) => i.toJson(),       // T -> Map<String, dynamic>
  fromMap: Item.fromJson,         // Map<String, dynamic> -> T
  idOf: (i) => i.id,              // T -> stable document id
);
```

The codec never sees encrypted bytes — encryption happens below it, in the
storage and transport layers.

## Merge strategies

A `MergeStrategy` controls how a document is decomposed into independently
clocked CRDT records, which in turn decides how concurrent edits merge. Pass one
when you create the collection:

```dart
final items = db.collection<Item>(
  'items',
  itemCodec,
  merge: const ShallowMergeStrategy(),
);
```

`MergeStrategy` is a [port](../reference/transports.md), so you can also supply
your own implementation. Three are built in:

| Strategy | Granularity | Concurrent edits to one document |
| --- | --- | --- |
| `ObjectMergeStrategy` *(default)* | Whole document | Last write wins; one edit is lost. |
| `ShallowMergeStrategy` | Each top-level field | Edits to *different* fields both survive; same field is LWW. Nested objects stay atomic. |
| `DeepMergeStrategy` | Every nested field, recursively | Edits to *different* leaf paths both survive; lists are treated as atomic leaves. |

The strategy is fixed when the collection is first created. Re-requesting the
same name returns the existing instance and ignores a different `merge`
argument, so all devices sharing a collection should agree on the strategy.

### Deletion is always atomic

Whatever the strategy, a document's *existence* is tracked by a single
last-write-wins record — separate from its fields. Deleting tombstones only that
record, so a delete and a concurrent field edit are reconciled on one register
(latest wins) and a document can never come back missing some of its fields. If
an edit wins, the document survives intact; if the delete wins, it is fully
gone. Because the document type is fixed by `Codec<T>`, every device agrees on
the field set, so fields can never "appear from nowhere" either.

!!! note "Choosing a granularity"
    Field-granular modes merge each field independently, so the converged
    document may combine field values that were written on different devices.
    That is exactly what per-field convergence means — both edits are kept
    rather than one being discarded. `ObjectMergeStrategy` instead keeps the
    whole document as one record, so a write always lands as an atomic snapshot
    and concurrent writes resolve last-write-wins. Pick the granularity that
    matches how independent your fields really are.

## Writing

```dart
// Insert or update — the id comes from Codec.idOf:
await items.put(Item(id: 'abc', name: 'Milk'));

// Soft-delete by id (a tombstone is kept so the deletion syncs):
await items.delete('abc');
```

Both `put` and `delete` await the initial storage load internally, persist the
result, and notify peers.

## Reading and querying

```dart
final one = items.get('abc');                  // T? — null if absent or deleted
final all = items.all();                       // List<T> of live documents
final page = items.all(limit: 10, offset: 20); // page of 10, skip first 20
final todo = items.where((i) => !i.done);      // Iterable<T>
final some = items.where((i) => !i.done,
    limit: 5, offset: 10);                     // page of 5 matching docs
```

`get` and `all` are synchronous in-memory reads. If called before the initial
load completes they return empty results; use `watch()` to be notified once data
is ready.

Pagination via `limit`/`offset` decodes **only the requested page** — decoding
(parsing JSON into your model) is the expensive step, and it scales with the
page size, not the collection size. The collection's stored keys are still
scanned once per call to enumerate documents, so that part stays
`O(collection)` with the default in-memory engine. `where(test, …)` runs your
predicate against decoded documents, so it decodes up to the point it stops:
with `limit` it stops once enough matches are found. For an equality match on a
declared field, prefer `findBy` (below), which skips decoding non-matches
entirely.

### Secondary indexes

Declare indexed fields when creating a collection for O(matches) equality
lookups via `findBy`:

```dart
final items = db.collection<Item>(
  'items',
  itemCodec,
  merge: const ShallowMergeStrategy(),
  indexedFields: ['status', 'priority'],
);

final done = items.findBy('status', 'done');
final urgent = items.findBy('priority', 'high', limit: 5);
```

The index operates at the same granularity as the collection's merge strategy:
with `ShallowMergeStrategy`, index top-level field paths; with
`DeepMergeStrategy`, use dotted paths like `'address.city'`. The index is
derived state — rebuilt on load, updated incrementally with every write, and
never persisted separately.

Only equality lookups are supported — `findBy` matches a field against a single
value. Range, prefix, and multi-field queries are out of scope; use `where` for
those.

#### What `findBy` actually saves

The headline benefit is that `findBy` **decodes only the matching documents**,
whereas `where` decodes *every* document to test the predicate. When documents
are large or the codec is heavy, that is the dominant cost, so on a collection
of thousands this is a substantial, measurable win.

It is not (yet) a sub-linear lookup. The index lookup itself is `O(1)`, but the
matched documents' fields are then read back through the storage engine. The
default in-memory engine (`MapCrdtTable`) is a hash map with no range scan, so
gathering those fields costs one `O(collection)` pass over the stored keys —
cheap string comparisons, no decoding. A range-capable engine (a disk- or
SQL-backed `CrdtTable`, planned alongside the bounded-memory engine work) can
serve the matched ids without that pass, at which point `findBy` becomes truly
`O(matches)`; the decode savings already hold today regardless of engine.

!!! note "Cost today, in one line"
    `findBy` ≈ `O(collection)` cheap key scan **+** `O(matches)` decode, versus
    `where` ≈ `O(collection)` key scan **+** `O(collection)` decode. The index
    also keeps an in-memory map of size `O(indexed-fields × documents)` and is
    rebuilt with an `O(collection)` scan when the collection is opened.

!!! warning "Indexes require a field-granular merge strategy"
    An index path must be one of the flattened field paths the collection's
    merge strategy produces. The default **`ObjectMergeStrategy` flattens the
    whole document to a single record**, so its only valid index path is `''`
    (the entire document) — per-field indexing does **not** work with it. To
    index individual fields, create the collection with `ShallowMergeStrategy`
    (top-level fields) or `DeepMergeStrategy` (nested dotted paths).

    `findBy` throws an `ArgumentError` only when the field was never declared in
    `indexedFields`. A field that *is* declared but never matches the merge
    granularity (for example `findBy('status', …)` on an `ObjectMergeStrategy`
    collection) is not an error — it simply returns no results, because nothing
    was ever indexed under that path. If a `findBy` unexpectedly returns empty,
    check that the indexed path matches your merge strategy's granularity.

## Watching for changes

`watch()` returns a stream that emits the current document list once the initial
load completes, then again on every change — whether the change originated
locally or arrived from a peer:

```dart
final sub = items.watch().listen((all) {
  print('now ${all.length} items');
});
// later:
await sub.cancel();
```

!!! tip "Flutter"
    Don't subscribe by hand in widgets — use
    [`CollectionNotifier`](../reference/transports.md), a `ChangeNotifier` that wraps
    `watch()` and integrates with Provider, `ListenableBuilder`, or any
    `ChangeNotifier`-based state management.

## Conflict resolution

Collections are CRDTs with Hybrid Logical Clock arbitration:

- Concurrent edits to **different** document ids always both survive.
- Concurrent edits to the **same** document id resolve at the granularity of the
  collection's [merge strategy](#merge-strategies). The HLC chooses the same
  winner for each conflicting record on every device — convergence is
  deterministic regardless of strategy.

See [Sync & CRDTs](sync.md) for how this works on the wire.
