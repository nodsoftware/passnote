import 'package:crdt/crdt.dart';

import 'database.dart';
import 'encrypted_store.dart';
import 'ports/blob_store.dart';
import 'ports/cipher.dart';
import 'ports/hlc_clock.dart';
import 'ports/key_store.dart';
import 'ports/transport.dart';

/// Thrown by [Conclave.openDatabase] when the supplied passphrase does not
/// decrypt the database's existing local data.
///
/// The previously stored key is left untouched, so reopening with the correct
/// passphrase still works. This guards against a typo silently replacing a
/// valid key with a wrong one (which would orphan the data).
class WrongPassphraseException implements Exception {
  const WrongPassphraseException();

  @override
  String toString() =>
      'WrongPassphraseException: passphrase does not match existing data';
}

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

  /// Opens the database identified by [localId] using [passphrase] to derive
  /// its encryption key and room tag.
  ///
  /// If the database already has local data, the derived key is validated
  /// against it before anything is stored: a passphrase that does not decrypt
  /// the existing data throws [WrongPassphraseException] and leaves the
  /// previously stored key intact. On success the key is (re)written to the
  /// [KeyStore] so the database can later be reopened via [reopenDatabase]
  /// without the passphrase.
  Future<Database> openDatabase(
    String localId, {
    required String passphrase,
  }) async {
    if (_databases.containsKey(localId)) return _databases[localId]!;

    final entryKey = '${_config.appId}/$localId';
    final key = await _deriveKey(passphrase, _config.salt);
    final cipher = _cipherFactory(key);
    final store = EncryptedStore(_storeFactory(localId), cipher);
    await store.open();

    // Validate before overwriting the stored key (Bug #2): a wrong passphrase
    // must never clobber a good key.
    await _validateKey(store);
    await _keyStore.setKey(entryKey, key);

    return _finishOpen(localId, entryKey, key, cipher, store);
  }

  /// Reopens a database previously opened with [openDatabase], reusing the key
  /// already held in the [KeyStore] — no passphrase required.
  ///
  /// Throws [StateError] if no key is stored for [localId] (i.e. the database
  /// has never been opened on this device, or was [Database.leave]-d).
  Future<Database> reopenDatabase(String localId) async {
    if (_databases.containsKey(localId)) return _databases[localId]!;

    final entryKey = '${_config.appId}/$localId';
    final key = await _keyStore.getKey(entryKey);
    if (key == null) {
      throw StateError(
        'No stored key for "$localId"; call openDatabase with a passphrase '
        'first.',
      );
    }
    final cipher = _cipherFactory(key);
    final store = EncryptedStore(_storeFactory(localId), cipher);
    await store.open();

    return _finishOpen(localId, entryKey, key, cipher, store);
  }

  /// Permanently forgets [localId]: removes it from the open set and deletes its
  /// encryption key from the [KeyStore]. The on-disk data becomes unreadable
  /// until reopened with the original passphrase.
  Future<void> forget(String localId) async {
    final db = _databases.remove(localId);
    if (db == null) return;
    await db.leave();
  }

  /// Decrypts one existing blob to confirm [store]'s cipher key is correct.
  /// No-ops on a fresh database (nothing stored yet).
  Future<void> _validateKey(EncryptedStore store) async {
    final keys = await store.keys();
    if (keys.isEmpty) return;
    try {
      // EncryptedStore.read decrypts; a wrong key throws CipherAuthError.
      await store.read(keys.first);
    } on CipherAuthError {
      throw const WrongPassphraseException();
    }
  }

  /// Shared tail of [openDatabase] / [reopenDatabase]: builds the [Database],
  /// registers it, and announces it to already-connected peers.
  Future<Database> _finishOpen(
    String localId,
    String entryKey,
    List<int> key,
    Cipher cipher,
    EncryptedStore store,
  ) async {
    final db = await Database.open(
      id: localId,
      room: _roomTag(key),
      store: store,
      cipher: cipher,
      nodeId: _nodeId,
      transport: _transport,
      keyStore: _keyStore,
      entryKey: entryKey,
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

  /// Closes all open databases (keeping their keys) and stops the transport.
  ///
  /// Use [forget] to additionally delete a database's key from the [KeyStore].
  Future<void> close() async {
    for (final db in _databases.values) {
      await db.close();
    }
    _databases.clear();
    await _transport.stop();
  }

  // ---------------------------------------------------------------------------
  // Transport wiring

  void _wireTransport() {
    _transport.events.listen(_onPeerEvent, onError: _onStreamError);
    _transport.inbound.listen(_onInbound, onError: _onStreamError);
  }

  // A misbehaving peer or adapter must never escalate to an unhandled zone
  // error. Swallow stream errors here; individual frames are already dropped on
  // decode/decrypt failure.
  void _onStreamError(Object error, StackTrace stack) {}

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
