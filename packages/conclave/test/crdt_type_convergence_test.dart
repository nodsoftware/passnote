import 'package:conclave/conclave.dart';
import 'package:conclave/engine.dart';
import 'package:test/test.dart';

/// XOR cipher, fast and deterministic — the wire is not what these tests check.
class _XorCipher implements Cipher {
  _XorCipher(List<int> key) : _key = key[0];
  final int _key;

  @override
  Future<List<int>> encrypt(List<int> p) async =>
      [0xAC ^ _key, 0xED ^ _key, ...p.map((b) => b ^ _key)];

  @override
  Future<List<int>> decrypt(List<int> c) async {
    if (c.length < 2 || (c[0] ^ _key) != 0xAC || (c[1] ^ _key) != 0xED) {
      throw const CipherAuthError();
    }
    return c.skip(2).map((b) => b ^ _key).toList();
  }
}

class _MemKeyStore implements KeyStore {
  final _keys = <String, List<int>>{};
  @override
  Future<List<int>?> getKey(String id) async => _keys[id];
  @override
  Future<void> setKey(String id, List<int> key) async => _keys[id] = key;
  @override
  Future<void> clear(String id) async => _keys.remove(id);
}

/// A shopping item exercising all three types: `name` is untyped (LWW),
/// `qty` a counter, `tags` a set.
class _Item {
  _Item(this.id, this.name, this.qty, this.tags);
  final String id;
  final String name;
  final num qty;
  final List<String> tags;

  _Item copyWith({String? name, List<String>? tags}) =>
      _Item(id, name ?? this.name, qty, tags ?? this.tags);

  static final codec = JsonCodec<_Item>(
    toMap: (i) => {'id': i.id, 'name': i.name, 'qty': i.qty, 'tags': i.tags},
    fromMap: (m) => _Item(
      m['id'] as String,
      m['name'] as String,
      m['qty'] as num,
      (m['tags'] as List).cast<String>(),
    ),
    idOf: (i) => i.id,
  );
}

const _schema = SchemaMergeStrategy({'qty': PnCounter(), 'tags': OrSet()});

