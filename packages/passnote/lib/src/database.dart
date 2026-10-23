import 'dart:async';
import 'package:crdt/crdt.dart' show CrdtChangeset, Hlc;
import 'package:meta/meta.dart';

import 'codec.dart';
import 'collection.dart';
import 'identity/device_roster.dart';
import 'identity/ratchet.dart';
import 'merge_strategies.dart';
import 'ports/cipher.dart';
import 'ports/crdt_table.dart';
import 'ports/identity.dart';
import 'ports/key_store.dart';
import 'ports/merge_strategy.dart';
import 'ports/transport.dart';
import 'protocol/anti_entropy.dart';
import 'protocol/frame_window.dart';
import 'protocol/handshake.dart';
import 'protocol/messages.dart';
import 'protocol/reconciliation.dart';

/// A shared, encrypted, peer-synced database.
///
/// Open a [Database] by calling [Passnote.openDatabase]. Create typed
/// [Collection]s with [collection]. Call [close] to stop syncing while keeping
/// the key, or [leave] to additionally drop the encryption key from the local
/// key store (a permanent "forget this database" action).
class Database {
  Database._({
    required String id,
    required String room,
    required Cipher cipher,
    required NodeId nodeId,
    required Transport transport,
    required KeyStore keyStore,
    required String entryKey,
    required List<int> baseKey,
    required Identity? identity,
    required Cipher Function(List<int> key) cipherFactory,
    required FutureOr<CrdtTable> Function(String collection, List<int> key)
        engineFor,
    required List<int> wireVersions,
    required List<String> wireCapabilities,
    required Duration antiEntropyInterval,
    required int maxInFlightFrames,
    required Duration maxClockDrift,
    void Function(PeerId peer, List<int> local, List<int> remote)?
        onIncompatiblePeer,
  })  : _id = id,
        _room = room,
        _cipher = cipher,
        _nodeId = nodeId,
        _transport = transport,
        _keyStore = keyStore,
        _entryKey = entryKey,
        _baseKey = baseKey,
        _identity = identity,
        _cipherFactory = cipherFactory,
        _engineFor = engineFor,
        _wireVersions = wireVersions,
        _wireCapabilities = wireCapabilities,
        _maxInFlightFrames = maxInFlightFrames,
        _maxClockDrift = maxClockDrift,
        _onIncompatiblePeer = onIncompatiblePeer {
    _antiEntropy = AntiEntropy(
      interval: antiEntropyInterval,
      exchange: _antiEntropyExchange,
    )..start();
  }

  final String _id;

  /// The public discovery tag this device speaks in for this database.
  ///
  /// Derived from the passphrase key, so it moves when the passphrase is
  /// rotated ([adoptPassphraseKey]).
  String _room;

  /// Encrypts roster and control frames. Rebuilt when the passphrase key
  /// changes.
  Cipher _cipher;
  final NodeId _nodeId;
  final Transport _transport;
  final KeyStore _keyStore;
  final String _entryKey;

  /// The passphrase-derived key. Encrypts the reserved device-roster collection;
  /// also encrypts every user collection when no [Identity] is configured.
  ///
  /// Replaced in place by [adoptPassphraseKey] when the passphrase is rotated.
  List<int> _baseKey;

  /// This device's identity, when the device-keypair model is active. `null`
  /// keeps the legacy behaviour: the passphrase-derived key encrypts everything
  /// and there is no roster.
  final Identity? _identity;

  /// Builds a [Cipher] for a key. Used to rebuild the data cipher when the
  /// group key rotates.
  final Cipher Function(List<int> key) _cipherFactory;

  /// The reserved device roster, present iff [_identity] is set.
  DeviceRoster? _roster;

  /// The group key this device currently holds, or `null` until it is
  /// [DeviceState.ready]. Sessions are rooted in it, and a change of it
  /// (rotation) restarts every session.
  List<int>? _dataKey;

  /// Per-peer forward-secret transport sessions, keyed by [PeerId]. Present
  /// only with an [Identity] and after the signed ephemeral-key exchange with
  /// a non-revoked roster member. With an [Identity], user data, collection
  /// metadata and reconciliation travel only inside a session; outside one a
  /// frame carries nothing but the handshake, ratchet hellos and the roster.
  final Map<PeerId, RatchetSession> _sessions = {};

  /// This side's ephemeral key for each peer, until its session is
  /// established (the private half is destroyed then).
  final Map<PeerId, Future<RatchetEphemeral>> _myEphemeral = {};

  /// This side's signed hello for each peer, cached so a re-send is the same
  /// hello rather than a new handshake.
  final Map<PeerId, Future<RatchetHelloMessage>> _myHello = {};

  /// Each peer's verified ephemeral public key.
  final Map<PeerId, List<int>> _peerEphemeral = {};

  /// The latest hello from a peer whose signer this device cannot vouch for
  /// yet (its roster record has not arrived). Re-checked after roster sync.
  final Map<PeerId, RatchetHelloMessage> _pendingHellos = {};

  /// The wire versions this node advertises in its handshake.
  final List<int> _wireVersions;

  /// The optional protocol features this node advertises in its handshake.
  final List<String> _wireCapabilities;

  /// Called once per peer whose advertised versions share nothing with ours.
  final void Function(PeerId peer, List<int> local, List<int> remote)?
      _onIncompatiblePeer;

  /// Peers whose handshake has been received at least once (bounds the
  /// handshake reply ping-pong to one reply each).
  final Set<PeerId> _handshakeReceived = {};

  /// The wire version negotiated per peer. Sync starts only once present.
  final Map<PeerId, int> _negotiatedVersion = {};

  /// The optional protocol features each peer advertised in its handshake.
  final Map<PeerId, Set<String>> _peerCapabilities = {};

  /// Peers that advertised no common wire version: deregistered, their frames
  /// swallowed, nothing further sent.
  final Set<PeerId> _incompatiblePeers = {};

  /// Cap on outstanding frames per peer ([PassnoteConfig.maxInFlightFrames]).
  final int _maxInFlightFrames;

  /// How far ahead of the local clock an inbound record may be stamped
  /// ([PassnoteConfig.maxClockDrift]).
  final Duration _maxClockDrift;

  /// Per-peer ordered, bounded send queues. Every encrypted frame flows
  /// through its peer's window: FIFO order protects the ratchet chain, and the
  /// bound is the backpressure a slow peer applies to a streaming sender.
  final Map<PeerId, FrameWindow> _sendWindows = {};

  /// The periodic hello exchange that heals dropped frames; stopped on
  /// [close] and [leave].
  late final AntiEntropy _antiEntropy;

