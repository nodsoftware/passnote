# Changelog

## 1.0.0

First release.

- `conclaveBuilder(appId:, salt:)`: the batteries-included entry point with
  the production pieces installed (SQLite with SQLCipher at rest, mDNS LAN
  transport, OS keychain key store, XChaCha20-Poly1305, SPAKE2 pairing).
- `KeychainKeyStore`: derived keys and the device identity in the OS
  keychain via `flutter_secure_storage`.
- `CollectionNotifier`: a `ChangeNotifier` over a collection or a collection
  query, for `provider` and plain `ListenableBuilder` apps.
- Re-exports the full `conclave`, `conclave_crypto`, and `conclave_lan`
  surfaces: one dependency for a Flutter app.
