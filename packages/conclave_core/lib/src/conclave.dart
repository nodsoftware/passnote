import 'package:crdt/crdt.dart';

import 'database.dart';
import 'encrypted_store.dart';
import 'ports/blob_store.dart';
import 'ports/cipher.dart';
import 'ports/hlc_clock.dart';
import 'ports/key_store.dart';
import 'ports/transport.dart';

/// Passphrase word-count policy.
///
/// The word count maps directly to BIP39 entropy strength:
/// 12 = 128 bit, 15 = 160 bit, 18 = 192 bit, 21 = 224 bit, 24 = 256 bit
/// (default).
class PassphrasePolicy {
  const PassphrasePolicy({this.words = 24});

  /// Number of mnemonic words to generate. Must be 12, 15, 18, 21, or 24.
  final int words;
}

/// Top-level configuration for a [Conclave] instance.
class ConclaveConfig {
  const ConclaveConfig({
    required this.appId,
    required this.salt,
    this.passphrase = const PassphrasePolicy(),
  });

  /// Scopes mDNS discovery and storage namespacing for this app.
  final String appId;

  /// App-wide PBKDF2 salt. The same passphrase with different salts produces
  /// different keys — use a stable, app-specific string such as `"myapp:v1"`.
  final String salt;

  /// Passphrase generation policy.
  final PassphrasePolicy passphrase;
}

/// The app-level handle for Conclave.
///
/// Constructed once via [Conclave.open] and shared across the app. Owns
/// exactly one [Transport] and any number of open [Database] instances.
///
/// ```dart
/// final conclave = await Conclave.open(
///   config:    ConclaveConfig(appId: 'notes', salt: 'notes:v1'),
///   store:     (id) => SembastStore(namespace: 'notes/$id'),
///   keyStore:  KeychainKeyStore(appId: 'notes'),
///   transport: LanTransport(),
///   clock:     SystemHlcClock.new,
///   deriveKey: deriveKey,
///   roomTag:   roomTag,
///   cipher:    AesGcmCipher.new,
/// );
/// ```
class Conclave {
  Conclave._({
    required ConclaveConfig config,
    required BlobStore Function(String) storeFactory,
    required KeyStore keyStore,
    required Transport transport,
    required HlcClock clock,
    required NodeId nodeId,
    required Future<List<int>> Function(String, String) deriveKey,
    required String Function(List<int>) roomTag,
    required Cipher Function(List<int>) cipherFactory,
    required List<String> Function(int words) mnemonicGenerator,
  })  : _config = config,
        _storeFactory = storeFactory,
        _keyStore = keyStore,
        _transport = transport,
        _clock = clock,
        _nodeId = nodeId,
        _deriveKey = deriveKey,
        _roomTag = roomTag,
        _cipherFactory = cipherFactory,
        _mnemonicGenerator = mnemonicGenerator;

  final ConclaveConfig _config;
  final BlobStore Function(String) _storeFactory;
  final KeyStore _keyStore;
  final Transport _transport;
  // ignore: unused_field
  final HlcClock _clock;
  final NodeId _nodeId;
  final Future<List<int>> Function(String, String) _deriveKey;
  final String Function(List<int>) _roomTag;
  final Cipher Function(List<int>) _cipherFactory;
  final List<String> Function(int words) _mnemonicGenerator;

  final Map<String, Database> _databases = {};
  final Set<PeerId> _connectedPeers = {};

  // ---------------------------------------------------------------------------
  // Public API

