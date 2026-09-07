import 'package:crdt/crdt.dart';

import 'collection.dart';
import 'database.dart';
import 'encrypted_store.dart';
import 'ports/blob_store.dart';
import 'ports/cipher.dart';
import 'ports/key_store.dart';
import 'ports/transport.dart';

part 'builder.dart';

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

/// Thrown by [Conclave.openDatabase] when [PassphrasePolicy.strictness] is
/// [PassphraseStrictness.reject] and the supplied passphrase is not a valid
/// BIP39 mnemonic with known entropy.
///
/// The exception is thrown **before** any key derivation or storage write, so
/// no keys are written to the [KeyStore] on rejection.
class WeakPassphraseException implements Exception {
  const WeakPassphraseException();

  @override
  String toString() =>
      'WeakPassphraseException: passphrase is not a valid BIP39 mnemonic';
}

/// How [Conclave.openDatabase] treats a passphrase that is not a recognised BIP39
/// mnemonic.
enum PassphraseStrictness {
  /// Accept any string. The app is responsible for vetting entropy.
  warn,

  /// Throw [WeakPassphraseException] unless the passphrase is a valid BIP39
  /// mnemonic.
  ///
  /// This gate accepts **only** valid BIP39 mnemonics; it cannot recognise a
  /// high-entropy non-mnemonic string. Apps that want to allow long random
  /// strings must stay on [warn] and vet entropy themselves.
  reject,
}

/// Passphrase word-count and strictness policy.
///
/// The word count maps directly to BIP39 entropy strength:
/// 12 = 128 bit, 15 = 160 bit, 18 = 192 bit, 21 = 224 bit, 24 = 256 bit
/// (default).
class PassphrasePolicy {
  const PassphrasePolicy({
    this.words = 24,
    this.strictness = PassphraseStrictness.warn,
  });

  /// Number of mnemonic words to generate. Must be 12, 15, 18, 21, or 24.
  final int words;

  /// How [Conclave.openDatabase] treats a passphrase that is not a recognised
  /// BIP39 mnemonic. Defaults to [PassphraseStrictness.warn] (allow, but it is
  /// the app's responsibility to vet entropy). Set to [PassphraseStrictness.reject]
  /// to force callers through the generated-mnemonic path.
  final PassphraseStrictness strictness;
}

/// Top-level configuration for a [Conclave] instance.
class ConclaveConfig {
  const ConclaveConfig({
    required this.appId,
    required this.salt,
    this.passphrasePolicy = const PassphrasePolicy(),
    this.compactionHorizon = const Duration(days: 30),
    this.maxInboundFramesPerSecond = 100,
  });

  /// Scopes mDNS discovery and storage namespacing for this app.
  final String appId;

  /// App-wide PBKDF2 salt. The same passphrase with different salts produces
  /// different keys — use a stable, app-specific string such as `"myapp:v1"`.
  final String salt;

  /// Passphrase generation policy.
  final PassphrasePolicy passphrasePolicy;

  /// Tombstones (deleted documents and removed fields) older than this are
  /// eligible for physical compaction. Must comfortably exceed the longest time
  /// any peer is expected to stay offline, or compaction can resurrect deleted
  /// data when that peer reconnects. Compaction never runs automatically; call
  /// [Database.compact] explicitly. Defaults to 30 days.
  final Duration compactionHorizon;

  /// Max inbound frames per second per peer before rate limiting kicks in.
  ///
  /// Frames from a peer that exceed this rate are silently dropped. This is a
  /// defence-in-depth measure against a misbehaving or flooded peer; under the
  /// LAN-only threat model a trusted-key peer is already inside the trust
  /// boundary, so this is not a security boundary — it prevents a single noisy
  /// peer from starving the inbound event loop.
  final int maxInboundFramesPerSecond;
}

/// The app-level handle for Conclave.
///
/// Build one with [Conclave.builder] and share it across the app. It owns
/// exactly one [Transport] and any number of open [Database] instances.
///
/// ```dart
/// final conclave = await Conclave.builder(
///   appId: 'notes',
///   salt: 'notes:v1',
/// ).open();
/// ```
///
/// [Conclave.lowLevel] is the same wiring with every dependency passed
/// explicitly, for custom adapters or tests.
class Conclave {
  Conclave._({
    required ConclaveConfig config,
    required BlobStore Function(String) storeFactory,
    required KeyStore keyStore,
    required Transport transport,
    required NodeId nodeId,
    required Future<List<int>> Function(String, String) deriveKey,
    required String Function(List<int>) roomTag,
    required Cipher Function(List<int>) cipherFactory,
    required List<String> Function(int words) mnemonicGenerator,
    required IdMasker Function(List<int>) idMaskerFactory,
    required bool Function(String) validateMnemonic,
  })  : _config = config,
        _storeFactory = storeFactory,
        _keyStore = keyStore,
        _transport = transport,
        _nodeId = nodeId,
        _deriveKey = deriveKey,
        _roomTag = roomTag,
        _cipherFactory = cipherFactory,
        _mnemonicGenerator = mnemonicGenerator,
        _idMaskerFactory = idMaskerFactory,
        _validateMnemonic = validateMnemonic;

