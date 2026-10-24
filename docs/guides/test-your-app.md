# Test your app

Two complete Passnote nodes can run inside one ordinary `flutter test`: real
encryption, real pairing, real sync. Only the pieces that touch the
environment get swapped, each with a builder override:

| Piece | Production | In tests |
| --- | --- | --- |
| Storage | SQLite files | `MapCrdtTable` (in-memory) |
| Key store | OS keychain | A `Map` behind the `KeyStore` port |
| Network | mDNS / WebSockets | `InMemoryTransport` over one `InMemoryBus` |

Everything else (key derivation, the cipher, device identity, SPAKE2
pairing, the sync protocol) runs the production code, so a passing test
exercises the same path as two phones on a shelf.

The code on this page lives in
[`examples/quickstart/test/sync_test.dart`](https://github.com/nodsoftware/passnote/blob/main/examples/quickstart/test/sync_test.dart)
and runs in CI.

## The harness

One `InMemoryBus` is one network: every node built on it can reach the
others. The key store is a ten-line fake:

```dart
import 'package:passnote/engine.dart';
import 'package:passnote_flutter/passnote_flutter.dart';

class MemoryKeyStore implements KeyStore {
  final _keys = <String, List<int>>{};

  @override
  Future<List<int>?> getKey(String id) async => _keys[id];

  @override
  Future<void> setKey(String id, List<int> key) async => _keys[id] = key;

  @override
  Future<void> clear(String id) async => _keys.remove(id);
}

Future<Passnote> testNode(InMemoryBus bus) =>
    passnoteBuilder(appId: 'shopping', salt: 'shopping:v1')
        .storage((_, collection, __) => MapCrdtTable(collection))
        .keyStore(MemoryKeyStore.new)
        .transport(() => InMemoryTransport(bus))
        .open();
```

`MapCrdtTable` and the in-memory transport come from
`package:passnote/engine.dart`, the advanced surface. It arrives
transitively through `passnote_flutter`; list `passnote` in your
`pubspec.yaml` as well so the import is an explicit dependency.

## A convergence test

The test does exactly what the tutorial does: found a group on one device,
pair the second, write on one side, observe the other.

```dart
test('an item put on one device appears on a paired device', () async {
  final bus = InMemoryBus();
  final phone = await testNode(bus);
  final laptop = await testNode(bus);
  addTearDown(() async {
    await phone.close();
    await laptop.close();
  });

  final words = phone.generatePassphrase().join(' ');
  final db = await phone.openDatabase('home', passphrase: words);
  final code = await phone.startPairing('home', joinerLabel: 'laptop');
  final dbOnLaptop =
      await laptop.pairWith('home', PairingCode.parse(code.display));

  final items = db.collection<Item>('items', itemCodec);
  final itemsOnLaptop = dbOnLaptop.collection<Item>('items', itemCodec);

  await items.put(Item(id: newId(), name: 'Milk'));

  final synced = await itemsOnLaptop
      .watch()
      .firstWhere((all) => all.isNotEmpty)
      .timeout(const Duration(seconds: 10));
  expect(synced.single.name, 'Milk');
});
```

## Habits that keep these tests honest

- **Wait on observations, never on time.** `watch().firstWhere(...)` with a
  timeout is deterministic; a `Future.delayed` is a flake waiting to happen.
- **Assert convergence, not delivery order.** Write on both nodes, then
  expect the *same* final list on each; that is the property Passnote
  guarantees.
- **One bus per network shape.** Partitions are just two buses; "the laptop
  went offline" is closing one node and opening a fresh one on the same bus
  with the same key store instance.
- **Real key derivation runs.** Argon2id is deliberately slow, so the first
  `openDatabase` per node costs real milliseconds. Reuse nodes across
  assertions inside one test instead of rebuilding them per expectation.
- **Unit tests below the sync layer need no nodes at all.** Merge behaviour
  is testable on a bare table; the [passnote package
  example](https://pub.dev/packages/passnote/example) merges two
  `MapCrdtTable`s directly.
