# conclave_sembast

[Sembast](https://pub.dev/packages/sembast)-backed `BlobStore` for
[Conclave](https://github.com/nodsoftware/conclave). This is the default storage
backend used by the [`conclave`](https://pub.dev/packages/conclave) umbrella's
`conclaveBuilder`.

Pure Dart, works on all platforms. Conclave wraps it in an `EncryptedStore`, so
values are AES-256-GCM ciphertext at rest — the store itself never sees
plaintext.

## Install

```yaml
dependencies:
  conclave_sembast: ^0.1.0
```

## Usage

```dart
import 'package:conclave_sembast/conclave_sembast.dart';

final store = SembastStore(namespace: 'shopping/home');
```

- `namespace` scopes the database file and keys.
- Pass `path:` for a custom file location.
- Pass `factory: databaseFactoryMemory` (from `package:sembast/sembast_memory.dart`)
  for in-memory tests.

With the umbrella you don't construct it directly — `conclaveBuilder` builds a
`SembastStore` per database. Pass a custom factory to `Conclave.open` if you need
different storage:

```dart
store: (dbId) => SembastStore(namespace: 'myapp/$dbId'),
```

## Conformance

`SembastStore` passes Conclave's shared `BlobStore` conformance suite. See
[Storage adapters](https://nodsoftware.github.io/conclave/adapters/storage/) for how
to write and verify your own backend.
