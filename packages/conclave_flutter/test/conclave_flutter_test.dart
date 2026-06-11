import 'package:conclave_core/conclave_core.dart';
import 'package:conclave_flutter/conclave_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('KeychainKeyStore', () {
    const channel =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    late Map<String, String> backing;

    setUp(() {
      backing = {};
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        final args = (call.arguments as Map).cast<String, dynamic>();
        switch (call.method) {
          case 'write':
            backing[args['key'] as String] = args['value'] as String;
            return null;
          case 'read':
            return backing[args['key'] as String];
          case 'delete':
            backing.remove(args['key'] as String);
            return null;
          case 'containsKey':
            return backing.containsKey(args['key'] as String);
          default:
            return null;
        }
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('returns null for an unknown database', () async {
      final store = KeychainKeyStore();
      expect(await store.getKey('db-1'), isNull);
    });

    test('round-trips a key', () async {
      final store = KeychainKeyStore();
      final key = List<int>.generate(32, (i) => i);
      await store.setKey('db-1', key);
      expect(await store.getKey('db-1'), equals(key));
    });

    test('setKey overwrites an existing key', () async {
      final store = KeychainKeyStore();
      await store.setKey('db-1', List.filled(32, 1));
      await store.setKey('db-1', List.filled(32, 2));
      expect(await store.getKey('db-1'), equals(List.filled(32, 2)));
    });

    test('clear removes a key', () async {
      final store = KeychainKeyStore();
      await store.setKey('db-1', List.filled(32, 7));
      await store.clear('db-1');
      expect(await store.getKey('db-1'), isNull);
    });

    test('keys are namespaced', () async {
      final store = KeychainKeyStore(namespace: 'myapp');
      await store.setKey('db-1', List.filled(32, 9));
      expect(backing.keys.single, equals('myapp.db-1'));
    });

    test('different databases are isolated', () async {
      final store = KeychainKeyStore();
      await store.setKey('db-1', List.filled(32, 1));
      await store.setKey('db-2', List.filled(32, 2));
      expect(await store.getKey('db-1'), equals(List.filled(32, 1)));
      expect(await store.getKey('db-2'), equals(List.filled(32, 2)));
    });
  });

  group('CollectionNotifier', () {
    late _MemStore store;
    late Collection<_Item> collection;

    setUp(() {
      store = _MemStore();
      collection = Collection.create<_Item>('items', _Item.codec, store);
    });

    test('exposes the initial contents', () async {
      await collection.put(const _Item('a', 'Apples'));
      final notifier = CollectionNotifier(collection);
      addTearDown(notifier.dispose);
      // watch() emits the loaded snapshot asynchronously.
      await Future<void>.delayed(Duration.zero);
      expect(notifier.items.map((i) => i.id), contains('a'));
    });

    test('notifies and updates items on a local change', () async {
      final notifier = CollectionNotifier(collection);
      addTearDown(notifier.dispose);

      var notifications = 0;
      notifier.addListener(() => notifications++);

      await collection.put(const _Item('b', 'Bananas'));
      await Future<void>.delayed(Duration.zero);

      expect(notifications, greaterThan(0));
      expect(notifier.items.map((i) => i.id), contains('b'));
    });

    test('items is unmodifiable', () async {
      final notifier = CollectionNotifier(collection);
      addTearDown(notifier.dispose);
      expect(() => notifier.items.add(const _Item('x', 'X')),
          throwsUnsupportedError);
    });

    test('stops listening after dispose', () async {
      final notifier = CollectionNotifier(collection);
      var notifications = 0;
      notifier.addListener(() => notifications++);
      notifier.dispose();

      await collection.put(const _Item('c', 'Cherries'));
      await Future<void>.delayed(Duration.zero);
      expect(notifications, equals(0));
    });
  });
}

class _Item {
  const _Item(this.id, this.name);

  final String id;
  final String name;

  static final codec = JsonCodec<_Item>(
    toJson: (i) => {'id': i.id, 'name': i.name},
    fromJson: (j) => _Item(j['id'] as String, j['name'] as String),
    id: (i) => i.id,
  );
}

class _MemStore implements BlobStore {
  final Map<String, List<int>> _data = {};

  @override
  Future<void> open() async {}

  @override
  Future<List<int>?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, List<int> bytes) async =>
      _data[key] = List.of(bytes);

  @override
  Future<void> delete(String key) async => _data.remove(key);

  @override
  Future<List<String>> keys({String? prefix}) async => prefix == null
      ? _data.keys.toList()
      : _data.keys.where((k) => k.startsWith(prefix)).toList();

  @override
  Future<void> close() async {}
}
