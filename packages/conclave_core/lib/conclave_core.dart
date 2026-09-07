/// Pure-Dart core for Conclave: port interfaces, CRDT engine, typed
/// collections, protocol, and an in-memory transport for testing.
library conclave_core;

export 'src/codec.dart';
export 'src/collection.dart';
export 'src/id.dart';
export 'src/conclave.dart';
export 'src/database.dart';
export 'src/identity/device_roster.dart'
    show
        DeviceRecord,
        DeviceRosterEntry,
        DeviceState,
        WrappedGroupKey,
        kDeviceCollection;
export 'src/merge_strategies.dart';
export 'src/map_crdt_table.dart';
export 'src/ports/cipher.dart';
export 'src/ports/crdt_table.dart';
export 'src/ports/identity.dart';
export 'src/ports/key_store.dart';
export 'src/ports/merge_strategy.dart';
export 'src/ports/transport.dart';
export 'src/transport/in_memory_bus.dart';
export 'src/transport/in_memory_transport.dart';
