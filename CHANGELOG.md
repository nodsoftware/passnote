# Conclave releases

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
- **Storage.** SQLite with SQLCipher encryption at rest, transactional schema
  management, and automatic corruption recovery from snapshots or peers.
- **Sync.** A binary wire protocol with a fail-closed, fuzz-tested decoder;
  streamed bounded frames; periodic anti-entropy; and range-fingerprint
  reconciliation that finds any gap in a few round trips.
- **Security.** XChaCha20-Poly1305 everywhere, Argon2id key derivation from a
  BIP39 passphrase, per-device X25519/Ed25519 keypairs, SPAKE2 pairing by a
  nine-digit one-time code, revocation with group-key rotation, a
  forward-secrecy ratchet per connection, and an opt-in recovery phrase.
  Every primitive is pinned by published known-answer test vectors.
- **Transports.** Zero-configuration mDNS discovery on the LAN, WebSockets
  everywhere (including the browser), and a self-hostable reference relay
  that only ever sees ciphertext.
- **Tooling.** A code generator that turns one `@Document()` annotation into
  the codec, the id extractor, and the per-field CRDT schema.

The packages: [`conclave_flutter`](packages/conclave_flutter) (the Flutter
entry point), [`conclave`](packages/conclave) (the pure-Dart engine),
[`conclave_crypto`](packages/conclave_crypto),
[`conclave_lan`](packages/conclave_lan), and
[`conclave_generator`](packages/conclave_generator).

Semver applies from this release; [`VERSIONING.md`](VERSIONING.md) states
what each surface guarantees.

### Planned for 1.x

- Collaborative text (sequence CRDTs).
- A WebRTC transport for direct browser-to-browser sync.
- An independent third-party security audit.
- A prepared-statement cache in the SQLite engine.