  /// Set by [close] and [leave]; stops the pull timer from firing after
  /// engines are disposed.
  bool _closed = false;

  /// Records per delta frame: a changeset larger than this streams as several
  /// frames, split only on document boundaries so a receiver never applies
  /// half a document.
  static const int _maxRecordsPerFrame = 500;

  /// Frame prefix (only when an [Identity] is configured): `0x01` = the payload
  /// is ratchet-wrapped, `0x00` = plain (control / bootstrap).
  static const int _framePlain = 0x00;
  static const int _frameRatcheted = 0x01;

  /// Builds the backing [CrdtTable] for a collection, given the key that
  /// collection's data is encrypted with.
  final FutureOr<CrdtTable> Function(String collection, List<int> key)
      _engineFor;

  // Type-erased collection registry. Values are always Collection<T> for the
  // T supplied by the caller; cast back at retrieval time.
  final Map<String, dynamic> _collections = {};

  // Peers currently in this room.
  final Set<PeerId> _peers = {};

  // Per-collection HLC watermark already pushed via local-write broadcasts.
  // Lets _broadcastCollection send only newer records instead of the whole
  // collection on every put/delete.
  final Map<String, String> _broadcastHwm = {};

  // ---------------------------------------------------------------------------
  // Public API

  /// The local identifier for this database (used as a storage namespace).
  String get id => _id;

  /// The public discovery tag derived from the database key.
  String get room => _room;

  /// Returns (or creates) the typed collection named [name].
  ///
  /// Calling this method twice with the same [name] and compatible [T] returns
  /// the same [Collection] instance; the [merge] argument is honoured only on
  /// the first call that creates the collection. The initial storage load
  /// starts asynchronously; [Collection.put] and [Collection.delete] await it
  /// internally.
  ///
  /// [merge] selects how concurrent edits to the same document are reconciled
  /// (whole-document, per-field, or deep); it defaults to whole-document
  /// last-write-wins.
  ///
  /// [onRemoteConflict] is called during sync for every document that existed
  /// locally before the remote merge and whose key appears in the incoming
  /// changeset. Ignored on repeated calls (the first creation wins, just like
  /// [merge]).
  ///
  /// Throws [StateError] **synchronously** when an [Identity] is configured
  /// and this device is not [DeviceState.ready]: membership is a
  /// precondition for user collections (their key is the group key), and
  /// checking it here lets the call site catch the failure with an ordinary
  /// try/catch instead of meeting it later on the collection's async reads.
  /// Pair the device (or found the group) first.
  Collection<T> collection<T>(
    String name,
    Codec<T> codec, {
    MergeStrategy merge = const ObjectMergeStrategy(),
    List<String> indexedFields = const [],
    void Function(String documentId)? onRemoteConflict,
  }) {
    if (name == kDeviceCollection) {
      throw ArgumentError.value(
        name,
        'name',
        'Collection name "$kDeviceCollection" is reserved for Passnote device '
            'management.',
      );
    }
    if (_identity != null &&
        deviceState != DeviceState.ready &&
        !_collections.containsKey(name)) {
      throw StateError(
        'Database "$_id" needs pairing before collection "$name" can be '
        'opened (deviceState is $deviceState). Pair this device or call '
        'Database.foundGroup() on a new database.',
      );
    }
    return _getOrCreate<T>(
      name,
      codec,
      merge: merge,
      indexedFields: indexedFields,
      onRemoteConflict: onRemoteConflict,
    );
  }

  Collection<T> _getOrCreate<T>(
    String name,
    Codec<T> codec, {
    MergeStrategy merge = const ObjectMergeStrategy(),
    List<String> indexedFields = const [],
    void Function(String documentId)? onRemoteConflict,
  }) {
    if (_collections.containsKey(name)) {
      final existing = _collections[name] as Collection<T>;
      assert(
        existing.mergeType == merge.runtimeType,
        'Collection "$name" was first created with ${existing.mergeType}; '
        'the merge: ${merge.runtimeType} passed now is ignored. Use a '
        'consistent merge strategy for the same collection.',
      );
      return existing;
    }
    // late final allows the closure to capture `col` before it is assigned.
    late final Collection<T> col;
    col = Collection.create<T>(
      name,
      codec,
      merge: merge,
      engine: () => _engineForCollection(name),
      indexedFields: indexedFields,
      onLocalChange: () => _broadcastCollection(col),
      onRemoteConflict: onRemoteConflict,
    );
    _collections[name] = col;
    // A collection whose engine will not open (this device is not paired yet)
    // has nothing to ask for; that failure reaches the app through the
    // collection's own reads, writes, and watches.
    unawaited(_registerPull(col).catchError((Object _) {}));
    return col;
  }

  /// How long a freshly opened collection waits for a peer to send its records
  /// unprompted before asking for them.
  static const Duration _newCollectionPullDelay = Duration(milliseconds: 250);

  /// Collections opened since the last pull round, each with the watermark it
  /// had once loaded. One debounced poke round serves all of them.
  final Map<Collection<dynamic>, String> _pendingPulls = {};
  Timer? _pullTimer;

  /// Registers [col] for a pull round once its initial load completes.
  ///
  /// Peers name the collections they hold in the handshake, so a collection
  /// opened after a peer connected — every collection on a device that has
  /// just paired, and any collection an app opens lazily — is invisible to
  /// that peer until the next anti-entropy round. A poke prompts the peer to
  /// hello, which pulls its records now. The rounds are debounced per
  /// database: an app opening many collections at startup costs one poke per
  /// peer, not one per collection, and a round is skipped entirely when every
  /// registered collection is already receiving records.
  Future<void> _registerPull(Collection<dynamic> col) async {
    await col.ready;
    if (_closed) return;
    _pendingPulls[col] = col.maxHlc;
    _pullTimer?.cancel();
    _pullTimer = Timer(_newCollectionPullDelay, () {
      unawaited(_pullPending().catchError((Object _) {}));
    });
  }

  Future<void> _pullPending() async {
    final pending = Map.of(_pendingPulls);
    _pendingPulls.clear();
    if (_closed || _peers.isEmpty || pending.isEmpty) return;
    final stalled =
        pending.entries.any((entry) => entry.key.maxHlc == entry.value);
    if (!stalled) return;
    for (final peer in _peers.toList()) {
      await _sendPoke(peer);
    }
  }

