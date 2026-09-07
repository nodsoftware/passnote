import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crdt/crdt.dart';
import 'package:sqlite3/sqlite3.dart';

import '../ports/crdt_table.dart';

/// A [CrdtTable] backed by SQLite (`package:sqlite3`).
///
/// Records live in a single `crdt_records` table keyed by `(collection, key)`;
/// one SQLite database can host every collection. Values are stored as JSON
/// text. Ordering and sync filtering use `hlc_key`, a fixed-width sortable
/// encoding of the record's Hybrid Logical Clock, so `WHERE hlc_key > ?` is a
/// correct causal comparison.
///
/// Open one with [open]. On native targets pass an
/// [encryptionKey] to use SQLCipher (the native library must be a SQLCipher
/// build; the Dart API is unchanged). [isPersistent] is `true`: [Collection]
/// delegates its whole lifecycle here.
final class SqliteCrdtTable implements CrdtTable {
  SqliteCrdtTable._(this._db, this._nodeId, this._canonical);

  /// Opens (creating if needed) a database at [path]. Pass `":memory:"` for a
  /// transient database. [encryptionKey] enables SQLCipher on a SQLCipher build
  /// of the native library.
  static Future<SqliteCrdtTable> open(
    String path, {
    List<int>? encryptionKey,
  }) async {
    final db = sqlite3.open(path);
    if (encryptionKey != null) {
      final hex =
          encryptionKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      db.execute("PRAGMA key = \"x'$hex'\"");
    }
    db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA synchronous = NORMAL');
    db.execute('PRAGMA foreign_keys = ON');

    _migrate(db);

    final nodeId = _readOrCreateNodeId(db);
    final canonical = _readMaxHlc(db) ?? Hlc.zero(nodeId);
    return SqliteCrdtTable._(db, nodeId, canonical);
  }

  final Database _db;
  final String _nodeId;
  Hlc _canonical;
  final _watchers = <String, StreamController<void>>{};
  bool _closed = false;

  @override
  bool get isPersistent => true;

  @override
  Future<void> init() async {}

  /// Closes the database and every watch stream. Safe to call more than once.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final c in _watchers.values) {
      await c.close();
    }
    _watchers.clear();
    _db.dispose();
  }

  @override
  Future<void> put(
    String table,
    String key,
    Object? value, {
    bool isDeleted = false,
  }) async {
    _canonical = _canonical.increment();
    _db.execute(
      'INSERT INTO crdt_records (collection, key, value, is_deleted, hlc, '
      'hlc_key) VALUES (?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(collection, key) DO UPDATE SET '
      'value = excluded.value, is_deleted = excluded.is_deleted, '
      'hlc = excluded.hlc, hlc_key = excluded.hlc_key',
      [
        table,
        key,
        jsonEncode(value),
        isDeleted ? 1 : 0,
        _canonical.toString(),
        _hlcKey(_canonical),
      ],
    );
    _emit(table);
  }

  @override
  Future<Object?> value(String table, String key) async {
    final rows = _db.select(
      'SELECT value FROM crdt_records '
      'WHERE collection = ? AND key = ? AND is_deleted = 0',
      [table, key],
    );
    if (rows.isEmpty) return null;
    return jsonDecode(rows.first['value'] as String);
  }

  @override
  Future<Map<String, Object?>> liveFields(String table, String prefix) async {
    final rows = prefix.isEmpty
        ? _db.select(
            'SELECT key, value FROM crdt_records '
            'WHERE collection = ? AND is_deleted = 0',
            [table],
          )
        : _db.select(
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
    final rows = prefix.isEmpty
        ? _db.select(
            'SELECT key FROM crdt_records '
            'WHERE collection = ? AND is_deleted = 0',
            [table],
          )
        : _db.select(
            'SELECT key FROM crdt_records '
            'WHERE collection = ? AND is_deleted = 0 AND substr(key, 1, ?) = ?',
            [table, prefix.length, prefix],
          );
    return {for (final r in rows) r['key'] as String};
  }

  @override
  Future<CrdtChangeset> changeset(String table, {String? sinceHlc}) async {
    final ResultSet rows;
    if (sinceHlc == null || sinceHlc.isEmpty) {
      rows = _db.select(
        'SELECT key, value, is_deleted, hlc FROM crdt_records '
        'WHERE collection = ?',
        [table],
      );
    } else {
      rows = _db.select(
        'SELECT key, value, is_deleted, hlc FROM crdt_records '
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
          },
      ],
    };
  }

  @override
  String maxHlc(String table) {
    final rows = _db.select(
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

    _db.execute('BEGIN');
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

          final existing = _db.select(
            'SELECT hlc FROM crdt_records WHERE collection = ? AND key = ?',
            [table, key],
          );
          if (existing.isNotEmpty &&
              Hlc.parse(existing.first['hlc'] as String) >= incoming) {
            continue;
          }

          _db.execute(
            'INSERT INTO crdt_records (collection, key, value, is_deleted, '
            'hlc, hlc_key) VALUES (?, ?, ?, ?, ?, ?) '
            'ON CONFLICT(collection, key) DO UPDATE SET '
            'value = excluded.value, is_deleted = excluded.is_deleted, '
            'hlc = excluded.hlc, hlc_key = excluded.hlc_key',
            [
              table,
              key,
              jsonEncode(record['value']),
              (record['is_deleted'] as bool) ? 1 : 0,
              incoming.toString(),
              _hlcKey(incoming),
            ],
          );
          changed = true;
          touchedTables.add(table);
        }
      }
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
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
    _db.execute(
      'DELETE FROM crdt_records '
      'WHERE collection = ? AND is_deleted = 1 AND hlc_key < ?',
      [table, _hlcKey(cutoff)],
    );
    final removed = _db.updatedRows;
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

  static void _migrate(Database db) {
    final version =
        db.select('PRAGMA user_version').first['user_version'] as int;
    if (version < 1) {
      db.execute('''
        CREATE TABLE IF NOT EXISTS crdt_records (
          collection TEXT NOT NULL,
          key        TEXT NOT NULL,
          value      TEXT NOT NULL,
          is_deleted INTEGER NOT NULL DEFAULT 0,
          hlc        TEXT NOT NULL,
          hlc_key    TEXT NOT NULL,
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
      db.execute('PRAGMA user_version = 1');
    }
  }

  static String _readOrCreateNodeId(Database db) {
    final rows = db.select("SELECT v FROM crdt_meta WHERE k = 'node_id'");
    if (rows.isNotEmpty) return rows.first['v'] as String;
    final rng = Random.secure();
    final id = List.generate(8, (_) => rng.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    db.execute("INSERT INTO crdt_meta (k, v) VALUES ('node_id', ?)", [id]);
    return id;
  }

  static Hlc? _readMaxHlc(Database db) {
    final rows = db.select(
      'SELECT hlc FROM crdt_records ORDER BY hlc_key DESC LIMIT 1',
    );
    return rows.isEmpty ? null : Hlc.parse(rows.first['hlc'] as String);
  }
}
