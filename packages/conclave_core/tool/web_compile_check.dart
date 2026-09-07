// Compile-only: proves conclave_core builds for the web (no dart:io leak).
import 'package:conclave_core/conclave_core.dart' as api;
import 'package:conclave_core/engine.dart' as engine;

void main() {
  // Touch the web-relevant surface so tree-shaking keeps it.
  engine.SqliteCrdtTable(':memory:');
  engine.MapCrdtTable('t');
  api.newId();
}
