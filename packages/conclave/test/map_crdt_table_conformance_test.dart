import 'package:conclave/engine.dart';

import '../test_support/crdt_table_conformance.dart';

void main() {
  // MapCrdtTable is in-memory and compacts via Collection.compact, not in place.
  runCrdtTableConformance('MapCrdtTable', (table) => MapCrdtTable(table));
}
