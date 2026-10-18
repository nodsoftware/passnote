import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crdt/crdt.dart';
import 'package:sqlite3/common.dart';

import '../crdt/crdt_type.dart';
import '../exceptions.dart';
import '../ports/crdt_table.dart';
import '../ports/query.dart';
import 'sqlite_open_io.dart' if (dart.library.js_interop) 'sqlite_open_web.dart'
    as backend;

/// A [CrdtTable] backed by SQLite (`package:sqlite3`).
///
/// Records live in a single `crdt_records` table keyed by `(collection, key)`;
/// one SQLite database can host every collection. Values are stored as JSON
/// text. Ordering and sync filtering use `hlc_key`, a fixed-width sortable
/// encoding of the record's Hybrid Logical Clock, so `WHERE hlc_key > ?` is a
/// correct causal comparison.
///
/// Construct it with a path; the database is opened on the first [init] (which
/// [Collection] calls, since [isPersistent] is `true`). On native targets pass
/// an [encryptionKey] to use SQLCipher. The open fails closed: [init] throws
/// [SqlCipherUnavailableException] when a key is given but the linked native
/// library is not a SQLCipher build, so data is never silently written in
/// plaintext.
///
/// ## Wrong key versus corruption
///
/// An existing encrypted file that does not decrypt under [encryptionKey]
/// makes [init] throw [WrongPassphraseException] and leaves the file exactly
/// as it was — retrying with the right key succeeds. An encrypted file whose
/// damage makes it unreadable answers exactly like a mis-keyed one, so the
/// snapshot arbitrates: when `<path>.snapshot` opens cleanly under the same
/// key, the key is proven right, the file is treated as corrupt, and recovery
/// proceeds. Without a snapshot the ambiguity resolves to
/// [WrongPassphraseException] — the file is never destroyed on a guess, at
/// the price that an encrypted database without snapshots recovers from
/// header damage only by the user confirming the passphrase and deleting the
/// file. Corruption past the header (a damaged page under a valid key) fails
/// `PRAGMA quick_check` directly and recovers without arbitration.
///
/// ## Corruption recovery
///
/// [init] runs `PRAGMA quick_check` on open. If a corrupt file does not pass,
/// it is moved aside to `<path>.corrupt-<timestamp>` and the store is
/// rebuilt: from `<path>.snapshot` if a readable one exists, otherwise empty
/// (and [recoveries] emits so the sync layer can pull the data back from a
/// peer). Set [snapshotInterval] (or [PassnoteConfig.snapshotInterval]) to keep
/// those snapshots current.
final class SqliteCrdtTable implements CrdtTable, SnapshotCapable {
  /// Creates a table for the database at [path], which is opened on the first
  /// [init]. Pass `":memory:"` for a transient database; pass an
  /// [encryptionKey] to use SQLCipher on a SQLCipher build of the native
  /// library. [snapshotInterval] sets how often a recovery snapshot is written
  /// (`Duration.zero`, the default, disables it).
  SqliteCrdtTable(
    this._path, {
    List<int>? encryptionKey,
    Duration snapshotInterval = Duration.zero,
  })  : _encryptionKey = encryptionKey == null
            ? null
            : List<int>.unmodifiable(encryptionKey),
        _snapshotInterval = snapshotInterval;

  /// Web-only configuration (a no-op on native): points the engine at the
  /// `sqlite3.wasm` module. Call it once before opening a database.
  static void configureWeb({Uri? wasmUri}) =>
      backend.configureWeb(wasmUri: wasmUri);

  /// Convenience for tests: constructs and [init]s in one step.
  static Future<SqliteCrdtTable> open(
    String path, {
    List<int>? encryptionKey,
  }) async {
    final table = SqliteCrdtTable(path, encryptionKey: encryptionKey);
    await table.init();
    return table;
  }

  final String _path;
  List<int>? _encryptionKey;

  CommonDatabase? _db;
  late String _nodeId;
  late Hlc _canonical;
  final _watchers = <String, StreamController<void>>{};
  bool _closed = false;

