# SQLite schema

The disk engine (`SqliteCrdtTable`) keeps one SQLite database per collection,
opened with SQLCipher when an encryption key is supplied (the default through
the builder). WAL journaling, `synchronous = NORMAL`.

## Tables

```sql
CREATE TABLE crdt_records (
  collection TEXT NOT NULL,
  key        TEXT NOT NULL,           -- docId, or docId ␟ fieldPath
  value      TEXT NOT NULL,           -- JSON (a typed field stores its state)
  is_deleted INTEGER NOT NULL DEFAULT 0,
  hlc        TEXT NOT NULL,
  hlc_key    TEXT NOT NULL,           -- fixed-width sortable HLC encoding
  crdt_type  TEXT NOT NULL DEFAULT 'lww',
  doc_id     TEXT GENERATED ALWAYS AS (...) VIRTUAL,  -- key before ␟
  field_path TEXT GENERATED ALWAYS AS (...) VIRTUAL,  -- key after ␟, or NULL
  PRIMARY KEY (collection, key)
);

CREATE TABLE crdt_meta (k TEXT PRIMARY KEY, v TEXT NOT NULL);  -- node_id
```

Indexes: `(collection, hlc_key)` for watermark and range scans,
`(collection, doc_id)` for single-document reads, plus one small partial
expression index per path declared in `indexedFields`
(`json_extract(value, '$'), doc_id` filtered to that collection and path),
which serves query equality predicates.

## Schema version

The schema version lives in `PRAGMA user_version` (currently **1**). Schema
creation, and any future migration, runs in one transaction with the version
bump included, so an interrupted step reopens at the old version, never
half-applied. The virtual `doc_id` / `field_path` columns are computed on
read: they cost nothing on the write path.

## Encryption is verified on open

When an encryption key is supplied, the engine issues `PRAGMA key` and then
checks `PRAGMA cipher_version`. A linked SQLite that is not a SQLCipher build
returns no row, and the open throws `SqlCipherUnavailableException` instead of
silently writing plaintext. A key that does not decrypt an existing file
throws `WrongPassphraseException` and leaves the file untouched, so a retry
with the right passphrase succeeds.

## Corruption recovery

Opening runs `PRAGMA quick_check`. A corrupt file is moved aside to
`<path>.corrupt-<timestamp>` and the store is rebuilt: from `<path>.snapshot`
when a readable one exists, otherwise empty, followed by an automatic re-sync
from peers. `snapshotInterval` (default 30 minutes) controls how often the
snapshot is refreshed with `VACUUM INTO` (the snapshot inherits the
encryption key). Either recovery surfaces a `StoreRecovered` event on
`Passnote.events`.

For an **encrypted** database the corrupt and mis-keyed cases can look
identical: SQLCipher answers header damage and a wrong key with the same
error. The snapshot arbitrates. When `<path>.snapshot` opens cleanly under
the supplied key, the key is proven right, the file is treated as corrupt,
and recovery proceeds. Without a snapshot the ambiguity resolves to
`WrongPassphraseException` and the file is preserved: the engine never
destroys data on a guess, at the price that recovering from header damage
then takes the user confirming the passphrase and deleting the file. Damage
past the header (a broken page under a valid key) fails `quick_check`
directly and recovers without arbitration. Opening an encrypted file with
**no** key also reads as corruption; the quarantine keeps the original file,
so a lost key entry quarantines the working copy rather than deleting it.

## Key rotation

`rekey` runs SQLCipher's `PRAGMA rekey`, re-encrypting the whole file in
place. It is called automatically when the group key rotates after a device
revocation.

## What the file leaks

SQLCipher encrypts the whole file: schema, row counts, and content are all
ciphertext to an attacker with only the file. Opening with a key on a
non-SQLCipher build fails closed (see above), so a keyed database is never
plaintext by accident. Only a database deliberately opened **without** an
encryption key stores collection names, keys, HLCs, and values as plaintext
SQLite.