  /// Picks the encryption key for [name] and builds its engine.
  ///
  /// The reserved roster collection, and every collection when no [Identity] is
  /// configured, use the passphrase-derived key. Otherwise a user collection
  /// uses the unwrapped group key; opening one before this device is paired is
  /// a [StateError].
  FutureOr<CrdtTable> _engineForCollection(String name) {
    if (name == kDeviceCollection || _identity == null) {
      return _engineFor(name, _baseKey);
    }
    final groupKey = _roster?.groupKey;
    if (groupKey == null) {
      throw StateError(
        'Database "$_id" needs pairing before collection "$name" can be '
        'opened (deviceState is ${_roster?.state ?? DeviceState.needsPairing}). '
        'Pair this device or call Database.foundGroup() on a new database.',
      );
    }
    return _engineFor(name, groupKey);
  }

  /// Stops syncing and releases local resources, **keeping** the encryption key
  /// in the [KeyStore] so the database can later be reopened without the
  /// passphrase via [Passnote.reopenDatabase]. Used on normal shutdown.
  Future<void> close() async {
    _closed = true;
    _antiEntropy.stop();
    _pullTimer?.cancel();
    _tearDownSessions();
    for (final col in _collections.values) {
      await (col as Collection<dynamic>).dispose();
    }
  }

  /// Permanently forgets this database: removes its encryption key and the
  /// roster trust pins from the [KeyStore]. After [leave] the data can only be
  /// reopened by re-supplying the original passphrase.
  Future<void> leave() async {
    _closed = true;
    _antiEntropy.stop();
    _pullTimer?.cancel();
    for (final col in _collections.values) {
      await (col as Collection<dynamic>).dispose();
    }
    await _keyStore.clear(_entryKey);
    await _keyStore.clear(_rosterPinsKey);
  }

  /// The [KeyStore] entry holding the device roster's local trust pins.
  String get _rosterPinsKey => rosterPinsKeyFor(_entryKey);

  /// The [KeyStore] entry holding the roster trust pins of the database whose
  /// key lives under [entryKey].
  @internal
  static String rosterPinsKeyFor(String entryKey) => '$entryKey/roster-pins';

  /// Permanently removes tombstoned records older than [horizon] from every
  /// open collection. Returns the total number of records reclaimed across all
  /// collections.
  ///
  /// When [horizon] is `null` it defaults to 30 days. See
  /// [Collection.compact] for the resurrection caveat.
  Future<int> compact({Duration? horizon}) async {
    var total = 0;
    for (final col in _collections.values) {
      total += await (col as Collection<dynamic>)
          .compact(horizon: horizon ?? const Duration(days: 30));
    }
    return total;
  }

  /// Triggers a full bidirectional re-sync with every connected peer.
  ///
  /// Sends a `Hello` to each peer (pushing this node's records *to* the peer)
  /// followed by a `Poke` (prompting the peer to reply with `Hello`, which
  /// pulls the peer's records *back*). After both exchanges, both sides
  /// converge on the union of their changes. Use this to recover data that may
  /// have been lost during a rate-limiting window or after a transient
  /// disconnect.
  Future<void> forceSync() async {
    for (final peer in _peers.toList()) {
      await _sendHello(peer);
      await _sendPoke(peer);
    }
  }

  // ---------------------------------------------------------------------------
  // Device roster (only when an Identity is configured)

  /// This device's position relative to the database's group key.
  ///
  /// [DeviceState.ready] once a valid wrap has been unwrapped;
  /// [DeviceState.needsPairing] until this device is admitted (see
  /// [Passnote.identity] and task-18 pairing); [DeviceState.revoked] if its
  /// roster entry has been revoked. Always [DeviceState.needsPairing] when no
  /// [Identity] is configured.
  DeviceState get deviceState => _roster?.state ?? DeviceState.needsPairing;

  /// The devices in this database's roster, oldest first.
  ///
  /// Empty when no [Identity] is configured.
  Future<List<DeviceRecord>> listDevices() async =>
      _roster?.listDevices() ?? const [];

  /// The roster as [DeviceInfo] (id, label, paired-at, revoked, is-this-device),
  /// oldest first. Empty when no [Identity] is configured.
  Future<List<DeviceInfo>> devices() async => _roster?.devices() ?? const [];

  /// Re-resolves [deviceState] from the roster after sync has delivered new
  /// rows from a peer, adopting a rotated group key if one arrived. Returns the
  /// new state.
  ///
  /// Drive sync first (`await passnote.forceSync()` then let the event loop
  /// settle) so freshly synced rows are visible.
  Future<DeviceState> refreshDeviceState() async {
    final roster = _roster;
    if (roster == null) return DeviceState.needsPairing;
    await roster.reconcile();
    await _applyGroupKey();
    return roster.state;
  }

  /// Founds a brand-new database: generates the random group key and seals it to
  /// this device at epoch 0.
  ///
  /// Only for the very first device. Throws [StateError] if the roster already
  /// carries a wrap (another device founded it — pair this device instead) or if
  /// no [Identity] is configured.
  Future<void> foundGroup({String label = 'this device'}) async {
    final roster = _requireRoster();
    await roster.found(label: label);
    await _applyGroupKey();
  }

  /// Adds [peer] to the roster and seals the current group key to it.
  ///
  /// Called by the pairing flow once a new device has been authenticated.
  /// Requires [deviceState] of [DeviceState.ready].
  Future<void> admitDevice(
    DevicePublicKey peer, {
    required String label,
  }) async {
    final roster = _requireRoster();
    await roster.admit(peer, label: label);
  }

  /// This device's roster trust pins, freshly validated, for a device it is
  /// admitting to adopt ([Passnote.startPairing]).
  @internal
  Future<List<int>> exportRosterPins() => _requireRoster().exportPins();

  /// Unwraps the group key with [recovery] (a keypair derived from a recovery
  /// phrase) and admits this physical device to the roster as [label].
  ///
  /// Returns `false` when the roster holds no wrap for [recovery] yet — the
  /// caller drives sync and retries. Throws [StateError] when [recovery]'s
  /// roster entry has been revoked. Called by [Passnote.recoverFrom].
  @internal
  Future<bool> adoptRecovery(
    Identity recovery, {
    required String label,
  }) async {
    final roster = _requireRoster();
    if (!await roster.adoptVia(recovery, label: label)) return false;
    await _applyGroupKey();
    return true;
  }

  /// Revokes [deviceId]: rotates the group key to the next epoch, re-wraps it to
  /// every other non-revoked device, re-keys this database, and marks the device
  /// revoked. Peers adopt the new epoch on sync; the revoked device drops to
  /// [DeviceState.revoked] and its frames no longer authenticate.
  ///
  /// Requires [deviceState] of [DeviceState.ready].
  Future<void> revokeDevice(String deviceId) async {
    final roster = _requireRoster();
    await roster.revoke(deviceId);
    await _applyGroupKey();
    _broadcastCollection(
        _collections[kDeviceCollection] as Collection<dynamic>);
  }

