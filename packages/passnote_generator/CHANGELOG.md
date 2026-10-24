# Changelog

## 1.1.2

- No changes of its own; released with the 1.1.2 patch of `passnote`, which
  it now requires. See the repository `CHANGELOG.md`.

## 1.1.1

- No changes of its own; released with the 1.1.1 security patch of
  `passnote`, which it now requires. See the repository `CHANGELOG.md`.

## 1.1.0

- No changes of its own; released with the 1.1.0 security release of the
  other packages, which it now requires. See the repository `CHANGELOG.md`.

## 1.0.0

First release.

- `@Document()` on a model class generates its `Codec` (`_$XCodec`), its
  per-field CRDT schema (`_$XSchema`), and a const `SchemaMergeStrategy`
  (`_$XMergeStrategy`) into the shared `.g.dart` part file.
- `@DocumentId()` marks the id field; `@Crdt(PnCounter())` and
  `@Crdt(OrSet())` declare per-field merge behaviour; nested paths use dotted
  field names.
- Runs under `build_runner`; drift between the model and the generated file
  fails the build.
