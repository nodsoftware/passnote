# Tutorial

This walkthrough goes from an empty Flutter app to two devices sharing an
encrypted shopping list. All code on this page lives in
[`examples/quickstart/`](https://github.com/nodsoftware/conclave/tree/main/examples/quickstart)
and is compiled in CI, so it cannot drift from the real API.

## 1. Install

Add the Flutter package to your `pubspec.yaml`, plus the code generator as a
dev dependency:

```yaml
dependencies:
  conclave_flutter: ^1.0.0

dev_dependencies:
  build_runner: ^2.15.0
  conclave_generator: ^1.0.0
```

`conclave_flutter` brings the whole library: the engine, the crypto, the
transports, and the Flutter glue (keychain key store, change notifiers).

```sh
flutter pub get
```

## 2. Define a model

Annotate a plain class. The generator produces its codec: the mapping to and
from stored form, with `@DocumentId()` marking the stable id.

```dart
part 'main.g.dart';

@Document()
class Item {
  const Item({required this.id, required this.name, this.done = false});

  @DocumentId()
  final String id;

  final String name;
  final bool done;

  Item copyWith({String? name, bool? done}) =>
      Item(id: id, name: name ?? this.name, done: done ?? this.done);
}

// `dart run build_runner build` generates _$ItemCodec from the annotations:
// toMap/fromMap over the fields, with `id` as the document id.
final itemCodec = _$ItemCodec;
```

Run the generator after changing the model:

```sh
dart run build_runner build
```

## 3. Open Conclave

`conclaveBuilder` returns a builder with the production pieces installed:
SQLite storage, the OS keychain, LAN discovery, XChaCha20-Poly1305 encryption.
Call it once and share the handle across the app.

```dart
final conclave = await conclaveBuilder(
  appId: 'shopping', // scopes discovery + storage
  salt: 'shopping:v1', // stable, app-specific key-derivation salt
)
    // Override any default before open(). This one is optional.
    .compactionHorizon(const Duration(days: 60))
    .open();
```

`appId` scopes discovery and storage: only apps with the same id see each
other. `salt` pins your keys to your app; keep it constant.

## 4. Open a database

A database is one shared, encrypted dataset. Its passphrase protects the
device roster and seeds discovery.

```dart
// On the first device, generate a passphrase to show the user:
final words = conclave.generatePassphrase().join(' ');

// On every device, open the database with that passphrase:
final db = await conclave.openDatabase('home', passphrase: words);

final items = db.collection<Item>('items', itemCodec);
```

The first device to open a database founds its device group and holds its
group key. Other devices join by pairing (step 7), not by retyping the
passphrase.

On every later launch, reopen without asking for the passphrase again; the
derived key was stored in the OS keychain by `openDatabase`:

```dart
final db = await conclave.reopenDatabase('home');
```

## 5. Read and write

```dart
Future<void> seed(Collection<Item> items) async {
  await items.put(Item(id: newId(), name: 'Milk'));
  await items.put(Item(id: newId(), name: 'Bread'));

  // Soft-delete by id:
  final someId = itemCodec.idOf((await items.all()).first);
  await items.delete(someId);

  // Query by scanning the decoded documents:
  final remaining = await items.where((i) => !i.done);
  debugPrint('${remaining.length} item(s) still to buy');
}
```

Writes work immediately, online or offline. For filtered, sorted, or paginated
reads there is also an indexed query builder; see
[Query and paginate](../guides/query-and-paginate.md).

## 6. React to changes

`watch()` emits the current list once loaded, then again on every change,
local or from a peer:

```dart
void logChanges(Collection<Item> items) {
  items.watch().listen((all) {
    debugPrint('list now has ${all.length} items');
  });
}
```

In widgets, use `CollectionNotifier` (or `CollectionNotifier.query` for a
bounded slice) instead of hand-managing subscriptions.

## 7. Pair a second device

!!! note "Real devices need OS permissions first"
    Local discovery is gated by every platform: an Info.plist entry and an
    entitlement on iOS, manifest permissions on Android, sandbox
    entitlements on macOS. A missing one fails silently. Do
    [Set up platform permissions](../guides/set-up-platforms.md) once per
    platform; simulators are more permissive than devices.

Run the app on a second device on the same network. On the device that already
has the data, create a one-time nine-digit code and show it:

```dart
Future<void> sponsorPairing(Conclave conclave) async {
  // On a device that already has the data: create a one-time code.
  final code = await conclave.startPairing('home', joinerLabel: 'new phone');
  debugPrint('On the new device, enter: ${code.display}');
}
```

On the new device, enter that code:

```dart
Future<Database> joinWithCode(Conclave conclave, String typedCode) {
  // On the new device: enter the code. The exchange authenticates both
  // sides, hands over the keys, and returns a ready database.
  return conclave.pairWith('home', PairingCode.parse(typedCode));
}
```

Add an item on either device. It appears on the other within a moment.

## 8. What just happened

- Each device keeps its own complete copy of the list in an encrypted SQLite
  file. Reads and writes never wait for the network.
- The devices found each other over the local network and exchanged only
  encrypted data. Nothing left the room in plaintext, and nothing touched a
  server.
- The nine-digit code ran a short cryptographic exchange
  ([PAKE](../concepts/glossary.md#pake)) that proved both devices held the
  same code, then sealed the data keys to the new device's own keypair.
  Guessing costs an attacker one visible failed attempt per guess, and the
  sponsor stops after three.
- Edits made on both devices at once merge automatically and every device
  arrives at the same result. How that works is in
  [Clocks and merge](../concepts/clocks-and-merge.md).

Next: pick per-field merge behaviour in
[Choose field types](../guides/choose-field-types.md), write your first
convergence test with [Test your app](../guides/test-your-app.md), or read
the [data model](../concepts/data-model.md). If the two devices never found
each other, [Troubleshoot sync](../guides/troubleshoot-sync.md) walks the
usual causes.
