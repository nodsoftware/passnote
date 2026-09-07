@TestOn('browser')
library;

import 'package:conclave_core/engine.dart';
import 'package:test/test.dart';

import '../../test_support/crdt_table_conformance.dart';

void main() {
  // sqlite3.wasm is served next to this test (test/web/sqlite3.wasm).
  SqliteCrdtTable.configureWeb(wasmUri: Uri.parse('sqlite3.wasm'));

  runCrdtTableConformance(
    'SqliteCrdtTable (wasm)',
    (_) => SqliteCrdtTable.open(':memory:'),
    supportsCompaction: true,
    dispose: (t) => (t as SqliteCrdtTable).close(),
  );
}
