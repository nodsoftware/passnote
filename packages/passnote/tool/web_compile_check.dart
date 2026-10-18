// Compile-only: proves passnote builds for the web (no dart:io leak).
import 'package:passnote/passnote.dart' as api;
import 'package:passnote/engine.dart' as engine;

void main() {
  // Touch the web-relevant surface so tree-shaking keeps it.
  engine.SqliteCrdtTable(':memory:');
  engine.MapCrdtTable('t');
  api.newId();
}
