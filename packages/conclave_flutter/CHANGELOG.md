# Changelog

## 0.1.0

First public version.

- `KeychainKeyStore`: a `KeyStore` backed by the operating system keychain via
  `flutter_secure_storage`, namespaced per app.
- `CollectionNotifier<T>`: a `ChangeNotifier` over `Collection.watch` for use
  with `provider` and similar, exposing an unmodifiable item list.
