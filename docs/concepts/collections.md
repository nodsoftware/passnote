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

`MergeStrategy` is a [port](../adapters/transport.md), so you can also supply
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
final one = items.get('abc');          // T? — null if absent or deleted
final all = items.all;                 // List<T> of live documents
final todo = items.where((i) => !i.done); // Iterable<T>
```

`get` and `all` are synchronous in-memory reads. If called before the initial
load completes they return empty results; use `watch()` to be notified once data
is ready.

## Watching for changes

`watch()` returns a stream that emits the current document list immediately and
again on every change — whether the change originated locally or arrived from a
peer:

```dart
final sub = items.watch().listen((all) {
  print('now ${all.length} items');
});
// later:
await sub.cancel();
```

!!! tip "Flutter"
    Don't subscribe by hand in widgets — use
    [`CollectionNotifier`](../adapters/storage.md), a `ChangeNotifier` that wraps
    `watch()` and integrates with Provider, `ListenableBuilder`, or any
    `ChangeNotifier`-based state management.

## Conflict resolution

Collections are CRDTs with Hybrid Logical Clock arbitration:

- Concurrent edits to **different** document ids always both survive.
- Concurrent edits to the **same** document id resolve at the granularity of the
  collection's [merge strategy](#merge-strategies). The HLC chooses the same
  winner for each conflicting record on every device — convergence is
  deterministic regardless of strategy.

See [Sync & CRDTs](sync-and-crdt.md) for how this works on the wire.
