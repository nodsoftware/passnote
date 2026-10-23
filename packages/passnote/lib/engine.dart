/// Advanced and testing surface for Passnote.
///
/// The supported entry point is [Passnote.builder] from
/// `package:passnote/passnote.dart`. Use this library only to build a
/// custom adapter, wire everything by hand with [passnoteLowLevel], or run the
/// port conformance suites.
///
/// Everything here is covered by semver, but may change within a minor version
/// with a CHANGELOG note. Application code should not need it.
library passnote.engine;

export 'src/passnote.dart'
    show
        Passnote,
        PassnoteEvent,
        PairingBundle,
        PairingCode,
        PairingRejected,
        PairingTimeout,
        PeerAppeared,
        PeerDisappeared,
        StoreRecovered,
        passnoteLowLevel;
export 'src/exceptions.dart';
export 'src/identity/device_roster.dart'
    show
        DeviceInfo,
        DeviceRecord,
        DeviceRosterEntry,
        DeviceState,
        KeyRotation,
        WrappedGroupKey,
        kDeviceCollection;
export 'src/identity/ratchet.dart'
    show RatchetEphemeral, RatchetSession, deriveRatchetRoot, newRatchetNonce;
export 'src/ports/pake.dart';

export 'src/crdt/crdt_type.dart';
export 'src/engine/sqlite_crdt_table.dart';
export 'src/map_crdt_table.dart';
export 'src/protocol/anti_entropy.dart';
export 'src/protocol/frame_window.dart';
export 'src/protocol/handshake.dart';
export 'src/protocol/reconciliation.dart';
export 'src/typed_crdt_table.dart';
export 'src/ports/cipher.dart';
export 'src/ports/crdt_table.dart';
export 'src/ports/identity.dart';
export 'src/ports/key_store.dart';
export 'src/ports/merge_strategy.dart';
export 'src/ports/query.dart';
export 'src/ports/transport.dart';
export 'src/transport/in_memory_bus.dart';
export 'src/transport/in_memory_transport.dart';