  /// Changes the label shown for [deviceId] in the roster.
  Future<void> renameDevice(String deviceId, String label) async {
    final roster = _requireRoster();
    await roster.rename(deviceId, label);
    _broadcastCollection(
        _collections[kDeviceCollection] as Collection<dynamic>);
  }

  /// The collections this database keeps under the passphrase-derived key.
  ///
  /// With an [Identity] that is the reserved roster alone — user collections
  /// are under the group key. Without one, the passphrase key carries
  /// everything. Only these have to be re-encrypted when the passphrase
  /// changes, and [Passnote.rotatePassphrase] journals the list so an
  /// interrupted rotation knows what it was in the middle of.
  @internal
  List<String> get passphraseKeyedCollections => [
        for (final name in _collections.keys)
          if (name == kDeviceCollection || _identity == null) name,
      ];

  /// Adopts [newKey] as the passphrase-derived key, in place.
  ///
  /// Re-encrypts every store in [passphraseKeyedCollections] under it, rebuilds
  /// the cipher that seals roster and control frames, and starts speaking in
  /// [newRoom]. Open [Collection] handles stay valid throughout: the engines
  /// are re-keyed, not replaced.
  ///
  /// The group key is untouched — it is not derived from the passphrase — so
  /// user collections, the device roster's contents and this device's
  /// membership all survive a rotation unchanged.
  ///
  /// Called by [Passnote.rotatePassphrase], which owns the crash-safe order of
  /// events around it.
  @internal
  Future<void> adoptPassphraseKey(
    List<int> newKey, {
    required String newRoom,
  }) async {
    for (final name in passphraseKeyedCollections) {
      await (_collections[name]! as Collection<dynamic>).rekeyEngine(newKey);
    }
    _baseKey = List<int>.unmodifiable(newKey);
    _cipher = _cipherFactory(newKey);
    _room = newRoom;
  }

  /// Re-keys every user-collection engine whenever the resolved group key has
  /// changed, and re-runs the ratchet handshake so sessions no longer derive
  /// from the old key. Safe to call repeatedly.
  Future<void> _applyGroupKey() async {
    final key = _roster?.groupKey;
    if (key == null) {
      _dataKey = null;
      _tearDownSessions();
      return;
    }
    if (_dataKey != null && _listEquals(_dataKey!, key)) return;
    _dataKey = List<int>.unmodifiable(key);
    for (final entry in _collections.entries) {
      if (entry.key == kDeviceCollection) continue;
      await (entry.value as Collection<dynamic>).rekeyEngine(key);
    }
    _tearDownSessions();
    for (final peer in _peers) {
      await _kickRatchet(peer);
    }
  }

  void _tearDownSessions() {
    for (final session in _sessions.values) {
      session.dispose();
    }
    _sessions.clear();
    for (final peer in _myEphemeral.keys.toList()) {
      _forgetEphemeral(peer);
    }
    _peerEphemeral.clear();
    _pendingHellos.clear();
  }

  /// Drops (and wipes) this side's ephemeral key and cached hello for [peer].
  void _forgetEphemeral(PeerId peer) {
    _myHello.remove(peer);
    final ephemeral = _myEphemeral.remove(peer);
    if (ephemeral != null) {
      unawaited(ephemeral.then((e) => e.destroy()).catchError((Object _) {}));
    }
  }

  static bool _listEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  DeviceRoster _requireRoster() {
    final roster = _roster;
    if (roster == null) {
      throw StateError(
        'No Identity is configured for this database; the device roster is '
        'unavailable. Use Passnote.builder with an identity, or pass '
        'identity: to passnoteLowLevel.',
      );
    }
    return roster;
  }

  /// Opens the reserved roster collection and awaits its initial load,
  /// forcing the backing engine open. The disk engine validates its
  /// encryption key on open, so this is where a wrong passphrase surfaces —
  /// in every configuration, not only when an [Identity] is present. Called
  /// by [Passnote] before the database is registered or announced.
  @internal
  Future<void> openReservedStore() =>
      _getOrCreate<DeviceRosterEntry>(kDeviceCollection, deviceRosterCodec)
          .ready;

  /// Opens the reserved roster collection and resolves this device's initial
  /// group-key state. Called by [Passnote] right after the database is
  /// registered and known peers announced, when an [Identity] is configured.
  ///
  /// [autoFound] founds the group key when this device is demonstrably alone
  /// (no connected peers), has never held trust pins for this database, and
  /// no device has founded it yet — the first-run path.
  @internal
  Future<void> initDeviceRoster(
    Identity identity, {
    required bool autoFound,
  }) async {
    final col =
        _getOrCreate<DeviceRosterEntry>(kDeviceCollection, deviceRosterCodec);
    // The roster's trust pins (founder, known device keys, revoked ids) are
    // local, monotone state: they must survive restarts or a revoked device
    // could rewrite pre-revocation history against a freshly started peer.
    final pins = await _keyStore.getKey(_rosterPinsKey);
    final roster = DeviceRoster(
      col,
      identity,
      pinBytes: pins,
      savePins: (bytes) => _keyStore.setKey(_rosterPinsKey, bytes),
    );
    _roster = roster;
    await roster.ready;

    final state = await roster.resolve();
    // Only a database this device has never seen founds itself: one with
    // pins already belongs to a group, and founding again would fork it.
    if (state == DeviceState.needsPairing &&
        autoFound &&
        pins == null &&
        await roster.isUnfounded) {
      await roster.found(label: 'this device');
    }
    await _applyGroupKey();
  }

  // ---------------------------------------------------------------------------
  // Engine-internal: called by Passnote

  /// Called when a peer has just connected (or when [Passnote.openDatabase]
  /// discovers already-connected peers).
  @internal
  Future<void> onPeerConnected(PeerId peer) async {
    if (_incompatiblePeers.contains(peer)) return;
    _peers.add(peer);
    // Handshake first: the ratchet and the hello/state/delta exchange start
    // only once a common wire version is negotiated (see [handlePlaintext]).
    await _sendHandshake(peer);
  }

  /// Called when a peer has disconnected. Drops the transport session so a
  /// reconnect derives a fresh ratchet chain.
  @internal
  void onPeerLost(PeerId peer) {
    _peers.remove(peer);
    _sessions.remove(peer)?.dispose();
    _forgetEphemeral(peer);
    _peerEphemeral.remove(peer);
    _pendingHellos.remove(peer);
    // A reconnect renegotiates from scratch — the peer may have upgraded.
    _handshakeReceived.remove(peer);
    _negotiatedVersion.remove(peer);
    _peerCapabilities.remove(peer);
    _incompatiblePeers.remove(peer);
  }

