# Clocks and merge

!!! abstract "In plain terms"
    Every record carries a timestamp that is safe against wrong clocks and
    offline edits. When two devices change the same record, every device picks
    the same winner from those timestamps. Counter and set fields do better:
    instead of picking a winner, they combine both edits.

## How it works

### Hybrid logical clocks

"Last write wins" needs a meaning of *last* that survives clock skew, offline
periods, and simultaneous edits. Passnote stamps every record with an
[HLC](glossary.md#hlc): wall-clock time, plus a counter, plus the device id.

- **Never backwards.** If a device's clock jumps back, the counter keeps the
  HLC moving forward.
- **Causal.** If edit B was made after seeing edit A, then B's HLC is larger.
- **Total.** The device id breaks exact ties, so two devices comparing the
  same two records always agree which one is newer.

### Last write wins

For an `LwwRegister` field (the default), merging two versions of a record
keeps the one with the larger HLC and discards the other. This is simple,
deterministic, and right for fields where the newest value is the truth: a
title, a status, a note body.

### Counters add up

A `PnCounter` field stores, per device, how much that device has added and
subtracted; the field's value is the sum of everything. Merging takes the
maximum of each device's contribution, so applying the same information twice
changes nothing, and increments made at the same time on two devices both
count:

```text
device A: qty +3          device B: qty +4
      merged everywhere: qty == 7
```

### Sets keep both edits

An `OrSet` field stores each element with a tag unique to the add that created
it; removing an element removes the tags the remover could see. Merging unions
the adds and the removes. The consequences:

- Adding on one device and removing a *different* element on another: both
  take effect.
- Removing an element on one device while another re-adds it: the re-add wins,
  because the remove never saw the new add. Nobody's addition disappears
  silently.

### Tombstones and compaction

A deletion writes a [tombstone](glossary.md#tombstone) so peers learn about
it. Tombstones older than `compactionHorizon` (default 30 days) are physically
removed by an explicit `compact` call.

## Edge cases and guarantees

- **Convergence is unconditional.** Any set of devices that exchange their
  records ends with identical state, whatever the message order.
- **Merging is idempotent.** Receiving the same records twice is a no-op; the
  protocol relies on this and redelivers freely.
- **Wall-clock quality affects only tie-breaking fairness.** A device with a
  fast clock wins more last-write races; correctness and convergence are
  unaffected.
- **Resurrection after deep offline.** A device offline longer than the
  compaction horizon may reintroduce documents whose tombstones were
  compacted away. Choose a horizon comfortably longer than any expected
  offline stretch.
- **Counters cannot be `put`.** Setting a counter field to a number (other
  than its current value) throws, since that would erase other devices'
  contributions. Use `increment`.
