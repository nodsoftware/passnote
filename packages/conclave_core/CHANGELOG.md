# Changelog

## Unreleased

- Added `Conclave.builder(appId:, salt:)`, a staged configuration API, and
  `ConclaveDefaults` / `ConclaveBuilder.installDefaults` for supplying its
  defaults. Prefer it over the low-level entry.
- **Breaking:** `Conclave.open(...)` is renamed `Conclave.lowLevel(...)` and now
  lives in the new `package:conclave_core/engine.dart` advanced library. The
  builder is the supported path.
- **Breaking:** the `BlobStore` port, the `EncryptedStore` decorator, and the
  `IdMasker` type are removed. Persistence and at-rest encryption move into the
  storage engine (a disk-backed `CrdtTable`); the `conclave_sembast` and
  `conclave_hive` adapter packages are removed with them. The default engine is
  now in-memory only until the disk-backed engine lands.
- **Breaking:** `Conclave.rotatePassphrase` and `Conclave.hasPendingRotation`
  are removed. Key rotation returns with the disk-backed engine and the
  device-pairing model.
- Added `SqliteCrdtTable` (in `package:conclave_core/engine.dart`): a
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
  exposes the resolved one (throws until one is configured). Not yet used by
  `openDatabase`; pairing and key wrap land next.

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