  /// Last time a ratchet re-bootstrap was asked of a peer, so a peer that
  /// keeps sealing does not turn every dropped frame into a fresh hello.
  final Map<PeerId, DateTime> _lastRebootstrap = {};

  /// Last time a repeated hello from a peer was answered, bounding the volley
  /// two peers could otherwise keep up.
  final Map<PeerId, DateTime> _lastDuplicateAnswer = {};

  /// The shortest gap between two re-bootstrap requests to the same peer.
  static const Duration _rebootstrapInterval = Duration(seconds: 2);

  /// Starts the ratchet exchange again after a frame that could not be
  /// opened, clearing this side's half of a session the peer still believes
  /// in.
  void _rebootstrapRatchet(PeerId peer) {
    final now = DateTime.now();
    final last = _lastRebootstrap[peer];
    if (last != null && now.difference(last) < _rebootstrapInterval) return;
    _lastRebootstrap[peer] = now;
    // This side's ephemeral key stays as it is. Minting a fresh one reads to
    // the peer as "it redid its handshake", so the peer drops its session and
    // mints one back, which reads the same way here: the two chase each other
    // and establish a session per round forever. Re-sending the hello already
    // on record asks the peer for its own without disturbing what it holds.
    unawaited(_sendRatchetHello(peer).catchError((Object _) {}));
  }

  /// Kicks off the ratchet handshake with [peer]: sends our hello if no
  /// session exists yet and this device holds the group key.
  Future<void> _kickRatchet(PeerId peer) async {
    if (_sessions.containsKey(peer) || _dataKey == null) return;
    await _sendRatchetHello(peer);
    await _tryEstablishSession(peer);
  }

  /// Sends this side's connection handshake: the wire versions this build
  /// speaks, and its device public key when an identity is configured.
  Future<void> _sendHandshake(PeerId peer) async {
    final identity = _identity;
    await _sendPlain(
      peer,
      HandshakeMessage(
        node: _nodeId,
        versions: _wireVersions,
        capabilities: _wireCapabilities,
        devicePublicKey:
            identity == null ? null : (await identity.publicKey).toBytes(),
      ),
    );
  }

  /// Sends this side's signed hello for [peer]: its ephemeral key for this
  /// connection, tagged with the current group-key generation so the peer
  /// only pairs it against the same key. Re-sending sends the same hello.
  Future<void> _sendRatchetHello(PeerId peer) async {
    final key = _dataKey;
    final identity = _identity;
    if (key == null || identity == null) return;
    final hello = await _myHello.putIfAbsent(
      peer,
      () => _buildRatchetHello(peer, key, identity),
    );
    await _sendPlain(peer, hello);
  }

  Future<RatchetHelloMessage> _buildRatchetHello(
    PeerId peer,
    List<int> key,
    Identity identity,
  ) async {
    final ephemeral = await _myEphemeral.putIfAbsent(
      peer,
      RatchetEphemeral.generate,
    );
    final keyTag = ratchetKeyTag(key);
    final payload = ratchetHelloPayload(
      fromNode: _nodeId,
      toNode: peer,
      deviceId: identity.deviceId,
      keyTag: keyTag,
      ephemeral: ephemeral.publicKey,
    );
    return RatchetHelloMessage(
      node: _nodeId,
      to: peer,
      deviceId: identity.deviceId,
      ephemeral: ephemeral.publicKey,
      keyTag: keyTag,
      signature: await identity.sign(payload),
    );
  }

  /// Whether [hello] is signed by a non-revoked roster member, for this node,
  /// by the transport peer it came from.
  Future<bool> _verifyRatchetHello(
    PeerId from,
    RatchetHelloMessage hello,
  ) async {
    final identity = _identity;
    final roster = _roster;
    if (identity == null || roster == null) return false;
    if (hello.node != from || hello.to != _nodeId) return false;
    final signer = await roster.memberKey(hello.deviceId);
    if (signer == null) return false;
    return identity.verify(
      ratchetHelloPayload(
        fromNode: hello.node,
        toNode: hello.to,
        deviceId: hello.deviceId,
        keyTag: hello.keyTag,
        ephemeral: hello.ephemeral,
      ),
      signature: hello.signature,
      signer: signer,
    );
  }

  Future<void> _handleRatchetHello(
    PeerId from,
    RatchetHelloMessage hello,
  ) async {
    final key = _dataKey;
    // Ignore until we hold the group key, and ignore a hello minted under a
    // different key generation — a stale queued frame, or the other branch
    // of two concurrent rotations that share an epoch number. A session
    // established from it would have a mismatched root and silently drop
    // every frame.
    if (key == null || !_listEquals(hello.keyTag, ratchetKeyTag(key))) {
      return;
    }
    if (!await _verifyRatchetHello(from, hello)) {
      // Possibly a member whose roster record has not reached this device
      // yet: keep the latest one and look again after roster sync. Nothing
      // about the current session changes on an unverified hello.
      if (hello.node == from && hello.to == _nodeId) {
        _pendingHellos[from] = hello;
      }
      return;
    }
    _pendingHellos.remove(from);
    if (_sessions.containsKey(from)) {
      final known = _peerEphemeral[from];
      if (known != null && _listEquals(known, hello.ephemeral)) {
        // The hello this session was built from, sent again. The peer is
        // asking because it never received ours — its copy arrived before
        // it held the group key — and it stays deaf to everything sealed
        // here until it gets one. Answer, at most once per interval so two
        // peers cannot volley.
        final last = _lastDuplicateAnswer[from];
        if (last == null ||
            DateTime.now().difference(last) >= _rebootstrapInterval) {
          _lastDuplicateAnswer[from] = DateTime.now();
          await _sendRatchetHello(from);
        }
        return;
      }
      // A fresh key from a peer we hold a session with: the peer redid its
      // handshake (it adopted the key later than we did) and our session is
      // one-sided. Drop it and pair anew, or every ratcheted frame between
      // us is silently lost.
      _sessions.remove(from)?.dispose();
      _forgetEphemeral(from);
    }
    _peerEphemeral[from] = List<int>.unmodifiable(hello.ephemeral);
    // This side's key is minted by [_sendRatchetHello], so send before
    // trying: establishing first leaves no key of ours on record and no
    // session, and nothing retries.
    await _sendRatchetHello(from);
    await _tryEstablishSession(from);
  }

