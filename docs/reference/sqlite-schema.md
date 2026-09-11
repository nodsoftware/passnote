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

## Corruption recovery

Opening runs `PRAGMA quick_check`. A file that will not open or does not pass
is moved aside to `<path>.corrupt-<timestamp>` and the store is rebuilt: from
`<path>.snapshot` when a readable one exists, otherwise empty, followed by an
automatic re-sync from peers. `snapshotInterval` (default 30 minutes)
controls how often the snapshot is refreshed with `VACUUM INTO`. Either
recovery surfaces a `StoreRecovered` event on `Conclave.events`.

## Key rotation

`rekey` runs SQLCipher's `PRAGMA rekey`, re-encrypting the whole file in
place. It is called automatically when the group key rotates after a device
revocation.

## What the file leaks

SQLCipher encrypts the whole file: schema, row counts, and content are all
ciphertext to an attacker with only the file. Without an encryption key (a
custom setup), collection names, keys, HLCs, and values are plaintext SQLite.
