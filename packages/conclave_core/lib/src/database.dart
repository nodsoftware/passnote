import 'codec.dart';
import 'collection.dart';
import 'merge_strategies.dart';
import 'ports/blob_store.dart';
import 'ports/cipher.dart';
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
    required BlobStore store,
    required Cipher cipher,
    required NodeId nodeId,
    required Transport transport,
    required KeyStore keyStore,
    required String entryKey,
  })  : _id = id,
        _room = room,
        _store = store,
        _cipher = cipher,
        _nodeId = nodeId,
        _transport = transport,
        _keyStore = keyStore,
        _entryKey = entryKey;

  final String _id;
  final String _room;
  final BlobStore _store;
  final Cipher _cipher;
  final NodeId _nodeId;
  final Transport _transport;
  final KeyStore _keyStore;
  final String _entryKey;

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
      _store,
      merge: merge,
      onLocalChange: () => _broadcastCollection(col),
      onRemoteConflict: onRemoteConflict,
    );
    _collections[name] = col;
    return col;
  }

  /// Stops syncing and releases local resources, **keeping** the encryption key
  /// in the [KeyStore] so the database can later be reopened without the
  /// passphrase via [Conclave.reopenDatabase]. Used on normal shutdown.
  Future<void> close() async {
    await _store.close();
  }

  /// Permanently forgets this database: removes its encryption key from the
  /// [KeyStore] and then closes the store. After [leave] the data can only be
  /// reopened by re-supplying the original passphrase.
  Future<void> leave() async {
    await _keyStore.clear(_entryKey);
    await _store.close();
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

      final changeset = col.getChangeset(sinceHlc: peerHlc);
      if (changeset.isEmpty) continue;

      for (final tableEntry in changeset.entries) {
        // Cast List<CrdtRecord> → List<Map<String,dynamic>>; Hlc values are
        // left as Hlc objects — encodeMessage converts them to strings.
        final records = tableEntry.value
            .map((r) => Map<String, dynamic>.from(r))
            .toList();
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
    final changeset = col.getChangeset(sinceHlc: _broadcastHwm[col.name]);
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

  /// Builds a database around an **already-opened** [store]. The caller
  /// ([Conclave]) opens the store first so it can validate the key against
  /// existing data before this point.
  static Future<Database> open({
    required String id,
    required String room,
    required BlobStore store,
    required Cipher cipher,
    required NodeId nodeId,
    required Transport transport,
    required KeyStore keyStore,
    required String entryKey,
  }) async {
    return Database._(
      id: id,
      room: room,
      store: store,
      cipher: cipher,
      nodeId: nodeId,
      transport: transport,
      keyStore: keyStore,
      entryKey: entryKey,
    );
  }
}
