import 'dart:io';
import 'dart:typed_data';

/// Deterministically corrupts the SQLite database file at [path] so that a
/// subsequent open fails `PRAGMA quick_check`.
///
/// Every byte from [offset] to the end of the file is overwritten with `0xDB`.
/// The default keeps page 1 (the file header and schema) intact and scrambles
/// the b-tree pages after it, so the file stays "a database" but a malformed
/// one. The `-wal` and `-shm` sidecars are removed so the corrupted main file
/// is what gets read on the next open.
void corruptDatabaseFile(String path, {int offset = 4096}) {
  for (final sidecar in ['$path-wal', '$path-shm']) {
    final file = File(sidecar);
    if (file.existsSync()) file.deleteSync();
  }

  final file = File(path);
  final bytes = Uint8List.fromList(file.readAsBytesSync());
  if (bytes.length <= offset + 512) {
    throw StateError('$path is too small to corrupt past offset $offset');
  }
  for (var i = offset; i < bytes.length; i++) {
    bytes[i] = 0xDB;
  }
  file.writeAsBytesSync(bytes, flush: true);
}
