# Changelog

## Unreleased

- First version. `@Document()` on a model class generates its `Codec`
  (`_$XCodec`), its per-field CRDT schema (`_$XSchema`), and a const
  `SchemaMergeStrategy` over it (`_$XMergeStrategy`) into the shared `.g.dart`
  part file. `@DocumentId()` marks the id field; `@Crdt(PnCounter())` /
  `@Crdt(OrSet())` type a field, and unannotated fields merge last-write-wins.
