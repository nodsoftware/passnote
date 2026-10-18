# passnote

The pure-Dart engine behind
[Passnote](https://github.com/nodsoftware/passnote), an end-to-end encrypted,
local-first CRDT sync engine: CRDT-backed collections, the SQLite storage
engine, device identity, the port interfaces, and the wire protocol. No Flutter
dependency.

Flutter apps should depend on
[`passnote_flutter`](https://pub.dev/packages/passnote_flutter) instead: it adds
the platform key store, a `ChangeNotifier` view of a collection, and
`passnoteBuilder` for batteries-included setup, and it re-exports this package.
Depend on `passnote` directly for a pure-Dart program, or when wiring your own
adapters.

## What's inside

- **`Passnote` / `Database` / `Collection<T>`**: the app handle, an encrypted
  shared dataset, and typed queryable document sets.
- **`Passnote.builder(...)`**: staged configuration; `passnoteLowLevel` and
  `package:passnote/engine.dart` are the advanced surface.
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
  passnote: ^1.0.0
```

## Usage

```dart
import 'package:passnote/passnote.dart';

// Supply the adapters as builder defaults once, then open.
final passnote = await Passnote.builder(appId: 'myapp', salt: 'myapp:v1').open();
final db = await passnote.openDatabase('home', passphrase: words);
final items = db.collection<Item>('items', itemCodec);
```

## Adapters

Backends implementing the ports are published separately: `passnote_crypto`
(cipher, key derivation, PAKE), `passnote_lan` (mDNS + WebSocket transport),
`passnote_flutter` (keychain key store, `CollectionNotifier`, `passnoteBuilder`).

## Documentation

See the [Passnote documentation](https://nodsoftware.github.io/passnote/), in
particular [Sync](https://nodsoftware.github.io/passnote/concepts/sync/).
