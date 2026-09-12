# Choose field types

Give a field a CRDT type when "latest edit wins" would lose someone's change:

```dart
@Document()
class Item {
  const Item({required this.id, required this.name, this.qty = 0, this.tags = const []});

  @DocumentId()
  final String id;

  final String name;          // last write wins (default)

  @Crdt(PnCounter())
  final num qty;              // concurrent increments all count

  @Crdt(OrSet())
  final List<String> tags;    // concurrent adds and removes all apply
}
```

Annotations describe the fields; the collection still has to be created with
the strategy they produce, or every field stays last-write-wins:

```dart
final items = db.collection<Item>('items', _$ItemCodec,
    merge: _$ItemMergeStrategy);
```

Without annotations (or with a hand-written codec), pass a
`SchemaMergeStrategy({'qty': PnCounter(), 'tags': OrSet()})` instead.

## Before and after, concretely

Two devices edit the same item while offline, then sync.

**A quantity as `LwwRegister` (the default):**

```text
both see qty == 5
A sets qty = 6 (+1)      B sets qty = 8 (+3)
merged: qty == 8         A's increment is gone
```

**The same field as `PnCounter`:**

```text
A: increment(by: 1)      B: increment(by: 3)
merged: qty == 9         both count
```

Counters change only through `items.increment(id, 'qty', by: n)`; a `put`
that would overwrite the total throws, because it would erase other devices'
contributions.

**Tags as `LwwRegister`:** A adds `urgent`, B removes `dairy`; the later
write's whole list wins and the other edit vanishes.

**Tags as `OrSet`:** both edits apply; the merged list has `urgent` and not
`dairy`. Re-adding an element beats a removal that never saw it.

## Picking

- Independent facts that get replaced: keep the default.
- Anything counted (quantities, scores, tallies): `PnCounter`.
- Membership lists (tags, participants, flags): `OrSet`.
- Cross-field invariants that must move atomically: keep the whole document
  `ObjectMergeStrategy` instead.

More depth: [Clocks and merge](../concepts/clocks-and-merge.md).
