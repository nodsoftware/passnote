# Glossary

Short definitions of the specialised terms used across this site. Every page
links here on a term's first use.

## Anti-entropy

A periodic exchange between connected devices that repairs anything a lost
frame left behind. Runs every few minutes by default; see
[Sync](sync.md#anti-entropy-and-reconciliation).

## Changeset

A batch of records travelling between devices, or between the engine and
storage: each entry carries a key, a value, a deletion flag, and an
[HLC](#hlc).

## CRDT

A conflict-free replicated data type: a data structure that devices can edit
independently and still merge to one identical result, in any order, without
coordination. Passnote models every collection this way.

## Existence register

The one record that says a document exists. It is separate from the document's
field records, so a delete and a concurrent edit are settled on a single
record and a document can never survive with half its fields missing.

## Group key

The random symmetric key that encrypts a database's user data, at rest and on
the wire. It is sealed ("wrapped") individually to every paired device and
replaced by a new one when a device is revoked.

## HLC

A hybrid logical clock: a timestamp that combines wall-clock time, a counter,
and a device id. HLCs never run backwards, order causally related edits
correctly, and break ties identically on every device. Each record carries the
HLC of its last change.

## Key epoch

A counter that increases every time the group key is rotated. Wraps are tagged
with their epoch so devices can tell a current key from a superseded one.

## Local-first

The design stance that each device owns a complete, always-usable copy of the
data. The network only keeps copies in step; nothing depends on a server.

## PAKE

A password-authenticated key exchange. During pairing, both devices prove they
hold the same short code without revealing it, and derive a shared secret. An
attacker cannot test guesses offline; each wrong guess costs one visible
failed attempt.

## Range reconciliation

The mechanism that finds exactly which records two devices disagree on by
comparing fingerprints of [HLC](#hlc) ranges and splitting mismatches, instead
of re-sending history. Finds even a very old missing record in a handful of
round trips.

## Ratchet

A chain of single-use message keys derived per connection. Every frame is
encrypted with a fresh key and the previous one is destroyed, so a key
captured later cannot decrypt earlier traffic (forward secrecy).

## Room tag

The short public identifier devices use to find each other for one database.
It is a one-way hash derived from key material: it reveals nothing about the
key or the data, and knowing it grants no access.

## Roster

The reserved, synced collection inside every database that lists its paired
devices and carries each device's wrapped [group key](#group-key). Rows in it
merge like any other data.

## Tombstone

The marker left behind by a deletion. Deletes must sync like writes, so a
deleted record is kept (empty, flagged) until compaction removes it after a
configurable horizon.

## Watermark

A collection's highest [HLC](#hlc): "I have everything up to here". The state
exchange ships records newer than the peer's watermark. Older gaps are the job
of [range reconciliation](#range-reconciliation).

## Wire version

The version of the frame encoding two devices agree on during the connection
handshake. No common version is surfaced as a `PeerIncompatible` event rather
than a silent failure.