  Duration _snapshotInterval;
  Timer? _snapshotTimer;
  final _recoveries = StreamController<CrdtRecovery>.broadcast();
  CrdtRecovery? _recovery;

  CommonDatabase get _open =>
      _db ?? (throw StateError('SqliteCrdtTable.init() first'));

  @override
  bool get isPersistent => true;

  /// The node id persisted in `crdt_meta`, stable across restarts. Created on
  /// the first [init] of a fresh database. Throws [StateError] before [init].
  @override
  String get nodeId => _db == null
      ? (throw StateError('SqliteCrdtTable.init() first'))
      : _nodeId;

  @override
  set snapshotInterval(Duration value) {
    _snapshotInterval = value;
    // Re-arm the timer when the database is already open; before [init] the
    // new interval is picked up by the [_startSnapshots] call inside it.
    if (_db != null && !_closed) {
      _snapshotTimer?.cancel();
      _snapshotTimer = null;
      _startSnapshots();
    }
  }

  /// Non-null once [init] has run if it had to rebuild an unreadable store.
  CrdtRecovery? get recovery => _recovery;

  @override
  Stream<CrdtRecovery> get recoveries => _recoveries.stream;

  @override
  Future<void> init() async {
    if (_db != null || _closed) return;
    var db = await _openIfHealthy(_path);
    if (db == null) {
      final tag = 'corrupt-${DateTime.now().toUtc().millisecondsSinceEpoch}';
      final quarantine = backend.quarantineDatabase(_path, tag);
      db = await _restoreOrReset(quarantine);
    }
    db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA synchronous = NORMAL');
    db.execute('PRAGMA foreign_keys = ON');
    _migrate(db);
    _nodeId = _readOrCreateNodeId(db);
    _canonical = _readMaxHlc(db) ?? Hlc.zero(_nodeId);
    _db = db;
    _startSnapshots();

    final recovery = _recovery;
    if (recovery != null) {
      scheduleMicrotask(() {
        if (!_recoveries.isClosed) _recoveries.add(recovery);
      });
    }
  }

  /// `SQLITE_NOTADB`: the first read against a keyed database raises this when
  /// the key does not decrypt the file.
  static const int _sqliteNotADb = 26;

  /// Opens [path] and returns the handle only if `PRAGMA quick_check` passes;
  /// otherwise disposes it and returns `null` (corrupt — the caller
  /// quarantines and rebuilds).
  ///
  /// Two failures are not corruption and rethrow instead of returning `null`:
  /// [SqlCipherUnavailableException] (a key was given on a non-SQLCipher
  /// build) and [WrongPassphraseException] (an existing encrypted file does
  /// not decrypt under the key). Both leave the file untouched.
  Future<CommonDatabase?> _openIfHealthy(String path) async {
    CommonDatabase db;
    try {
      db = await backend.openSqliteDb(path, encryptionKey: _encryptionKey);
    } on SqlCipherUnavailableException {
      rethrow;
    } catch (_) {
      return null;
    }
    try {
      final rows = db.select('PRAGMA quick_check');
      if (rows.isNotEmpty && rows.first.values.first == 'ok') return db;
    } on SqliteException catch (e) {
      db.close();
      if (_encryptionKey != null &&
          (e.resultCode == _sqliteNotADb ||
              e.extendedResultCode == _sqliteNotADb)) {
        // SQLCipher answers NOTADB both for a mis-keyed file and for a file
        // whose header is damaged; the two are indistinguishable from the
        // file alone. The snapshot arbitrates: it carries the same key
        // (VACUUM INTO inherits it), so a snapshot that opens under this key
        // proves the key right and the file corrupt — recovery proceeds.
        // Without that proof, report the wrong key and leave the file alone:
        // never destroy data on ambiguity.
        if (await _keyOpensSnapshot()) return null;
        throw const WrongPassphraseException();
      }
      return null;
    } catch (_) {
      // Unreadable enough that quick_check itself failed.
    }
    db.close();
    return null;
  }

