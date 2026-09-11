# conclave

The pure-Dart engine behind
[Conclave](https://github.com/nodsoftware/conclave), an end-to-end encrypted,
local-first CRDT sync engine: CRDT-backed collections, the SQLite storage
engine, device identity, the port interfaces, and the wire protocol. No Flutter
dependency.

Flutter apps should depend on
[`conclave_flutter`](https://pub.dev/packages/conclave_flutter) instead: it adds
the platform key store, a `ChangeNotifier` view of a collection, and
`conclaveBuilder` for batteries-included setup, and it re-exports this package.
Depend on `conclave` directly for a pure-Dart program, or when wiring your own
adapters.

## What's inside

- **`Conclave` / `Database` / `Collection<T>`**: the app handle, an encrypted
  shared dataset, and typed queryable document sets.
- **`Conclave.builder(...)`**: staged configuration; `Conclave.lowLevel` and
  `package:conclave/engine.dart` are the advanced surface.
- **Ports**: `CrdtTable`, `Cipher`, `KeyStore`, `Transport`, `MergeStrategy`,
  `Identity`, `Pake`. The engine depends only on these interfaces.
- **Engine**: `SqliteCrdtTable` (SQLite, SQLCipher at rest, wasm on the web);
  `MapCrdtTable` for tests.
- **Identity**: per-device keypairs, PAKE pairing, group-key wrap and rotation,
  a forward-secrecy ratchet.
- **`Codec` / `JsonCodec`**: typed document (de)serialisation.
- **In-memory transport**: `InMemoryTransport` over an `InMemoryBus` for tests.

## Install

```yaml
dependencies:
  conclave: ^0.1.0
```

## Usage

```dart
import 'package:conclave/conclave.dart';

// Supply the adapters as builder defaults once, then open.
final conclave = await Conclave.builder(appId: 'myapp', salt: 'myapp:v1').open();
final db = await conclave.openDatabase('home', passphrase: words);
final items = db.collection<Item>('items', itemCodec);
```

## Adapters

Backends implementing the ports are published separately: `conclave_crypto`
(cipher, key derivation, PAKE), `conclave_lan` (mDNS + WebSocket transport),
`conclave_flutter` (keychain key store, `CollectionNotifier`, `conclaveBuilder`).

## Documentation

See the [Conclave documentation](https://nodsoftware.github.io/conclave/), in
particular [Sync](https://nodsoftware.github.io/conclave/concepts/sync/).
