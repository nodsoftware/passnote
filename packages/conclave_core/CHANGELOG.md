# Changelog

## Unreleased

- Added `Conclave.builder(appId:, salt:)`, a staged configuration API, and
  `ConclaveDefaults` / `ConclaveBuilder.installDefaults` for supplying its
  defaults. Prefer it over the low-level entry.
- **Breaking:** `Conclave.open(...)` is renamed `Conclave.lowLevel(...)` and now
  lives in the new `package:conclave_core/engine.dart` advanced library. The
  builder is the supported path.

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