  final ConclaveConfig _config;
  final BlobStore Function(String) _storeFactory;
  final KeyStore _keyStore;
  final Transport _transport;
  final NodeId _nodeId;
  final Future<List<int>> Function(String, String) _deriveKey;
  final String Function(List<int>) _roomTag;
  final Cipher Function(List<int>) _cipherFactory;
  final List<String> Function(int words) _mnemonicGenerator;
  final IdMasker Function(List<int>) _idMaskerFactory;
  final bool Function(String) _validateMnemonic;

  final Map<String, Database> _databases = {};
  final Set<PeerId> _connectedPeers = {};

  // Per-peer sliding-window timestamps (ms since epoch) for inbound rate
  // limiting. Cleaned up on peer disconnect.
  final Map<PeerId, List<int>> _inboundTimestamps = {};

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

    if (_config.passphrasePolicy.strictness == PassphraseStrictness.reject &&
        !_validateMnemonic(passphrase)) {
      throw const WeakPassphraseException();
    }

    final entryKey = '${_config.appId}/$localId';
    final key = await _deriveKey(passphrase, _config.salt);

    // Detect and resolve any interrupted rotation — senses whether the caller
    // supplied the old or new passphrase and either reverses or completes the
    // rotation accordingly.
    await _recoverInterruptedRotation(entryKey, localId, key: key);

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

    // Complete any interrupted rotation forward before opening the store so
    // the rotation eventually isolates this peer (security rotations must not
    // silently revert on restart).
    await _recoverInterruptedRotation(entryKey, localId);

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

  /// Returns `true` if [rotatePassphrase] was interrupted for [localId] and a
  /// crash-recovery pass has not yet resolved it.
  ///
  /// Use this to detect that a previous rotation attempt crashed. After a
  /// successful [openDatabase] or [reopenDatabase] call the pending state is
  /// always resolved, so this will return `false`.
  Future<bool> hasPendingRotation(String localId) async {
    final entryKey = '${_config.appId}/$localId';
    return await _keyStore.getKey('$entryKey.rotate_new') != null;
  }

  /// Re-encrypts the local data of [localId] with a key derived from
  /// [newPassphrase] instead of [oldPassphrase].
  ///
  /// Derives both keys, validates [oldPassphrase] against the stored data,
  /// decrypts every blob with the old key and re-encrypts it with the new key,
  /// then stores the new key in the [KeyStore]. If the database is currently
  /// open it is closed first — call [openDatabase] or [reopenDatabase] with
  /// the new passphrase to resume.
  ///
  /// Throws [WrongPassphraseException] if the [oldPassphrase] does not match
  /// the existing data.
  ///
  /// ## Crash safety
  ///
  /// Both keys are stored in the [KeyStore] before re-encryption starts
  /// (`"<entryKey>.rotate_backup"` and `"<entryKey>.rotate_new"`). If the
  /// process is interrupted:
  ///
  /// - Call [openDatabase] with **either** the old or the new passphrase — the
  ///   recovery path senses which key was supplied and either reverses the
  ///   partial rotation (old passphrase) or completes it (new passphrase).
  /// - Call [reopenDatabase] without a passphrase — the rotation is always
  ///   **completed forward** so that security rotations are never silently
  ///   reverted on restart.
  /// - Use [hasPendingRotation] to detect whether a rotation was interrupted
  ///   before opening.
  ///
  /// No data is lost and no passphrase is forgotten.
  Future<void> rotatePassphrase(
    String localId, {
    required String oldPassphrase,
    required String newPassphrase,
  }) async {
    final entryKey = '${_config.appId}/$localId';

    // Close the database if it is open so the store is not in use.
    final db = _databases.remove(localId);
    if (db != null) {
      await db.close();
    }

    // Derive both keys.
    final oldKey = await _deriveKey(oldPassphrase, _config.salt);
    final newKey = await _deriveKey(newPassphrase, _config.salt);

    final oldCipher = _cipherFactory(oldKey);
    final newCipher = _cipherFactory(newKey);

    // Open the raw store and re-encrypt every blob.
    final store = _storeFactory(localId);
    await store.open();
    try {
      final blobKeys = await store.keys();
      if (blobKeys.isNotEmpty) {
        // Validate: try old key, then new key (handles interrupted rotation).
        final first = await store.read(blobKeys.first);
        if (first != null) {
          final oldWorks = await _tryDecrypt(oldCipher, first);
          final newWorks = await _tryDecrypt(newCipher, first);
          if (!oldWorks && !newWorks) {
            throw const WrongPassphraseException();
          }
          // Even when validation passes via the new key (interrupted state),
          // verify the caller knows the current primary key so a wrong old
          // passphrase is never stored as the recovery anchor.
          final storedKey = await _keyStore.getKey(entryKey);
          if (storedKey != null && !_keysEqual(oldKey, storedKey)) {
            throw const WrongPassphraseException();
          }
        }
      }

      // Store both keys before touching data so recovery can reverse a
      // partial re-encryption after a crash.
      await _keyStore.setKey('$entryKey.rotate_backup', oldKey);
      await _keyStore.setKey('$entryKey.rotate_new', newKey);

      await _rekeyStore(store, oldCipher, newCipher);

      // Atomically flip: new key becomes primary, temp keys removed.
      // rotate_new is cleared before rotate_backup so a crash between the
      // two clears never orphans rotate_new (which would make
      // hasPendingRotation permanently lie).
      await _keyStore.setKey(entryKey, newKey);
      await _keyStore.clear('$entryKey.rotate_new');
      await _keyStore.clear('$entryKey.rotate_backup');
    } finally {
      await store.close();
    }
  }

