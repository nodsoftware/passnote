import 'package:conclave_core/conclave_core.dart';
import 'package:test/test.dart';

class _RecordingKeyStore implements KeyStore {
  _RecordingKeyStore(this.label);

  final String label;
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
  late _RecordingKeyStore defaultKeyStore;
  late InMemoryTransport defaultTransport;
  List<int>? cipherKey;

  setUp(() {
    defaultKeyStore = _RecordingKeyStore('default');
    defaultTransport = InMemoryTransport(InMemoryBus());
    cipherKey = null;

    ConclaveBuilder.installDefaults(
      ConclaveDefaults(
        keyStore: (_) => defaultKeyStore,
        transport: () => defaultTransport,
        cipher: (key) {
          cipherKey = key;
          return _IdentityCipher();
        },
        deriveKey: (passphrase, salt) async => List<int>.filled(32, 7),
        roomTag: (key) => 'room-${key.length}',
        mnemonicGenerator: (words) => List.filled(words, 'abandon'),
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
    final customKeyStore = _RecordingKeyStore('custom');

    final conclave = await Conclave.builder(appId: 'a', salt: 'a:v1')
        .maxInboundFramesPerSecond(5)
        .keyStore(() => customKeyStore)
        .passphrase(words: 15)
        .open();
    addTearDown(conclave.close);
    await conclave.openDatabase('home', passphrase: 'ignored');

    expect(customKeyStore.setCalls, contains('a/home'),
        reason: 'override key store used');
    expect(defaultKeyStore.setCalls, isEmpty,
        reason: 'default key store not used');
    expect(conclave.generatePassphrase().length, 15);
  });

  test('setting the same slot twice throws StateError', () {
    final builder = Conclave.builder(appId: 'a', salt: 'a:v1');
    builder.keyStore(() => _RecordingKeyStore('x'));

    expect(
      () => builder.keyStore(() => _RecordingKeyStore('y')),
      throwsStateError,
    );
  });
}
