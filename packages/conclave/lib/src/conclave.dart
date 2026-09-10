import 'dart:async';

import 'package:crdt/crdt.dart';

import 'database.dart';
import 'identity/device_roster.dart';
import 'identity/pairing.dart';
import 'ports/crdt_table.dart';
import 'ports/cipher.dart';
import 'ports/identity.dart';
import 'ports/key_store.dart';
import 'ports/pake.dart';
import 'ports/transport.dart';
import 'protocol/handshake.dart';

export 'identity/pairing.dart'
    show PairingCode, PairingBundle, PairingRejected, PairingTimeout;

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
    this.snapshotInterval = const Duration(minutes: 30),
    this.recoveryEnabled = false,
    this.antiEntropyInterval = const Duration(minutes: 3),
    this.maxInFlightFrames = 16,
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

  /// How often a disk-backed engine writes a recovery snapshot of each
  /// collection (`<file>.snapshot`).
  ///
  /// If a collection's file is found corrupt on open, the engine restores the
  /// most recent snapshot; failing that it resets to empty and re-syncs from a
  /// peer. Either way a [StoreRecovered] event is emitted on [Conclave.events].
  /// Set to [Duration.zero] to disable snapshots (a peer is then the only way
  /// back). Ignored by the in-memory engine. Defaults to 30 minutes.
  final Duration snapshotInterval;

  /// How often each open database runs an anti-entropy exchange: a `Hello` to
  /// every connected peer, whose replies carry anything either side is
  /// missing. This heals a frame lost to a flaky link or the inbound rate
  /// limiter without a manual [Conclave.forceSync]. [Duration.zero] disables
  /// it (sync is then push-only). Defaults to 3 minutes.
  final Duration antiEntropyInterval;

  /// Maximum frames queued or in flight per peer. A sender streaming a large
  /// changeset to a slow peer pauses at this bound instead of buffering
  /// without limit. Defaults to 16.
  final int maxInFlightFrames;

  /// Whether this app offers a written recovery phrase
  /// ([Conclave.enableRecovery] / [Conclave.recoverFrom]).
  ///
  /// Off by default: "no recovery" is a valid product choice (a lost phrase
  /// and lost devices then mean lost access, by design). When enabled, the app
  /// calls [Conclave.enableRecovery] once after setup, shows the returned
  /// 24-word phrase to the user, and never stores it.
  final bool recoveryEnabled;
}

/// An observable event from a [Conclave] instance. Listen via [Conclave.events].
sealed class ConclaveEvent {
  const ConclaveEvent();
}

/// A peer became reachable on the transport.
final class PeerAppeared extends ConclaveEvent {
  const PeerAppeared(this.peer);

  /// The peer that connected.
  final PeerId peer;
}

/// A peer stopped being reachable.
final class PeerDisappeared extends ConclaveEvent {
  const PeerDisappeared(this.peer);

  /// The peer that disconnected.
  final PeerId peer;
}

/// A peer advertised wire versions that share nothing with this build's.
///
/// The peer is not registered and nothing further is exchanged with it: one of
/// the two apps needs an update before they can sync. Emitted once per
/// connection.
final class PeerIncompatible extends ConclaveEvent {
  /// Creates the event.
  const PeerIncompatible({
    required this.peer,
    required this.localVersions,
    required this.remoteVersions,
  });

  /// The incompatible peer's transport id.
  final PeerId peer;

  /// The wire versions this build speaks.
  final List<int> localVersions;

  /// The wire versions the peer advertised.
  final List<int> remoteVersions;
}

/// A collection's local store was found unreadable on open and rebuilt.
///
/// With [CrdtRecoverySource.snapshot] the last on-disk snapshot was restored;
/// with [CrdtRecoverySource.reset] the store was emptied and a full re-sync
/// from peers was triggered automatically. The unreadable file is kept at
/// [quarantinePath] for inspection.
final class StoreRecovered extends ConclaveEvent {
  const StoreRecovered({
    required this.databaseId,
    required this.collection,
    required this.source,
    required this.quarantinePath,
  });

  /// The local id of the database whose store was rebuilt.
  final String databaseId;

  /// The name of the affected collection.
  final String collection;

  /// Whether a snapshot was restored or the store was reset to empty.
  final CrdtRecoverySource source;