  /// Re-checks hellos held back for want of a roster record, after roster
  /// rows have arrived.
  Future<void> _retryPendingHellos() async {
    for (final entry in Map.of(_pendingHellos).entries) {
      if (!identical(_pendingHellos[entry.key], entry.value)) continue;
      await _handleRatchetHello(entry.key, entry.value);
    }
  }

  Future<void> _tryEstablishSession(PeerId peer) async {
    if (_sessions.containsKey(peer)) return;
    final pending = _myEphemeral[peer];
    final theirs = _peerEphemeral[peer];
    final groupKey = _dataKey;
    if (pending == null || theirs == null || groupKey == null) return;
    final mine = await pending;
    final shared = await mine.agree(theirs);
    if (shared == null) return;
    // The exchange may have moved on while the agreement ran.
    if (_sessions.containsKey(peer) ||
        !identical(_myEphemeral[peer], pending) ||
        !identical(_peerEphemeral[peer], theirs) ||
        !identical(_dataKey, groupKey)) {
      return;
    }
    final root = deriveRatchetRoot(
      groupKey: groupKey,
      sharedSecret: shared,
      ephemeralA: mine.publicKey,
      ephemeralB: theirs,
      nodeA: _nodeId,
      nodeB: peer,
    );
    shared.fillRange(0, shared.length, 0);
    _sessions[peer] = RatchetSession.establish(
      root: root,
      thisNodeIsLow: _nodeId.compareTo(peer) < 0,
      cipherFactory: _cipherFactory,
    );
    root.fillRange(0, root.length, 0);
    // The private half has done its job; once it is gone no key on this
    // device can rebuild this session's root.
    mine.destroy();
    // User data waits for a session, so ask for it the moment there is one.
    if (_negotiatedVersion.containsKey(peer)) await _sendHello(peer);
  }

  /// Called by [Passnote] for an inbound frame on this database's room.
  ///
  /// With an [Identity], a ratcheted frame opens under the peer's session
  /// and counts as authenticated: the session was rooted in a hello signed
  /// by a non-revoked roster member. A plain frame opens under the
  /// roster/control cipher only, and is allowed to carry nothing but the
  /// handshake, ratchet hellos and the roster (see [handlePlaintext]).
  /// Without an [Identity] the passphrase key is the whole membership, so
  /// what it opens is authenticated. Returns `true` if the frame was handled.
  @internal
  Future<bool> handleFrame(PeerId from, List<int> frame) async {
    // A closed database answers nothing: its engines are disposed, and a
    // reply here would be a frame sent after close(). Swallowed, not passed
    // on — the frame was addressed to this room.
    if (_closed) return true;
    // An incompatible peer's frames are swallowed: addressed to us, not
    // processable, never an error loop.
    if (_incompatiblePeers.contains(from)) return true;
    var payload = frame;
    if (_identity != null) {
      if (payload.isEmpty) return false;
      final kind = payload[0];
      payload = payload.sublist(1);
      if (kind == _frameRatcheted) {
        final session = _sessions[from];
        final inner = await session?.open(payload);
        if (inner == null) {
          // No session at all means the peer seals under one this side never
          // built: its hello arrived before this device held the group key,
          // or under an older generation, and was dropped. The peer cannot
          // tell, and keeps sealing, so everything it sends is lost until the
          // exchange starts again. Ask for that.
          //
          // With a session in hand the frame is instead stale or replayed,
          // and tearing a working session down over one would be the more
          // expensive mistake.
          if (session == null) _rebootstrapRatchet(from);
          return false;
        }
        await handlePlaintext(from, inner, authenticated: true);
        return true;
      }
      if (kind != _framePlain) return false;
    }

    final List<int> plaintext;
    try {
      plaintext = await _cipher.decrypt(payload);
    } catch (_) {
      // Wrong key or tampered: a frame from outside the room.
      return false;
    }
    await handlePlaintext(from, plaintext, authenticated: _identity == null);
    return true;
  }

  /// Dispatches an already-decrypted protocol message.
  ///
  /// [authenticated] is `false` for a frame that only proves knowledge of the
  /// passphrase key — which every device that ever joined holds, revoked ones
  /// included. Such a frame may carry the handshake, ratchet hellos, hello and
  /// poke, and roster rows (which are vetted by signature); its user-collection
  /// deltas, reconciliation and watermarks are ignored.
  @internal
  Future<void> handlePlaintext(
    PeerId from,
    List<int> plaintext, {
    required bool authenticated,
  }) async {
    final msg = decodeMessage(plaintext);
    if (msg == null) return;
    switch (msg) {
      case HelloMessage():
        await _handleHello(from);
      case StateMessage(:final cols):
        await _handleState(from, authenticated ? cols : _rosterOnly(cols));
      case DeltaMessage(:final col, :final records):
        if (!authenticated && col != kDeviceCollection) return;
        await _handleDelta(col, records);
      case PokeMessage():
        await _sendHello(from);
      case RatchetHelloMessage():
        await _handleRatchetHello(from, msg);
      case HandshakeMessage(:final versions, :final capabilities):
        await _handleHandshake(from, versions, capabilities);
      case ReconcileMessage(:final col):
        if (!authenticated && col != kDeviceCollection) return;
        await _handleReconcile(from, msg);
    }
  }

  /// [cols] narrowed to the roster collection.
  static Map<String, String> _rosterOnly(Map<String, String> cols) => {
        if (cols[kDeviceCollection] case final hlc?) kDeviceCollection: hlc,
      };

  /// Negotiates the wire version with [from] and, on success, starts the
  /// ratchet and the sync exchange. Replies once to the first handshake a
  /// peer sends (both sides also send one on connect, so a peer that opened
  /// its database later still gets ours), which bounds the exchange to at
  /// most two frames each.
  Future<void> _handleHandshake(
    PeerId from,
    List<int> versions,
    List<String> capabilities,
  ) async {
    if (_incompatiblePeers.contains(from)) return;
    _peerCapabilities[from] = capabilities.toSet();
    final firstReceipt = _handshakeReceived.add(from);
    if (firstReceipt) await _sendHandshake(from);
    if (_negotiatedVersion.containsKey(from)) return;

    final version = negotiate(_wireVersions, versions);
    if (version == null) {
      _incompatiblePeers.add(from);
      _peers.remove(from);
      _onIncompatiblePeer?.call(
        from,
        List<int>.unmodifiable(_wireVersions),
        List<int>.unmodifiable(versions),
      );
      return;
    }
    _negotiatedVersion[from] = version;
    _peers.add(from);
    // Only a device that holds the current group key can derive a ratchet root;
    // a not-yet-paired device syncs the roster in the clear first.
    if (_identity != null && _dataKey != null) await _kickRatchet(from);
    await _sendHello(from);
  }

