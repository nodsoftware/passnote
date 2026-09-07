import 'dart:async';

import 'package:sqlite3/common.dart';
import 'package:sqlite3/sqlite3.dart';

/// Opens a native SQLite database at [path] (`:memory:` for a transient one).
///
/// When [encryptionKey] is given, `PRAGMA key` is issued first (a no-op unless
/// the native library is a SQLCipher build).
FutureOr<CommonDatabase> openSqliteDb(String path, {List<int>? encryptionKey}) {
  final db = sqlite3.open(path);
  if (encryptionKey != null) {
    final hex =
        encryptionKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    db.execute("PRAGMA key = \"x'$hex'\"");
  }
  return db;
}

/// No-op on native; see the web backend.
void configureWeb({Uri? wasmUri}) {}