  /// Where the unreadable file was moved.
  final String quarantinePath;
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
    required FutureOr<CrdtTable> Function(
            String databaseId, String collection, List<int> key)
        engineFactory,
    Identity? identity,
    Pake? pake,
    Future<Identity> Function(String phrase, String salt)? recoveryIdentity,
    List<int> wireVersions = supportedWireVersions,
  })  : _config = config,
        _engineFactory = engineFactory,
        _identity = identity,
        _pake = pake,
        _recoveryIdentity = recoveryIdentity,
        _wireVersions = wireVersions,
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
  final FutureOr<CrdtTable> Function(
      String databaseId, String collection, List<int> key) _engineFactory;
  final Identity? _identity;
  final Pake? _pake;
  final Future<Identity> Function(String phrase, String salt)?
      _recoveryIdentity;

  /// The wire versions advertised in every handshake. Overridable (staged
  /// rollouts, incompatibility tests); defaults to [supportedWireVersions].
  final List<int> _wireVersions;

  final Map<String, Database> _databases = {};
  // The key each open database's user data is derived from (group key when an
  // identity is configured, else passphrase-derived). Needed by pairing to
  // share the roster key with a joining device.
  final Map<String, List<int>> _databaseKeys = {};
  final Set<PeerId> _connectedPeers = {};
  final _events = StreamController<ConclaveEvent>.broadcast();

  PairingCoordinator? _pairing;

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
    _databaseKeys.remove(localId);
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
    Cipher cipher, {
    bool allowAutoFound = true,
  }) async {
    final db = await Database.open(
      id: localId,
      room: _roomTag(key),
      cipher: cipher,
      nodeId: _nodeId,
      transport: _transport,
      keyStore: _keyStore,
      entryKey: entryKey,
      baseKey: key,
      identity: _identity,
      cipherFactory: _cipherFactory,
      engineFor: (collection, engineKey) =>
          _buildEngine(localId, collection, engineKey),
      wireVersions: _wireVersions,
      antiEntropyInterval: _config.antiEntropyInterval,
      maxInFlightFrames: _config.maxInFlightFrames,
      onIncompatiblePeer: (peer, local, remote) => _emit(PeerIncompatible(
        peer: peer,
        localVersions: local,
        remoteVersions: remote,
      )),
    );

    _databases[localId] = db;
    _databaseKeys[localId] = key;

    // Announce to peers that were already connected before this database
    // was opened (common when openDatabase is called after transport start).
    final aloneAtOpen = _connectedPeers.isEmpty;
    for (final peer in _connectedPeers) {
      await db.onPeerConnected(peer);
    }

    // With an identity configured, resolve this device's group-key state from
    // the reserved roster collection. A brand-new database with no peers founds
    // its own group key here (first-run path); otherwise the device is
    // `needsPairing` until it is admitted.
    final identity = _identity;
    if (identity != null) {
      await db.initDeviceRoster(identity,
          autoFound: aloneAtOpen && allowAutoFound);
    }

    return db;
  }

  /// Peer-lifecycle ([PeerAppeared] / [PeerDisappeared]) and store-recovery
  /// ([StoreRecovered]) events. Broadcast; safe to ignore.
  Stream<ConclaveEvent> get events => _events.stream;

  /// This device's cryptographic [Identity].
  ///
  /// Throws [StateError] when none was configured — install a
  /// [ConclaveDefaults.identity] (the `conclave` umbrella does) or pass
  /// `identity:` to [Conclave.lowLevel].
  Identity get identity =>
      _identity ??
      (throw StateError(
        'No Identity configured. Use Conclave.builder with an umbrella that '
        'installs one, or pass identity: to Conclave.lowLevel.',
      ));

  // ---------------------------------------------------------------------------
  // Device pairing

  /// Starts sponsoring a device join for the already-open database [localId].
  ///
  /// Returns a one-time [PairingCode] to show the user. The other device calls
  /// [pairWith] with it; a PAKE over the transport authenticates the exchange,
  /// and this device seals the group key to the new one. If [localId] has no
  /// group key yet (a brand-new database), this founds it first.
  ///
  /// Requires a configured [Identity] and PAKE. The armed session is single-use
  /// and replaced by the next [startPairing] call; [cancelPairing] drops it.
  Future<PairingCode> startPairing(
    String localId, {
    String joinerLabel = 'paired device',
  }) async {
    final coordinator = _requirePairing();
    final db = _databases[localId];
    final rosterKey = _databaseKeys[localId];
    if (db == null || rosterKey == null) {
      throw StateError('Open database "$localId" before starting pairing.');
    }
    if (db.deviceState != DeviceState.ready) {
      await db.foundGroup();
    }
    return coordinator.arm(
      rosterKey: rosterKey,
      onAdmit: (joiner) => db.admitDevice(joiner, label: joinerLabel),
    );
  }

  /// Drops an armed pairing session started with [startPairing].
  void cancelPairing() => _pairing?.disarm();

  /// The device roster for the open database [localId] (id, label, paired-at,
  /// revoked, is-this-device). Empty when no [Identity] is configured.
  Future<List<DeviceInfo>> devices(String localId) async =>
      _database(localId).devices();

  /// Renames device [deviceId] in [localId]'s roster.
  Future<void> renameDevice(String localId, String deviceId, String label) =>
      _database(localId).renameDevice(deviceId, label);

  /// Revokes device [deviceId] from [localId]: rotates the group key, re-wraps
  /// it to every other device, and re-keys this database. Peers adopt the new
  /// key on sync; the revoked device can no longer read or write.
  Future<void> revokeDevice(String localId, String deviceId) =>
      _database(localId).revokeDevice(deviceId);

  Database _database(String localId) {
    final db = _databases[localId];
    if (db == null) {
      throw StateError('Database "$localId" is not open.');
    }
    return db;
  }

  /// Joins the database sponsored under [code], opening it locally as [localId].
  ///
  /// Runs the PAKE with the sponsor, receives the roster key, opens the
  /// database, and waits for this device's wrapped group key to arrive by sync
  /// so the returned [Database] is [DeviceState.ready].
  ///
  /// Throws [PairingRejected] (wrong code, too many tries, or the code was
  /// already used) or [PairingTimeout].
  Future<Database> pairWith(String localId, PairingCode code) async {
    final coordinator = _requirePairing();
    if (_databases.containsKey(localId)) {
      throw StateError('Database "$localId" is already open.');
    }
    final joinerKey = await identity.publicKey;
    final bundle = await coordinator.join(code, joinerPublicKey: joinerKey);

    final entryKey = '${_config.appId}/$localId';
    await _keyStore.setKey(entryKey, bundle.rosterKey);
    final db = await _finishOpen(
      localId,
      entryKey,
      bundle.rosterKey,
      _cipherFactory(bundle.rosterKey),
    );

    for (var i = 0; i < 100 && db.deviceState != DeviceState.ready; i++) {
      await db.forceSync();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await db.refreshDeviceState();
    }
    return db;
  }

  // ---------------------------------------------------------------------------
  // Recovery phrase

  /// Mints a recovery phrase for the open database [localId] and registers it
  /// in the roster: 24 BIP39 words whose derived keypair is admitted as a
  /// virtual device holding a wrap of the group key, so a fresh install can
  /// later regain access with [recoverFrom] — even when the device that called
  /// this is gone.
  ///
  /// Returns the words. **Show them to the user once and never store them**;
  /// they are equivalent to a device that can read everything. Calling this
  /// again mints an independent second phrase (each is its own roster entry).
  /// A phrase is withdrawn like a device: pass its device id (labelled
  /// [label] in [devices]) to [revokeDevice].
  ///
  /// Requires [ConclaveConfig.recoveryEnabled], a configured recovery
  /// derivation (see `Conclave.builder` / `recoveryIdentity:` on
  /// [Conclave.lowLevel]), and a database in [DeviceState.ready]; throws
  /// [StateError] otherwise.
  Future<List<String>> enableRecovery(
    String localId, {
    String label = 'recovery phrase',
  }) async {
    final derive = _requireRecovery();
    final db = _database(localId);
    if (db.deviceState != DeviceState.ready) {
      throw StateError(
        'Database "$localId" does not hold the group key '
        '(deviceState is ${db.deviceState}); pair or found it first.',
      );
    }
    final words = _mnemonicGenerator(24);
    final recovery = await derive(words.join(' '), _config.salt);
    await db.admitDevice(await recovery.publicKey, label: label);
    return words;
  }

  /// Regains access to the database [localId] on a fresh install, using a
  /// recovery [phrase] minted by [enableRecovery] plus the database
  /// [passphrase].
  ///
  /// The passphrase unlocks the device roster (its key derives from it); the
  /// roster then syncs from any reachable peer, and the keypair derived from
  /// [phrase] unwraps the group key from its still-valid wrap. This device is
  /// then admitted to the roster as [deviceLabel] and the returned [Database]
  /// is [DeviceState.ready].
  ///
  /// Needs at least one reachable peer that holds the roster (there is no
  /// server to ask). Throws [StateError] when recovery is disabled, when the
  /// phrase's roster entry has been revoked, or when no usable wrap arrives in
  /// time; [ArgumentError] when [phrase] is not a valid mnemonic.
  Future<Database> recoverFrom(
    String localId,
    String phrase, {
    required String passphrase,
    String deviceLabel = 'recovered device',
  }) async {
    final derive = _requireRecovery();
    if (_databases.containsKey(localId)) {
      throw StateError('Database "$localId" is already open.');
    }
    if (!_validateMnemonic(phrase)) {
      throw ArgumentError.value(
        phrase,
        'phrase',
        'not a valid recovery mnemonic',
      );
    }
    final recovery = await derive(phrase, _config.salt);

    final entryKey = '${_config.appId}/$localId';
    final key = await _deriveKey(passphrase, _config.salt);
    await _keyStore.setKey(entryKey, key);
    // Never auto-found here: the group exists elsewhere; founding a fresh key
    // on a briefly-alone install would fork it.
    final db = await _finishOpen(
      localId,
      entryKey,
      key,
      _cipherFactory(key),
      allowAutoFound: false,
    );

    var adopted = false;
    for (var i = 0; i < 100 && !adopted; i++) {
      await db.forceSync();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      adopted = await db.adoptRecovery(recovery, label: deviceLabel);
    }
    if (!adopted) {
      throw StateError(
        'Recovery timed out: no usable wrap for this phrase arrived. Is a '
        'peer that holds the roster reachable?',
      );
    }
    return db;
  }

  Future<Identity> Function(String phrase, String salt) _requireRecovery() {
    final derive = _recoveryIdentity;
    if (!_config.recoveryEnabled || derive == null) {
      throw StateError(
        'Recovery is not enabled for this app. Opt in with '
        'Conclave.builder(...).recovery(enabled: true), or pass '
        'recoveryIdentity: to Conclave.lowLevel with recoveryEnabled in the '
        'config.',
      );
    }
    return derive;
  }

  PairingCoordinator _requirePairing() {
    final pake = _pake;
    if (pake == null) {
      throw StateError(
        'No PAKE configured; pairing is unavailable. Use Conclave.builder with '
        'an umbrella that installs one, or pass pake: to Conclave.lowLevel.',
      );
    }
    return _pairing ??= PairingCoordinator(
      appId: _config.appId,
      pake: pake,
      deriveKey: _deriveKey,
      cipherFactory: _cipherFactory,
      roomTag: _roomTag,
      send: _transport.send,
      peers: () => _connectedPeers,
    );
  }

  /// Builds a collection's backing engine, applies the snapshot interval, and
  /// subscribes to its recovery signal so a rebuilt store surfaces a
  /// [StoreRecovered] event and re-syncs from peers.
  Future<CrdtTable> _buildEngine(
    String localId,
    String collection,
    List<int> key,
  ) async {
    final CrdtTable table = await _engineFactory(localId, collection, key);
    if (table is SnapshotCapable) {
      (table as SnapshotCapable).snapshotInterval = _config.snapshotInterval;
    }
    table.recoveries.listen((recovery) {
      _emit(StoreRecovered(
        databaseId: localId,
        collection: collection,
        source: recovery.source,
        quarantinePath: recovery.quarantinePath,
      ));
      if (recovery.source == CrdtRecoverySource.reset) {
        unawaited(_databases[localId]?.forceSync() ?? Future<void>.value());
      }
    });
    return table;
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
    _pairing?.disarm();
    for (final db in _databases.values) {
      await db.close();
    }
    _databases.clear();
    _databaseKeys.clear();
    await _transport.stop();
    await _events.close();
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
      _emit(PeerAppeared(event.peer));
    } else if (event is PeerLost) {
      _connectedPeers.remove(event.peer);
      _inboundTimestamps.remove(event.peer);
      for (final db in _databases.values) {
        db.onPeerLost(event.peer);
      }
      _emit(PeerDisappeared(event.peer));
    }
  }

  void _emit(ConclaveEvent event) {
    if (!_events.isClosed) _events.add(event);
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

    // A pairing exchange in progress has its own rendezvous room.
    final pairing = _pairing;
    if (pairing != null &&
        pairing.rendezvousRoom == inbound.frame.room &&
        await pairing.handleFrame(inbound.from, inbound.frame.bytes)) {
      return;
    }

    for (final db in _databases.values) {
      if (db.room != inbound.frame.room) continue;
      // The database tries its roster/control cipher and its data cipher; a
      // frame that authenticates with neither (a revoked device after a key
      // rotation) is dropped.
      await db.handleFrame(inbound.from, inbound.frame.bytes);
      return;
    }
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
    required FutureOr<CrdtTable> Function(
            String databaseId, String collection, List<int> key)
        engine,
    Identity? identity,
    Pake? pake,
    Future<Identity> Function(String phrase, String salt)? recoveryIdentity,
    List<int> wireVersions = supportedWireVersions,
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
      engineFactory: engine,
      pake: pake,
      identity: identity,
      recoveryIdentity: recoveryIdentity,
      wireVersions: wireVersions,
    );
    // Wire listeners BEFORE start so PeerConnected events emitted during
    // registration are not missed.
    instance._wireTransport();
    await transport.start(self: nodeId, appId: config.appId);
    return instance;
  }
}
