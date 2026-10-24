# Passnote releases

All five packages release together with matching versions. Per-package detail
lives in each package's own `CHANGELOG.md`; this file is the cross-package
summary.

## 1.1.2

A bug-fix patch for defects found while porting Passnote to Rust; upgrading
is recommended. Wire- and API-compatible with 1.1.0 and 1.1.1: devices on any
1.1 release sync with each other.

- **The local clock survives a reopen.** A SQLite store reopened after
  merging a peer's records stamped local writes with the peer's node id, and
  refused every local write while a stored record was more than a minute
  ahead. The clock now resumes from the newest record not ahead of the
  device's own time, under its own node id.
- **A record at the HLC counter limit no longer blocks writes.** After
  adopting a record whose counter is 0xFFFF, the next local write moves to
  the next microsecond with counter 0 instead of failing, on both engines.
- **Stores a key rotation did not reach open again.** A collection that was
  not open during a revocation or passphrase rotation refused the new key for
  good. It now opens under its earlier key and is re-keyed on the spot.
- **No half-written documents.** Reads could see a document part-way through
  a put, and a crash part-way through left it half-written on disk. Reads now
  wait for the write in progress, and a put is one SQLite transaction.
- **An unknown roster row no longer breaks the roster.** One row of a kind
  this version does not know made every roster read throw.
- **Text outside the Basic Multilingual Plane.** Document ids with emoji lost
  their fields on disk, and the in-memory engine ordered such text unlike
  SQLite; both now work by code point.
- **Mnemonics use every byte value.** Generated recovery phrases never
  encoded the byte 0xFF.
- **A restarted peer is renegotiated with** even when the transport never
  reported it lost: each instance advertises an `inst:` handshake token.
- Malformed HLCs on the wire are refused when the frame is decoded instead of
  failing later.

## 1.1.1

A security patch from a second review of 1.1.0; upgrading is recommended.
Wire- and API-compatible with 1.1.0: devices on 1.1.0 and 1.1.1 sync with
each other.

- **Inbound memory is bounded.** A peer sending large frames faster than they
  could be handled, with or without a key, could grow its handling queue
  until the device ran out of memory. Frames waiting to be handled are now
  capped at 32 MiB per peer and 128 MiB in total.
- **Snapshots follow a rekey.** After a passphrase rotation the recovery
  snapshot stayed under the old key until the next snapshot tick; it is now
  rewritten under the new key at once.
- **Clock problems are visible.** Records refused for being stamped too far
  in the future are reported as `FrameHandlingFailed`, so a device whose own
  clock lags no longer just stops syncing.
- **Replayed handshakes are ignored.** A recorded ratchet hello replayed under
  a member's transport id could reset that member's session; one carrying an
  ephemeral key that already served an ended session is now ignored.
- Documentation: passphrase normalisation, macOS Local Network permission,
  logging `FrameHandlingFailed` safely.

## 1.1.0

A security release. It fixes the findings of an internal security review of
1.0.0; upgrade every device, all five packages together.

**Upgrade note: every device must move to 1.1 together.** The wire protocol is
now version 2 and 1.1 no longer speaks version 1, because version 1 is what the
most serious findings live in. A 1.1 device and a 1.0 device see each other as
`PeerIncompatible` and do not sync, and a 1.1 device refuses to pair with a 1.0
sponsor. Stored data, keys, the roster and every device's membership carry
over unchanged; nothing has to be re-paired or migrated. This drops a wire
version without the one-minor notice `VERSIONING.md` promises, deliberately:
keeping version 1 would keep the vulnerabilities.

- **Only members write user data.** Under 1.0 a frame encrypted with the
  passphrase-derived key could carry user-collection deltas, so a revoked
  device, or anyone who learned the passphrase, could insert, overwrite and
  delete documents on every device. User data, collection names and
  reconciliation now travel only inside a session opened with a non-revoked
  roster member's signature.
- **Real forward secrecy.** The 1.0 ratchet root was derived from the group key
  and nonces sent under the passphrase key, so recorded traffic plus one stolen
  device decrypted everything. Each connection now runs an X25519 exchange of
  ephemeral keys signed by both devices' roster identities, and wipes the
  private halves once the session exists.
