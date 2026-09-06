# conclave_hive

[Hive](https://pub.dev/packages/hive_ce)-backed `BlobStore` for
[Conclave](https://github.com/nodsoftware/conclave). A lightweight, fast key-value
storage backend — an alternative to the default
[`conclave_sembast`](https://pub.dev/packages/conclave_sembast).

Conclave wraps it in an `EncryptedStore`, so values are AES-256-GCM ciphertext at
rest — the store itself never sees plaintext.

## Install

```yaml
dependencies:
  conclave_hive: ^0.1.0
```

## Usage

```dart
import 'package:conclave_hive/conclave_hive.dart';

final store = HiveStore(namespace: 'shopping/home', path: dir.path);
```

- `namespace` is sanitised into a valid, filesystem-safe box name.
- `path` sets the directory for the box file.

To use Hive instead of Sembast, pass the factory to `Conclave.open`:

```dart
store: (dbId) => HiveStore(namespace: 'myapp/$dbId', path: appDir.path),
```

## Conformance

`HiveStore` passes Conclave's shared `BlobStore` conformance suite, so it behaves
identically to other backends through the port. See
[Storage adapters](https://nodsoftware.github.io/conclave/adapters/storage/).
