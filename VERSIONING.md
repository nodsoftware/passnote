# Versioning

Passnote follows [semantic versioning](https://semver.org) from v1.0.0. All
five packages release together with matching versions.

## What semver covers, per surface

| Surface | Guarantee |
| --- | --- |
| `package:passnote/passnote.dart` (and everything `passnote_flutter` re-exports from it) | **Frozen.** Any breaking change is a major version. An export-surface test in the repository guards the exact export set. |
| `package:passnote/engine.dart` (the advanced library: `passnoteLowLevel`, engine implementations, conformance suites, protocol types) | Covered, but it may change in a **minor** version with a prominent CHANGELOG entry. Pin a minor if you build engines or transports. |
| The wire protocol | Versioned independently (`wireVersion`, currently 1) and negotiated per connection. A release that drops a wire version says so in the CHANGELOG one minor ahead; incompatible peers surface as `PeerIncompatible`, never silent failure. |
| The SQLite schema | Versioned by `PRAGMA user_version` (currently 1) with forward, transactional migrations. A release never requires manual migration; downgrade is not supported. |
| The stored data formats (typed CRDT states, record shapes) | Breaking changes are a major version with a migration. |

## Deprecation policy

An API is deprecated with `@Deprecated` naming its replacement, kept for at
least one minor version, and removed in the next major.
