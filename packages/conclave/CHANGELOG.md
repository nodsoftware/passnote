# Changelog

## Unreleased

- **Breaking:** this package is renamed from `conclave_core` to `conclave`
  (`core` is not a name). Update imports to `package:conclave/conclave.dart` and
  `package:conclave/engine.dart`. The old `conclave` umbrella package is gone;
  its `conclaveBuilder` batteries-included setup now lives in
  `package:conclave_flutter`, which also re-exports this package plus
  `conclave_crypto` and `conclave_lan`.
- Added `Conclave.builder(appId:, salt:)`, a staged configuration API, and
  `ConclaveDefaults` / `ConclaveBuilder.installDefaults` for supplying its
  defaults. Prefer it over the low-level entry.
- **Breaking:** `Conclave.open(...)` is renamed `Conclave.lowLevel(...)` and now
  lives in the new `package:conclave/engine.dart` advanced library. The
  builder is the supported path.
- **Breaking:** the `BlobStore` port, the `EncryptedStore` decorator, and the
  `IdMasker` type are removed. Persistence and at-rest encryption move into the
  storage engine (a disk-backed `CrdtTable`); the `conclave_sembast` and
  `conclave_hive` adapter packages are removed with them. The default engine is
  now in-memory only until the disk-backed engine lands.
- **Breaking:** `Conclave.rotatePassphrase` and `Conclave.hasPendingRotation`
  are removed. Key rotation returns with the disk-backed engine and the
  device-pairing model.
- Added `SqliteCrdtTable` (in `package:conclave/engine.dart`): a
  disk-backed `CrdtTable` on `package:sqlite3`, with WAL mode, a `user_version`
  migration, a persisted node id, and optional SQLCipher at-rest encryption.
- **The disk-backed engine is now the default.** `Conclave.builder(...)` uses a
  SQLite engine per collection; `.engine(MapCrdtTable.new)` selects the
  in-memory engine. Engine selection is threaded through `Conclave`, `Database`,
  and `Collection` via an engine factory; `Collection` builds its engine
  asynchronously during the initial load.
- Added `CrdtTable.close()` (default no-op) so a disk-backed engine releases its
  file on `Database.close`.
- Added `InMemoryBus.paused` for simulating a network outage in tests.
- `SqliteCrdtTable` now runs on the web via `sqlite3/wasm` behind a
  conditional import; `SqliteCrdtTable.configureWeb(wasmUri:)` points it at the
  `sqlite3.wasm` module. Web persistence (an OPFS VFS) and web at-rest
  encryption are not implemented yet.
- Added `runCrdtTableConformance`, the shared `CrdtTable` behavioural contract.
- `SqliteCrdtTable` now recovers from a corrupt file. `init` runs
  `PRAGMA quick_check`; a file that will not open or does not pass is moved to
  `<path>.corrupt-<timestamp>` and the store is rebuilt — from
  `<path>.snapshot` if a readable one exists, otherwise empty. The schema
  migration now runs in one transaction, so an interrupted migration reopens
  at the old version, never half-applied.
- Added `ConclaveConfig.snapshotInterval` (default 30 minutes; `Duration.zero`
  disables): how often the disk-backed engine writes `<file>.snapshot` as a
  peerless recovery fallback.
- Added `Conclave.events`, a broadcast `Stream<ConclaveEvent>` carrying
  `PeerAppeared` / `PeerDisappeared` and `StoreRecovered`. A `reset` recovery
  triggers an automatic re-sync from peers.
- Added `CrdtTable.recoveries` (default empty) and the `SnapshotCapable`
  marker interface for engines that keep on-disk snapshots.
- Added the `Identity` port (`DevicePublicKey`, `WrappedKey`) — a per-device
  keypair for pairing, key wrap, and signed control messages.
  `Conclave.builder(...).identity(...)` overrides it; `Conclave.identity`
  exposes the resolved one (throws until one is configured).
- When an `Identity` is configured, a database now keeps a reserved, synced
  `__conclave_devices` collection: one `DeviceRecord` per paired device plus the
  random group key wrapped (`WrappedGroupKey`) to each device at a `keyEpoch`.
  `Database.collection` refuses the reserved name.
  - On open, the device unwraps its wrap and every user collection is encrypted
    with the **group key**, not the passphrase-derived key (which now only
    protects the roster).
  - A brand-new database with no connected peers founds its own group key
    (`Database.foundGroup()` is the explicit form). A device with no wrap opens
    in `DeviceState.needsPairing` — not an error; user collections stay
    unopenable until it is paired.
  - `Database.deviceState`, `listDevices()`, `admitDevice()`, `revokeDevice()`,
    and `refreshDeviceState()` manage the roster. It converges under the CRDT
    like any other collection.
  - `Identity` gained `fingerprintOf(DevicePublicKey)` so a device can key
    roster rows for a peer.
  - No `Identity` configured: unchanged — the passphrase-derived key encrypts
    everything and there is no roster.
- Added device pairing. `Conclave.startPairing(localId)` on the sponsor returns
  a nine-digit `PairingCode`; `Conclave.pairWith(localId, code)` on the new
  device runs a PAKE over the transport, receives the roster key, and returns a
  `DeviceState.ready` database. Wrong codes are rejected (`PairingRejected`) and
  the sponsor disarms the code after three failed tries.
  - Added the `Pake` port (`PakeSession`, `PakeResult`) and
    `ConclaveBuilder.pake(...)` / `ConclaveDefaults.pake`; the umbrella installs
    SPAKE2.
  - `PairingCode`, `PairingBundle`, `PairingRejected`, `PairingTimeout` are
    exported. `Conclave.cancelPairing()` drops an armed session.
