# passnote_flutter

The Flutter entry point for
[Passnote](https://github.com/nodsoftware/passnote), the end-to-end
encrypted, server-less, local-first sync engine. One dependency: it
re-exports the full `passnote`, `passnote_crypto`, and `passnote_lan`
surfaces and adds the Flutter pieces.

## What's inside

- **`passnoteBuilder(appId:, salt:)`** — batteries-included setup: SQLite
  with SQLCipher at rest, mDNS LAN transport, the OS keychain,
  XChaCha20-Poly1305, and SPAKE2 pairing, each overridable before `.open()`.
- **`KeychainKeyStore`** — a `KeyStore` backed by the platform secure storage
  (iOS/macOS Keychain, Android Keystore-wrapped storage, etc.) via
  [`flutter_secure_storage`](https://pub.dev/packages/flutter_secure_storage).
  Per-database keys are stored namespaced so they never collide.
- **`CollectionNotifier<T>`** — a `ChangeNotifier` over a collection or a
  collection query that rebuilds dependent widgets on every local or synced
  change. Works with Provider, `ListenableBuilder`, or any
  `ChangeNotifier`-based state management.

## Install

```yaml
dependencies:
  passnote_flutter: ^1.0.0
```

Then select the SQLCipher build of `package:sqlite3` in your app's **root**
`pubspec.yaml` — the engine refuses to open an encrypted database on a plain
SQLite build (`SqlCipherUnavailableException`) rather than store plaintext:

```yaml
hooks:
  user_defines:
    sqlite3:
      source: sqlcipher
```

## Usage

```dart
import 'package:passnote_flutter/passnote_flutter.dart';

final passnote = await passnoteBuilder(appId: 'shopping', salt: 'shopping:v1').open();
final db = await passnote.openDatabase('home', passphrase: words);
final items = db.collection<Item>('items', Item.codec);
```

With Provider:

```dart
import 'package:provider/provider.dart';

ChangeNotifierProvider(
  create: (_) => CollectionNotifier<Item>(items),
  child: Consumer<CollectionNotifier<Item>>(
    builder: (_, notifier, __) => ListView(
      children: [for (final item in notifier.items) Text(item.name)],
    ),
  ),
);
```

The [tutorial](https://nodsoftware.github.io/passnote/start-here/tutorial/)
walks from an empty app to two paired devices in eight steps.

## Examples

See the runnable apps in the repository:
[`quickstart`](https://github.com/nodsoftware/passnote/tree/main/examples/quickstart),
[`shopping_list_provider`](https://github.com/nodsoftware/passnote/tree/main/examples/shopping_list_provider),
and
[`shopping_list_bloc`](https://github.com/nodsoftware/passnote/tree/main/examples/shopping_list_bloc).
