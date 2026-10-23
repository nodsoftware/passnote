# Changelog

## 1.1.1

- Frames waiting to be handled are bounded to 32 MiB per peer and 128 MiB in
  total; beyond that they are dropped like rate-limited frames.
- `SqliteCrdtTable.rekey` rewrites an existing recovery snapshot under the new
  key immediately.
- Records refused by `maxClockDrift` are reported as `FrameHandlingFailed` (a
  `StateError`), at most once a minute per peer.
- A verified ratchet hello carrying an ephemeral key that already served an
  ended session with that peer is ignored instead of resetting the session.

## 1.1.0

Security release; see the repository `CHANGELOG.md` for the summary and the
upgrade note (every device moves to 1.1 together).

- **Wire version 2**, and version 1 is no longer spoken. Sessions are rooted in
  an ephemeral X25519 agreement signed by each device's roster identity
  (`RatchetHelloMessage` carries the key, the device id and an Ed25519
  signature), and the root is `HKDF(groupKey ‖ agreement)`. With an identity
  configured, user-collection deltas, reconciliation and watermarks are
  accepted only inside a session; a frame under the passphrase key carries the
  handshake, ratchet hellos and the roster only. The handshake keeps frame
  version 1 so 1.0 peers report `PeerIncompatible`.
- Inbound frames are handled one at a time per peer, in arrival order.
- `PassnoteConfig.maxClockDrift` (default 10 minutes): inbound documents with a
  record stamped further ahead are refused.
- Roster: revocations judged in epoch order with the trust chain recomputed
  after each; records signed by a revoked device no longer introduce anyone,
  and `revokeDevice` re-signs the records the revoked device last wrote; device
  ids must equal the fingerprint of their key; rotation rows are
  `rotation:<epoch>:<device>`, so concurrent rotations both survive; new
  `RosterPinsCorruptException` when stored pins are unreadable.
- Pairing: the grant carries the sponsor's trust pins
  (`PairingBundle.rosterPins`), adopted before the first sync; a grant without
  them is refused. Tries are budgeted 3 per peer and 20 per code, pending
  exchanges are kept per peer, and a joiner fails only when every greeted peer
  has refused. The channel key is HKDF of the PAKE output and the rendezvous
  tag a hash of the app id (no Argon2id runs per exchange).
- A database auto-founds only when this device has never held trust pins for
  it; `pairWith` never auto-founds.
- `Passnote.forget` also clears the key store entries of a database that is
  not open.
- **`engine.dart` changes:** `deriveRatchetRoot` now takes `sharedSecret`,
  `ephemeralA` and `ephemeralB` instead of `nonceA` and `nonceB`; new
  `RatchetEphemeral`; `newRatchetNonce` is deprecated and unused.
- New dependency: `cryptography` (for the session's X25519).

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
