import 'dart:async';
import 'dart:convert';

import 'package:crdt/crdt.dart';

import 'database.dart';
import 'exceptions.dart';
import 'identity/device_roster.dart';
import 'identity/pairing.dart';
import 'ports/crdt_table.dart';
import 'ports/cipher.dart';
import 'ports/identity.dart';
import 'ports/key_store.dart';
import 'ports/pake.dart';
import 'ports/transport.dart';
import 'protocol/handshake.dart';
import 'protocol/reconciliation.dart';

export 'exceptions.dart';
export 'identity/pairing.dart'
    show PairingCode, PairingBundle, PairingRejected, PairingTimeout;

part 'builder.dart';

/// Thrown by [Passnote.openDatabase] when [PassphrasePolicy.strictness] is
/// [PassphraseStrictness.reject] and the supplied passphrase is not a valid
/// BIP39 mnemonic with known entropy.
///
/// The exception is thrown **before** any key derivation or storage write, so
/// no keys are written to the [KeyStore] on rejection.
class WeakPassphraseException implements Exception {
  /// Creates the exception.
  const WeakPassphraseException();

  @override
  String toString() =>
      'WeakPassphraseException: passphrase is not a valid BIP39 mnemonic';
}

/// How [Passnote.openDatabase] treats a passphrase that is not a recognised BIP39
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
  /// Creates a policy.
  const PassphrasePolicy({
    this.words = 24,
    this.strictness = PassphraseStrictness.warn,
  });

  /// Number of mnemonic words to generate. Must be 12, 15, 18, 21, or 24.
  final int words;

  /// How [Passnote.openDatabase] treats a passphrase that is not a recognised
  /// BIP39 mnemonic. Defaults to [PassphraseStrictness.warn] (allow, but it is
  /// the app's responsibility to vet entropy). Set to [PassphraseStrictness.reject]
  /// to force callers through the generated-mnemonic path.
  final PassphraseStrictness strictness;
}

/// Top-level configuration for a [Passnote] instance.
class PassnoteConfig {
  /// Creates a configuration.
  const PassnoteConfig({
    required this.appId,
    required this.salt,
    this.passphrasePolicy = const PassphrasePolicy(),
    this.compactionHorizon = const Duration(days: 30),
    this.maxInboundFramesPerSecond = 100,
    this.snapshotInterval = const Duration(minutes: 30),
    this.recoveryEnabled = false,
    this.antiEntropyInterval = const Duration(minutes: 3),
    this.maxInFlightFrames = 16,
    this.maxClockDrift = const Duration(minutes: 10),
  });

  /// Scopes mDNS discovery and storage namespacing for this app.
  final String appId;

  /// App-wide key-derivation salt (fed to Argon2id by the default deriver).
  /// The same passphrase with different salts produces different keys — use a
  /// stable, app-specific string such as `"myapp:v1"`.
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
  /// The budget is per peer and per [Passnote] instance: a peer syncing
  /// several databases with this instance shares one budget across them.
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
  /// peer. Either way a [StoreRecovered] event is emitted on [Passnote.events].
  /// Set to [Duration.zero] to disable snapshots (a peer is then the only way
  /// back). Ignored by the in-memory engine. Defaults to 30 minutes.
  final Duration snapshotInterval;

  /// How often each open database runs an anti-entropy exchange: a `Hello` to
  /// every connected peer, whose replies carry anything either side is
  /// missing. This heals a frame lost to a flaky link or the inbound rate
  /// limiter without a manual [Passnote.forceSync]. [Duration.zero] disables
  /// it (sync is then push-only). Defaults to 3 minutes.
  final Duration antiEntropyInterval;

  /// Maximum frames queued or in flight per peer. A sender streaming a large
  /// changeset to a slow peer pauses at this bound instead of buffering
  /// without limit. Defaults to 16.
  final int maxInFlightFrames;

  /// How far ahead of this device's clock a received record's timestamp may
  /// be.
  ///
  /// Merging is last-write-wins by hybrid logical clock, so a record stamped
  /// far in the future would beat every later edit, permanently. A record
  /// beyond this bound is refused, together with the rest of its document;
  /// it is not lost, since anti-entropy offers it again and it is accepted
  /// once this device's clock has caught up. Defaults to 10 minutes, which
  /// absorbs ordinary clock skew between devices.
  final Duration maxClockDrift;

