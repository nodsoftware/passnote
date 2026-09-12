import 'dart:async';
import 'dart:io';

import 'package:sqlite3/common.dart';
import 'package:sqlite3/sqlite3.dart';

import '../exceptions.dart';

/// The path that means "no file": an in-memory database.
const inMemoryPath = ':memory:';

/// Opens a native SQLite database at [path] (`:memory:` for a transient one).
///
/// When [encryptionKey] is given, `PRAGMA key` is issued first and the open
/// **fails closed**: `PRAGMA cipher_version` must confirm the linked library
/// is a SQLCipher build, otherwise the key would be silently ignored and the
/// file written in plaintext. Throws [SqlCipherUnavailableException] when the
/// library is not SQLCipher.
FutureOr<CommonDatabase> openSqliteDb(String path, {List<int>? encryptionKey}) {
  final db = sqlite3.open(path);
  if (encryptionKey != null) {
    final hex =
        encryptionKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    db.execute("PRAGMA key = \"x'$hex'\"");
    // On a non-SQLCipher build `PRAGMA key` is an unknown pragma and is
    // silently ignored; `PRAGMA cipher_version` returning no row is the only
    // reliable signal. Refuse to continue rather than store plaintext.
    final cipherVersion = db.select('PRAGMA cipher_version');
    if (cipherVersion.isEmpty) {
      db.close();
      throw const SqlCipherUnavailableException();
    }
  }
  return db;
}

/// Whether a database file exists at [path]. Always `false` for `:memory:`.
bool databaseFileExists(String path) =>
    path != inMemoryPath && File(path).existsSync();

/// Moves the database at [path] and its `-wal` / `-shm` sidecars aside to
/// `<path>.<tag>`, quarantining an unreadable file. Returns the new base path.
///
/// A no-op for `:memory:`.
String quarantineDatabase(String path, String tag) {
  final dest = '$path.$tag';
  if (path == inMemoryPath) return dest;
  for (final suffix in const ['', '-wal', '-shm']) {
    final file = File('$path$suffix');
    if (file.existsSync()) file.renameSync('$dest$suffix');
  }
  return dest;
}

/// Replaces the database at [path] with a copy of [source], first clearing any
/// stale `-wal` / `-shm` sidecars. A no-op for `:memory:`.
void restoreDatabase({required String source, required String path}) {
  if (path == inMemoryPath) return;
  for (final suffix in const ['-wal', '-shm']) {
    final file = File('$path$suffix');
    if (file.existsSync()) file.deleteSync();
  }
  File(source).copySync(path);
}

/// Deletes the file at [path] if it exists (`VACUUM INTO` needs a free target).
void deleteFileIfPresent(String path) {
  final file = File(path);
  if (file.existsSync()) file.deleteSync();
}

/// No-op on native; see the web backend.
void configureWeb({Uri? wasmUri}) {}
