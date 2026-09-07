/// Advanced and testing surface for Conclave.
///
/// The supported entry point is [Conclave.builder] from
/// `package:conclave_core/conclave_core.dart`. Use this library only to build a
/// custom adapter, wire everything by hand with [Conclave.lowLevel], or run the
/// port conformance suites.
///
/// Everything here is covered by semver, but may change within a minor version
/// with a CHANGELOG note. Application code should not need it.
library conclave_core.engine;

export 'src/conclave.dart'
    show
        Conclave,
        ConclaveEvent,
        PairingBundle,
        PairingCode,
        PairingRejected,
        PairingTimeout,
        PeerAppeared,
        PeerDisappeared,
        StoreRecovered;
export 'src/identity/device_roster.dart'
    show
        DeviceRecord,
        DeviceRosterEntry,
        DeviceState,
        WrappedGroupKey,
        kDeviceCollection;
export 'src/ports/pake.dart';

export 'src/engine/sqlite_crdt_table.dart';
export 'src/map_crdt_table.dart';
export 'src/ports/cipher.dart';
export 'src/ports/crdt_table.dart';
export 'src/ports/identity.dart';
export 'src/ports/key_store.dart';
export 'src/ports/merge_strategy.dart';
export 'src/ports/transport.dart';
export 'src/transport/in_memory_bus.dart';
export 'src/transport/in_memory_transport.dart';