  /// Whether this app offers a written recovery phrase
  /// ([Passnote.enableRecovery] / [Passnote.recoverFrom]).
  ///
  /// Off by default: "no recovery" is a valid product choice (a lost phrase
  /// and lost devices then mean lost access, by design). When enabled, the app
  /// calls [Passnote.enableRecovery] once after setup, shows the returned
  /// 24-word phrase to the user, and never stores it.
  final bool recoveryEnabled;
}

/// An observable event from a [Passnote] instance. Listen via [Passnote.events].
sealed class PassnoteEvent {
  const PassnoteEvent();
}

/// A peer became reachable on the transport.
final class PeerAppeared extends PassnoteEvent {
  /// Creates the event.
  const PeerAppeared(this.peer);

  /// The peer that connected.
  final PeerId peer;
}

/// A peer stopped being reachable.
final class PeerDisappeared extends PassnoteEvent {
  /// Creates the event.
  const PeerDisappeared(this.peer);

  /// The peer that disconnected.
  final PeerId peer;
}

/// A peer advertised wire versions that share nothing with this build's.
///
/// The peer is not registered and nothing further is exchanged with it: one of
/// the two apps needs an update before they can sync. Emitted once per
/// connection.
final class PeerIncompatible extends PassnoteEvent {
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

/// The transport reported that peer discovery is unavailable on this
/// platform ([DiscoveryUnavailable] at the transport layer) — typically a
/// missing local-network permission or multicast entitlement.
///
/// Emitted when discovery stops working, and again after each recovery, but
/// never once per failed retry. Show the user guidance (see the platform-setup
/// guide) instead of an empty peer list: without this event, "discovery is
/// blocked" looks exactly like "no peers nearby".
///
/// A transport reports this while it starts, which is inside [Passnote.open] —
/// before any caller holds the object to listen on. Read
/// [Passnote.discoveryUnavailableReason] once after opening to catch that
/// case, then listen for later changes.
final class PeerDiscoveryUnavailable extends PassnoteEvent {
  /// Creates the event.
  const PeerDiscoveryUnavailable({required this.reason});

  /// A short human-readable description of what was refused.
  final String reason;
}

/// Discovery works again after a [PeerDiscoveryUnavailable].
///
/// Take down whatever warning that event raised: peers will appear by
/// themselves from here.
final class PeerDiscoveryRestored extends PassnoteEvent {
  /// Creates the event.
  const PeerDiscoveryRestored();
}

/// An inbound frame was dropped because handling it threw.
///
/// Sync is self-healing (anti-entropy re-delivers anything that mattered), so
/// a single occurrence is harmless — but a steady stream of these on one
/// database points at a bug or a malformed peer and is worth logging.
final class FrameHandlingFailed extends PassnoteEvent {
  /// Creates the event.
  const FrameHandlingFailed({
    required this.peer,
    required this.databaseId,
    required this.error,
  });

  /// The peer whose frame failed.
  final PeerId peer;

  /// The local id of the database the frame was addressed to.
  final String databaseId;

  /// What the handler threw.
  final Object error;
}

/// A collection's local store was found unreadable on open and rebuilt.
///
/// With [CrdtRecoverySource.snapshot] the last on-disk snapshot was restored;
/// with [CrdtRecoverySource.reset] the store was emptied and a full re-sync
/// from peers was triggered automatically. The unreadable file is kept at
/// [quarantinePath] for inspection.
final class StoreRecovered extends PassnoteEvent {
  /// Creates the event.
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

/// The app-level handle for Passnote.
///
/// Build one with [Passnote.builder] and share it across the app. It owns
/// exactly one [Transport] and any number of open [Database] instances.
///
/// ```dart
/// final passnote = await Passnote.builder(
///   appId: 'notes',
///   salt: 'notes:v1',
/// ).open();
/// ```
///
/// [passnoteLowLevel] is the same wiring with every dependency passed
/// explicitly, for custom adapters or tests.
class Passnote {
  Passnote._({
    required PassnoteConfig config,
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
    List<String> wireCapabilities = const [reconCapability],
  })  : _config = config,
        _engineFactory = engineFactory,
        _identity = identity,
        _pake = pake,
        _recoveryIdentity = recoveryIdentity,
        _wireVersions = wireVersions,
        _wireCapabilities = wireCapabilities,
        _keyStore = keyStore,
        _transport = transport,
        _nodeId = nodeId,
        _deriveKey = deriveKey,
        _roomTag = roomTag,
        _cipherFactory = cipherFactory,
        _mnemonicGenerator = mnemonicGenerator,
        _validateMnemonic = validateMnemonic;

