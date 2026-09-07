import 'package:conclave_core/conclave_core.dart';
import 'package:test/test.dart';

class _RecordingBlobStore implements BlobStore {
  bool opened = false;
  final _data = <String, List<int>>{};

  @override
  Future<void> open() async => opened = true;

  @override
  Future<List<int>?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, List<int> bytes) async => _data[key] = bytes;

  @override
  Future<void> delete(String key) async => _data.remove(key);

  @override
  Future<List<String>> keys({String? prefix}) async =>
      _data.keys.where((k) => prefix == null || k.startsWith(prefix)).toList();

  @override
  Future<void> close() async {}
}

class _RecordingKeyStore implements KeyStore {
  final _keys = <String, List<int>>{};
  final setCalls = <String>[];

  @override
  Future<List<int>?> getKey(String databaseId) async => _keys[databaseId];

  @override
  Future<void> setKey(String databaseId, List<int> key) async {
    setCalls.add(databaseId);
    _keys[databaseId] = key;
  }

  @override
  Future<void> clear(String databaseId) async => _keys.remove(databaseId);
}

class _IdentityCipher implements Cipher {
  @override
  Future<List<int>> encrypt(List<int> plaintext) async => plaintext;

  @override
  Future<List<int>> decrypt(List<int> ciphertext) async => ciphertext;
}

void main() {
  late _RecordingBlobStore defaultStore;
  late _RecordingKeyStore defaultKeyStore;
  late InMemoryTransport defaultTransport;
  List<int>? cipherKey;

  setUp(() {
    defaultStore = _RecordingBlobStore();
    defaultKeyStore = _RecordingKeyStore();
    defaultTransport = InMemoryTransport(InMemoryBus());
    cipherKey = null;

    ConclaveBuilder.installDefaults(
      ConclaveDefaults(
        store: (_, __) => defaultStore,
        keyStore: (_) => defaultKeyStore,
        transport: () => defaultTransport,
        cipher: (key) {
          cipherKey = key;
          return _IdentityCipher();
        },
        deriveKey: (passphrase, salt) async => List<int>.filled(32, 7),
        roomTag: (key) => 'room-${key.length}',
        mnemonicGenerator: (words) => List.filled(words, 'abandon'),
        idMasker: (key) => (id) => id,
        validateMnemonic: (phrase) => true,
      ),
    );
  });

  test('minimal open() with no overrides returns a Conclave', () async {
    final conclave = await Conclave.builder(appId: 'a', salt: 'a:v1').open();
    addTearDown(conclave.close);

    expect(conclave, isA<Conclave>());
  });

  test('unset slots come from the installed defaults', () async {
    final conclave = await Conclave.builder(appId: 'a', salt: 'a:v1').open();
    addTearDown(conclave.close);
    await conclave.openDatabase('home', passphrase: 'ignored');

    expect(defaultStore.opened, isTrue);
    expect(defaultKeyStore.setCalls, contains('a/home'));
    expect(cipherKey, equals(List<int>.filled(32, 7)));
  });

  test('.passphrase(words:) drives generatePassphrase', () async {
    final conclave = await Conclave.builder(appId: 'a', salt: 'a:v1')
        .passphrase(words: 12)
        .open();
    addTearDown(conclave.close);

    expect(conclave.generatePassphrase().length, 12);
  });

  test('overrides reach their slot and are order-independent', () async {
    final customStore = _RecordingBlobStore();

    final conclave = await Conclave.builder(appId: 'a', salt: 'a:v1')
        .maxInboundFramesPerSecond(5)
        .store((_) => customStore)
        .passphrase(words: 15)
        .open();
    addTearDown(conclave.close);
    await conclave.openDatabase('home', passphrase: 'ignored');

    expect(customStore.opened, isTrue, reason: 'override store used');
    expect(defaultStore.opened, isFalse, reason: 'default store not used');
    expect(conclave.generatePassphrase().length, 15);
  });

  test('setting the same slot twice throws StateError', () {
    final builder = Conclave.builder(appId: 'a', salt: 'a:v1');
    builder.store((_) => _RecordingBlobStore());

    expect(
      () => builder.store((_) => _RecordingBlobStore()),
      throwsStateError,
    );
  });
}
