/// Conclave: an end-to-end encrypted, local-first CRDT sync engine for Dart.
///
/// This is the **frozen** app-facing library, covered by semver from v1.0.0
/// (see `VERSIONING.md`): the builder entry, databases, collections and
/// queries, codecs and their annotations, merge strategies and CRDT types,
/// the device / pairing / recovery API, configuration, events, and the port
/// interfaces the builder's overrides accept.
///
/// Engine implementations, the conformance suites, protocol internals, and
/// `Conclave.lowLevel` wiring live on the advanced
/// `package:conclave/engine.dart` library. Flutter bindings and
/// batteries-included setup live in `package:conclave_flutter`.
library;

export 'src/annotations.dart';
export 'src/codec.dart';
export 'src/collection.dart';
export 'src/conclave.dart';
export 'src/crdt/crdt_type.dart';
export 'src/database.dart';
export 'src/id.dart';
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
export 'src/ports/cipher.dart';
export 'src/ports/crdt_table.dart';
export 'src/ports/identity.dart';
export 'src/ports/key_store.dart';
export 'src/ports/merge_strategy.dart';
export 'src/ports/pake.dart';
export 'src/ports/query.dart';
export 'src/ports/transport.dart';