  /// Compares two key byte-lists for equality.
  bool _keysEqual(List<int> a, List<int> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Returns `true` if [cipher] can successfully decrypt [encrypted].
  Future<bool> _tryDecrypt(Cipher cipher, List<int> encrypted) async {
    try {
      await cipher.decrypt(encrypted);
      return true;
    } on CipherAuthError {
      return false;
    }
  }

  /// Re-encrypts every blob in [store] from [fromCipher] to [toCipher].
  ///
  /// For each blob, tries [fromCipher] first; if that fails falls back to
  /// [toCipher] (the blob was already re-encrypted on a prior attempt). If
  /// both fail the blob is corrupt or encrypted with an unknown key — it is
  /// silently skipped so a single bad entry does not permanently brick the
  /// database.
  Future<void> _rekeyStore(
    BlobStore store,
    Cipher fromCipher,
    Cipher toCipher,
  ) async {
    final blobKeys = await store.keys();
    for (final bk in blobKeys) {
      final encrypted = await store.read(bk);
      if (encrypted == null) continue;
      List<int> plaintext;
      try {
        plaintext = await fromCipher.decrypt(encrypted);
      } on CipherAuthError {
        try {
          plaintext = await toCipher.decrypt(encrypted);
        } on CipherAuthError {
          continue;
        }
      }
      await store.write(bk, await toCipher.encrypt(plaintext));
    }
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

  /// If [rotatePassphrase] was interrupted, re-encrypts every blob to match
  /// whichever key best serves the caller.
  ///
  /// When [key] is `null` (i.e. the caller is [reopenDatabase]), the rotation
  /// is always **completed forward** — security rotations must not silently
  /// revert. When [key] is provided the method senses which passphrase was
  /// supplied and either reverses (old passphrase) or completes (new
  /// passphrase) the rotation accordingly.
  ///
  /// The re-encryption loop is idempotent: blobs already encrypted with the
  /// target key are decrypted with that same key and re-encrypted (a no-op).
  ///
  /// Returns `true` when recovery was performed, `false` when no interrupted
  /// rotation was detected.
  Future<bool> _recoverInterruptedRotation(
    String entryKey,
    String localId, {
    List<int>? key,
  }) async {
    final rotateNewKey = await _keyStore.getKey('$entryKey.rotate_new');
    if (rotateNewKey == null) return false;

    final rotateBackupKey = await _keyStore.getKey('$entryKey.rotate_backup');
    if (rotateBackupKey == null) return false;

    final bool continueForward;
    if (key == null) {
      // reopenDatabase — no passphrase; always complete forward so that
      // security rotations eventually isolate this peer.
      continueForward = true;
    } else if (_keysEqual(key, rotateNewKey)) {
      continueForward = true;
    } else if (_keysEqual(key, rotateBackupKey)) {
      continueForward = false;
    } else {
      // Key matches neither stored key — nothing to recover.
      return false;
    }

    final fromCipher = continueForward
        ? _cipherFactory(rotateBackupKey)
        : _cipherFactory(rotateNewKey);
    final toCipher = continueForward
        ? _cipherFactory(rotateNewKey)
        : _cipherFactory(rotateBackupKey);

    final store = _storeFactory(localId);
    await store.open();
    try {
      await _rekeyStore(store, fromCipher, toCipher);

      if (continueForward) {
        await _keyStore.setKey(entryKey, rotateNewKey);
      } else {
        await _keyStore.setKey(entryKey, rotateBackupKey);
      }
      // Clear rotate_new first so a crash between the two clears never
      // orphans rotate_new (which would make hasPendingRotation lie).
      await _keyStore.clear('$entryKey.rotate_new');
      await _keyStore.clear('$entryKey.rotate_backup');
    } finally {
      await store.close();
    }
    return true;
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
      idMasker: _idMaskerFactory(key),
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
  /// [ConclaveConfig.passphrasePolicy].
  ///
  /// Delegates to the [mnemonicGenerator] injected at construction.
  List<String> generatePassphrase() =>
      _mnemonicGenerator(_config.passphrasePolicy.words);

  /// Triggers a full bidirectional re-sync on every open database with all
  /// connected peers.
  ///
  /// Each database sends a `Hello` (push its records *to* each peer) followed
  /// by a `Poke` (pull the peer's records *back*). After both exchanges, both
  /// sides converge on the union of their changes. Use this to recover data
  /// that was dropped during a rate-limiting window or after a transient
  /// disconnect.
  Future<void> forceSync() async {
    for (final db in _databases.values) {
      await db.forceSync();
    }
  }

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
      _inboundTimestamps.remove(event.peer);
      for (final db in _databases.values) {
        db.onPeerLost(event.peer);
      }
    }
  }

  /// Returns `true` if [peer] has exceeded the inbound rate limit in the
  /// current one-second sliding window.
  bool _isRateLimited(PeerId peer) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final window = 1000;
    final maxFrames = _config.maxInboundFramesPerSecond;

    final timestamps = _inboundTimestamps.putIfAbsent(peer, () => []);
    // Prune timestamps outside the current window.
    timestamps.removeWhere((t) => now - t > window);

    if (timestamps.length >= maxFrames) return true;
    timestamps.add(now);
    return false;
  }

