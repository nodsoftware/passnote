# Conclave

**End-to-end encrypted, server-less, local-first sync for Dart and Flutter.**

Conclave lets a small group of devices share a live, mergeable dataset with no
server and no account. Every device holds a full copy and works offline; new
devices join with a short one-time code; a lost device can be revoked. No
plaintext ever leaves a device.

```dart
import 'package:conclave_flutter/conclave_flutter.dart';

final conclave = await conclaveBuilder(appId: 'shopping', salt: 'shopping:v1').open();
final list = await conclave.openDatabase('home', passphrase: words);
final items = list.collection<Item>('items', Item.codec);

await items.put(Item(id: newId(), name: 'Milk'));
items.watch().listen((all) => print('now ${all.length} items'));
```

## Highlights

- **End-to-end encrypted.** XChaCha20-Poly1305 at rest (SQLCipher) and on the
  wire, Argon2id key derivation, and a forward-secrecy ratchet per connection.
- **Real device membership.** Per-device keypairs; pairing by a nine-digit
  code over SPAKE2; revocation by group-key rotation; an optional recovery
  phrase.
- **Server-less.** mDNS discovery and direct sync on the LAN, or explicit
  WebSocket addresses (and a reference relay) for browsers and remote peers.
- **Local-first, conflict-free.** Offline reads and writes; deterministic
  merges via hybrid logical clocks; per-field counters and sets when
  last-write-wins is not what you mean.
- **Queryable.** Indexed, typed queries with stable keyset pagination and
  bounded-cost live watching, compiled to SQL on the disk engine.
- **Self-healing.** Streamed bounded sync frames, periodic anti-entropy, and
  range-fingerprint reconciliation that finds any gap in a few round trips.

## Packages

This is a [Melos](https://melos.invertase.dev/) monorepo.

| Package | Description |
| --- | --- |
| [`conclave_flutter`](packages/conclave_flutter) | Flutter entry point: `conclaveBuilder`, keychain key store, notifiers; re-exports the rest |
| [`conclave`](packages/conclave) | Pure-Dart engine: collections, CRDTs, queries, protocol, SQLite store, device identity |
| [`conclave_crypto`](packages/conclave_crypto) | XChaCha20-Poly1305, Argon2id, BIP39, SPAKE2, device identity keys |
| [`conclave_lan`](packages/conclave_lan) | Transports: mDNS LAN discovery (native), WebSockets (everywhere), reference relay |
| [`conclave_generator`](packages/conclave_generator) | Codecs and CRDT schemas generated from `@Document()` annotations |

## Quick start

Add the Flutter package (it pulls in the rest):

```yaml
dependencies:
  conclave_flutter: ^0.1.0
```

Then follow the [tutorial](docs/start-here/tutorial.md): model, builder,
database, collection, and pairing a second device, in eight short steps.

## Examples

Complete, runnable Flutter apps sharing the same data code:

- [`examples/quickstart`](examples/quickstart): the tutorial, compiled.
- [`examples/shopping_list_provider`](examples/shopping_list_provider):
  Provider + `CollectionNotifier`.
- [`examples/shopping_list_bloc`](examples/shopping_list_bloc): `flutter_bloc`
  Cubit over `items.watch()`.

Run one on two devices on the same Wi-Fi and pair them; edits sync live.

## Documentation

The prose docs are a [Zensical](https://zensical.org/) site under
[`docs/`](docs):

- [Start here](docs/start-here/index.md) and the
  [tutorial](docs/start-here/tutorial.md)
- [Guides](docs/guides/index.md)
- [Concepts](docs/concepts/data-model.md)
- [Reference](docs/reference/builder.md)
- [Security](docs/security.md)

Build and preview locally:

```sh
python3 -m venv .venv && source .venv/bin/activate
pip install zensical==0.0.60
zensical serve   # http://localhost:8000
```

## Development

The toolchain is pinned so `dart format` stays deterministic. Use Flutter
**3.44.1** (Dart 3.12.1); with [fvm](https://fvm.app) installed, `fvm use`
reads the version from [`.fvmrc`](.fvmrc). CI pins the same version in
[`.github/workflows/ci.yml`](.github/workflows/ci.yml); keep the two in sync.

Melos config lives in [`pubspec.yaml`](pubspec.yaml) under `melos:`, and CI
runs melos **7.8.2**.

The tutorial is compiled as [`examples/quickstart/`](examples/quickstart/);
edit it and [`docs/start-here/tutorial.md`](docs/start-here/tutorial.md)
together. CI analyzes every workspace package, regenerates the annotated
models (`melos run generate`) and fails on drift, builds the docs, and fails
on broken links.

On the web the SQLite engine runs via `sqlite3/wasm`. Serve a `sqlite3.wasm`
build matching the `sqlite3` package version (from its GitHub releases) and
call `SqliteCrdtTable.configureWeb(wasmUri: ...)` before opening. Browser
tests (`dart test -P web` in `packages/conclave` and `packages/conclave_lan`)
cover the wasm engine and the browser transport.

```sh
dart pub global activate melos 7.8.2
melos bootstrap
melos run generate  # build_runner over the annotated models
melos run format
melos run analyze
melos run test      # test:dart, then test:flutter, then a coverage check
```

The mDNS loopback integration test is excluded from the default run; run it
with `dart test --run-skipped -t integration` in `packages/conclave_lan`. See
[the contributing guide](docs/guides/contributing.md) for the rest.

## Security

Read [`docs/security.md`](docs/security.md) for what Conclave protects and
where its boundaries are, and [`SECURITY.md`](SECURITY.md) for reporting a
vulnerability privately. Conclave has not yet had an independent audit.

## Versioning

Semver from v1.0.0; see [`VERSIONING.md`](VERSIONING.md) for what each surface
(frozen API, advanced library, wire protocol, storage schema) guarantees.

## License

See [`LICENSE`](LICENSE).
