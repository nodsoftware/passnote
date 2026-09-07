# Storage

!!! note "Being rewritten"
    Conclave's storage model is changing. The engine now owns persistence
    directly (a disk-backed CRDT table) instead of a separate `BlobStore`
    adapter, so the `conclave_sembast` and `conclave_hive` packages have been
    removed. This page will be rewritten once the new engine lands. For now,
    the in-memory engine is the default and data is not persisted across
    restarts.
