import 'dart:async';

import 'dart:math';

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

/// A shared, encrypted, peer-synced database.
///
/// Open a [Database] by calling [Conclave.openDatabase]. Create typed
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
    required Duration antiEntropyInterval,
    required int maxInFlightFrames,
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
        _maxInFlightFrames = maxInFlightFrames,
        _onIncompatiblePeer = onIncompatiblePeer {
    _antiEntropy = AntiEntropy(
      interval: antiEntropyInterval,
      exchange: _antiEntropyExchange,
    )..start();
  }

  final String _id;
  final String _room;
  final Cipher _cipher;
  final NodeId _nodeId;
  final Transport _transport;
  final KeyStore _keyStore;
  final String _entryKey;

  /// The passphrase-derived key. Encrypts the reserved device-roster collection;
  /// also encrypts every user collection when no [Identity] is configured.
  final List<int> _baseKey;

  /// This device's identity, when the device-keypair model is active. `null`
  /// keeps the legacy behaviour: the passphrase-derived key encrypts everything
  /// and there is no roster.
  final Identity? _identity;

  /// Builds a [Cipher] for a key. Used to rebuild the data cipher when the
  /// group key rotates.
  final Cipher Function(List<int> key) _cipherFactory;

  /// The reserved device roster, present iff [_identity] is set.
  DeviceRoster? _roster;

  /// Cipher for user-collection frames on the wire: the group-key cipher once
  /// this device is [DeviceState.ready], else `null`. Roster and control frames
  /// always use [_cipher] (the passphrase / roster key), which every device in
  /// the room holds.
  Cipher? _dataCipher;

  /// The group key [_dataCipher] was built from, to detect rotation.
  List<int>? _dataKey;

  /// Per-peer forward-secret transport sessions, keyed by [PeerId]. Present
  /// only with an [Identity] and after the ratchet-nonce exchange. Frames to a
  /// peer with a session are wrapped in an outer ratchet layer.
  final Map<PeerId, RatchetSession> _sessions = {};
  final Map<PeerId, List<int>> _myNonce = {};
  final Map<PeerId, List<int>> _peerNonce = {};

  static final Random _nonceRng = Random.secure();

  /// The wire versions this node advertises in its handshake.
  final List<int> _wireVersions;

  /// Called once per peer whose advertised versions share nothing with ours.
  final void Function(PeerId peer, List<int> local, List<int> remote)?
      _onIncompatiblePeer;

  /// Peers whose handshake has been received at least once (bounds the
  /// handshake reply ping-pong to one reply each).
  final Set<PeerId> _handshakeReceived = {};

  /// The wire version negotiated per peer. Sync starts only once present.
  final Map<PeerId, int> _negotiatedVersion = {};

  /// Peers that advertised no common wire version: deregistered, their frames
  /// swallowed, nothing further sent.
  final Set<PeerId> _incompatiblePeers = {};

  /// Cap on outstanding frames per peer ([ConclaveConfig.maxInFlightFrames]).
  final int _maxInFlightFrames;

  /// Per-peer ordered, bounded send queues. Every encrypted frame flows
  /// through its peer's window: FIFO order protects the ratchet chain, and the
  /// bound is the backpressure a slow peer applies to a streaming sender.
  final Map<PeerId, FrameWindow> _sendWindows = {};

  /// The periodic hello exchange that heals dropped frames; stopped on
  /// [close] and [leave].
  late final AntiEntropy _antiEntropy;

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
        'Collection name "$kDeviceCollection" is reserved for Conclave device '
            'management.',
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
    return col;
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
  /// passphrase via [Conclave.reopenDatabase]. Used on normal shutdown.
  Future<void> close() async {
    _antiEntropy.stop();
    _tearDownSessions();
    for (final col in _collections.values) {
      await (col as Collection<dynamic>).dispose();
    }
  }

  /// Permanently forgets this database: removes its encryption key from the
  /// [KeyStore]. After [leave] the data can only be reopened by re-supplying
  /// the original passphrase.
  Future<void> leave() async {
    _antiEntropy.stop();
    for (final col in _collections.values) {
      await (col as Collection<dynamic>).dispose();
    }
    await _keyStore.clear(_entryKey);
  }

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
  /// [Conclave.identity] and task-18 pairing); [DeviceState.revoked] if its
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
  /// Drive sync first (`await conclave.forceSync()` then let the event loop
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

  /// Unwraps the group key with [recovery] (a keypair derived from a recovery
  /// phrase) and admits this physical device to the roster as [label].
  ///
  /// Returns `false` when the roster holds no wrap for [recovery] yet — the
  /// caller drives sync and retries. Throws [StateError] when [recovery]'s
  /// roster entry has been revoked. Called by [Conclave.recoverFrom].
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

  /// Rebuilds [_dataCipher] and re-keys every user-collection engine whenever
  /// the resolved group key has changed, and re-runs the ratchet handshake so
  /// sessions no longer derive from the old key. Safe to call repeatedly.
  Future<void> _applyGroupKey() async {
    final key = _roster?.groupKey;
    if (key == null) {
      _dataCipher = null;
      _dataKey = null;
      _tearDownSessions();
      return;
    }
    if (_dataKey != null && _listEquals(_dataKey!, key)) return;
    _dataKey = List<int>.unmodifiable(key);
    _dataCipher = _cipherFactory(key);
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
    _myNonce.clear();
    _peerNonce.clear();
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
        'unavailable. Use Conclave.builder with an identity, or pass '
        'identity: to Conclave.lowLevel.',
      );
    }
    return roster;
  }

  /// Opens the reserved roster collection and resolves this device's initial
  /// group-key state. Called by [Conclave] right after the database is
  /// registered and known peers announced, when an [Identity] is configured.
  ///
  /// [autoFound] founds the group key when this device is demonstrably alone
  /// (no connected peers) and no device has founded it yet — the first-run path.
  Future<void> initDeviceRoster(
    Identity identity, {
    required bool autoFound,
  }) async {
    final col =
        _getOrCreate<DeviceRosterEntry>(kDeviceCollection, deviceRosterCodec);
    final roster = DeviceRoster(col, identity);
    _roster = roster;
    await roster.ready;

    final state = await roster.resolve();
    if (state == DeviceState.needsPairing &&
        autoFound &&
        await roster.isUnfounded) {
      await roster.found(label: 'this device');
    }
    await _applyGroupKey();
  }

  // ---------------------------------------------------------------------------
  // Engine-internal: called by Conclave

  /// Called when a peer has just connected (or when [Conclave.openDatabase]
  /// discovers already-connected peers).
  Future<void> onPeerConnected(PeerId peer) async {
    if (_incompatiblePeers.contains(peer)) return;
    _peers.add(peer);
    // Handshake first: the ratchet and the hello/state/delta exchange start
    // only once a common wire version is negotiated (see [handlePlaintext]).
    await _sendHandshake(peer);
  }

  /// Called when a peer has disconnected. Drops the transport session so a
  /// reconnect derives a fresh ratchet chain.
  void onPeerLost(PeerId peer) {
    _peers.remove(peer);
    _sessions.remove(peer)?.dispose();
    _myNonce.remove(peer);
    _peerNonce.remove(peer);
    // A reconnect renegotiates from scratch — the peer may have upgraded.
    _handshakeReceived.remove(peer);
    _negotiatedVersion.remove(peer);
    _incompatiblePeers.remove(peer);
  }

  /// Kicks off the ratchet handshake with [peer]: sends our nonce if no session
  /// exists yet and this device holds the group key.
  Future<void> _kickRatchet(PeerId peer) async {
    if (_sessions.containsKey(peer) || _dataKey == null) return;
    await _sendRatchetNonce(peer);
    _tryEstablishSession(peer);
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
        devicePublicKey:
            identity == null ? null : (await identity.publicKey).toBytes(),
      ),
    );
  }

  /// Sends this side's stable nonce for [peer], tagged with the current
  /// group-key generation so the peer only pairs it against the same key.
  Future<void> _sendRatchetNonce(PeerId peer) async {
    final key = _dataKey;
    if (key == null) return;
    final nonce = _myNonce.putIfAbsent(
      peer,
      () => List<int>.generate(16, (_) => _nonceRng.nextInt(256)),
    );
    await _sendPlain(
      peer,
      RatchetHelloMessage(
        node: _nodeId,
        nonce: nonce,
        keyTag: ratchetKeyTag(key),
      ),
    );
  }

  void _tryEstablishSession(PeerId peer) {
    if (_sessions.containsKey(peer)) return;
    final mine = _myNonce[peer];
    final theirs = _peerNonce[peer];
    final groupKey = _dataKey;
    if (mine == null || theirs == null || groupKey == null) return;
    final root = deriveRatchetRoot(
      groupKey: groupKey,
      nonceA: mine,
      nonceB: theirs,
      nodeA: _nodeId,
      nodeB: peer,
    );
    _sessions[peer] = RatchetSession.establish(
      root: root,
      thisNodeIsLow: _nodeId.compareTo(peer) < 0,
      cipherFactory: _cipherFactory,
    );
  }

  /// Called by [Conclave] for an inbound frame on this database's room.
  ///
  /// Tries the roster/control cipher, then the data cipher; a frame that
  /// decrypts with neither (a revoked device's traffic after rotation) is
  /// dropped. Returns `true` if the frame was handled.
  Future<bool> handleFrame(PeerId from, List<int> frame) async {
    // An incompatible peer's frames are swallowed: addressed to us, not
    // processable, never an error loop.
    if (_incompatiblePeers.contains(from)) return true;
    var payload = frame;
    if (_identity != null) {
      if (payload.isEmpty) return false;
      final kind = payload[0];
      payload = payload.sublist(1);
      if (kind == _frameRatcheted) {
        final inner = await _sessions[from]?.open(payload);
        if (inner == null) return false; // no session yet, or ratcheted past
        payload = inner;
      }
    }

    List<int>? plaintext;
    for (final cipher in [_cipher, _dataCipher]) {
      if (cipher == null) continue;
      try {
        plaintext = await cipher.decrypt(payload);
        break;
      } catch (_) {
        // Try the next cipher.
      }
    }
    if (plaintext == null) return false;
    await handlePlaintext(from, plaintext);
    return true;
  }

  /// Dispatches an already-decrypted protocol message.
  Future<void> handlePlaintext(PeerId from, List<int> plaintext) async {
    final msg = decodeMessage(plaintext);
    if (msg == null) return;
    switch (msg) {
      case HelloMessage():
        await _handleHello(from);
      case StateMessage(:final cols):
        await _handleState(from, cols);
      case DeltaMessage(:final col, :final records):
        await _handleDelta(col, records);
      case PokeMessage():
        await _sendHello(from);
      case RatchetHelloMessage(:final nonce, :final keyTag):
        final key = _dataKey;
        // Ignore until we hold the group key, and ignore a nonce minted under
        // a different key generation — a stale queued frame, or the other
        // branch of two concurrent rotations that share an epoch number. A
        // session established from such a nonce would have a mismatched root
        // and silently drop every frame.
        if (key == null || !_listEquals(keyTag, ratchetKeyTag(key))) break;
        if (_sessions.containsKey(from)) {
          // Duplicate of the nonce we already paired with: ping-pong ends.
          final known = _peerNonce[from];
          if (known != null && _listEquals(known, nonce)) break;
          // A fresh nonce from a peer we hold a session with: the peer redid
          // its handshake (it adopted the key later than we did) and our
          // session is one-sided. Drop it and pair anew, or every ratcheted
          // frame between us is silently lost.
          _sessions.remove(from)?.dispose();
          _myNonce.remove(from);
        }
        _peerNonce[from] = nonce;
        _tryEstablishSession(from);
        await _sendRatchetNonce(from);
      case HandshakeMessage(:final versions):
        await _handleHandshake(from, versions);
    }
  }

  /// Negotiates the wire version with [from] and, on success, starts the
  /// ratchet and the sync exchange. Replies once to the first handshake a
  /// peer sends (both sides also send one on connect, so a peer that opened
  /// its database later still gets ours), which bounds the exchange to at
  /// most two frames each.
  Future<void> _handleHandshake(PeerId from, List<int> versions) async {
    if (_incompatiblePeers.contains(from)) return;
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
    final changeset = parseDeltaChangeset(colName, rawRecords);
    await col.mergeChangeset(changeset);

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

  // ---------------------------------------------------------------------------
  // Wire helpers

  Future<void> _sendHello(PeerId peer) =>
      _sendEncrypted(peer, HelloMessage(node: _nodeId));

  Future<void> _sendPoke(PeerId peer) =>
      _sendEncrypted(peer, const PokeMessage());

  /// One anti-entropy round: a hello to every negotiated peer, whose
  /// state/delta replies carry anything either side is missing.
  Future<void> _antiEntropyExchange() async {
    for (final peer in _peers.toList()) {
      if (!_negotiatedVersion.containsKey(peer)) continue;
      await _sendHello(peer);
    }
  }

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
    final cipher = _cipherForMessage(msg);
    if (cipher == null) return; // user data, but no group key yet
    final inner = await cipher.encrypt(encodeMessage(msg));

    if (_identity == null) {
      await _transport.send(peer, Frame(_room, inner));
      return;
    }
    final session = _sessions[peer];
    final payload = session == null
        ? [_framePlain, ...inner]
        : [_frameRatcheted, ...await session.seal(inner)];
    await _transport.send(peer, Frame(_room, payload));
  }

  /// Sends [msg] under the roster/control cipher only, never ratcheted — used
  /// for the ratchet nonce exchange, which bootstraps the session.
  Future<void> _sendPlain(PeerId peer, ProtocolMessage msg) async {
    final inner = await _cipher.encrypt(encodeMessage(msg));
    final payload = _identity == null ? inner : <int>[_framePlain, ...inner];
    await _transport.send(peer, Frame(_room, payload));
  }

  /// With the group-key model active, user-collection deltas travel under the
  /// group-key cipher so a revoked device cannot read them; control frames and
  /// roster deltas use [_cipher], which every device in the room holds. Without
  /// an [Identity], [_cipher] carries everything.
  Cipher? _cipherForMessage(ProtocolMessage msg) {
    if (_identity == null) return _cipher;
    if (msg is DeltaMessage && msg.col != kDeviceCollection) {
      return _dataCipher;
    }
    return _cipher;
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

  /// Builds a database handle. Called by [Conclave] once the key has been
  /// derived and stored.
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
    Duration antiEntropyInterval = Duration.zero,
    int maxInFlightFrames = 16,
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
      antiEntropyInterval: antiEntropyInterval,
      maxInFlightFrames: maxInFlightFrames,
      onIncompatiblePeer: onIncompatiblePeer,
    );
  }
}
