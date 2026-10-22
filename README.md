<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/passnote-horizontal-on-dark.svg">
    <img src="docs/assets/passnote-horizontal.svg" alt="Passnote" width="320">
  </picture>
</h1>

**End-to-end encrypted, server-less, local-first sync for Dart and Flutter.**

Passnote lets a small group of devices share a live, mergeable dataset with no
server and no account. Every device holds a full copy and works offline; new
devices join with a short one-time code; a lost device can be revoked. No
plaintext ever leaves a device.

```dart
import 'package:passnote_flutter/passnote_flutter.dart';

final passnote = await passnoteBuilder(appId: 'shopping', salt: 'shopping:v1').open();
final list = await passnote.openDatabase('home', passphrase: words);
final items = list.collection<Item>('items', Item.codec);

await items.put(Item(id: newId(), name: 'Milk'));
items.watch().listen((all) => print('now ${all.length} items'));
```

## Highlights

- **End-to-end encrypted.** XChaCha20-Poly1305 on the wire with a
  forward-secrecy ratchet per connection, SQLCipher at rest (enforced: the
  engine refuses to open with a key on a non-SQLCipher build), Argon2id key
  derivation.
- **Real device membership.** Per-device keypairs; pairing by a nine-digit
  code over SPAKE2; Ed25519-signed roster rows; revocation by group-key
  rotation; an optional recovery phrase.
- **Server-less.** mDNS discovery and direct sync on the LAN, or explicit
  WebSocket addresses (and a reference relay) for browsers and remote peers.
- **Local-first, conflict-free.** Offline reads and writes; deterministic
  merges via hybrid logical clocks; per-field counters and sets when
  last-write-wins is not what you mean.
- **Queryable.** Indexed, typed queries with stable keyset pagination and
  bounded-cost live query watching (`query()...watch()`), compiled to SQL on
  the disk engine. `Collection.watch()` re-reads the whole collection per
  change — see [limits](docs/reference/limits.md).
- **Self-healing.** Streamed bounded sync frames, periodic anti-entropy, and
  range-fingerprint reconciliation that finds any gap in a few round trips.

## Packages

This is a [Melos](https://melos.invertase.dev/) monorepo.

| Package | Description |
| --- | --- |
| [`passnote_flutter`](packages/passnote_flutter) | Flutter entry point: `passnoteBuilder`, keychain key store, notifiers; re-exports the rest |
| [`passnote`](packages/passnote) | Pure-Dart engine: collections, CRDTs, queries, protocol, SQLite store, device identity |
| [`passnote_crypto`](packages/passnote_crypto) | XChaCha20-Poly1305, Argon2id, BIP39, SPAKE2, device identity keys |
| [`passnote_lan`](packages/passnote_lan) | Transports: mDNS LAN discovery (native), WebSockets (everywhere), reference relay |
| [`passnote_generator`](packages/passnote_generator) | Codecs and CRDT schemas generated from `@Document()` annotations |

## Quick start

Add the Flutter package (it pulls in the rest):

```yaml
dependencies:
  passnote_flutter: ^1.1.0
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
- [`examples/cli_logbook`](examples/cli_logbook): pure Dart, no Flutter — a
  two-terminal logbook with hand-wired adapters, a file-backed key store, and
  a generated per-field merge strategy (counters) in use.

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
tests (`dart test -P web` in `packages/passnote` and `packages/passnote_lan`)
cover the wasm engine and the browser transport.

```sh
dart pub global activate melos 7.8.2
melos bootstrap
melos run generate  # build_runner over the annotated models
melos run format
melos run analyze
melos run test      # test:dart, then test:flutter, then a runner-wiring check
```

The mDNS loopback integration test is excluded from the default run; run it
with `dart test --run-skipped -t integration` in `packages/passnote_lan`. See
[the contributing guide](docs/guides/contributing.md) for the rest.

## Security

Read [`docs/security.md`](docs/security.md) for what Passnote protects and
where its boundaries are, and [`SECURITY.md`](SECURITY.md) for reporting a
vulnerability privately. Passnote has not yet had an independent audit.

## Versioning

Semver from v1.0.0; see [`VERSIONING.md`](VERSIONING.md) for what each surface
(frozen API, advanced library, wire protocol, storage schema) guarantees.

## License

See [`LICENSE`](LICENSE).
