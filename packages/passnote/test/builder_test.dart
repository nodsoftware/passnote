import 'package:passnote/passnote.dart';
import 'package:passnote/engine.dart';
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

class _StubIdentity implements Identity {
  _StubIdentity(this.deviceId);

  @override
  final String deviceId;

  @override
  Future<DevicePublicKey> get publicKey async =>
      const DevicePublicKey(keyExchange: [], signing: []);

  @override
  String fingerprintOf(DevicePublicKey publicKey) => deviceId;

  @override
  Future<List<int>> sign(List<int> message) async => message;

  @override
  Future<bool> verify(
    List<int> message, {
    required List<int> signature,
    required DevicePublicKey signer,
  }) async =>
      true;

  @override
  Future<WrappedKey> wrapFor(DevicePublicKey peer, List<int> key) async =>
      WrappedKey(
        ephemeralPublicKey: List<int>.filled(32, 0),
        nonce: List<int>.filled(12, 0),
        ciphertext: [...key, ...List<int>.filled(16, 0)],
      );

  @override
  Future<List<int>> unwrap(WrappedKey wrapped) async =>
      wrapped.ciphertext.sublist(0, wrapped.ciphertext.length - 16);
}

void main() {
  late _RecordingKeyStore defaultKeyStore;
  late InMemoryTransport defaultTransport;
  List<int>? cipherKey;

  setUp(() {
    defaultKeyStore = _RecordingKeyStore('default');
    defaultTransport = InMemoryTransport(InMemoryBus());
    cipherKey = null;

    PassnoteBuilder.installDefaults(
      PassnoteDefaults(
        engine: (_, collection, __) => MapCrdtTable(collection),
        keyStore: (_) => defaultKeyStore,
        transport: () => defaultTransport,
        cipher: (key) {
          // Record the first cipher key — the passphrase-derived roster/control
          // key. A later call builds the data cipher from the group key.
          cipherKey ??= key;
          return _IdentityCipher();
        },
        deriveKey: (passphrase, salt) async => List<int>.filled(32, 7),
        roomTag: (key) => 'room-${key.length}',
        mnemonicGenerator: (words) => List.filled(words, 'abandon'),
        validateMnemonic: (phrase) => true,
        identity: (_) async => _StubIdentity('default-device'),
      ),
    );
  });

  test('minimal open() with no overrides returns a Passnote', () async {
    final passnote = await Passnote.builder(appId: 'a', salt: 'a:v1').open();
    addTearDown(passnote.close);

    expect(passnote, isA<Passnote>());
  });

  test('unset slots come from the installed defaults', () async {
    final passnote = await Passnote.builder(appId: 'a', salt: 'a:v1').open();
    addTearDown(passnote.close);
    await passnote.openDatabase('home', passphrase: 'ignored');

    expect(defaultKeyStore.setCalls, contains('a/home'));
    expect(cipherKey, equals(List<int>.filled(32, 7)));
  });

  test('.passphrase(words:) drives generatePassphrase', () async {
    final passnote = await Passnote.builder(appId: 'a', salt: 'a:v1')
        .passphrase(words: 12)
        .open();
    addTearDown(passnote.close);

    expect(passnote.generatePassphrase().length, 12);
  });

  test('overrides reach their slot and are order-independent', () async {
    final customKeyStore = _RecordingKeyStore('custom');

    final passnote = await Passnote.builder(appId: 'a', salt: 'a:v1')
        .maxInboundFramesPerSecond(5)
        .keyStore(() => customKeyStore)
        .passphrase(words: 15)
        .open();
    addTearDown(passnote.close);
    await passnote.openDatabase('home', passphrase: 'ignored');

    expect(customKeyStore.setCalls, contains('a/home'),
        reason: 'override key store used');
    expect(defaultKeyStore.setCalls, isEmpty,
        reason: 'default key store not used');
    expect(passnote.generatePassphrase().length, 15);
  });

  test('the default identity factory reaches passnote.identity', () async {
    final passnote = await Passnote.builder(appId: 'a', salt: 'a:v1').open();
    addTearDown(passnote.close);

    expect(passnote.identity.deviceId, 'default-device');
  });

  test('.identity(...) overrides the default and is handed the key store',
      () async {
    KeyStore? seen;
    final passnote = await Passnote.builder(appId: 'a', salt: 'a:v1')
        .identity((keyStore) async {
      seen = keyStore;
      return _StubIdentity('custom-device');
    }).open();
    addTearDown(passnote.close);

    expect(passnote.identity.deviceId, 'custom-device');
    expect(seen, same(defaultKeyStore));
  });

  test('setting the same slot twice throws StateError', () {
    final builder = Passnote.builder(appId: 'a', salt: 'a:v1');
    builder.keyStore(() => _RecordingKeyStore('x'));

    expect(
      () => builder.keyStore(() => _RecordingKeyStore('y')),
      throwsStateError,
    );
  });

  test('the engine slot reaches Collection through the builder', () async {
    var engineBuilds = 0;
    PassnoteBuilder.installDefaults(
      PassnoteDefaults(
        engine: (_, collection, __) {
          engineBuilds++;
          return SqliteCrdtTable(':memory:');
        },
        keyStore: (_) => _RecordingKeyStore('d'),
        transport: () => InMemoryTransport(InMemoryBus()),
        cipher: (_) => _IdentityCipher(),
        deriveKey: (_, __) async => List<int>.filled(32, 1),
        roomTag: (_) => 'room',
        mnemonicGenerator: (words) => List.filled(words, 'abandon'),
        validateMnemonic: (_) => true,
      ),
    );

    final passnote = await Passnote.builder(appId: 'a', salt: 'a:v1').open();
    addTearDown(passnote.close);
    final db = await passnote.openDatabase('home', passphrase: 'x');
    final notes = db.collection<Map<String, dynamic>>(
      'notes',
      JsonCodec(
        toMap: (m) => m,
        fromMap: (m) => m,
        idOf: (m) => m['id'] as String,
      ),
    );
    await notes.put({'id': 'n1', 'text': 'hi'});

    // Two builds: openDatabase validates the key against the reserved roster
    // store (one engine), then the app collection gets its own.
    expect(engineBuilds, 2, reason: 'the default engine factory was used');
    expect((await notes.get('n1'))?['text'], 'hi');
  });
}
