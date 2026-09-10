/// Conclave: an end-to-end encrypted, local-first CRDT sync engine for Dart.
///
/// Port interfaces, the SQLite-backed engine, typed collections, device
/// identity, the wire protocol, and an in-memory transport for testing. Flutter
/// bindings and batteries-included setup live in `package:conclave_flutter`.
library conclave;

export 'src/codec.dart';
export 'src/collection.dart';
export 'src/crdt/crdt_type.dart';
export 'src/id.dart';
export 'src/conclave.dart';
export 'src/database.dart';
export 'src/identity/device_roster.dart'
    show
        DeviceInfo,
        DeviceRecord,
        DeviceRosterEntry,
        DeviceState,
        KeyRotation,
        WrappedGroupKey,
        kDeviceCollection;
export 'src/merge_strategies.dart';
export 'src/map_crdt_table.dart';
export 'src/ports/cipher.dart';
export 'src/ports/crdt_table.dart';
export 'src/ports/identity.dart';
export 'src/ports/key_store.dart';
export 'src/ports/pake.dart';
export 'src/ports/merge_strategy.dart';
export 'src/ports/transport.dart';
export 'src/transport/in_memory_bus.dart';
export 'src/transport/in_memory_transport.dart';
