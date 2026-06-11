import 'dart:typed_data';

import 'package:conclave_core/conclave_core.dart' show BlobStore;
import 'package:hive_ce/hive.dart';

/// A [BlobStore] backed by a [Hive CE](https://pub.dev/packages/hive_ce) box.
///
/// Each blob is stored as a `Uint8List` value keyed by its blob key. Blob keys
/// are arbitrary strings (e.g. `col/doc1`); they are used directly as Hive box
/// keys and never touch the filesystem, so they need no sanitisation.
///
/// The box itself is one file named after a sanitised [namespace]. Provide
/// [path] to control where the box file lives (a temp directory in tests, the
/// app documents directory in production):
///
/// ```dart
/// final store = HiveStore(namespace: 'notes/home', path: dir.path);
/// await store.open();
/// ```
class HiveStore implements BlobStore {
  /// Creates a store whose box file is derived from [namespace] and lives in
  /// [path] (the Hive default location when omitted).
  HiveStore({required this.namespace, this.path});

  /// Logical namespace for this store; sanitised to form the box name.
  final String namespace;

  /// Directory holding the box file. When `null`, Hive's default is used.
  final String? path;

  Box<Uint8List>? _box;

  /// Box names must be ASCII; map anything else to `_` so arbitrary
  /// namespaces (e.g. `appId/dbId`) yield a valid, stable file name.
  String get _boxName =>
      namespace.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_').toLowerCase();

  Box<Uint8List> get _open {
    final box = _box;
    if (box == null) {
      throw StateError('HiveStore.open() must be called before use');
    }
    return box;
  }

  @override
  Future<void> open() async {
    _box ??= await Hive.openBox<Uint8List>(_boxName, path: path);
  }

  @override
  Future<List<int>?> read(String key) async => _open.get(key);

  @override
  Future<void> write(String key, List<int> bytes) async =>
      _open.put(key, Uint8List.fromList(bytes));

  @override
  Future<void> delete(String key) async => _open.delete(key);

  @override
  Future<List<String>> keys({String? prefix}) async {
    final all = _open.keys.cast<String>();
    if (prefix == null) return all.toList();
    return all.where((k) => k.startsWith(prefix)).toList();
  }

  @override
  Future<void> close() async {
    await _box?.close();
    _box = null;
  }
}
