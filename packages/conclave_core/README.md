# conclave_core

The pure-Dart core of [Conclave](https://github.com/nodsoftware/conclave) — the sync
engine, CRDT-backed collections, port interfaces, and the wire protocol. No
Flutter dependency.

This is the package every other Conclave package builds on. App authors usually
depend on the [`conclave`](https://pub.dev/packages/conclave) umbrella instead;
depend on `conclave_core` directly when you want the engine with your own
adapters.

## What's inside

- **`Conclave` / `Database` / `Collection<T>`** — the app handle, an encrypted
  shared dataset, and typed queryable document sets.
- **Ports** — `BlobStore`, `Cipher`, `KeyStore`, `Transport`, `HlcClock`. The
  engine depends only on these interfaces.
- **`EncryptedStore`** — a `BlobStore` decorator that encrypts values at rest.
- **`Codec` / `JsonCodec`** — typed document (de)serialisation.
- **Wire protocol** — `hello` / `state` / `delta` messages with HLC-based
  reconciliation.
- **In-memory transport** — `InMemoryTransport` over an `InMemoryBus` for tests.

## Install

```yaml
dependencies:
  conclave_core: ^0.1.0
```

## Usage

```dart
import 'package:conclave_core/conclave_core.dart';

final conclave = await Conclave.open(
  config: ConclaveConfig(appId: 'myapp', salt: 'myapp:v1'),
  store: (dbId) => MyBlobStore(namespace: 'myapp/$dbId'),
  keyStore: MyKeyStore(),
  transport: MyTransport(),
  clock: SystemHlcClock.new,
  deriveKey: myDeriveKey,
  roomTag: myRoomTag,
  cipher: MyCipher.new,
  mnemonicGenerator: myMnemonicGenerator,
);
```

## Adapters

Backends implementing the ports are published separately:
`conclave_crypto`, `conclave_sembast`, `conclave_hive`, `conclave_lan`,
`conclave_flutter`.

## Documentation

See the [Conclave documentation](https://nodsoftware.github.io/conclave/), in
particular [Sync & CRDTs](https://nodsoftware.github.io/conclave/concepts/sync-and-crdt/).