- **No trust-on-first-use at pairing.** The pairing grant now carries the
  sponsor's roster trust pins, which the new device adopts before its first
  sync, so a passphrase holder can no longer feed it a forged roster and group
  key.
- **Future-dated records are refused.** A record stamped beyond
  `PassnoteConfig.maxClockDrift` (default 10 minutes) ahead of the local clock
  used to win every later merge forever; it is now refused until the clock
  catches up.
- **Roster hardening.** Revocations are judged in epoch order with the trust
  chain recomputed after each, so a revoked device's signatures introduce
  nobody; the revoking device re-signs the devices the revoked one had
  admitted; device ids must be the fingerprint of their key; concurrent
  rotations no longer overwrite each other; unreadable trust pins refuse to
  open (`RosterPinsCorruptException`) instead of trusting anew.
- **Pairing robustness.** Tries are budgeted per peer (3) and per code (20); a
  stray refusal from another peer no longer cuts a join off; a briefly-alone
  device no longer founds a rival group on reopen or pairing.
- **Transport hardening.** A WebSocket peer can no longer send frames in
  another peer's name, through a direct connection or the relay; listeners cap
  inbound connections, evict silent sockets, and close oversize messages.
- **Key wraps** bind both public keys and refuse low-order points; 1.0 wraps
  still open.
- Documentation states the remaining boundaries plainly: a revoked device keeps
  the passphrase key until the passphrase is rotated, and the room tag is a
  stable identifier.

## 1.0.0

The first release: an end-to-end encrypted, server-less, local-first sync
engine for Dart and Flutter.

- **Data.** Typed, queryable collections over a CRDT store. Merges are
  deterministic by hybrid logical clock, with per-field counters and sets
  where last-write-wins is not what you mean. Queries are indexed, paginate
  stably, and can be watched live.
- **Storage.** SQLite with SQLCipher encryption at rest (verified on open),
  transactional schema management, and automatic corruption recovery from
  snapshots or peers.
- **Sync.** A binary wire protocol with a fail-closed decoder; streamed
  bounded frames; periodic anti-entropy; and range-fingerprint reconciliation
  that finds any gap in a few round trips.
- **Security.** XChaCha20-Poly1305 everywhere, Argon2id key derivation from a
  BIP39 passphrase, per-device X25519/Ed25519 keypairs, an Ed25519-signed
  device roster with a trust chain rooted at the founding device, SPAKE2
  pairing by a nine-digit one-time code, revocation with group-key rotation,
  a forward-secrecy ratchet per connection, and an opt-in recovery phrase.
  Every primitive is pinned by published known-answer test vectors.
- **Passphrase rotation.** `Passnote.rotatePassphrase` re-encrypts a database's
  roster and control key under new words, in place, leaving the group key, the
  data and every device's membership untouched. Crash-safe: the new key is
  journalled before any store is touched, and an interrupted rotation finishes
  itself on the next `openDatabase` or `reopenDatabase`.
  `hasPendingRotation` reports one that was interrupted. The discovery room
  tag moves with the passphrase, so each device is rotated or paired again —
  see [Rotate the passphrase](docs/guides/rotate-the-passphrase.md).
- **Transports.** Zero-configuration mDNS discovery on the LAN, WebSockets
  everywhere (including the browser), and a self-hostable reference relay
  that only ever sees ciphertext.
- **Tooling.** A code generator that turns one `@Document()` annotation into
  the codec, the id extractor, and the per-field CRDT schema.

The packages: [`passnote_flutter`](packages/passnote_flutter) (the Flutter
entry point), [`passnote`](packages/passnote) (the pure-Dart engine),
[`passnote_crypto`](packages/passnote_crypto),
[`passnote_lan`](packages/passnote_lan), and
[`passnote_generator`](packages/passnote_generator).

Semver applies from this release; [`VERSIONING.md`](VERSIONING.md) states
what each surface guarantees.

### Planned for 1.x

- Collaborative text (sequence CRDTs).
- A WebRTC transport for direct browser-to-browser sync.
- An independent third-party security audit.
- A prepared-statement cache in the SQLite engine.
