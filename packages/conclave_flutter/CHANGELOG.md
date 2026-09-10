# Changelog

## Unreleased

- This package is now the entry point for Flutter apps. It re-exports
  `package:conclave` (renamed from `conclave_core`), `package:conclave_crypto`,
  and `package:conclave_lan`, and absorbs `conclaveBuilder` from the former
  `conclave` umbrella package (which is removed). A Flutter app depends on
  `conclave_flutter` alone.

## 0.1.0

First public version.

- `KeychainKeyStore`: a `KeyStore` backed by the operating system keychain via
  `flutter_secure_storage`, namespaced per app.
- `CollectionNotifier<T>`: a `ChangeNotifier` over `Collection.watch` for use
  with `provider` and similar, exposing an unmodifiable item list.
