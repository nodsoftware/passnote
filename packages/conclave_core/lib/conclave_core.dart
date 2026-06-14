/// Pure-Dart core for Conclave: port interfaces, engine, CRDT collections,
/// encrypted-store decorator, and in-memory transport for testing.
library conclave_core;

export 'src/codec.dart';
export 'src/collection.dart';
export 'src/id.dart';
export 'src/conclave.dart';
export 'src/database.dart';
export 'src/encrypted_store.dart';
export 'src/merge_strategies.dart';
export 'src/ports/blob_store.dart';
export 'src/ports/cipher.dart';
export 'src/ports/key_store.dart';
export 'src/ports/merge_strategy.dart';
export 'src/ports/transport.dart';
export 'src/transport/in_memory_bus.dart';
export 'src/transport/in_memory_transport.dart';
