import 'dart:convert';

import 'package:conclave_core/conclave_core.dart' show BlobStore;
import 'package:sembast/sembast_io.dart';

/// A [BlobStore] backed by a [Sembast](https://pub.dev/packages/sembast)
/// database.
///
/// Each blob is stored as one record keyed by its blob key, with the bytes
/// held as a base64 string so any binary payload round-trips through Sembast's
/// JSON value model.
///
/// By default the store persists to a file via `databaseFactoryIo` at [path]
/// (or `'<namespace>.db'` when omitted). Tests and web hosts can inject a
/// different [factory] — for example `databaseFactoryMemory` for a fast,
/// disk-free store:
///
/// ```dart
/// SembastStore(namespace: 'notes', factory: databaseFactoryMemory);
/// ```
class SembastStore implements BlobStore {
  /// Creates a store namespaced by [namespace].
  ///
  /// [factory] overrides the Sembast database factory (defaults to the native
  /// file factory). [path] overrides the on-disk location and is ignored by
  /// the in-memory factory.
  SembastStore({
    required this.namespace,
    DatabaseFactory? factory,
    String? path,
  })  : _factory = factory ?? databaseFactoryIo,
        _path = path ?? '$namespace.db';

  /// Logical namespace for this store (used as the default file name stem).
  final String namespace;

  final DatabaseFactory _factory;
  final String _path;

  final StoreRef<String, String> _store = StoreRef<String, String>.main();
  Database? _db;

  Database get _open {
    final db = _db;
    if (db == null) {
      throw StateError('SembastStore.open() must be called before use');
    }
    return db;
  }

  @override
  Future<void> open() async {
    _db ??= await _factory.openDatabase(_path);
  }

  @override
  Future<List<int>?> read(String key) async {
    final value = await _store.record(key).get(_open);
    return value == null ? null : base64Decode(value);
  }

  @override
  Future<void> write(String key, List<int> bytes) async {
    await _store.record(key).put(_open, base64Encode(bytes));
  }

  @override
  Future<void> delete(String key) async {
    await _store.record(key).delete(_open);
  }

  @override
  Future<List<String>> keys({String? prefix}) async {
    final finder = prefix == null
        ? null
        : Finder(
            filter: Filter.custom(
              (record) => (record.key as String).startsWith(prefix),
            ),
          );
    final records = await _store.find(_open, finder: finder);
    return records.map((r) => r.key).toList();
  }

  @override
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
