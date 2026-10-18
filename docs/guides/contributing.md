# Contributing

## Toolchain

The toolchain is pinned so `dart format` output is deterministic:

- Flutter **3.44.1** (Dart 3.12.1). With [fvm](https://fvm.app), `fvm use`
  reads `.fvmrc`; otherwise match the version by hand. CI pins the same in
  `.github/workflows/ci.yml`.
- Melos **7.8.2**, configured in the root `pubspec.yaml` under `melos:`.

## A fresh clone

```sh
dart pub global activate melos 7.8.2
melos bootstrap
melos run generate   # build_runner over the @Document models
melos run format     # formatter is the source of truth; CI fails on drift
melos run analyze    # dart analyze --fatal-infos everywhere
melos run test       # dart test + flutter test + a runner-wiring check
```

Generated `*.g.dart` files are checked in; CI regenerates and fails on drift.

## The suites worth knowing

| Suite | Where | Runs |
| --- | --- | --- |
| Engine conformance | `packages/passnote/test/*_conformance_test.dart` | Every `CrdtTable` against the shared behavioural contract, typed layer included. |
| Convergence | `packages/passnote/test/*convergence*`, `handshake`, `reconciliation`, `recovery`, `revocation`, `ratchet`, `pairing` | Multi-node scenarios over the in-memory bus. |
| Protocol fuzz | `packages/passnote/test/protocol_codec_test.dart` | Round-trips plus random/truncation/corruption fuzzing of the decoder. |
| Web | `dart test -P web` in `passnote` (wasm engine) and `passnote_lan` (browser transport vs a native hybrid peer) | Headless Chrome. |
| mDNS loopback | `packages/passnote_lan` | Socket-bound; excluded from the default unit run, executed by CI: `dart test --run-skipped -t integration`. |
| Memory bounds | `packages/passnote` | `dart test --run-skipped -t benchmark`. |

## Docs

The tutorial's code is `examples/quickstart/`; edit it and
`docs/start-here/tutorial.md` together. Build the site with
`pip install zensical==0.0.60 && zensical build`; CI also checks every
internal link and enforces the em-dash ceiling.

## Commits

One logical change per commit. The message is one imperative line, prefixed
with a gitmoji, ending in a period, under about 72 characters:

```text
✨ Add an optional BIP39 recovery phrase, off by default.
```

Tests pass before a pull request opens, documentation ships in the same branch
as the behaviour it describes, and analyzer strictness is never lowered to
make a build pass.
