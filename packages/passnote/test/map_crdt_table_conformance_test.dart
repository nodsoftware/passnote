import 'package:passnote/engine.dart';

import '../test_support/crdt_table_conformance.dart';

void main() {
  // MapCrdtTable is in-memory and compacts via Collection.compact, not in place.
  runCrdtTableConformance('MapCrdtTable', (table) => MapCrdtTable(table));

  // The typed layer must preserve the base contract and add the per-type
  // merge rules, over this engine.
  runCrdtTableConformance(
    'TypedCrdtTable over MapCrdtTable',
    (table) => TypedCrdtTable(MapCrdtTable(table)),
  );
  runCrdtTypeConformance('MapCrdtTable', (table) => MapCrdtTable(table));
}
