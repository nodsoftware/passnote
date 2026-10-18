# cli_logbook

Passnote in a plain Dart process — no Flutter. A tiny shared logbook two
machines on the same network keep in sync, end-to-end encrypted, with no
server.

It demonstrates the three things the Flutter examples cannot:

- **Wiring the production adapters yourself.** `installLogbookDefaults`
  (in `lib/logbook.dart`) fills every `PassnoteDefaults` slot the way
  `passnote_flutter`'s `passnoteBuilder` does for Flutter apps: SQLCipher
  SQLite engine, LAN transport, XChaCha20-Poly1305, Argon2id, device
  identity, SPAKE2.
- **A `KeyStore` without an OS keychain.** `FileKeyStore` keeps keys in one
  owner-only JSON file. Example-grade by design: whoever reads the file holds
  the keys; a real app uses the platform's secret storage.
- **A generated per-field merge strategy in use.** `Entry.stars` is annotated
  `@Crdt(PnCounter())`, and the collection is created with
  `merge: entryMerge` (the generated `_$EntryMergeStrategy`). Without that
  argument the annotation does nothing and `star` would throw.

## Run it

```sh
dart run cli_logbook create            # first machine: founds, prints words
dart run cli_logbook add "hello"       # write an entry
dart run cli_logbook pair              # prints a one-time nine-digit code
# on the second machine, same network:
dart run cli_logbook join 123456789
dart run cli_logbook list              # the entries are already there
dart run cli_logbook star <id>        # counter: stars from both devices count
dart run cli_logbook watch             # live view
```

State lives in `.logbook/` (override with `LOGBOOK_DIR`). Discovery is mDNS:
if the terminal prints `discovery unavailable`, the OS is refusing multicast —
see [Set up platforms](../../docs/guides/set-up-platforms.md).

When copying this example out of the workspace, keep the `hooks:` stanza in
`pubspec.yaml`: it selects the SQLCipher build of `package:sqlite3`, and the
engine refuses to store plaintext without it.
