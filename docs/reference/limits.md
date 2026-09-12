# Limits and performance

Honest numbers and the design bounds behind them, so you can judge fit
before you build. Conclave is sized for a small group of devices sharing a
dataset every device can hold in full; see
[Is it a fit?](../start-here/index.md#is-it-a-fit) for the qualitative
version.

## Group size

Every device connects to every other device it can reach, so connections
grow quadratically with the group. The design target is household and small
team scale: a handful of devices, comfortably up to around a dozen. Nothing
enforces a ceiling, but Conclave has no relay-mesh or gossip layer to make
hundreds of peers cheap, and pairing is a deliberate one-at-a-time human
act.

## Data volume

Every device stores the full dataset, so the practical bound is the
smallest device's disk, and the interesting engineering bound is memory and
sync behaviour as records grow. Measured points, from the benchmark and the
test suite:

- **100,000 single-field documents** on the SQLite engine (macOS, 2026-09):
  the resident set grows about **9 MB** over the whole write workload,
  writes average **27 µs per document**, and reading a 1,000-document
  sample takes **14 ms**. The disk engine's memory stays flat as data
  grows; the in-memory `MapCrdtTable` does not, which is why it is for
  tests.
- **A 100,000-record first sync** streams in bounded frames and converges;
  no step of sync ever loads the whole dataset into memory.
- Range reconciliation finds a missing record among 100,000 in a few round
  trips by fingerprint halving, shipping only the difference.

Reproduce the memory numbers with the harness in
[`packages/conclave/benchmark/`](https://github.com/nodsoftware/conclave/tree/main/packages/conclave/benchmark).

## Documents

Documents are JSON-shaped values, sent whole. There is no hard size cap,
but a delta frame carries at most 500 records and is never split inside a
document, so a single document should stay well under a frame: kilobytes,
not megabytes. Conclave is not a blob store; keep images and files outside
and sync references to them.

## Live watching

`Collection.watch()` re-reads and decodes the **whole collection on every
change**: every local `put`, and every synced remote changeset (remote
batches coalesce into one refresh per changeset, but a loop of local writes
triggers one full rescan each). That is fine for the small collections it is
meant for; for a screen that shows a filtered or paginated slice of a large
collection, use `query()...watch()`, whose cost per change is bounded by the
page size.

## The knobs and their defaults

Every bound below is a builder or config option; the defaults are the
tested configuration.

| Bound | Default | What it protects |
| --- | --- | --- |
| Records per delta frame | 500 (fixed) | Peak memory per frame, on both ends. |
| Send window per peer (`maxInFlightFrames`) | 16 frames | A fast sender cannot bury a slow receiver. |
| Inbound rate limit (`maxInboundFramesPerSecond`) | 100/s per peer | A noisy peer cannot starve the event loop; anti-entropy heals anything dropped. |
| Anti-entropy interval (`antiEntropyInterval`) | 3 minutes | How stale a missed update can get before repair. |
| Compaction horizon (`compactionHorizon`) | 30 days | How long tombstones survive so late-returning devices still learn about deletes. `compact()` removes older ones. |
| Snapshot interval (`snapshotInterval`) | 30 minutes | Worst-case data loss window when recovering a corrupt store with no peer around. |

## What is deliberately not here

- **Thousands of users on one dataset.** That is a server's job; Conclave
  has no central authority to arbitrate at that scale.
- **Partial replicas.** Every device holds everything; there is no
  subscribe-to-a-subset mode.
- **Collaborative text.** Sequence CRDTs are planned for 1.x; today's field
  types are registers, counters, and sets.