void main() {
  const passphrase =
      'one two three four five six seven eight nine ten eleven twelve';

  Future<Conclave> openNode(InMemoryBus bus) => Conclave.lowLevel(
        config: const ConclaveConfig(appId: 'test', salt: 'test:v1'),
        keyStore: _MemKeyStore(),
        transport: InMemoryTransport(bus),
        deriveKey: (passphrase, salt) async =>
            List<int>.generate(32, (i) => passphrase.codeUnitAt(0) ^ i),
        roomTag: (key) => 'room',
        cipher: _XorCipher.new,
        mnemonicGenerator: (words) => List.generate(words, (i) => 'word$i'),
        validateMnemonic: (_) => true,
        engine: (dbId, collection, _) => MapCrdtTable(collection),
      );

  /// Two devices sharing one bus, with an `items` collection each, and the
  /// seed [_Item] already converged on both.
  Future<
      ({
        InMemoryBus bus,
        Database dbA,
        Collection<_Item> itemsA,
        Collection<_Item> itemsB,
      })> twoDevices(_Item seed) async {
    final bus = InMemoryBus();
    final a = await openNode(bus);
    final b = await openNode(bus);
    addTearDown(() async {
      await a.close();
      await b.close();
    });

    final dbA = await a.openDatabase('list', passphrase: passphrase);
    final dbB = await b.openDatabase('list', passphrase: passphrase);
    final itemsA = dbA.collection<_Item>('items', _Item.codec, merge: _schema);
    final itemsB = dbB.collection<_Item>('items', _Item.codec, merge: _schema);

    await itemsA.put(seed);
    await itemsB
        .watch()
        .firstWhere((l) => l.isNotEmpty)
        .timeout(const Duration(seconds: 5));
    return (bus: bus, dbA: dbA, itemsA: itemsA, itemsB: itemsB);
  }

  /// Reconnects after an offline window and waits until [what] holds on both
  /// sides.
  Future<void> reconnectAndWait(
    ({
      InMemoryBus bus,
      Database dbA,
      Collection<_Item> itemsA,
      Collection<_Item> itemsB,
    }) d,
    bool Function(_Item) what,
  ) async {
    d.bus.paused = false;
    await d.dbA.forceSync();
    await Future.wait([
      d.itemsA.watch().firstWhere((l) => l.isNotEmpty && what(l.single)),
      d.itemsB.watch().firstWhere((l) => l.isNotEmpty && what(l.single)),
    ]).timeout(const Duration(seconds: 5));
  }

  group('LwwRegister', () {
    test('the later edit to an untyped field wins on both devices', () async {
      final d = await twoDevices(_Item('i1', 'Milk', 0, []));

      await d.itemsA.put((await d.itemsA.get('i1'))!.copyWith(name: 'from A'));
      // B writes after A: last write wins, as it always did.
      await d.itemsB.put((await d.itemsB.get('i1'))!.copyWith(name: 'from B'));

      await reconnectAndWait(d, (i) => i.name == 'from B');
      expect((await d.itemsA.get('i1'))!.name, 'from B');
      expect((await d.itemsB.get('i1'))!.name, 'from B');
    });
  });

  group('PnCounter', () {
    test('concurrent increments on two devices sum after convergence',
        () async {
      final d = await twoDevices(_Item('i1', 'Milk', 0, []));

      d.bus.paused = true; // Offline: the edits are genuinely concurrent.
      await d.itemsA.increment('i1', 'qty', by: 3);
      await d.itemsB.increment('i1', 'qty', by: 4);

      await reconnectAndWait(d, (i) => i.qty == 7);
      expect((await d.itemsA.get('i1'))!.qty, 7);
      expect((await d.itemsB.get('i1'))!.qty, 7);
    });

    test('a negative increment and a put seed take part in the sum', () async {
      final d = await twoDevices(_Item('i1', 'Milk', 10, []));

      d.bus.paused = true;
      await d.itemsA.increment('i1', 'qty', by: -2);
      await d.itemsB.increment('i1', 'qty', by: 5);

      await reconnectAndWait(d, (i) => i.qty == 13);
      expect((await d.itemsB.get('i1'))!.qty, 13);
    });

    test('a put that would change the counter throws', () async {
      final d = await twoDevices(_Item('i1', 'Milk', 1, []));
      final current = (await d.itemsA.get('i1'))!;
      expect(
        () => d.itemsA.put(_Item(current.id, current.name, 99, current.tags)),
        throwsArgumentError,
      );
    });

    test('increment on a missing document throws', () async {
      final d = await twoDevices(_Item('i1', 'Milk', 0, []));
      expect(
        () => d.itemsA.increment('nope', 'qty', by: 1),
        throwsStateError,
      );
    });
  });

  group('OrSet', () {
    test('a concurrent add and a remove of a different element both apply',
        () async {
      final d = await twoDevices(_Item('i1', 'Milk', 0, ['dairy']));

      d.bus.paused = true;
      await d.itemsA
          .put((await d.itemsA.get('i1'))!.copyWith(tags: ['dairy', 'urgent']));
      await d.itemsB.put((await d.itemsB.get('i1'))!.copyWith(tags: []));

      await reconnectAndWait(d, (i) => i.tags.length == 1);
      expect((await d.itemsA.get('i1'))!.tags, ['urgent']);
      expect((await d.itemsB.get('i1'))!.tags, ['urgent']);
    });

    test('an add wins over a concurrent remove that did not observe it',
        () async {
      final d = await twoDevices(_Item('i1', 'Milk', 0, ['dairy']));

      d.bus.paused = true;
      // B removes the tag it observed; A removes and re-adds it, so A's fresh
      // add was never observed by B's remove.
      await d.itemsB.put((await d.itemsB.get('i1'))!.copyWith(tags: []));
      await d.itemsA.put((await d.itemsA.get('i1'))!.copyWith(tags: []));
      await d.itemsA.put((await d.itemsA.get('i1'))!.copyWith(tags: ['dairy']));

      await reconnectAndWait(d, (i) => i.tags.isNotEmpty);
      expect((await d.itemsA.get('i1'))!.tags, ['dairy']);
      expect((await d.itemsB.get('i1'))!.tags, ['dairy']);
    });
  });

  group('mixed document', () {
    test('LWW, counter, and set edits to one document all survive', () async {
      final d = await twoDevices(_Item('i1', 'Milk', 1, ['dairy']));

      d.bus.paused = true;
      await d.itemsA.increment('i1', 'qty', by: 2);
      await d.itemsA
          .put((await d.itemsA.get('i1'))!.copyWith(tags: ['dairy', 'urgent']));
      await d.itemsB.put((await d.itemsB.get('i1'))!.copyWith(name: 'Milk 2L'));

      await reconnectAndWait(
        d,
        (i) => i.name == 'Milk 2L' && i.qty == 3 && i.tags.length == 2,
      );
      final onA = (await d.itemsA.get('i1'))!;
      final onB = (await d.itemsB.get('i1'))!;
      expect(onA.name, 'Milk 2L');
      expect(onA.qty, 3);
      expect(onA.tags, ['dairy', 'urgent']);
      expect(onB.name, 'Milk 2L');
      expect(onB.qty, 3);
      expect(onB.tags, ['dairy', 'urgent']);
    });
  });
}
