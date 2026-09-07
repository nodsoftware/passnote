# Changelog

## Unreleased

- **Breaking:** `openDefault(appId:, salt:)` is removed. Use
  `conclaveBuilder(appId:, salt:).open()`, which returns a
  `ConclaveBuilder` with the production adapters installed and lets you override
  any of them before `open()`.
- **Breaking:** the `conclave_sembast` dependency and re-export are removed
  (storage moves into the engine). `conclave_hive` is removed too.

## 0.1.0

First public version of the umbrella package.

- Re-exports every Conclave library from a single import.
- `openDefault(appId:, salt:)` for batteries-included setup: Sembast storage,
  OS-keychain key store, LAN transport, and AES-GCM encryption.