- Added group-key rotation and device revocation. `Conclave.revokeDevice(localId,
  deviceId)` (also `Database.revokeDevice`) generates a fresh group key at the
  next epoch, re-wraps it to every other non-revoked device, re-keys this
  database, and marks the device revoked. Peers adopt the new epoch on sync; the
  revoked device drops to `DeviceState.revoked` and its user-data frames no
  longer authenticate. Concurrent revocations of different devices converge —
  the lowest-id survivor performs a final rotation excluding both.
  - `Conclave.devices(localId)` / `Database.devices()` return `DeviceInfo`
    (id, label, paired-at, revoked, is-this-device). `renameDevice` relabels.
  - User-collection frames now travel under the group-key cipher (control and
    roster frames stay on the passphrase/roster key), so a revoked device
    cannot read new data even though it can still see the roster.
  - Added `CrdtTable.rekey(newKey)` (default no-op); `SqliteCrdtTable.rekey`
    runs `PRAGMA rekey`.
- Added a forward-secrecy ratchet on each peer-to-peer transport session. Two
  peers derive a session root from the group key plus a random nonce each, then
  every frame is encrypted with a fresh message key from a hash chain and the
  previous chain key is wiped — a key captured later cannot decrypt earlier
  frames. A reconnect exchanges new nonces and starts a fresh chain; a group-key
  rotation tears every session down and re-handshakes. Control and roster
  bootstrap frames stay outside the ratchet. `RatchetSession` /
  `deriveRatchetRoot` / `newRatchetNonce` are on the advanced library. (Hash
  ratchet only — post-compromise security via a DH re-key is a later addition
  behind the same seam.)
  - `conclave` now depends on `package:crypto` for the ratchet's HKDF.
- Added per-field CRDT types. `CrdtType` is a sealed hierarchy — `LwwRegister`
  (the default and current behaviour), `OrSet`, and `PnCounter` — and
  `SchemaMergeStrategy({'qty': PnCounter(), 'tags': OrSet()})` assigns a type to
  named field paths, with every other field staying last-write-wins.
  - **Breaking:** `MergeStrategy.flatten` is replaced by
    `Iterable<FieldSpec> fields(document)` (each entry is
    `(path, value, CrdtType)`), and `unflatten` now takes `Iterable<FieldValue>`
    rows instead of a map. `ObjectMergeStrategy`, `ShallowMergeStrategy`, and
    `DeepMergeStrategy` are unchanged in behaviour — every field is
    `LwwRegister`.
  - `CrdtTable.put` gains an optional `crdtType` (defaults to `LwwRegister`).
    `SqliteCrdtTable` records it in a new `crdt_type` column (schema
    `user_version` 2; a v1 database is migrated in place and its rows default to
    `lww`). `MapCrdtTable` accepts and ignores it.
- Fixed `newId()` crashing on the web: its random bound was written as
  `1 << 32`, which wraps to 0 when compiled to JavaScript.
- The `OrSet` and `PnCounter` merge algorithms are wired: typed fields now
  merge by their CRDT rule instead of last-write-wins. `TypedCrdtTable` (on the
  advanced library) wraps every collection's engine and does the work — the
  engine itself stays a plain record store, so any `CrdtTable` implementation
  gets typed fields for free. Typed states are self-describing on the wire and
  at rest, so a peer or engine that does not store the `crdt_type` tag still
  merges them correctly.
  - An `OrSet` field holds a list. A put adds the elements that joined the
    list and removes the ones that left it; concurrent edits on other devices
    are preserved, and an add wins over a remove that did not observe it.
  - A `PnCounter` field holds a number that only changes through the new
    `Collection.increment(documentId, fieldPath, by:)` — each device
    accumulates its own deltas, so concurrent increments all count. The first
    put seeds the counter; a later put whose number differs from the counter's
    value throws `ArgumentError`.
  - The `CrdtTable` port gains `nodeId`, the stable replica id the typed layer
    keys counter contributions by.
  - `runCrdtTypeConformance` joins the conformance suite: the typed behavioural
    contract, run over both shipped engines.

## 0.1.0

First public version of the pure-Dart core.

- `Conclave` / `Database` / `Collection<T>` hierarchy with typed documents via
  `Codec<T>`.
- Conflict-free merge using Hybrid Logical Clocks, with a configurable
  `MergeStrategy` (whole-document, shallow, or deep).
- `CrdtTable` port with an in-memory `MapCrdtTable`; per-document blob
  persistence so a write costs one blob, not a full rewrite.
- Secondary indexes and pagination on `Collection`: `findBy(field, value)` and
  `limit` / `offset` on `all` and `where`.
- Sync protocol with watermarked deltas, manual `forceSync`, per-peer inbound
  frame rate limiting, and an `onRemoteConflict` callback.
- Collection lifecycle: `ready`, `length`, and database `close` / `forget` /
  `reopenDatabase`; crash-safe `rotatePassphrase` with dual-direction recovery.
- `EncryptedStore` decorator, `InMemoryBus` / `InMemoryTransport` for tests, and
  a public `newId()` id generator.
