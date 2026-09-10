import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crdt/crdt.dart';
import 'package:sqlite3/common.dart';

import '../crdt/crdt_type.dart';
import '../ports/crdt_table.dart';
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
/// an [encryptionKey] to use SQLCipher (the native library must be a SQLCipher
/// build; the Dart API is unchanged).
///
/// ## Corruption recovery
///
/// [init] runs `PRAGMA quick_check` on open. If the file will not open or does
/// not pass, it is moved aside to `<path>.corrupt-<timestamp>` and the store is
/// rebuilt: from `<path>.snapshot` if a readable one exists, otherwise empty
/// (and [recoveries] emits so the sync layer can pull the data back from a
/// peer). Set [snapshotInterval] (or [ConclaveConfig.snapshotInterval]) to keep
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

  @override
  set snapshotInterval(Duration value) => _snapshotInterval = value;

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

  /// Opens [path] and returns the handle only if `PRAGMA quick_check` passes;
  /// otherwise disposes it and returns `null`.
  Future<CommonDatabase?> _openIfHealthy(String path) async {
    CommonDatabase db;
    try {
      db = await backend.openSqliteDb(path, encryptionKey: _encryptionKey);
    } catch (_) {
      return null;
    }
    try {
      final rows = db.select('PRAGMA quick_check');
      if (rows.isNotEmpty && rows.first.values.first == 'ok') return db;
    } catch (_) {
      // Unreadable enough that quick_check itself failed.
    }
    db.dispose();
    return null;
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

  /// Re-encrypts the database under [newKey] with SQLCipher's `PRAGMA rekey`
  /// (a no-op on a non-SQLCipher build). All data is preserved. Subsequent
  /// opens and recovery snapshots use [newKey].
  @override
  Future<void> rekey(List<int> newKey) async {
    _encryptionKey = List<int>.unmodifiable(newKey);
    final db = _db;
    if (db == null) return;
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
    _db?.dispose();
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
  Future<CrdtChangeset> changeset(String table, {String? sinceHlc}) async {
    if (_db == null) return {table: <CrdtRecord>[]};
    final ResultSet rows;
    if (sinceHlc == null || sinceHlc.isEmpty) {
      rows = _open.select(
        'SELECT key, value, is_deleted, hlc, crdt_type FROM crdt_records '
        'WHERE collection = ?',
        [table],
      );
    } else {
      rows = _open.select(
        'SELECT key, value, is_deleted, hlc, crdt_type FROM crdt_records '
        'WHERE collection = ? AND hlc_key > ?',
        [table, _hlcKey(Hlc.parse(sinceHlc))],
      );
    }
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
  static const int _schemaVersion = 2;

  /// Brings the schema up to date. The whole step runs in one transaction —
  /// including the `user_version` bump, which is header state and rolls back
  /// with it — so an interrupted migration reopens at the old version with no
  /// objects, never half-applied.
  ///
  /// - v1 created `crdt_records`, its HLC index, and `crdt_meta`.
  /// - v2 adds the per-record `crdt_type` column (the field's CRDT merge rule).
  ///   A database created fresh gets the column in `CREATE TABLE`; a v1 database
  ///   gets it by `ALTER TABLE`, and its existing rows default to `'lww'`
  ///   (last-write-wins, the behaviour before per-field types).
  static void _migrate(CommonDatabase db) {
    final version =
        db.select('PRAGMA user_version').first['user_version'] as int;
    if (version >= _schemaVersion) return;

    db.execute('BEGIN');
    try {
      if (version < 1) {
        db.execute('''
          CREATE TABLE IF NOT EXISTS crdt_records (
            collection TEXT NOT NULL,
            key        TEXT NOT NULL,
            value      TEXT NOT NULL,
            is_deleted INTEGER NOT NULL DEFAULT 0,
            hlc        TEXT NOT NULL,
            hlc_key    TEXT NOT NULL,
            crdt_type  TEXT NOT NULL DEFAULT 'lww',
            PRIMARY KEY (collection, key)
          )
        ''');
        db.execute(
          'CREATE INDEX IF NOT EXISTS idx_crdt_hlc '
          'ON crdt_records (collection, hlc_key)',
        );
        db.execute('''
          CREATE TABLE IF NOT EXISTS crdt_meta (
            k TEXT PRIMARY KEY,
            v TEXT NOT NULL
          )
        ''');
      } else if (version < 2) {
        db.execute(
          "ALTER TABLE crdt_records ADD COLUMN crdt_type TEXT NOT NULL "
          "DEFAULT 'lww'",
        );
      }
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
