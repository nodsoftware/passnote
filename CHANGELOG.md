# Passnote releases

All five packages release together with matching versions. Per-package detail
lives in each package's own `CHANGELOG.md`; this file is the cross-package
summary.

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