  Future<void> _onInbound(InboundFrame inbound) async {
    if (_isRateLimited(inbound.from)) return;
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

  /// Starts a staged configuration for a [Conclave] instance.
  ///
  /// Set overrides on the returned [ConclaveBuilder], then `await`
  /// [ConclaveBuilder.open]. Any slot left unset comes from the [ConclaveDefaults]
  /// the `conclave` umbrella installs on import.
  ///
  /// ```dart
  /// final conclave = await Conclave.builder(
  ///   appId: 'shopping',
  ///   salt: 'shopping:v1',
  /// ).open();
  /// ```
  static ConclaveBuilder builder({
    required String appId,
    required String salt,
  }) =>
      ConclaveBuilder._(appId, salt);

  /// Constructs and wires a [Conclave] instance.
  ///
  /// All dependencies are explicit: pass adapters from the other packages or
  /// supply custom implementations that satisfy the port interfaces. Prefer
  /// [builder] unless you need this level of control.
  static Future<Conclave> lowLevel({
    required ConclaveConfig config,
    required BlobStore Function(String databaseId) store,
    required KeyStore keyStore,
    required Transport transport,
    required Future<List<int>> Function(String passphrase, String salt)
        deriveKey,
    required String Function(List<int> key) roomTag,
    required Cipher Function(List<int> key) cipher,
    required List<String> Function(int words) mnemonicGenerator,
    required IdMasker Function(List<int>) idMaskerFactory,
    required bool Function(String) validateMnemonic,
  }) async {
    final nodeId = generateNodeId();

    final instance = Conclave._(
      config: config,
      storeFactory: store,
      keyStore: keyStore,
      transport: transport,
      nodeId: nodeId,
      deriveKey: deriveKey,
      roomTag: roomTag,
      cipherFactory: cipher,
      mnemonicGenerator: mnemonicGenerator,
      idMaskerFactory: idMaskerFactory,
      validateMnemonic: validateMnemonic,
    );
    // Wire listeners BEFORE start so PeerConnected events emitted during
    // registration are not missed.
    instance._wireTransport();
    await transport.start(self: nodeId, appId: config.appId);
    return instance;
  }
}
