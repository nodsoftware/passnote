// Dead sketch for a lazy KV engine. Not exported, not covered by semver.
// The v1.0 engine is SQLite-backed; this file is deleted when that lands.
import 'dart:async';
import 'dart:convert';

import 'package:crdt/crdt.dart';

import 'ports/blob_store.dart';
import 'ports/crdt_table.dart';

/// Metadata tracked per record in the in-memory index.
class _RecordMeta {
  final Hlc hlc;
  final Hlc modified;
  final bool isDeleted;

  _RecordMeta(this.hlc, this.modified, this.isDeleted);
}

/// A [CrdtTable] backed by per-document blobs in a [BlobStore].
///
/// **Memory:** maintains a lightweight in-memory index (`key → HLC +
/// tombstone-flag`), ~40 bytes per record. Per-document values are loaded on
/// demand from the [BlobStore] and cached in memory once accessed. This means
/// collections with millions of records that only touch a subset at a time
/// use bounded memory relative to the working set, not the total dataset.
///
/// **Lazy loading:** [init] only builds the index from blob metadata — it does
/// NOT decode or cache per-document values. Every read method ([value],
/// [liveFields], [changeset]) loads the required blobs asynchronously on first
/// access and retains them in the value cache for subsequent requests.
///
/// **Persistence:** every [put] and [merge] writes the affected per-document
/// blob to the [BlobStore] immediately. The blob format is identical to the one
/// used by [Collection._persistDocuments], so existing data survives a switch
/// between [MapCrdtTable] and [LazyCrdtTable].
///
/// **Watch:** a broadcast `Stream<void>` per table fires on every mutating
/// operation, matching the [CrdtTable] contract.
class LazyCrdtTable implements CrdtTable {
  LazyCrdtTable(this._table, this._store) : _nodeId = _generateNodeId() {
    _canonicalTime = Hlc.zero(_nodeId);
  }

  static String _generateNodeId() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  final String _table;
  final BlobStore _store;
  final String _nodeId;

  /// In-memory index: CRDT key → metadata.
  final _index = <String, _RecordMeta>{};

  /// Per-document blob cache: doc-id → decoded blob content.
  ///
  /// Populated lazily — blobs are loaded on demand during reads and retained
  /// for the lifetime of the table.
  final _cache = <String, Map<String, Map<String, dynamic>>>{};

  /// Local canonical HLC, advanced on every local write and on every merge.
  late Hlc _canonicalTime;

  /// Broadcast stream controller per table.
  final _watchControllers = <String, StreamController<void>>{};

  /// Separator between document id and field path.
  static const _sep = '\x1F';

  /// Whether the init phase has completed.
  bool _initialized = false;

  @override
  bool get isPersistent => true;

  // ---------------------------------------------------------------------------
  // init
  // ---------------------------------------------------------------------------

  @override
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    final keys = await _store.keys(prefix: '$_table/d/');
    if (keys.isEmpty) return;

    var maxHlc = Hlc.zero(_nodeId);
    for (final blobKey in keys) {
      List<int>? bytes;
      try {
        bytes = await _store.read(blobKey);
      } catch (_) {
        continue;
      }
      if (bytes == null) continue;
      final raw = jsonDecode(utf8.decode(bytes));
      if (raw is! Map) continue;

      final rawMap = raw as Map<String, dynamic>;
      for (final entry in rawMap.entries) {
        final data = entry.value as Map<String, dynamic>;
        final hlcStr = data['h'] as String;
        final hlc = Hlc.parse(hlcStr);
        final isDeleted = data['d'] as bool;
        _index[entry.key] = _RecordMeta(hlc, hlc, isDeleted);
        if (hlc > maxHlc) maxHlc = hlc;
      }
    }

