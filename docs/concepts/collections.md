# Collections

A `Collection<T>` is a typed, queryable set of documents inside a database. Each
document is identified by a stable string id and merges last-write-wins with its
peers.

## Obtaining a collection

Collections are created (or re-opened) by name on a database. Pass a `Codec<T>`
that knows how to (de)serialise the document and extract its id:

```dart
final items = db.collection<Item>('items', itemCodec);
```

Re-requesting the same name returns the same collection instance.

## Codecs

A `Codec<T>` is the bridge between your type and the string stored in the CRDT.
For JSON-friendly models, use `JsonCodec`:

```dart
final itemCodec = JsonCodec<Item>(
  toJson: (i) => i.toJson(),     // T -> Map<String, dynamic>
  fromJson: Item.fromJson,        // Map<String, dynamic> -> T
  id: (i) => i.id,                // T -> stable document id
);
```

The codec never sees encrypted bytes — encryption happens below it, in the
storage and transport layers.

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
- Concurrent edits to the **same** document id resolve last-write-wins, with the
  HLC choosing the same winner on every device — convergence is deterministic.

See [Sync & CRDTs](sync-and-crdt.md) for how this works on the wire.