  final PassnoteConfig _config;
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

  /// The optional protocol features advertised in every handshake.
  final List<String> _wireCapabilities;

  final Map<String, Database> _databases = {};
  // The key each open database's user data is derived from (group key when an
  // identity is configured, else passphrase-derived). Needed by pairing to
  // share the roster key with a joining device.
  final Map<String, List<int>> _databaseKeys = {};
  final Set<PeerId> _connectedPeers = {};

  String? _discoveryUnavailableReason;
  final _events = StreamController<PassnoteEvent>.broadcast();

  PairingCoordinator? _pairing;

  // Per-peer sliding-window timestamps (ms since epoch) for inbound rate
  // limiting. Cleaned up on peer disconnect.
  final Map<PeerId, List<int>> _inboundTimestamps = {};

  // Per-peer tail of the inbound handling chain: a peer's frames are handled
  // one at a time, in arrival order. A session is established asynchronously
  // from a hello, and the sealed frame right behind that hello must not be
  // tried before the session exists. Cleaned up on peer disconnect.
  final Map<PeerId, Future<void>> _inboundChains = {};

  // Bytes each peer has queued on its chain and not yet handled, and their
  // total. The rate limit caps how many frames a peer may send per second,
  // not how long they take to handle, so a peer sending large frames faster
  // than they decrypt would otherwise queue memory without limit, whether or
  // not it holds a key.
  final Map<PeerId, int> _inboundPendingBytes = {};
  int _inboundPendingTotal = 0;

  /// The most bytes one peer may have waiting to be handled. Far above a
  /// large first sync's backlog; a frame beyond it is dropped like a
  /// rate-limited one, and anti-entropy re-sends what mattered. A peer with
  /// nothing pending may always queue one frame.
  static const int _maxPendingInboundBytesPerPeer = 32 << 20;

  /// The most bytes all peers together may have waiting, so that many
  /// connections cannot multiply the per-peer bound.
  static const int _maxPendingInboundBytes = 128 << 20;

  // ---------------------------------------------------------------------------
  // Public API

  /// Opens the database identified by [localId] using [passphrase] to derive
  /// its encryption key and room tag.
  ///
  /// The key is written to the [KeyStore] **after** a successful open, so the
  /// database can later be reopened via [reopenDatabase] without the
  /// passphrase.
  ///
  /// The derived key is validated against local storage before this method
  /// returns, whether or not an [Identity] is configured: with the
  /// disk-backed engine, a passphrase that does not decrypt existing local
  /// data throws [WrongPassphraseException], the data on disk is left
  /// untouched, and no key is stored, so retrying with the right passphrase
  /// succeeds. The in-memory engine has nothing to validate against and
  /// accepts any passphrase.
  Future<Database> openDatabase(
    String localId, {
    required String passphrase,
  }) async {
    if (_databases.containsKey(localId)) return _databases[localId]!;
    await resumePendingRotation(localId);

    if (_config.passphrasePolicy.strictness == PassphraseStrictness.reject &&
        !_validateMnemonic(passphrase)) {
      throw const WeakPassphraseException();
    }

    final entryKey = '${_config.appId}/$localId';
    final key = await _deriveKey(passphrase, _config.salt);
    final cipher = _cipherFactory(key);

    final db = await _finishOpen(localId, entryKey, key, cipher);
    // Only a key that opened the database is worth keeping: storing it before
    // the open would make every later [reopenDatabase] repeat a wrong
    // passphrase.
    await _keyStore.setKey(entryKey, key);
    return db;
  }