  /// Whether `<path>.snapshot` exists and passes `PRAGMA quick_check` under
  /// the current [_encryptionKey]. Used to tell a corrupt file from a wrong
  /// key.
  Future<bool> _keyOpensSnapshot() async {
    final snapshot = '$_path.snapshot';
    if (!backend.databaseFileExists(snapshot)) return false;
    CommonDatabase db;
    try {
      db = await backend.openSqliteDb(snapshot, encryptionKey: _encryptionKey);
    } catch (_) {
      return false;
    }
    try {
      final rows = db.select('PRAGMA quick_check');
      return rows.isNotEmpty && rows.first.values.first == 'ok';
    } catch (_) {
      return false;
    } finally {
      db.close();
    }
  }

  /// Rebuilds the store after [_openIfHealthy] rejected it: restores the
  /// snapshot if there is a readable one, otherwise opens an empty database.
  Future<CommonDatabase> _restoreOrReset(String quarantinePath) async {
    final snapshot = '$_path.snapshot';
    if (backend.databaseFileExists(snapshot)) {
      backend.restoreDatabase(source: snapshot, path: _path);
      final restored = await _openIfHealthy(_path);
      if (restored != null) {
        _recovery = CrdtRecovery(
          source: CrdtRecoverySource.snapshot,
          quarantinePath: quarantinePath,
        );
        return restored;
      }
      backend.quarantineDatabase(_path, 'corrupt-snapshot');
    }
    _recovery = CrdtRecovery(
      source: CrdtRecoverySource.reset,
      quarantinePath: quarantinePath,
    );
    return backend.openSqliteDb(_path, encryptionKey: _encryptionKey);
  }

  /// Re-encrypts the database under [newKey] with SQLCipher's `PRAGMA rekey`.
  /// All data is preserved. Subsequent opens and recovery snapshots use
  /// [newKey].
  ///
  /// Fails closed like [init]: throws [SqlCipherUnavailableException] when the
  /// linked library is not a SQLCipher build (the rekey would be silently
  /// ignored and the file left in plaintext).
  @override
  Future<void> rekey(List<int> newKey) async {
    _encryptionKey = List<int>.unmodifiable(newKey);
    final db = _db;
    if (db == null) return;
    if (db.select('PRAGMA cipher_version').isEmpty) {
      throw const SqlCipherUnavailableException();
    }
    final hex = newKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    db.execute('PRAGMA rekey = "x\'$hex\'"');
  }

