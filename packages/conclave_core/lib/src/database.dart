import 'dart:async';

import 'codec.dart';
import 'collection.dart';
import 'identity/device_roster.dart';
import 'merge_strategies.dart';
import 'ports/cipher.dart';
import 'ports/crdt_table.dart';
import 'ports/identity.dart';
import 'ports/key_store.dart';
import 'ports/merge_strategy.dart';
import 'ports/transport.dart';
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
    required FutureOr<CrdtTable> Function(String collection, List<int> key)
        engineFor,
  })  : _id = id,
        _room = room,
        _cipher = cipher,
        _nodeId = nodeId,
        _transport = transport,
        _keyStore = keyStore,
        _entryKey = entryKey,
        _baseKey = baseKey,
        _identity = identity,
        _engineFor = engineFor;

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

  /// The reserved device roster, present iff [_identity] is set.
  DeviceRoster? _roster;

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
    for (final col in _collections.values) {
      await (col as Collection<dynamic>).dispose();
    }
  }

  /// Permanently forgets this database: removes its encryption key from the
  /// [KeyStore]. After [leave] the data can only be reopened by re-supplying
  /// the original passphrase.
  Future<void> leave() async {
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

  /// Re-resolves [deviceState] from the roster after sync has delivered new
  /// rows from a peer. Returns the new state.
  ///
  /// Drive sync first (`await conclave.forceSync()` then let the event loop
  /// settle) so a freshly synced wrap is visible.
  Future<DeviceState> refreshDeviceState() async =>
      _roster?.resolve() ?? DeviceState.needsPairing;

  /// Founds a brand-new database: generates the random group key and seals it to
  /// this device at epoch 0.
  ///
  /// Only for the very first device. Throws [StateError] if the roster already
  /// carries a wrap (another device founded it — pair this device instead) or if
  /// no [Identity] is configured.
  Future<void> foundGroup({String label = 'this device'}) async {
    final roster = _requireRoster();
    await roster.found(label: label);
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

  /// Marks [deviceId] revoked in the roster.
  ///
  /// The flag propagates to every device on the next sync. Cryptographic
  /// exclusion (rotating the group key) is a separate, later step.
  Future<void> revokeDevice(String deviceId) async {
    final roster = _requireRoster();
    await roster.revoke(deviceId);
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

    var state = await roster.resolve();
    if (state == DeviceState.needsPairing &&
        autoFound &&
        await roster.isUnfounded) {
      await roster.found(label: 'this device');
      state = roster.state;
    }
  }

  // ---------------------------------------------------------------------------
  // Engine-internal: called by Conclave

  /// Called when a peer has just connected (or when [Conclave.openDatabase]
  /// discovers already-connected peers).
  Future<void> onPeerConnected(PeerId peer) async {
    _peers.add(peer);
    await _sendHello(peer);
  }

  /// Called when a peer has disconnected.
  void onPeerLost(PeerId peer) => _peers.remove(peer);

  /// Called by [Conclave] when an inbound frame matches this database's room.
  ///
  /// [plaintext] has already been decrypted by [Conclave] before dispatch.
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
    }
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
        await _sendEncrypted(
          from,
          DeltaMessage(col: colName, records: records),
        );
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
  }

  // ---------------------------------------------------------------------------
  // Wire helpers

  Future<void> _sendHello(PeerId peer) =>
      _sendEncrypted(peer, HelloMessage(node: _nodeId));

  Future<void> _sendPoke(PeerId peer) =>
      _sendEncrypted(peer, const PokeMessage());

  Future<void> _sendEncrypted(PeerId peer, ProtocolMessage msg) async {
    final encrypted = await _cipher.encrypt(encodeMessage(msg));
    await _transport.send(peer, Frame(_room, encrypted));
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
          // fire-and-forget; errors surface in transport layer
          _sendEncrypted(peer, DeltaMessage(col: col.name, records: records));
        }
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Engine-internal: cipher access for Conclave frame routing

  /// Decrypts a raw frame payload using this database's cipher.
  ///
  /// Called by [Conclave] before dispatching an inbound frame. Throws
  /// [CipherAuthError] if the frame was not encrypted with this key.
  Future<List<int>> decryptFrame(List<int> ciphertext) =>
      _cipher.decrypt(ciphertext);

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
    required FutureOr<CrdtTable> Function(String collection, List<int> key)
        engineFor,
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
      engineFor: engineFor,
    );
  }
}
