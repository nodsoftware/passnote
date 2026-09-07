import 'package:crdt/crdt.dart';

import 'database.dart';
import 'ports/cipher.dart';
import 'ports/key_store.dart';
import 'ports/transport.dart';

part 'builder.dart';

/// Thrown when a supplied passphrase does not decrypt a database's existing
/// local data.
///
/// Reserved for the disk-backed engine, which fails to open with the wrong
/// key. The in-memory engine has nothing to validate against, so it does not
/// currently throw this.
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
    required KeyStore keyStore,
    required Transport transport,
    required NodeId nodeId,
    required Future<List<int>> Function(String, String) deriveKey,
    required String Function(List<int>) roomTag,
    required Cipher Function(List<int>) cipherFactory,
    required List<String> Function(int words) mnemonicGenerator,
    required bool Function(String) validateMnemonic,
  })  : _config = config,
        _keyStore = keyStore,
        _transport = transport,
        _nodeId = nodeId,
        _deriveKey = deriveKey,
        _roomTag = roomTag,
        _cipherFactory = cipherFactory,
        _mnemonicGenerator = mnemonicGenerator,
        _validateMnemonic = validateMnemonic;

  final ConclaveConfig _config;
  final KeyStore _keyStore;
  final Transport _transport;
  final NodeId _nodeId;
  final Future<List<int>> Function(String, String) _deriveKey;
  final String Function(List<int>) _roomTag;
  final Cipher Function(List<int>) _cipherFactory;
  final List<String> Function(int words) _mnemonicGenerator;
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
  /// The key is written to the [KeyStore] so the database can later be reopened
  /// via [reopenDatabase] without the passphrase.
  ///
  /// A wrong passphrase is currently not detected here; that check returns with
  /// the disk-backed engine, which fails to open with the wrong key.
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
    final cipher = _cipherFactory(key);
    await _keyStore.setKey(entryKey, key);

    return _finishOpen(localId, entryKey, key, cipher);
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

    return _finishOpen(localId, entryKey, key, cipher);
  }

  /// Permanently forgets [localId]: removes it from the open set and deletes its
  /// encryption key from the [KeyStore].
  Future<void> forget(String localId) async {
    final db = _databases.remove(localId);
    if (db == null) return;
    await db.leave();
  }

  /// Shared tail of [openDatabase] / [reopenDatabase]: builds the [Database],
  /// registers it, and announces it to already-connected peers.
  Future<Database> _finishOpen(
    String localId,
    String entryKey,
    List<int> key,
    Cipher cipher,
  ) async {
    final db = await Database.open(
      id: localId,
      room: _roomTag(key),
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
    required KeyStore keyStore,
    required Transport transport,
    required Future<List<int>> Function(String passphrase, String salt)
        deriveKey,
    required String Function(List<int> key) roomTag,
    required Cipher Function(List<int> key) cipher,
    required List<String> Function(int words) mnemonicGenerator,
    required bool Function(String) validateMnemonic,
  }) async {
    final nodeId = generateNodeId();

    final instance = Conclave._(
      config: config,
      keyStore: keyStore,
      transport: transport,
      nodeId: nodeId,
      deriveKey: deriveKey,
      roomTag: roomTag,
      cipherFactory: cipher,
      mnemonicGenerator: mnemonicGenerator,
      validateMnemonic: validateMnemonic,
    );
    // Wire listeners BEFORE start so PeerConnected events emitted during
    // registration are not missed.
    instance._wireTransport();
    await transport.start(self: nodeId, appId: config.appId);
    return instance;
  }
}
