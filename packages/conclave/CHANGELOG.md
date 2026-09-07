# Changelog

## Unreleased

- **Breaking:** `openDefault(appId:, salt:)` is removed. Use
  `conclaveBuilder(appId:, salt:).open()`, which returns a
  `ConclaveBuilder` with the production adapters installed and lets you override
  any of them before `open()`.
- **Breaking:** the `conclave_sembast` dependency and re-export are removed
  (storage moves into the engine). `conclave_hive` is removed too.
- The batteries-included engine now keeps a recovery snapshot per collection
  (every 30 minutes by default) and rebuilds a corrupt file automatically —
  from the snapshot, or by re-syncing from a peer. Watch `Conclave.events` for
  `StoreRecovered`.
- `conclaveBuilder` now installs a default device `Identity` (`DeviceIdentity`,
  X25519 + Ed25519) backed by the OS keychain, reachable via
  `Conclave.identity`.
- A database's data is now encrypted with a per-database **group key** wrapped to
  each paired device, not straight from the passphrase. The first device founds
  the group key on open; further devices open in a "needs pairing" state until
  admitted (`Database.deviceState`, `listDevices`, `admitDevice`, `revokeDevice`).
  The synced device roster lives in a reserved collection.
- Added device pairing: `Conclave.startPairing` shows a nine-digit code,
  `Conclave.pairWith` joins with it. A SPAKE2 (RFC 9382) exchange over the
  transport authenticates both sides; the sponsor rate-limits wrong codes.
- The default cipher is now XChaCha20-Poly1305 and the passphrase stretch is
  Argon2id, replacing AES-256-GCM and PBKDF2.

## 0.1.0

First public version of the umbrella package.

- Re-exports every Conclave library from a single import.
- `openDefault(appId:, salt:)` for batteries-included setup: Sembast storage,
  OS-keychain key store, LAN transport, and AES-GCM encryption.
