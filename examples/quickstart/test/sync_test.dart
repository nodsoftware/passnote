// The "Test your app" guide, compiled. Each section matches
// docs/guides/test-your-app.md; keep the two in sync.
//
// Two complete Passnote nodes run inside one test: real crypto, real
// pairing, real sync. Only the pieces that touch the environment are
// swapped: storage is in-memory, keys live in a map, and frames travel
// over an in-process bus instead of the network.

import 'package:passnote/engine.dart';
import 'package:passnote_flutter/passnote_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quickstart/main.dart';

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
        .engine(MapCrdtTable.new)
        .keyStore(MemoryKeyStore.new)
        .transport(() => InMemoryTransport(bus))
        .open();

void main() {
  test('an item put on one device appears on a paired device', () async {
    // One bus is one network: every node constructed on it can reach the
    // others.
    final bus = InMemoryBus();
    final phone = await testNode(bus);
    final laptop = await testNode(bus);
    addTearDown(() async {
      await phone.close();
      await laptop.close();
    });

    // The first device founds the group; the second joins by pairing,
    // exactly as in the tutorial.
    final words = phone.generatePassphrase().join(' ');
    final db = await phone.openDatabase('home', passphrase: words);
    final code = await phone.startPairing('home', joinerLabel: 'laptop');
    final dbOnLaptop =
        await laptop.pairWith('home', PairingCode.parse(code.display));

    final items = db.collection<Item>('items', itemCodec);
    final itemsOnLaptop = dbOnLaptop.collection<Item>('items', itemCodec);

    await items.put(Item(id: newId(), name: 'Milk'));

    // watch() emits on every change, local or synced; wait for the sync.
    final synced = await itemsOnLaptop
        .watch()
        .firstWhere((all) => all.isNotEmpty)
        .timeout(const Duration(seconds: 10));
    expect(synced.single.name, 'Milk');
  });
}
