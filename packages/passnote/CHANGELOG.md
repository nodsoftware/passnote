# Changelog

## 1.0.0

First release.

- Typed collections over a CRDT store: `put`, `get`, `delete`, `watch`, and
  indexed queries with keyset pagination and live watching.
- Deterministic merging by hybrid logical clock, with per-field CRDT types
  (`LwwRegister`, `OrSet`, `PnCounter`) declared through a merge strategy.
- A SQLite storage engine with SQLCipher encryption at rest (verified on
  open), transactional schema management, corruption recovery from periodic
  snapshots, and an in-memory engine for tests.
- A binary wire protocol (version 1) with a fail-closed decoder, streamed
  bounded sync frames, periodic anti-entropy, and range-fingerprint
  reconciliation that finds any gap in a few round trips.
- Device membership: a per-device keypair port, a synced device roster with
  Ed25519-signed rows, pairing over a PAKE code, revocation with group-key
  rotation, a forward-secrecy ratchet per connection, and an opt-in recovery
  phrase.
- Two library surfaces: `package:passnote/passnote.dart` (frozen app-facing
  API) and `package:passnote/engine.dart` (advanced wiring, engine and
  transport implementations, conformance suites). See `VERSIONING.md`.
