import 'dart:io';

import 'package:conclave_hive/conclave_hive.dart';

// Shared conformance suite from conclave_core's test_support (kept outside
// lib/ so package:test stays out of the published core surface).
import '../../conclave_core/test_support/blob_store_conformance.dart';

void main() {
  // One temp dir for all box files; each store gets a unique namespace so the
  // conformance tests never share state.
  final tempDir = Directory.systemTemp.createTempSync('conclave_hive_test');
  var counter = 0;

  runBlobStoreConformance(
    () => HiveStore(
      namespace: 'conformance_${counter++}',
      path: tempDir.path,
    ),
  );
}
