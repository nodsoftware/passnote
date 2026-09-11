# Wire protocol

What actually travels between two devices, from the outside in. Wire version:
**2**. Version 1 (JSON) predates any release and is gone.

## The layer stack

```text
transport framing            (WebSocket messages / test bus)
└─ kind byte                 0x00 plain · 0x01 ratcheted   (identity mode only)
   └─ ratchet layer          one-use message key per frame (0x01 frames)
      └─ AEAD ciphertext     XChaCha20-Poly1305 under the roster or group key
         └─ binary message   the protocol frame below
```

Roster and control messages travel under the roster key; user-data deltas
under the group key, and additionally inside the
[ratchet](../concepts/glossary.md#ratchet) once a session exists. Anything
that fails authentication at any layer is dropped silently.

## Frame encoding

Every decrypted frame is `magic (0xC7) ‖ version (0x02) ‖ type ‖ body`.
Variable-length fields are varint-prefixed; varints use arithmetic, not
shifts, so 64-bit values survive JavaScript. Record values use a compact
tagged encoding (null, bool, int, double, string, list, map). A 50-record
counter delta measures about a third smaller than its old JSON form.

`decodeMessage` is fail-closed: malformed, truncated, unknown-tag, or
wrong-version input returns null, never throws. CI fuzzes it with random
bytes, corruptions, truncations, and nesting bombs.

## Messages

| Tag | Message | Carries |
| --- | --- | --- |
| 1 | `hello` | Sender's node id; asks for the peer's state. |
| 2 | `state` | Per-collection [watermarks](../concepts/glossary.md#watermark). |
| 3 | `delta` | Records for one collection (≤ 500 per frame, whole documents only). |
| 4 | `poke` | "Send me a hello": the pull half of `forceSync`. |
| 5 | `ratchet-hello` | Session nonce plus a tag of the key generation it belongs to. |
| 6 | `handshake` | Supported wire versions, capabilities, device public key. |
| 7 | `reconcile` | Range fingerprints and record requests (see below). |

Records travel as `(key, value, is_deleted, hlc, crdt_type?)` with the HLC in
string form.

## Connection handshake

Both sides send a `handshake` on connect and reply once to the first one they
receive (at most two frames each). Sync starts on the highest common version;
no overlap raises `PeerIncompatible` and ends the exchange. Capabilities are
feature flags within a version; `recon1` (range reconciliation) is the only
one today, and unknown names are ignored.

## Reconciliation exchange

One side probes a collection with the fingerprint of everything it holds. For
each probe the responder compares its own fingerprint of the same
[HLC](../concepts/glossary.md#hlc) range:

- **Match:** that range is settled; nothing is sent.
- **Small mismatch** (at most 32 records on either side, or the depth cap of
  24 reached): a leaf. The responder ships its records for the range and asks
  for the peer's.
- **Large mismatch:** split at the time midpoint of the responder's data and
  probe back one level deeper.

A fingerprint is the XOR of `SHA-256(key ‖ 0x00 ‖ hlc)` truncated to 16 bytes
per record: order-independent and splittable. Reply fan-out is capped at 64
probes per message; overflow ranges ship as leaves. Duplicated shipping is
harmless because merging is idempotent.

## Flow control

All frames to one peer pass through an ordered send window
(`maxInFlightFrames`, default 16). Order matters: the ratchet chain assumes
frames arrive as sealed. The window bound is the backpressure that stops a
fast sender from burying a slow receiver.
