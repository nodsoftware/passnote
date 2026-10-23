# Changelog

## 1.1.1

- No changes of its own; released with the 1.1.1 security patch of
  `passnote`, which it now requires. See the repository `CHANGELOG.md`.

## 1.1.0

- No changes of its own; released with the 1.1.0 security release of the
  other packages, which it now requires. See the repository `CHANGELOG.md`.

## 1.0.0

First release.

- `passnoteBuilder(appId:, salt:)`: the batteries-included entry point with
  the production pieces installed (SQLite with SQLCipher at rest, mDNS LAN
  transport, OS keychain key store, XChaCha20-Poly1305, SPAKE2 pairing).
- `KeychainKeyStore`: derived keys and the device identity in the OS
  keychain via `flutter_secure_storage`.
- `CollectionNotifier`: a `ChangeNotifier` over a collection or a collection
  query, for `provider` and plain `ListenableBuilder` apps.
- Re-exports the full `passnote`, `passnote_crypto`, and `passnote_lan`
  surfaces: one dependency for a Flutter app.