  /// Opens (or re-opens) the database identified by [localId] using
  /// [passphrase] to derive its encryption key and room tag.
  ///
  /// If the database was previously opened with the same passphrase the stored
  /// data is restored. Re-opening with a new passphrase re-encrypts in-place.
  Future<Database> openDatabase(
    String localId, {
    required String passphrase,
  }) async {
    if (_databases.containsKey(localId)) return _databases[localId]!;

    final key = await _deriveKey(passphrase, _config.salt);
    await _keyStore.setKey('${_config.appId}/$localId', key);

    final cipher = _cipherFactory(key);
    final room = _roomTag(key);
    final rawStore = _storeFactory(localId);
    final store = EncryptedStore(rawStore, cipher);

    final db = await Database.open(
      id: localId,
      room: room,
      store: store,
      cipher: cipher,
      nodeId: _nodeId,
      transport: _transport,
    );

    _databases[localId] = db;

    // Announce to peers that were already connected before this database
    // was opened (common when openDatabase is called after transport start).
    for (final peer in _connectedPeers) {
      await db.onPeerConnected(peer);
    }

    return db;
  }

  /// Generates a BIP39 mnemonic of the length configured in
  /// [ConclaveConfig.passphrase].
  ///
  /// Delegates to the [mnemonicGenerator] injected via [Conclave.open].
  List<String> generatePassphrase() =>
      _mnemonicGenerator(_config.passphrase.words);

  /// Closes all open databases and stops the transport.
  Future<void> close() async {
    for (final db in _databases.values) {
      await db.leave();
    }
    _databases.clear();
    await _transport.stop();
  }

  // ---------------------------------------------------------------------------
  // Transport wiring

  void _wireTransport() {
    _transport.events.listen(_onPeerEvent);
    _transport.inbound.listen(_onInbound);
  }

  void _onPeerEvent(PeerEvent event) {
    if (event is PeerConnected) {
      _connectedPeers.add(event.peer);
      for (final db in _databases.values) {
        db.onPeerConnected(event.peer);
      }
    } else if (event is PeerLost) {
      _connectedPeers.remove(event.peer);
      for (final db in _databases.values) {
        db.onPeerLost(event.peer);
      }
    }
  }

  Future<void> _onInbound(InboundFrame inbound) async {
    for (final db in _databases.values) {
      if (db.room != inbound.frame.room) continue;
      List<int> plaintext;
      try {
        // Each database has its own cipher; decrypt and dispatch.
        // We re-derive the cipher from the stored key at open time, so
        // here we call through the database which holds the cipher reference.
        plaintext = await _decryptForDatabase(db, inbound.frame.bytes);
      } catch (_) {
        // Wrong key or tampered frame — silently drop.
        return;
      }
      await db.handlePlaintext(inbound.from, plaintext);
      return;
    }
  }

  Future<List<int>> _decryptForDatabase(
    Database db,
    List<int> ciphertext,
  ) async {
    // The cipher is owned by the Database; expose decryption via a package-
    // internal indirection to avoid making Database.cipher public.
    return db.decryptFrame(ciphertext);
  }

  // ---------------------------------------------------------------------------
  // Factory

  /// Constructs and wires a [Conclave] instance.
  ///
  /// All dependencies are explicit: pass adapters from the other packages or
  /// supply custom implementations that satisfy the port interfaces.
  static Future<Conclave> open({
    required ConclaveConfig config,
    required BlobStore Function(String databaseId) store,
    required KeyStore keyStore,
    required Transport transport,
    required HlcClock Function(NodeId) clock,
    required Future<List<int>> Function(String passphrase, String salt)
        deriveKey,
    required String Function(List<int> key) roomTag,
    required Cipher Function(List<int> key) cipher,
    required List<String> Function(int words) mnemonicGenerator,
  }) async {
    final nodeId = generateNodeId();
    final hlcClock = clock(nodeId);

    final instance = Conclave._(
      config: config,
      storeFactory: store,
      keyStore: keyStore,
      transport: transport,
      clock: hlcClock,
      nodeId: nodeId,
      deriveKey: deriveKey,
      roomTag: roomTag,
      cipherFactory: cipher,
      mnemonicGenerator: mnemonicGenerator,
    );
    // Wire listeners BEFORE start so PeerConnected events emitted during
    // registration are not missed.
    instance._wireTransport();
    await transport.start(self: nodeId, appId: config.appId);
    return instance;
  }
}
