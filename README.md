# Conclave

**End-to-end encrypted, server-less, local-first CRDT sync engine for Dart and
Flutter.**

Conclave lets a group of devices share a live, mergeable dataset over the local
network — with no server, no account, and no plaintext ever leaving the device.
Pairing is a passphrase; everything else is automatic.

```dart
import 'package:conclave_flutter/conclave_flutter.dart';

final conclave = await conclaveBuilder(appId: 'shopping', salt: 'shopping:v1').open();
final list = await conclave.openDatabase('home', passphrase: words);
final items = list.collection<Item>('items', itemCodec);

await items.put(Item(id: newId(), name: 'Milk'));
items.watch().listen((all) => print('now ${all.length} items'));
```

## Highlights

- **End-to-end encrypted** — AES-256-GCM at rest and on the wire; keys derived
  from a passphrase and never sent anywhere.
- **Server-less** — devices find each other over mDNS and sync directly over
  WebSocket on the LAN. Nothing to deploy.
- **Local-first** — every device holds a full copy and works offline; edits
  merge on reconnect.
- **Conflict-free** — CRDTs with Hybrid Logical Clock arbitration give
  deterministic convergence.
- **Ports & adapters** — swap storage, transport, key store, or cipher without
  touching app code.

## Packages

This is a [Melos](https://melos.invertase.dev/) monorepo.

| Package | Description |
| --- | --- |
| [`conclave`](packages/conclave) | Pure-Dart engine: CRDT collections, ports, SQLite engine, device identity, protocol |
| [`conclave_crypto`](packages/conclave_crypto) | XChaCha20-Poly1305 cipher, Argon2id / BIP39 key derivation, SPAKE2 |
| [`conclave_lan`](packages/conclave_lan) | LAN transport (mDNS discovery + WebSocket frames) |
| [`conclave_flutter`](packages/conclave_flutter) | Flutter apps: keychain key store, `CollectionNotifier`, `conclaveBuilder`; re-exports the other packages |

## Quick start

Add the Flutter package (it pulls in the rest):

```yaml
dependencies:
  conclave_flutter: ^0.1.0
```

Then open Conclave, unlock a database with a passphrase, and read/write a typed
collection — see the [Getting started guide](docs/getting-started.md) for the
full walkthrough.

## Examples

Two complete, runnable Flutter apps share the same data code and differ only in
state management:

- [`examples/shopping_list_provider`](examples/shopping_list_provider) — Provider
  + `CollectionNotifier`.
- [`examples/shopping_list_bloc`](examples/shopping_list_bloc) — `flutter_bloc`
  Cubit over `items.watch()`.

Run one on two devices on the same Wi-Fi, enter the same passphrase, and watch
edits sync live.

## Documentation

The prose docs are a [Zensical](https://zensical.org/) site under [`docs/`](docs):

- [Home](docs/index.md)
- [Getting started](docs/getting-started.md)
- [Concepts](docs/concepts/databases-keys.md)
- [Adapters](docs/adapters/storage.md)
- [Security](docs/security.md)

Build and preview locally:

```sh
python3 -m venv .venv && source .venv/bin/activate
pip install zensical
zensical serve   # http://localhost:8000
```

## Development

The toolchain is pinned so `dart format` stays deterministic. Use Flutter
**3.44.1** (Dart 3.12.1); with [fvm](https://fvm.app) installed, `fvm use` reads
the version from [`.fvmrc`](.fvmrc). CI pins the same version in
[`.github/workflows/ci.yml`](.github/workflows/ci.yml); keep the two in sync.

Melos config lives in [`pubspec.yaml`](pubspec.yaml) under `melos:`, and CI runs
melos **7.8.2**.

The getting-started walkthrough is compiled as
[`examples/quickstart/`](examples/quickstart/); edit it and
[`docs/getting-started.md`](docs/getting-started.md) together. CI analyzes every
workspace package, so a broken snippet fails the build.

On the web the SQLite engine runs via `sqlite3/wasm`. Serve a `sqlite3.wasm`
build matching the `sqlite3` package version (from its GitHub releases) and call
`SqliteCrdtTable.configureWeb(wasmUri: ...)` before opening. Browser tests
(`dart test -P web` in `packages/conclave`) fetch it into `test/web/`.

```sh
dart pub global activate melos 7.8.2
melos bootstrap
melos run format
melos run analyze
melos run test   # test:dart, then test:flutter, then a coverage check
```

The LAN transport's socket-bound integration test is excluded from the default
run; see [`docs/adapters/transport.md`](docs/adapters/transport.md).

## Security

Conclave's encryption key — and therefore the passphrase — is the only thing
protecting your data, and the project has **not** been independently audited.
Read [`SECURITY.md`](SECURITY.md) and [`docs/security.md`](docs/security.md)
before shipping.

## License

See [`LICENSE`](LICENSE).