  // ---------------------------------------------------------------------------
  // Protocol handlers

  Future<void> _handleHello(PeerId from) async {
    final cols = <String, String>{};
    for (final entry in _collections.entries) {
      final col = entry.value as Collection<dynamic>;
      cols[col.name] = col.maxHlc;
    }
    await _sendEncrypted(from, StateMessage(cols: cols));
  }

  Future<void> _handleState(
    PeerId from,
    Map<String, String> peerCols,
  ) async {
    for (final entry in peerCols.entries) {
      final colName = entry.key;
      final peerHlc = entry.value;
      final col = _collections[colName] as Collection<dynamic>?;
      if (col == null) continue;

      final changeset = await col.getChangeset(sinceHlc: peerHlc);
      if (changeset.isEmpty) continue;

      for (final tableEntry in changeset.entries) {
        // Cast List<CrdtRecord> → List<Map<String,dynamic>>; Hlc values are
        // left as Hlc objects — encodeMessage converts them to strings.
        final records =
            tableEntry.value.map((r) => Map<String, dynamic>.from(r)).toList();
        await _sendDeltas(from, colName, records);
      }
    }
  }

  Future<void> _handleDelta(
    String colName,
    List<Map<String, dynamic>> rawRecords,
  ) async {
    final col = _collections[colName] as Collection<dynamic>?;
    if (col == null) return;
    var changeset =
        _refuseFutureRecords(parseDeltaChangeset(colName, rawRecords));
    if (changeset.values.every((records) => records.isEmpty)) return;
    // Roster rows are vetted before they touch storage: any holder of the
    // roster key (including a revoked device) can send frames, but only rows
    // written by a known, non-revoked member are worth persisting.
    if (colName == kDeviceCollection && _roster != null) {
      changeset = await _roster!.vetInbound(changeset);
      if (changeset.values.every((records) => records.isEmpty)) return;
    }
    await col.mergeChangeset(changeset);
    if (colName == kDeviceCollection) await _retryPendingHellos();

    // A roster delta may carry a key rotation — adopt it, re-key, and if two
    // revocations raced, re-rotate.
    if (colName == kDeviceCollection && _roster != null) {
      final before = _dataKey;
      await _roster!.reconcile();
      await _applyGroupKey();
      if (before != null &&
          _dataKey != null &&
          !_listEquals(before, _dataKey!)) {
        _broadcastCollection(col);
      }
    }
  }

  /// [changeset] without the documents that carry a record stamped more than
  /// [_maxClockDrift] ahead of this device's clock. Such a record would win
  /// last-write-wins against every later edit; refusing the whole document
  /// keeps its records together, and anti-entropy offers it again later.
  CrdtChangeset _refuseFutureRecords(CrdtChangeset changeset) {
    final limit = DateTime.now().toUtc().add(_maxClockDrift);
    return {
      for (final entry in changeset.entries)
        entry.key: () {
          final tooNew = <String>{
            for (final record in entry.value)
              if ((record['hlc'] as Hlc).dateTime.isAfter(limit))
                _documentOf(record['key'] as String),
          };
          if (tooNew.isEmpty) return entry.value;
          return [
            for (final record in entry.value)
              if (!tooNew.contains(_documentOf(record['key'] as String)))
                record,
          ];
        }(),
    };
  }

  /// The document id a record key belongs to (the key up to the unit
  /// separator).
  static String _documentOf(String key) {
    final sep = key.indexOf('\x1F');
    return sep < 0 ? key : key.substring(0, sep);
  }

  // ---------------------------------------------------------------------------
  // Wire helpers

  Future<void> _sendHello(PeerId peer) =>
      _sendEncrypted(peer, HelloMessage(node: _nodeId));

  Future<void> _sendPoke(PeerId peer) =>
      _sendEncrypted(peer, const PokeMessage());

  /// One anti-entropy round per negotiated peer: a range-reconciliation probe
  /// when the peer advertised `recon1` (finds any difference — even a record
  /// older than both watermarks — in O(log n) round trips), else the plain
  /// hello whose state/delta replies carry everything newer than the peer's
  /// watermarks.
  Future<void> _antiEntropyExchange() async {
    for (final peer in _peers.toList()) {
      if (!_negotiatedVersion.containsKey(peer)) continue;
      if (_peerCapabilities[peer]?.contains(reconCapability) ?? false) {
        await _startReconcile(peer);
      } else {
        await _sendHello(peer);
      }
    }
  }

  /// Opens a reconciliation round with [peer]: one whole-range probe per
  /// collection.
  Future<void> _startReconcile(PeerId peer) async {
    for (final entry in _collections.entries.toList()) {
      final col = entry.value as Collection<dynamic>;
      final probe = await _reconcilerFor(col).initialProbe();
      if (probe == null) continue;
      await _sendEncrypted(
        peer,
        ReconcileMessage(col: col.name, probes: [_encodeProbe(probe)]),
      );
    }
  }

  Reconciler _reconcilerFor(Collection<dynamic> col) => Reconciler(
        digest: (from, to) => col.rangeDigest(fromHlc: from, toHlc: to),
      );

  Future<void> _handleReconcile(PeerId from, ReconcileMessage msg) async {
    final col = _collections[msg.col] as Collection<dynamic>?;
    if (col == null) return;

    // Ranges the peer asked for: ship them as ordinary bounded delta frames.
    for (final (rangeFrom, rangeTo) in msg.sendRanges) {
      await _sendRangeRecords(from, col, rangeFrom, rangeTo);
    }
    if (msg.probes.isEmpty) return;

    final plan = await _reconcilerFor(col).handleProbes([
      for (final (probeFrom, probeTo, depth, count, fingerprint) in msg.probes)
        RangeProbe(
          from: probeFrom,
          to: probeTo,
          depth: depth,
          count: count,
          fingerprint: fingerprint,
        ),
    ]);
    for (final range in plan.shipRanges) {
      await _sendRangeRecords(from, col, range.from, range.to);
    }
    if (plan.replyProbes.isNotEmpty || plan.requestRanges.isNotEmpty) {
      await _sendEncrypted(
        from,
        ReconcileMessage(
          col: col.name,
          probes: [for (final probe in plan.replyProbes) _encodeProbe(probe)],
          sendRanges: [
            for (final range in plan.requestRanges) (range.from, range.to),
          ],
        ),
      );
    }
  }

