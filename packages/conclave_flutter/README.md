# conclave_flutter

Flutter-specific adapters for [Conclave](https://github.com/wouterd/conclave):
an OS-keychain key store and a `ChangeNotifier` that mirrors a collection.

## What's inside

- **`KeychainKeyStore`** — a `KeyStore` backed by the platform secure storage
  (iOS/macOS Keychain, Android Keystore-wrapped storage, etc.) via
  [`flutter_secure_storage`](https://pub.dev/packages/flutter_secure_storage).
  Per-database keys are stored namespaced so they never collide.
- **`CollectionNotifier<T>`** — a `ChangeNotifier` that subscribes to
  `Collection.watch()` and rebuilds dependent widgets on every local or synced
  change. Works with Provider, `ListenableBuilder`, or any
  `ChangeNotifier`-based state management.

## Install

```yaml
dependencies:
  conclave_flutter: ^0.1.0
```

## Usage

```dart
import 'package:conclave_flutter/conclave_flutter.dart';
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

`KeychainKeyStore` is wired automatically by the
[`conclave`](https://pub.dev/packages/conclave) umbrella's `openDefault`; pass it
to `Conclave.open` if you wire adapters yourself.

## Examples

See the runnable apps in the repository:
[`shopping_list_provider`](https://github.com/wouterd/conclave/tree/main/examples/shopping_list_provider)
and
[`shopping_list_bloc`](https://github.com/wouterd/conclave/tree/main/examples/shopping_list_bloc).