    if (maxHlc > _canonicalTime) {
      _canonicalTime = maxHlc;
    }
  }

  // ---------------------------------------------------------------------------
  // put
  // ---------------------------------------------------------------------------

  @override
  Future<void> put(
    String table,
    String key,
    Object? value, {
    bool isDeleted = false,
  }) async {
    await _ensureInitialized();
    final hlc = _canonicalTime.increment();
    _canonicalTime = hlc;
    _index[key] = _RecordMeta(hlc, hlc, isDeleted);

    final docId = _docIdForKey(key);
    final blob = await _loadDocBlob(docId);
    blob[key] = <String, dynamic>{
      'v': value,
      'd': isDeleted,
      'h': hlc.toString(),
    };
    _cache[docId] = blob;
    await _writeDocBlob(docId, blob);
    _emitWatch(table);
  }

  // ---------------------------------------------------------------------------
  // value
  // ---------------------------------------------------------------------------

  @override
  Future<Object?> value(String table, String key) async {
    final meta = _index[key];
    if (meta == null || meta.isDeleted) return null;
    final docId = _docIdForKey(key);
    final blob = await _loadDocBlob(docId);
    final entry = blob[key];
    return entry == null ? null : entry['v'];
  }

  // ---------------------------------------------------------------------------
  // liveFields
  // ---------------------------------------------------------------------------

  @override
  Future<Map<String, Object?>> liveFields(String table, String prefix) async {
    final result = <String, Object?>{};

    // Group matching keys by document id so we load each doc blob at most once.
    final keysByDoc = <String, List<String>>{};
    for (final entry in _index.entries) {
      if (entry.value.isDeleted) continue;
      if (prefix.isNotEmpty && !entry.key.startsWith(prefix)) continue;
      final docId = _docIdForKey(entry.key);
      keysByDoc.putIfAbsent(docId, () => []).add(entry.key);
    }

    for (final docId in keysByDoc.keys) {
      final blob = await _loadDocBlob(docId);
      for (final key in keysByDoc[docId]!) {
        final blobEntry = blob[key];
        if (blobEntry != null) {
          result[key] = blobEntry['v'];
        }
      }
    }

    return result;
  }

  // ---------------------------------------------------------------------------
  // liveKeys
  // ---------------------------------------------------------------------------

  @override
  Set<String> liveKeys(String table, String prefix) {
    if (prefix.isEmpty) {
      return {
        for (final entry in _index.entries)
          if (!entry.value.isDeleted) entry.key,
      };
    }
    return {
      for (final entry in _index.entries)
        if (!entry.value.isDeleted && entry.key.startsWith(prefix)) entry.key,
    };
  }

  // ---------------------------------------------------------------------------
  // changeset
  // ---------------------------------------------------------------------------

  @override
  Future<CrdtChangeset> changeset(String table, {String? sinceHlc}) async {
    Hlc? since;
    if (sinceHlc != null && sinceHlc.isNotEmpty) {
      since = Hlc.parse(sinceHlc);
    }

    final keysByDoc = <String, List<String>>{};
    for (final entry in _index.entries) {
      if (since != null && entry.value.modified <= since) continue;
      final docId = _docIdForKey(entry.key);
      keysByDoc.putIfAbsent(docId, () => []).add(entry.key);
    }

    final records = <Map<String, Object?>>[];
    for (final docId in keysByDoc.keys) {
      final blob = await _loadDocBlob(docId);
      for (final key in keysByDoc[docId]!) {
        final blobEntry = blob[key];
        final meta = _index[key];
        if (blobEntry == null || meta == null) continue;
        records.add({
          'key': key,
          'value': blobEntry['v'],
          'is_deleted': meta.isDeleted,
          'hlc': meta.hlc,
        });
      }
    }

    return {table: records};
  }

  // ---------------------------------------------------------------------------
  // maxHlc
  // ---------------------------------------------------------------------------

  @override
  String maxHlc(String table) {
    var max = _canonicalTime;
    for (final entry in _index.entries) {
      if (entry.value.modified > max) {
        max = entry.value.modified;
      }
    }
    return max.toString();
  }

  // ---------------------------------------------------------------------------
  // merge
  // ---------------------------------------------------------------------------

  @override
  Future<void> merge(CrdtChangeset changeset) async {
    await _ensureInitialized();
    var hlc = _canonicalTime;
    for (final records in changeset.values) {
      for (final record in records) {
        try {
          hlc = hlc.merge(record['hlc'] as Hlc);
        } catch (_) {
          continue;
        }
      }
    }
    _canonicalTime = hlc;

    final touchedDocs = <String>{};
    for (final records in changeset.values) {
      for (final record in records) {
        final key = record['key'] as String;
        final incomingHlc = record['hlc'] as Hlc;
        final existing = _index[key];
        if (existing != null && incomingHlc <= existing.hlc) continue;
        final isDeleted = record['is_deleted'] as bool;
        _index[key] = _RecordMeta(incomingHlc, hlc, isDeleted);
        final docId = _docIdForKey(key);
        touchedDocs.add(docId);
        final blob = await _loadDocBlob(docId);
        blob[key] = <String, dynamic>{
          'v': record['value'],
          'd': isDeleted,
          'h': incomingHlc.toString(),
        };
        _cache[docId] = blob;
      }
    }

    for (final docId in touchedDocs) {
      await _writeDocBlob(docId, _cache[docId]!);
    }

    _emitWatch(changeset.keys.first);
  }

  // ---------------------------------------------------------------------------
  // watch
  // ---------------------------------------------------------------------------

  @override
  Stream<void> watch(String table) {
    _watchControllers.putIfAbsent(
        table, () => StreamController<void>.broadcast());
    return _watchControllers[table]!.stream;
  }

  // ---------------------------------------------------------------------------
  // compact
  // ---------------------------------------------------------------------------

  @override
  Future<int> compact(String table, {required Duration horizon}) async {
    await _ensureInitialized();
    final cutoff = DateTime.now().subtract(horizon);
    final toRemove = <String>[];
    for (final entry in _index.entries) {
      if (entry.value.isDeleted && entry.value.hlc.dateTime.isBefore(cutoff)) {
        toRemove.add(entry.key);
      }
    }
    if (toRemove.isEmpty) return 0;

    for (final key in toRemove) {
      _index.remove(key);
    }

    // Rewrite per-document blobs for affected docs.
    final affectedDocs = <String>{};
    for (final key in toRemove) {
      affectedDocs.add(_docIdForKey(key));
    }
    for (final docId in affectedDocs) {
      final blob = await _loadDocBlob(docId);
      blob.removeWhere((key, _) => !_index.containsKey(key));
      if (blob.isEmpty) {
        _cache.remove(docId);
        await _store.delete('$_table/d/$docId');
      } else {
        _cache[docId] = blob;
        await _writeDocBlob(docId, blob);
      }
    }

    _emitWatch(table);
    return toRemove.length;
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  Future<void> _ensureInitialized() async {
    if (!_initialized) await init();
  }

  /// Returns the document id part of [key].
  static String _docIdForKey(String key) {
    final sep = key.indexOf(_sep);
    return sep < 0 ? key : key.substring(0, sep);
  }

  /// Loads the decoded per-document blob for [docId], returning the cached
  /// version if available or reading from the [BlobStore] on cache miss.
  Future<Map<String, Map<String, dynamic>>> _loadDocBlob(String docId) async {
    final cached = _cache[docId];
    if (cached != null) return cached;

    final blobKey = '$_table/d/$docId';
    List<int>? bytes;
    try {
      bytes = await _store.read(blobKey);
    } catch (_) {
      return {};
    }
    if (bytes == null) return {};

    final raw = jsonDecode(utf8.decode(bytes));
    if (raw is! Map) return {};

    final rawMap = raw as Map<String, dynamic>;
    final decoded = <String, Map<String, dynamic>>{};
    for (final entry in rawMap.entries) {
      final data = entry.value as Map<String, dynamic>;
      decoded[entry.key] = <String, dynamic>{
        'v': data['v'],
        'd': data['d'],
        'h': data['h'],
      };
    }
    _cache[docId] = decoded;
    return decoded;
  }

  /// Serializes [blob] and writes it to the store under `"$_table/d/$docId"`,
  /// also updating the in-memory cache.
  Future<void> _writeDocBlob(
      String docId, Map<String, Map<String, dynamic>> blob) async {
    _cache[docId] = blob;
    final payload = blob.map((key, data) => MapEntry(key, <String, dynamic>{
          'v': data['v'],
          'd': data['d'],
          'h': data['h'],
        }));
    await _store.write(
      '$_table/d/$docId',
      utf8.encode(jsonEncode(payload)),
    );
  }

  void _emitWatch(String table) {
    final ctrl = _watchControllers[table];
    if (ctrl != null && ctrl.hasListener) {
      ctrl.add(null);
    }
  }
}