  /// Reopens a database previously opened with [openDatabase], reusing the key
  /// already held in the [KeyStore] — no passphrase required.
  ///
  /// Throws [StateError] if no key is stored for [localId] (i.e. the database
  /// has never been opened on this device, or was [Database.leave]-d).
  Future<Database> reopenDatabase(String localId) async {
    if (_databases.containsKey(localId)) return _databases[localId]!;
    await resumePendingRotation(localId);

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

  // ---------------------------------------------------------------------------
  // Passphrase rotation

  /// Key-store suffix under which a rotation in progress records itself.
  static const String _rotationSuffix = '#rotating';

  /// Whether a passphrase rotation for [localId] was interrupted and has not
  /// been finished.
  ///
  /// True only between the moment [rotatePassphrase] commits to a new key and
  /// the moment it finishes. [openDatabase] and [reopenDatabase] finish such a
  /// rotation before they open anything, so an app that simply opens as usual
  /// never has to act on this — it exists so one can *tell the user* what
  /// happened.
  ///
  /// ```dart
  /// if (await passnote.hasPendingRotation('household')) {
  ///   // Finished automatically on the next open; say so rather than worry.
  /// }
  /// ```
  Future<bool> hasPendingRotation(String localId) async =>
      await _keyStore.getKey(_rotationEntryKey(localId)) != null;

  /// Re-encrypts [localId] under a key derived from [newPassphrase].
  ///
  /// The database must be open, and [oldPassphrase] must be the one it is
  /// open under. Everything the old passphrase protected — the device roster,
  /// and every collection when no [Identity] is configured — is re-encrypted
  /// in place; open [Collection] handles keep working. The group key is not
  /// derived from the passphrase and is left alone, so no user data is
  /// re-encrypted, no device loses its membership, and nothing has to sync.
  ///
  /// ```dart
  /// await passnote.rotatePassphrase(
  ///   'household',
  ///   oldPassphrase: oldWords.join(' '),
  ///   newPassphrase: newWords.join(' '),
  /// );
  /// ```
  ///
  /// **This device only.** The passphrase key is also this database's
  /// discovery [Database.room], so a rotated device stops exchanging frames
  /// with peers that still hold the old one. Every other device has to be
  /// rotated with the same two phrases, or paired again — pairing hands over
  /// whatever key the sponsor currently holds.
  ///
  /// Crash-safe. The new key is written to the [KeyStore] under a pending
  /// entry *before* any store is re-encrypted, so a process that dies halfway
  /// leaves enough behind to finish the job: the next open re-keys whatever
  /// is still on the old key and promotes the new one. A database is never
  /// left unopenable.
  ///
  /// Throws [WrongPassphraseException] when [oldPassphrase] is not the one in
  /// force, [WeakPassphraseException] when [newPassphrase] fails the
  /// configured [PassphrasePolicy], and [StateError] when [localId] is not
  /// open.
  Future<void> rotatePassphrase(
    String localId, {
    required String oldPassphrase,
    required String newPassphrase,
  }) async {
    final db = _database(localId);
    if (_config.passphrasePolicy.strictness == PassphraseStrictness.reject &&
        !_validateMnemonic(newPassphrase)) {
      throw const WeakPassphraseException();
    }

    final entryKey = '${_config.appId}/$localId';
    final current = await _keyStore.getKey(entryKey);
    final oldKey = await _deriveKey(oldPassphrase, _config.salt);
    if (current == null || !_sameKey(current, oldKey)) {
      throw const WrongPassphraseException();
    }
    final newKey = await _deriveKey(newPassphrase, _config.salt);
    if (_sameKey(newKey, oldKey)) return;

    // Journal first. From here on the truth is "one of these two keys opens
    // each store", and finishing is always possible.
    await _keyStore.setKey(
      _rotationEntryKey(localId),
      _encodeRotation(newKey, db.passphraseKeyedCollections),
    );
    await db.adoptPassphraseKey(newKey, newRoom: _roomTag(newKey));
    await _keyStore.setKey(entryKey, newKey);
    _databaseKeys[localId] = newKey;
    await _keyStore.clear(_rotationEntryKey(localId));
  }

  /// Finishes a rotation that was interrupted, if there is one.
  ///
  /// Idempotent, and safe to call when nothing is pending. Called by
  /// [openDatabase] and [reopenDatabase] before they touch a store, which is
  /// why an interrupted rotation is invisible in practice.
  ///
  /// Every journalled store is tried under the key in force and then under the
  /// pending one: whichever opens it decides whether it still has to be
  /// re-encrypted. Throws [StateError] when [localId] is open (close it first)
  /// or when a store opens under neither key.
  Future<void> resumePendingRotation(String localId) async {
    final rotationKey = _rotationEntryKey(localId);
    final journal = await _keyStore.getKey(rotationKey);
    if (journal == null) return;
    if (_databases.containsKey(localId)) {
      throw StateError(
        'Close database "$localId" before finishing its passphrase rotation.',
      );
    }

    final (newKey, collections) = _decodeRotation(journal);
    final entryKey = '${_config.appId}/$localId';
    final current = await _keyStore.getKey(entryKey) ?? newKey;
    for (final collection in collections) {
      await _finishRekey(localId, collection, from: current, to: newKey);
    }
    await _keyStore.setKey(entryKey, newKey);
    _databaseKeys[localId] = newKey;
    await _keyStore.clear(rotationKey);
  }

  /// Re-encrypts one store, or leaves it alone when it is already done.
  Future<void> _finishRekey(
    String localId,
    String collection, {
    required List<int> from,
    required List<int> to,
  }) async {
    if (_sameKey(from, to)) return;
    final stale = await _engineFactory(localId, collection, from);
    try {
      await stale.init();
    } on WrongPassphraseException {
      // Already carried over before the crash. Prove it opens under the new
      // key rather than assuming, so a half-written store is not mistaken for
      // a finished one.
      await stale.close();
      final done = await _engineFactory(localId, collection, to);
      await done.init();
      await done.close();
      return;
    }
    await stale.rekey(to);
    await stale.close();
  }

  String _rotationEntryKey(String localId) =>
      '${_config.appId}/$localId$_rotationSuffix';

  /// The journal: the key being adopted, and what was under the old one.
  List<int> _encodeRotation(List<int> key, List<String> collections) =>
      utf8.encode(jsonEncode({
        'v': 1,
        'key': base64Encode(key),
        'collections': collections,
      }));

  (List<int>, List<String>) _decodeRotation(List<int> journal) {
    final decoded = jsonDecode(utf8.decode(journal)) as Map<String, dynamic>;
    return (
      base64Decode(decoded['key'] as String),
      (decoded['collections'] as List<dynamic>).cast<String>(),
    );
  }

  static bool _sameKey(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Permanently forgets [localId]: removes it from the open set and deletes its
  /// encryption key from the [KeyStore].
  ///
  /// Works on a database that is not open too — including one that no longer
  /// opens, such as after a [RosterPinsCorruptException] — by clearing its
  /// key store entries directly.
  Future<void> forget(String localId) async {
    _databaseKeys.remove(localId);
    final db = _databases.remove(localId);
    if (db != null) {
      await db.leave();
      return;
    }
    final entryKey = '${_config.appId}/$localId';
    await _keyStore.clear(entryKey);
    await _keyStore.clear(Database.rosterPinsKeyFor(entryKey));
    await _keyStore.clear(_rotationEntryKey(localId));
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
      wireCapabilities: _wireCapabilities,
      antiEntropyInterval: _config.antiEntropyInterval,
      maxInFlightFrames: _config.maxInFlightFrames,
      maxClockDrift: _config.maxClockDrift,
      onIncompatiblePeer: (peer, local, remote) => _emit(PeerIncompatible(
        peer: peer,
        localVersions: local,
        remoteVersions: remote,
      )),
    );

    // Force the reserved store open before the database is registered or
    // announced. The disk engine validates its encryption key on open, so a
    // wrong passphrase throws HERE in every configuration — with or without
    // an [Identity] — and openDatabase never returns a database (or stores a
    // key) it has not proven against local storage.
    try {
      await db.openReservedStore();
    } catch (_) {
      await db.close();
      rethrow;
    }

    _databases[localId] = db;
    _databaseKeys[localId] = key;

    try {
      // Announce to peers that were already connected before this database
      // was opened (common when openDatabase is called after transport start).
      final aloneAtOpen = _connectedPeers.isEmpty;
      for (final peer in _connectedPeers) {
        await db.onPeerConnected(peer);
      }

      // With an identity configured, resolve this device's group-key state
      // from the reserved roster collection. A brand-new database with no
      // peers founds its own group key here (first-run path); otherwise the
      // device is `needsPairing` until it is admitted.
      final identity = _identity;
      if (identity != null) {
        await db.initDeviceRoster(identity,
            autoFound: aloneAtOpen && allowAutoFound);
      }
    } catch (_) {
      // A database that failed mid-open must not stay registered: a later
      // openDatabase would hand back the broken instance without
      // re-validating anything.
      _databases.remove(localId);
      _databaseKeys.remove(localId);
      await db.close();
      rethrow;
    }

    return db;
  }

  /// Peer-lifecycle ([PeerAppeared] / [PeerDisappeared] /
  /// [PeerIncompatible]), discovery ([PeerDiscoveryUnavailable]),
  /// store-recovery ([StoreRecovered]), and frame-handling
  /// ([FrameHandlingFailed]) events. Broadcast; safe to ignore, worth
  /// logging.
  Stream<PassnoteEvent> get events => _events.stream;

  /// Why peer discovery is unavailable, or `null` when it works.
  ///
  /// [events] carries the same news as [PeerDiscoveryUnavailable] and
  /// [PeerDiscoveryRestored], but a transport reports its first failure while
  /// it starts — inside [open], before any caller can subscribe — so that one
  /// reaches nobody. This is the state behind those events, readable at any
  /// time. Check it once after opening; listen to [events] for later changes.
  String? get discoveryUnavailableReason => _discoveryUnavailableReason;

  /// This device's cryptographic [Identity].
  ///
  /// Throws [StateError] when none was configured — install a
  /// [PassnoteDefaults.identity] (the `passnote` umbrella does) or pass
  /// `identity:` to [passnoteLowLevel].
  Identity get identity =>
      _identity ??
      (throw StateError(
        'No Identity configured. Use Passnote.builder with an umbrella that '
        'installs one, or pass identity: to passnoteLowLevel.',
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
      onAdmit: (joiner) async {
        await db.admitDevice(joiner, label: joinerLabel);
        return db.exportRosterPins();
      },
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
    // The sponsor's trust state, adopted before the first sync: the roster
    // this device then receives is judged against the founder and members
    // the sponsor vouched for, not against whichever roster arrives first.
    await _keyStore.setKey(
      Database.rosterPinsKeyFor(entryKey),
      bundle.rosterPins,
    );
    // Never auto-found here: the group exists; founding a fresh key on a
    // briefly-alone install would fork it.
    final db = await _finishOpen(
      localId,
      entryKey,
      bundle.rosterKey,
      _cipherFactory(bundle.rosterKey),
      allowAutoFound: false,
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
  /// Requires [PassnoteConfig.recoveryEnabled], a configured recovery
  /// derivation (see `Passnote.builder` / `recoveryIdentity:` on
  /// [passnoteLowLevel]), and a database in [DeviceState.ready]; throws
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
        'Passnote.builder(...).recovery(enabled: true), or pass '
        'recoveryIdentity: to passnoteLowLevel with recoveryEnabled in the '
        'config.',
      );
    }
    return derive;
  }

  PairingCoordinator _requirePairing() {
    final pake = _pake;
    if (pake == null) {
      throw StateError(
        'No PAKE configured; pairing is unavailable. Use Passnote.builder with '
        'an umbrella that installs one, or pass pake: to passnoteLowLevel.',
      );
    }
    return _pairing ??= PairingCoordinator(
      appId: _config.appId,
      pake: pake,
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
  /// [PassnoteConfig.passphrasePolicy].
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
      _inboundChains.remove(event.peer);
      _inboundPendingTotal -= _inboundPendingBytes.remove(event.peer) ?? 0;
      for (final db in _databases.values) {
        db.onPeerLost(event.peer);
      }
      _emit(PeerDisappeared(event.peer));
    } else if (event is DiscoveryUnavailable) {
      _discoveryUnavailableReason = event.reason;
      _emit(PeerDiscoveryUnavailable(reason: event.reason));
    } else if (event is DiscoveryRestored) {
      _discoveryUnavailableReason = null;
      _emit(const PeerDiscoveryRestored());
    }
  }

  void _emit(PassnoteEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  /// Returns `true` if [peer] has exceeded the inbound rate limit in the
  /// current one-second sliding window.
  bool _isRateLimited(PeerId peer) {
    final now = DateTime.now().millisecondsSinceEpoch;
    const window = 1000;
    final maxFrames = _config.maxInboundFramesPerSecond;

    final timestamps = _inboundTimestamps.putIfAbsent(peer, () => []);
    // Prune timestamps outside the current window.
    timestamps.removeWhere((t) => now - t > window);

    if (timestamps.length >= maxFrames) return true;
    timestamps.add(now);
    return false;
  }

  void _onInbound(InboundFrame inbound) {
    if (_isRateLimited(inbound.from)) return;
    final peer = inbound.from;
    final size = inbound.frame.bytes.length;
    final pending = _inboundPendingBytes[peer] ?? 0;
    if (pending > 0 &&
        (pending + size > _maxPendingInboundBytesPerPeer ||
            _inboundPendingTotal + size > _maxPendingInboundBytes)) {
      return;
    }
    _inboundPendingBytes[peer] = pending + size;
    _inboundPendingTotal += size;
    final tail = _inboundChains[peer] ?? Future<void>.value();
    // A failure is contained here: it must neither stop this peer's later
    // frames nor surface as an unhandled async error.
    final next =
        tail.then((_) => _handleInbound(inbound)).catchError((Object _) {});
    _inboundChains[peer] = next;
    unawaited(
      next.whenComplete(() {
        // The peer may have disconnected (and its count been dropped) since.
        final held = _inboundPendingBytes[peer];
        if (held != null) {
          final left = held - size;
          _inboundPendingTotal -= size;
          if (left > 0) {
            _inboundPendingBytes[peer] = left;
          } else {
            _inboundPendingBytes.remove(peer);
          }
        }
        if (identical(_inboundChains[peer], next)) _inboundChains.remove(peer);
      }),
    );
  }

  Future<void> _handleInbound(InboundFrame inbound) async {
    // A pairing exchange in progress has its own rendezvous room.
    final pairing = _pairing;
    if (pairing != null &&
        pairing.rendezvousRoom == inbound.frame.room &&
        await pairing.handleFrame(inbound.from, inbound.frame.bytes)) {
      return;
    }

    for (final db in _databases.values) {
      if (db.room != inbound.frame.room) continue;
      // The database opens the frame under the peer's session or its
      // roster/control cipher; one that opens under neither is dropped, and
      // a plain frame carries no user data. This is remote-fed input: a
      // throw from deeper
      // handling must never become an unhandled async error (the transport's
      // onError does not catch throws from inside this async callback), but
      // it must not vanish either — a persistent failure is a signal.
      try {
        await db.handleFrame(inbound.from, inbound.frame.bytes);
      } catch (error) {
        _emit(FrameHandlingFailed(
          peer: inbound.from,
          databaseId: db.id,
          error: error,
        ));
      }
      return;
    }
  }

  // ---------------------------------------------------------------------------
  // Factory

  /// Starts a staged configuration for a [Passnote] instance.
  ///
  /// Set overrides on the returned [PassnoteBuilder], then `await`
  /// [PassnoteBuilder.open]. Any slot left unset comes from the [PassnoteDefaults]
  /// the `passnote` umbrella installs on import.
  ///
  /// ```dart
  /// final passnote = await Passnote.builder(
  ///   appId: 'shopping',
  ///   salt: 'shopping:v1',
  /// ).open();
  /// ```
  static PassnoteBuilder builder({
    required String appId,
    required String salt,
  }) =>
      PassnoteBuilder._(appId, salt);
}

/// Constructs and wires a [Passnote] instance with every dependency explicit.
///
/// Part of the advanced `package:passnote/engine.dart` surface, not the frozen
/// app-facing library: pass adapters from the other packages or supply custom
/// implementations that satisfy the port interfaces. Prefer [Passnote.builder]
/// unless you need this level of control.
Future<Passnote> passnoteLowLevel({
  required PassnoteConfig config,
  required KeyStore keyStore,
  required Transport transport,
  required Future<List<int>> Function(String passphrase, String salt) deriveKey,
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
  List<String> wireCapabilities = const [reconCapability],
}) async {
  final nodeId = generateNodeId();

  final instance = Passnote._(
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
    wireCapabilities: wireCapabilities,
  );
  // Wire listeners BEFORE start so PeerConnected events emitted during
  // registration are not missed.
  instance._wireTransport();
  await transport.start(self: nodeId, appId: config.appId);
  return instance;
}
