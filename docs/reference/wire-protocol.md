# Wire protocol

What actually travels between two devices, from the outside in. Wire version:
**2** (Passnote 1.1). Version 1 is no longer spoken: its sessions had no
forward secrecy and accepted user data under the passphrase key, so a 1.0 peer
is reported as `PeerIncompatible` rather than synced with.

## The layer stack

```text
transport framing            (WebSocket messages / test bus)
└─ kind byte                 0x00 plain · 0x01 ratcheted   (identity mode only)
   ├─ 0x00: AEAD ciphertext  XChaCha20-Poly1305 under the roster key
   └─ 0x01: ratchet layer    XChaCha20-Poly1305 under a one-use message key
      └─ binary message      the protocol frame below
```

With device identities (the default), a plain frame proves only that its
sender holds the roster key, which every device that ever joined keeps, so it
may carry nothing but `handshake`, `ratchet-hello`, `hello`, `poke`, and the
roster collection's `state`, `delta` and `reconcile`. Everything about user
collections, including their names and watermarks, travels only in ratcheted
frames, inside a [session](../concepts/glossary.md#ratchet) opened with a
non-revoked roster member; the receiver ignores it in a plain frame. Without
an identity, the passphrase key is the only membership and every message
travels under it. Anything that fails authentication at any layer is dropped
silently.

## Frame encoding

Every decrypted frame is `magic (0xC7) ‖ version (0x02) ‖ type ‖ body`. The
`handshake` alone keeps version byte `0x01`, its layout unchanged, so a 1.0
peer can still read which versions this build speaks.
Variable-length fields are varint-prefixed; varints use arithmetic, not
shifts, so 64-bit values survive JavaScript. Record values use a compact
tagged encoding (null, bool, int, double, string, list, map).

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
| 5 | `ratchet-hello` | Sender and receiver node ids, the sender's device id, its ephemeral X25519 public key, a tag of the key generation, and an Ed25519 signature over all of them. |
| 6 | `handshake` | Supported wire versions, capabilities, device public key. |
| 7 | `reconcile` | Range fingerprints and record requests (see below). |

Records travel as `(key, value, is_deleted, hlc, crdt_type?)` with the HLC in
string form.

## Connection handshake

Both sides send a `handshake` on connect and reply once to the first one they
receive (at most two frames each). Sync starts on the highest common version;
no overlap raises `PeerIncompatible` and ends the exchange. Capabilities are
feature flags within a version, and unknown names are ignored:

- `recon1`: range reconciliation (below).
- `inst:<16 hex>`: a random token minted per open database instance. A
  handshake carrying a token not seen before from that transport peer means
  the peer restarted, possibly without the transport reporting it lost: the
  receiver drops everything it held for the peer (session, negotiated
  version, pending hellos, as on a lost connection) and negotiates afresh. A
  token already seen (a redelivery or a replay) changes nothing; the last 8
  per peer are remembered. A peer that sends no token is not reset.

## Session handshake

Once the version is agreed, each side that holds the group key sends a
`ratchet-hello`: a fresh ephemeral X25519 public key for this connection,
signed with its device's Ed25519 roster key over
`"passnote-ratchet-hello-v2" ‖ from ‖ to ‖ deviceId ‖ keyTag ‖ ephemeral`.
The receiver accepts it only when it is addressed to itself, comes from the
transport peer it names, matches its own key generation, and verifies under
the key of a non-revoked roster member. A hello from a device whose roster
record has not arrived yet is held and re-checked after the next roster sync.

The session root is `HKDF-SHA256(groupKey ‖ X25519(ephemeral, peerEphemeral))`
with info `"passnote-ratchet-root-v2"`, the sorted node ids and the sorted
ephemeral keys; the low and high send chains derive from it. Each side wipes
its ephemeral private key once the session exists. A peer that seals frames
this side cannot open is asked to re-send its hello, rate-limited per peer.

Inbound frames from one peer are handled one at a time, in arrival order.

## Clock bound

A `delta` record whose HLC is more than `maxClockDrift` (default 10 minutes)
ahead of the receiver's clock is refused together with the rest of its
document; anti-entropy offers it again later.

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
