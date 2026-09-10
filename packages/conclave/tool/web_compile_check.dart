// Compile-only: proves conclave builds for the web (no dart:io leak).
import 'package:conclave/conclave.dart' as api;
import 'package:conclave/engine.dart' as engine;

void main() {
  // Touch the web-relevant surface so tree-shaking keeps it.
  engine.SqliteCrdtTable(':memory:');
  engine.MapCrdtTable('t');
  api.newId();
}
