import 'package:conclave_sembast/conclave_sembast.dart';
import 'package:sembast/sembast_memory.dart';

// The conformance suite lives in conclave_core's test_support (outside lib/ so
// package:test stays out of the published core surface); import it by path.
import '../../conclave_core/test_support/blob_store_conformance.dart';

void main() {
  var counter = 0;
  runBlobStoreConformance(
    () => SembastStore(
      // Unique path per store: databaseFactoryMemory keys databases by path,
      // so a shared name would leak state between conformance tests.
      namespace: 'conformance_${counter++}',
      factory: databaseFactoryMemory,
    ),
  );
}
