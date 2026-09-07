import 'dart:async';

import 'package:sqlite3/wasm.dart';

/// URL the `sqlite3.wasm` module is fetched from. The web app must serve a
/// build compatible with this `sqlite3` package version (see the package's
/// GitHub releases) and set this before opening a database.
Uri sqliteWasmUri = Uri.parse('sqlite3.wasm');

WasmSqlite3? _wasm;

/// Opens a wasm SQLite database.
///
/// [path] names a file inside an in-memory VFS: nothing is persisted across
/// page loads yet (a persistent OPFS / IndexedDB VFS is planned). [PRAGMA key]
/// is a no-op on the wasm build, so [encryptionKey] does not encrypt at rest on
/// the web; wrap values before storing them if that matters.
Future<CommonDatabase> openSqliteDb(
  String path, {
  List<int>? encryptionKey,
}) async {
  final wasm = _wasm ??= await WasmSqlite3.loadFromUrl(sqliteWasmUri);
  wasm.registerVirtualFileSystem(InMemoryFileSystem(), makeDefault: true);
  return wasm.open(path);
}

/// Overrides where `sqlite3.wasm` is fetched from.
void configureWeb({Uri? wasmUri}) {
  if (wasmUri != null) sqliteWasmUri = wasmUri;
}