  Future<void> _sendRangeRecords(
    PeerId peer,
    Collection<dynamic> col,
    String? from,
    String? to,
  ) async {
    final changeset = await col.getChangeset(sinceHlc: from, untilHlc: to);
    for (final entry in changeset.entries) {
      final records =
          entry.value.map((r) => Map<String, dynamic>.from(r)).toList();
      if (records.isEmpty) continue;
      await _sendDeltas(peer, col.name, records);
    }
  }

  static (String?, String?, int, int, List<int>) _encodeProbe(
          RangeProbe probe) =>
      (probe.from, probe.to, probe.depth, probe.count, probe.fingerprint);

  /// Splits [records] into frames of at most [_maxRecordsPerFrame], never
  /// splitting one document's records across two frames.
  static List<List<Map<String, dynamic>>> _frameRecords(
    List<Map<String, dynamic>> records,
  ) {
    // Group by document id (the key up to the unit separator) so a document's
    // existence register and field records travel together.
    final byDoc = <String, List<Map<String, dynamic>>>{};
    for (final record in records) {
      final key = record['key'] as String;
      final sep = key.indexOf('\x1F');
      final docId = sep < 0 ? key : key.substring(0, sep);
      (byDoc[docId] ??= []).add(record);
    }
    final frames = <List<Map<String, dynamic>>>[];
    var current = <Map<String, dynamic>>[];
    for (final group in byDoc.values) {
      if (current.isNotEmpty &&
          current.length + group.length > _maxRecordsPerFrame) {
        frames.add(current);
        current = <Map<String, dynamic>>[];
      }
      current.addAll(group);
    }
    if (current.isNotEmpty) frames.add(current);
    return frames;
  }

  /// Streams [records] for [colName] to [peer] as bounded frames through the
  /// peer's send window. Awaits admission of every frame — the producer-side
  /// backpressure — not their delivery.
  Future<void> _sendDeltas(
    PeerId peer,
    String colName,
    List<Map<String, dynamic>> records,
  ) async {
    for (final frame in _frameRecords(records)) {
      await _sendEncrypted(peer, DeltaMessage(col: colName, records: frame));
    }
  }

  Future<void> _sendEncrypted(PeerId peer, ProtocolMessage msg) async {
    final window = _sendWindows.putIfAbsent(
      peer,
      () => FrameWindow(capacity: _maxInFlightFrames),
    );
    await window.enqueue(() => _sendEncryptedNow(peer, msg));
  }

  Future<void> _sendEncryptedNow(PeerId peer, ProtocolMessage msg) async {
    if (_identity == null) {
      final inner = await _cipher.encrypt(encodeMessage(msg));
      await _transport.send(peer, Frame(_room, inner));
      return;
    }
    final session = _sessions[peer];
    if (session != null) {
      final sealed = await session.seal(encodeMessage(msg));
      await _transport.send(peer, Frame(_room, [_frameRatcheted, ...sealed]));
      return;
    }
    final plain = _outsideSession(msg);
    if (plain == null) return; // user data waits for a session
    final inner = await _cipher.encrypt(encodeMessage(plain));
    await _transport.send(peer, Frame(_room, [_framePlain, ...inner]));
  }

  /// What of [msg] may travel outside a session, under the passphrase key
  /// that revoked devices still hold: everything but user-collection deltas,
  /// reconciliation and watermarks. `null` when nothing may.
  static ProtocolMessage? _outsideSession(ProtocolMessage msg) => switch (msg) {
        DeltaMessage(:final col) when col != kDeviceCollection => null,
        ReconcileMessage(:final col) when col != kDeviceCollection => null,
        StateMessage(:final cols) => StateMessage(cols: _rosterOnly(cols)),
        _ => msg,
      };

  /// Sends [msg] under the roster/control cipher only, never ratcheted — used
  /// for the handshake and the ratchet hello, which bootstraps the session.
  Future<void> _sendPlain(PeerId peer, ProtocolMessage msg) async {
    final inner = await _cipher.encrypt(encodeMessage(msg));
    final payload = _identity == null ? inner : <int>[_framePlain, ...inner];
    await _transport.send(peer, Frame(_room, payload));
  }

  /// Broadcasts [col]'s newly-changed records to all currently-connected peers.
  ///
  /// Called after every local [Collection.put] / [Collection.delete] so that
  /// changes are pushed immediately rather than waiting for the next hello.
  /// Only records newer than the last broadcast watermark are sent, so the cost
  /// is proportional to the change, not the whole collection.
  void _broadcastCollection(Collection<dynamic> col) {
    if (_peers.isEmpty) return;
    col.getChangeset(sinceHlc: _broadcastHwm[col.name]).then((changeset) {
      if (changeset.isEmpty) return;
      // Advance the watermark to the collection's current max so the next
      // broadcast starts after everything sent now.
      _broadcastHwm[col.name] = col.maxHlc;
      for (final tableEntry in changeset.entries) {
        // Cast List<CrdtRecord> → List<Map<String,dynamic>>; Hlc values are
        // left as Hlc objects — encodeMessage converts them to strings.
        final records =
            tableEntry.value.map((r) => Map<String, dynamic>.from(r)).toList();
        for (final peer in _peers) {
          // Fire-and-forget: the window keeps it bounded and ordered.
          unawaited(_sendDeltas(peer, col.name, records));
        }
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Factory

  /// Builds a database handle. Called by [Passnote] once the key has been
  /// derived and stored.
  @internal
  static Future<Database> open({
    required String id,
    required String room,
    required Cipher cipher,
    required NodeId nodeId,
    required Transport transport,
    required KeyStore keyStore,
    required String entryKey,
    required List<int> baseKey,
    required Identity? identity,
    required Cipher Function(List<int> key) cipherFactory,
    required FutureOr<CrdtTable> Function(String collection, List<int> key)
        engineFor,
    List<int> wireVersions = supportedWireVersions,
    List<String> wireCapabilities = const [reconCapability],
    Duration antiEntropyInterval = Duration.zero,
    int maxInFlightFrames = 16,
    Duration maxClockDrift = const Duration(minutes: 10),
    void Function(PeerId peer, List<int> local, List<int> remote)?
        onIncompatiblePeer,
  }) async {
    return Database._(
      id: id,
      room: room,
      cipher: cipher,
      nodeId: nodeId,
      transport: transport,
      keyStore: keyStore,
      entryKey: entryKey,
      baseKey: baseKey,
      identity: identity,
      cipherFactory: cipherFactory,
      engineFor: engineFor,
      wireVersions: wireVersions,
      wireCapabilities: wireCapabilities,
      antiEntropyInterval: antiEntropyInterval,
      maxInFlightFrames: maxInFlightFrames,
      maxClockDrift: maxClockDrift,
      onIncompatiblePeer: onIncompatiblePeer,
    );
  }
}
