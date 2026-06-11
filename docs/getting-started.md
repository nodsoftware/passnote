# Getting started

This guide takes you from an empty Flutter app to a live, encrypted, multi-device
shopping list in a handful of steps.

## 1. Install

Add the umbrella package to your `pubspec.yaml`:

```yaml
dependencies:
  conclave: ^0.1.0
```

The umbrella re-exports everything you need and pulls in the default adapters
(Sembast storage, OS keychain, LAN transport, AES-GCM crypto). If you only want
the pure-Dart engine, depend on `conclave_core` instead and wire adapters
yourself — see [Adapters](concepts/databases-keys.md).

```sh
flutter pub get
```

## 2. Define a model and codec

A collection stores typed documents. You describe how to (de)serialise a
document and how to extract its stable id via a `Codec`:

```dart
class Item {
  const Item({required this.id, required this.name, this.done = false});

  final String id;
  final String name;
  final bool done;

  Item copyWith({String? name, bool? done}) =>
      Item(id: id, name: name ?? this.name, done: done ?? this.done);

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'done': done};

  factory Item.fromJson(Map<String, dynamic> json) => Item(
        id: json['id'] as String,
        name: json['name'] as String,
        done: (json['done'] as bool?) ?? false,
      );
}

final itemCodec = JsonCodec<Item>(
  toJson: (i) => i.toJson(),
  fromJson: Item.fromJson,
  id: (i) => i.id,
);
```

## 3. Open Conclave

`openDefault` wires the production adapters and starts the LAN transport. Call
it once and share the handle across your app.

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final conclave = await openDefault(
    appId: 'shopping',   // scopes discovery + storage
    salt: 'shopping:v1', // stable, app-specific PBKDF2 salt
  );

  runApp(MyApp(conclave: conclave));
}
```

- **`appId`** scopes mDNS discovery and storage namespacing — only apps with the
  same `appId` discover each other.
- **`salt`** is a stable, app-specific string mixed into key derivation. Change
  it only when you intend to invalidate all previously derived keys.

## 4. Open a database with a passphrase

A *database* is one shared, encrypted dataset. The passphrase derives its
encryption key and its discovery "room" — devices that enter the same passphrase
(under the same `appId`/`salt`) join the same encrypted room.

```dart
// On the first device, generate a passphrase to show the user:
final words = conclave.generatePassphrase().join(' ');

// On every device, open the database with that passphrase:
final db = await conclave.openDatabase('home', passphrase: words);
```

## 5. Read and write a collection

```dart
final items = db.collection<Item>('items', itemCodec);

await items.put(Item(id: newId(), name: 'Milk'));
await items.put(Item(id: newId(), name: 'Bread'));

// Soft-delete by id:
await items.delete(someId);

// Query in memory:
final remaining = items.where((i) => !i.done);
```

## 6. React to changes

`watch()` emits the current list immediately and again on every local or synced
change:

```dart
items.watch().listen((all) {
  print('list now has ${all.length} items');
});
```

In Flutter, prefer the ready-made `CollectionNotifier` (a `ChangeNotifier`):

```dart
ChangeNotifierProvider(
  create: (_) => CollectionNotifier<Item>(items),
  child: Consumer<CollectionNotifier<Item>>(
    builder: (_, n, __) => ListView(
      children: [for (final item in n.items) Text(item.name)],
    ),
  ),
);
```

## 7. Try multi-device sync

1. Run the app on two devices on the same Wi-Fi.
2. Enter the same passphrase on both.
3. Add an item on one — it appears on the other within moments.
4. Go offline, edit both, reconnect — the lists converge automatically.

Two complete, runnable examples live in the repository:

- `examples/shopping_list_provider` — Provider + `CollectionNotifier`.
- `examples/shopping_list_bloc` — `flutter_bloc` Cubit over `items.watch()`.

## Where to go next

- [Databases & keys](concepts/databases-keys.md)
- [Collections](concepts/collections.md)
- [Sync & CRDTs](concepts/sync-and-crdt.md)
- [Security](security.md)