  /// Closes the database and every watch stream. Safe to call more than once.
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _snapshotTimer?.cancel();
    for (final c in _watchers.values) {
      await c.close();
    }
    _watchers.clear();
    await _recoveries.close();
    _db?.close();
    _db = null;
  }

  /// Writes a consistent copy of the store to `<path>.snapshot`, replacing any
  /// previous one. Called by the periodic timer; also safe to call directly for
  /// a manual checkpoint. A no-op for an in-memory database.
  void snapshotNow() {
    if (_path == backend.inMemoryPath) return;
    final target = '$_path.snapshot';
    backend.deleteFileIfPresent(target);
    _open.execute('VACUUM INTO ?', [target]);
  }

  void _startSnapshots() {
    if (_snapshotInterval <= Duration.zero || _path == backend.inMemoryPath) {
      return;
    }
    _snapshotTimer = Timer.periodic(_snapshotInterval, (_) {
      try {
        snapshotNow();
      } catch (_) {
        // A failed snapshot is non-fatal; the next tick retries.
      }
    });
  }

  @override
  Future<void> put(
    String table,
    String key,
    Object? value, {
    bool isDeleted = false,
    CrdtType crdtType = const LwwRegister(),
  }) async {
    _canonical = _canonical.increment();
    _open.execute(
      'INSERT INTO crdt_records (collection, key, value, is_deleted, hlc, '
      'hlc_key, crdt_type) VALUES (?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(collection, key) DO UPDATE SET '
      'value = excluded.value, is_deleted = excluded.is_deleted, '
      'hlc = excluded.hlc, hlc_key = excluded.hlc_key, '
      'crdt_type = excluded.crdt_type',
      [
        table,
        key,
        jsonEncode(value),
        isDeleted ? 1 : 0,
        _canonical.toString(),
        _hlcKey(_canonical),
        crdtType.tag,
      ],
    );
    _emit(table);
  }

  @override
  Future<Object?> value(String table, String key) async {
    if (_db == null) return null;
    final rows = _open.select(
      'SELECT value FROM crdt_records '
      'WHERE collection = ? AND key = ? AND is_deleted = 0',
      [table, key],
    );
    if (rows.isEmpty) return null;
    return jsonDecode(rows.first['value'] as String);
  }

  @override
  Future<Map<String, Object?>> liveFields(String table, String prefix) async {
    if (_db == null) return {};
    final rows = prefix.isEmpty
        ? _open.select(
            'SELECT key, value FROM crdt_records '
            'WHERE collection = ? AND is_deleted = 0',
            [table],
          )
        : _open.select(
            'SELECT key, value FROM crdt_records '
            'WHERE collection = ? AND is_deleted = 0 '
            'AND substr(key, 1, ?) = ?',
            [table, prefix.length, prefix],
          );
    return {
      for (final r in rows)
        r['key'] as String: jsonDecode(r['value'] as String),
    };
  }

  @override
  Future<String?> recordHlc(String table, String key) async {
    if (_db == null) return null;
    final rows = _open.select(
      'SELECT hlc FROM crdt_records WHERE collection = ? AND key = ?',
      [table, key],
    );
    return rows.isEmpty ? null : rows.first['hlc'] as String;
  }

  /// One indexed lookup per chunk of ids (`doc_id IN (...)`), never a table
  /// scan.
  @override
  Future<Map<String, Map<String, Object?>>> docFields(
      String table, Iterable<String> docIds) async {
    if (_db == null) return {};
    final out = <String, Map<String, Object?>>{};
    final ids = docIds.toList();
    // Stay under SQLite's bound-parameter limit.
    const chunkSize = 400;
    for (var start = 0; start < ids.length; start += chunkSize) {
      final chunk = ids.sublist(start,
          start + chunkSize > ids.length ? ids.length : start + chunkSize);
      final rows = _open.select(
        'SELECT doc_id, field_path, value FROM crdt_records '
        'WHERE collection = ? AND is_deleted = 0 AND field_path IS NOT NULL '
        'AND doc_id IN (${List.filled(chunk.length, '?').join(', ')})',
        [table, ...chunk],
      );
      for (final r in rows) {
        (out[r['doc_id'] as String] ??= {})[r['field_path'] as String] =
            jsonDecode(r['value'] as String);
      }
    }
    return out;
  }

  @override
  Set<String> liveKeys(String table, String prefix) {
    if (_db == null) return const {};
    final rows = prefix.isEmpty
        ? _open.select(
            'SELECT key FROM crdt_records '
            'WHERE collection = ? AND is_deleted = 0',
            [table],
          )
        : _open.select(
            'SELECT key FROM crdt_records '
            'WHERE collection = ? AND is_deleted = 0 AND substr(key, 1, ?) = ?',
            [table, prefix.length, prefix],
          );
    return {for (final r in rows) r['key'] as String};
  }

  @override
  Future<CrdtChangeset> changeset(
    String table, {
    String? sinceHlc,
    String? untilHlc,
  }) async {
    if (_db == null) return {table: <CrdtRecord>[]};
    final conditions = ['collection = ?'];
    final params = <Object?>[table];
    if (sinceHlc != null && sinceHlc.isNotEmpty) {
      conditions.add('hlc_key > ?');
      params.add(_hlcKey(Hlc.parse(sinceHlc)));
    }
    if (untilHlc != null && untilHlc.isNotEmpty) {
      conditions.add('hlc_key <= ?');
      params.add(_hlcKey(Hlc.parse(untilHlc)));
    }
    final rows = _open.select(
      'SELECT key, value, is_deleted, hlc, crdt_type FROM crdt_records '
      'WHERE ${conditions.join(' AND ')}',
      params,
    );
    return {
      table: [
        for (final r in rows)
          {
            'key': r['key'] as String,
            'value': jsonDecode(r['value'] as String),
            'is_deleted': (r['is_deleted'] as int) == 1,
            'hlc': Hlc.parse(r['hlc'] as String),
            'crdt_type': r['crdt_type'] as String,
          },
      ],
    };
  }

  /// One indexed range scan over `(collection, hlc_key)`; O(1) memory.
  @override
  Future<RangeDigest> rangeDigest(
    String table, {
    String? fromHlc,
    String? toHlc,
  }) async {
    if (_db == null) return RangeDigest.empty;
    final conditions = ['collection = ?'];
    final params = <Object?>[table];
    if (fromHlc != null) {
      conditions.add('hlc_key > ?');
      params.add(_hlcKey(Hlc.parse(fromHlc)));
    }
    if (toHlc != null) {
      conditions.add('hlc_key <= ?');
      params.add(_hlcKey(Hlc.parse(toHlc)));
    }
    final builder = RangeDigestBuilder();
    final rows = _open.select(
      'SELECT key, hlc FROM crdt_records WHERE ${conditions.join(' AND ')}',
      params,
    );
    for (final row in rows) {
      builder.add(row['key'] as String, Hlc.parse(row['hlc'] as String));
    }
    return builder.build();
  }

  @override
  String maxHlc(String table) {
    if (_db == null) return '';
    final rows = _open.select(
      'SELECT hlc FROM crdt_records WHERE collection = ? '
      'ORDER BY hlc_key DESC LIMIT 1',
      [table],
    );
    return rows.isEmpty ? '' : rows.first['hlc'] as String;
  }

  @override
  Future<void> merge(CrdtChangeset changeset) async {
    var changed = false;
    final touchedTables = <String>{};

    _open.execute('BEGIN');
    try {
      for (final entry in changeset.entries) {
        final table = entry.key;
        for (final record in entry.value) {
          final key = record['key'] as String;
          final incoming = record['hlc'] as Hlc;

          // Advance the local clock; skip a record authored by our own node id
          // (it would be a merge against ourselves).
          try {
            _canonical = _canonical.merge(incoming);
          } catch (_) {
            // DuplicateNodeException / drift — leave the clock as is.
          }

          final existing = _open.select(
            'SELECT hlc FROM crdt_records WHERE collection = ? AND key = ?',
            [table, key],
          );
          if (existing.isNotEmpty &&
              Hlc.parse(existing.first['hlc'] as String) >= incoming) {
            continue;
          }

          _open.execute(
            'INSERT INTO crdt_records (collection, key, value, is_deleted, '
            'hlc, hlc_key, crdt_type) VALUES (?, ?, ?, ?, ?, ?, ?) '
            'ON CONFLICT(collection, key) DO UPDATE SET '
            'value = excluded.value, is_deleted = excluded.is_deleted, '
            'hlc = excluded.hlc, hlc_key = excluded.hlc_key, '
            'crdt_type = excluded.crdt_type',
            [
              table,
              key,
              jsonEncode(record['value']),
              (record['is_deleted'] as bool) ? 1 : 0,
              incoming.toString(),
              _hlcKey(incoming),
              // A peer that predates per-field types (or an in-memory engine)
              // sends no tag; treat it as last-write-wins.
              record['crdt_type'] as String? ?? const LwwRegister().tag,
            ],
          );
          changed = true;
          touchedTables.add(table);
        }
      }
      _open.execute('COMMIT');
    } catch (_) {
      _open.execute('ROLLBACK');
      rethrow;
    }

    if (changed) {
      for (final table in touchedTables) {
        _emit(table);
      }
    }
  }

  @override
  Stream<void> watch(String table) => _watchers
      .putIfAbsent(table, () => StreamController<void>.broadcast())
      .stream;

  @override
  Future<int> compact(String table, {required Duration horizon}) async {
    final cutoff = Hlc(DateTime.now().toUtc().subtract(horizon), 0, _nodeId);
    _open.execute(
      'DELETE FROM crdt_records '
      'WHERE collection = ? AND is_deleted = 1 AND hlc_key < ?',
      [table, _hlcKey(cutoff)],
    );
    final removed = _open.updatedRows;
    if (removed > 0) _emit(table);
    return removed;
  }

  /// Creates a small partial index for [fieldPath] in [table]: it covers only
  /// that field's live rows and indexes their extracted value, so an equality
  /// predicate on the path is an index search rather than a table scan.
  @override
  Future<void> ensureQueryIndex(String table, String fieldPath) async {
    _open.execute(
      'CREATE INDEX IF NOT EXISTS ${_indexName(table, fieldPath)} '
      "ON crdt_records (json_extract(value, '\$'), doc_id) "
      'WHERE collection = ${_lit(table)} AND field_path = ${_lit(fieldPath)} '
      'AND is_deleted = 0',
    );
  }

  @override
  Future<List<QueryRow>> queryDocIds(String table, QuerySpec spec) async {
    if (_db == null) return const [];
    final (sql, params) = _compileQuery(table, spec);
    final rows = _open.select(sql, params);
    return [
      for (final r in rows)
        QueryRow(docId: r['did'] as String, orderValue: r['ord']),
    ];
  }

  /// The `EXPLAIN QUERY PLAN` output for the SQL that [queryDocIds] would run
  /// for [spec] — one plan line per row. A diagnostic: use it to confirm a
  /// predicate on an indexed path searches its index instead of scanning.
  String explainQuery(String table, QuerySpec spec) {
    final (sql, params) = _compileQuery(table, spec);
    final rows = _open.select('EXPLAIN QUERY PLAN $sql', params);
    return rows.map((r) => r['detail']).join('\n');
  }

  /// Compiles [spec] to one SQL statement over `crdt_records` plus its bind
  /// parameters.
  ///
  /// Shape: an inner SELECT gathers the live document ids (existence registers
  /// of [table]) that satisfy every predicate — each predicate an EXISTS
  /// subquery against that document's field row — and computes the resolved
  /// order-by value; the outer SELECT applies the keyset window and the order.
  /// Collection and field-path constraints are inlined as literals so SQLite
  /// can match them against the partial indexes [ensureQueryIndex] creates;
  /// compared values are always bound.
  (String, List<Object?>) _compileQuery(String table, QuerySpec spec) {
    final params = <Object?>[];
    final conditions = [
      'e.collection = ${_lit(table)}',
      'e.field_path IS NULL',
      'e.is_deleted = 0',
    ];

    for (final p in spec.predicates) {
      final valueExpr = _resolvedExpr('p', p.type);
      final String cond;
      switch (p.op) {
        case QueryOp.contains:
          cond = "EXISTS (SELECT 1 FROM json_each(p.value, '\$.adds') ae "
              'WHERE ae.value IS ?)';
          params.add(_bindable(p.value));
        case QueryOp.equals:
          // IS, not =: a stored JSON null should match `isEqualTo: null`.
          cond = '$valueExpr IS ?';
          params.add(_bindable(p.value));
        case QueryOp.isIn:
          final values = p.value as List;
          cond =
              '$valueExpr IN (${List.filled(values.length, '?').join(', ')})';
          params.addAll(values.map(_bindable));
        case QueryOp.greaterThan:
          cond = '$valueExpr > ?';
          params.add(_bindable(p.value));
        case QueryOp.lessThan:
          cond = '$valueExpr < ?';
          params.add(_bindable(p.value));
      }
      conditions.add('EXISTS (SELECT 1 FROM crdt_records p '
          'WHERE p.collection = ${_lit(table)} '
          'AND p.field_path = ${_lit(p.path)} AND p.is_deleted = 0 '
          'AND p.doc_id = e.key AND $cond)');
    }

    final orderPath = spec.orderByPath;
    final String ordExpr;
    var join = '';
    if (orderPath == null) {
      ordExpr = 'NULL';
    } else {
      ordExpr = _resolvedExpr('o', spec.orderByType);
      join = 'LEFT JOIN crdt_records o ON o.collection = ${_lit(table)} '
          'AND o.doc_id = e.key AND o.field_path = ${_lit(orderPath)} '
          'AND o.is_deleted = 0 ';
    }

    final inner = 'SELECT e.key AS did, $ordExpr AS ord FROM crdt_records e '
        '$join'
        'WHERE ${conditions.join(' AND ')}';

    // Keyset window: strictly after the cursor in the (ord, did) total order.
    // Ascending sorts NULL order values first (SQLite's NULLS-first default),
    // descending sorts them last; the OR shapes below encode exactly that.
    final outerConditions = <String>[];
    final after = spec.after;
    if (after != null) {
      final cv = after.orderValue;
      if (orderPath == null) {
        outerConditions.add(spec.descending ? 'did < ?' : 'did > ?');
        params.add(after.docId);
      } else if (spec.descending) {
        if (cv == null) {
          outerConditions.add('(ord IS NULL AND did < ?)');
          params.add(after.docId);
        } else {
          outerConditions
              .add('(ord < ? OR ord IS NULL OR (ord = ? AND did < ?))');
          params.addAll([_bindable(cv), _bindable(cv), after.docId]);
        }
      } else {
        if (cv == null) {
          outerConditions.add('(ord IS NOT NULL OR did > ?)');
          params.add(after.docId);
        } else {
          outerConditions.add('(ord > ? OR (ord = ? AND did > ?))');
          params.addAll([_bindable(cv), _bindable(cv), after.docId]);
        }
      }
    }

    final direction = spec.descending ? 'DESC' : 'ASC';
    final where = outerConditions.isEmpty
        ? ''
        : 'WHERE ${outerConditions.join(' AND ')} ';
    var sql = 'SELECT did, ord FROM ($inner) $where'
        'ORDER BY ord $direction, did $direction';
    if (spec.limit != null) {
      sql += ' LIMIT ?';
      params.add(spec.limit);
    }
    return (sql, params);
  }

  /// The SQL expression for the resolved, comparable value of a field row
  /// aliased [a]: a counter state becomes its summed total, anything else its
  /// extracted JSON value (numbers as numbers, strings as text, booleans as
  /// 0/1 — the same domain the Dart scan evaluator normalises into).
  static String _resolvedExpr(String a, CrdtType type) => switch (type) {
        PnCounter() =>
          "(COALESCE((SELECT sum(pe.value) FROM json_each($a.value, '\$.p') "
              'pe), 0) - COALESCE((SELECT sum(ne.value) FROM '
              "json_each($a.value, '\$.n') ne), 0))",
        _ => "json_extract($a.value, '\$')",
      };

  /// A deterministic, quoted index name for [table]/[fieldPath].
  static String _indexName(String table, String fieldPath) {
    String sanitize(String s) => s.replaceAll(RegExp('[^A-Za-z0-9]'), '_');
    var hash = 5381;
    for (final unit in '$table\x1F$fieldPath'.codeUnits) {
      hash = ((hash * 33) ^ unit) & 0xFFFFFFFF;
    }
    return '"cq_${sanitize(table)}_${sanitize(fieldPath)}_'
        '${hash.toRadixString(16)}"';
  }

  /// [s] as a single-quoted SQL string literal.
  static String _lit(String s) => "'${s.replaceAll("'", "''")}'";

  /// A predicate value in SQLite's binding domain, matching what
  /// `json_extract` yields for stored values: booleans as 0/1, non-scalar
  /// values as their JSON text.
  static Object? _bindable(Object? value) => switch (value) {
        null => null,
        final bool b => b ? 1 : 0,
        final num n => n,
        final String s => s,
        _ => jsonEncode(value),
      };

  // ---------------------------------------------------------------------------

  void _emit(String table) {
    final c = _watchers[table];
    if (c != null && c.hasListener) c.add(null);
  }

  /// Fixed-width, lexicographically sortable encoding of an [Hlc].
  static String _hlcKey(Hlc hlc) {
    final micros =
        hlc.dateTime.microsecondsSinceEpoch.toString().padLeft(19, '0');
    final counter = hlc.counter.toString().padLeft(5, '0');
    return '$micros|$counter|${hlc.nodeId}';
  }

  /// The schema version this build expects. Bumped whenever [_migrate] gains a
  /// step.
  static const int _schemaVersion = 1;

  /// The generated-column expressions that split a record `key` into its
  /// document id and field path at the unit separator (`char(31)` = `\x1F`).
  /// An existence register (no separator) has the whole key as its document id
  /// and a NULL field path.
  static const String _docIdExpr = 'CASE WHEN instr(key, char(31)) = 0 '
      'THEN key ELSE substr(key, 1, instr(key, char(31)) - 1) END';
  static const String _fieldPathExpr = 'CASE WHEN instr(key, char(31)) = 0 '
      'THEN NULL ELSE substr(key, instr(key, char(31)) + 1) END';

  /// Brings the schema up to date. The whole step runs in one transaction —
  /// including the `user_version` bump, which is header state and rolls back
  /// with it — so an interrupted step reopens at the old version with no
  /// objects, never half-applied.
  ///
  /// v1 is the baseline: `crdt_records` (with `doc_id` and `field_path` as
  /// virtual columns generated from `key`, computed on read), the HLC and
  /// document indexes, and `crdt_meta`.
  static void _migrate(CommonDatabase db) {
    final version =
        db.select('PRAGMA user_version').first['user_version'] as int;
    if (version >= _schemaVersion) return;

    db.execute('BEGIN');
    try {
      db.execute('''
        CREATE TABLE IF NOT EXISTS crdt_records (
          collection TEXT NOT NULL,
          key        TEXT NOT NULL,
          value      TEXT NOT NULL,
          is_deleted INTEGER NOT NULL DEFAULT 0,
          hlc        TEXT NOT NULL,
          hlc_key    TEXT NOT NULL,
          crdt_type  TEXT NOT NULL DEFAULT 'lww',
          doc_id     TEXT GENERATED ALWAYS AS ($_docIdExpr) VIRTUAL,
          field_path TEXT GENERATED ALWAYS AS ($_fieldPathExpr) VIRTUAL,
          PRIMARY KEY (collection, key)
        )
      ''');
      db.execute(
        'CREATE INDEX IF NOT EXISTS idx_crdt_hlc '
        'ON crdt_records (collection, hlc_key)',
      );
      db.execute(
        'CREATE INDEX IF NOT EXISTS idx_crdt_doc '
        'ON crdt_records (collection, doc_id)',
      );
      db.execute('''
        CREATE TABLE IF NOT EXISTS crdt_meta (
          k TEXT PRIMARY KEY,
          v TEXT NOT NULL
        )
      ''');
      db.execute('PRAGMA user_version = $_schemaVersion');
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  static String _readOrCreateNodeId(CommonDatabase db) {
    final rows = db.select("SELECT v FROM crdt_meta WHERE k = 'node_id'");
    if (rows.isNotEmpty) return rows.first['v'] as String;
    final rng = Random.secure();
    final id = List.generate(8, (_) => rng.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    db.execute("INSERT INTO crdt_meta (k, v) VALUES ('node_id', ?)", [id]);
    return id;
  }

  static Hlc? _readMaxHlc(CommonDatabase db) {
    final rows = db.select(
      'SELECT hlc FROM crdt_records ORDER BY hlc_key DESC LIMIT 1',
    );
    return rows.isEmpty ? null : Hlc.parse(rows.first['hlc'] as String);
  }
}
