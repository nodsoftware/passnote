# Security

Passnote encrypts everything, everywhere, with modern primitives and real
device membership. Data is protected by authenticated end-to-end encryption
(XChaCha20-Poly1305); keys derive with Argon2id and never leave the devices;
each device carries its own keypair; pairing is authenticated by a
[PAKE](concepts/glossary.md#pake); a lost device is revoked by rotating the
group key; every connection runs a forward-secrecy
[ratchet](concepts/glossary.md#ratchet); the local store is SQLCipher
ciphertext; any tampered or wrong-key frame fails closed; and discovery uses a
one-way [room tag](concepts/glossary.md#room-tag) that reveals nothing.

!!! note "Audit status"
    An independent third-party audit is planned and has not happened yet. The
    design and its test suite are open; if you find a weakness, use the
    [private reporting process](https://github.com/nodsoftware/passnote/blob/main/SECURITY.md).

## What Passnote protects

- **Confidentiality, at rest and in transit.** Every record is encrypted with
  XChaCha20-Poly1305 before it touches disk or network. User data travels
  under the [group key](concepts/glossary.md#group-key); the device
  [roster](concepts/glossary.md#roster) under a key derived from the
  passphrase (BIP39 seed, then Argon2id). On Flutter, keys live in the OS
  keychain.
- **Integrity and authenticity.** Authenticated encryption everywhere: a
  tampered, truncated, or wrong-key frame fails authentication and is dropped.
  Malformed frames cannot crash a device either; the decoder is fail-closed,
  and CI drives it with thousands of seeded random and single-byte-corrupted
  inputs (property tests, not coverage-guided fuzzing).
- **Membership you can manage.** Each device has an X25519 + Ed25519 keypair
  whose private halves never leave it. Joining requires a live pairing: a
  nine-digit one-time code runs a PAKE (peer points are validated on-curve per
  RFC 9382 §4), so guesses cost one visible failure each; a peer gets three
  tries and the code is withdrawn after twenty in total. The sponsor hands
  the joiner its validated roster trust state with the grant, so a new device
  never trusts a roster just because it arrived first. Every roster row is
  Ed25519-signed by the member that wrote it and validated against a trust
  chain rooted at the founding device, with each device id bound to the
  fingerprint of its key, so holding the roster key alone admits nobody.
  Revoking a device rotates the group key to everyone else: the revoked device
  can read nothing written after, and its signatures stop counting, so it
  cannot re-admit itself (or a fresh identity it controls) even though it
  still holds the roster key.
- **Only members write.** With device identities, user data flows only inside
  a session opened by a hello signed with a non-revoked member's key. A frame
  that proves only knowledge of the passphrase key (which revoked devices
  keep) can carry the roster and nothing else, so neither a leaked passphrase
  nor a revoked device can insert, change or delete user data, or learn which
  collections exist. A record stamped far in the future, which would win every
  later merge, is refused until the receiving clock catches up.
- **Yesterday's traffic, tomorrow's theft.** Each connection starts with an
  exchange of ephemeral X25519 keys, signed by both devices, whose private
  halves are wiped once the session exists; every frame then uses a one-use
  key from a hash chain and the previous key is destroyed. Recording traffic
  now and stealing a device later, with all its long-term keys, does not
  decrypt the recording.
- **Opaque discovery.** The room tag peers advertise is a one-way hash. It
  grants no access and reveals nothing about keys or content. It is stable
  for as long as the passphrase is, so it does let an observer recognise the
  same group across networks.
- **At-rest opacity.** SQLCipher encrypts the whole database file: schema, row
  counts, and content are all ciphertext to whoever has only the file. This is
  enforced, not assumed: after keying, the engine checks `PRAGMA
  cipher_version` and throws `SqlCipherUnavailableException` when the linked
  SQLite is not a SQLCipher build, instead of silently writing plaintext. Apps
  select the SQLCipher build of `package:sqlite3` in their root pubspec (see
  [platform setup](guides/set-up-platforms.md)); the exception is the signal
  that the wiring is missing. The web (wasm) engine has no at-rest encryption
  yet and says so in [run on the web](guides/run-on-the-web.md).

## Boundaries and design choices

Each of these is a deliberate scope decision, stated with its reason.

- **The passphrase still matters.** It protects the device roster and seeds
  discovery. A generated 24-word mnemonic (256-bit) makes it unguessable; if
  you accept a user-chosen passphrase, its entropy sets that ceiling, not the
  KDF cost. Since data is under the group key and membership needs a pairing
  or the roster, a leaked passphrase alone does not hand over the data, but
  treat it as sensitive anyway.
- **No recovery, unless you opt in.** By default, losing every device means
  losing the data; nothing is escrowed anywhere, which is the point. Apps that
  want a way back enable the
  [recovery phrase](guides/recover-from-a-lost-passphrase.md), which is a
  deliberate, visible trade.
- **Reachability is a transport choice.** mDNS discovery is LAN-only by
  design: the trust story is simplest when sync happens on networks you are
  on. `WebSocketTransport` reaches further with explicit addresses or a
  self-hosted relay; the relay routes ciphertext and is never trusted with
  keys.
- **Metadata is visible to the network.** An observer sees that a Passnote
  service exists, its opaque room tag, and the sizes and timing of encrypted
  frames. Traffic analysis of volume and timing is possible; contents are not.
  The reference relay raises the stakes from passive to active: it is
  unauthenticated, so anyone who can reach it can claim a node id that is not
  currently connected, silencing that node and collecting its (encrypted)
  traffic and metadata. Deploy it only on a network you control, or behind an
  authenticating proxy; see [transports](reference/transports.md). On any
  transport a node id is only a claim: claiming someone else's can disrupt
  them, but sessions are bound to signed roster identities, so it cannot read
  or write their data.
- **A compromised device is out of scope.** Passnote protects data between
  devices. An attacker who controls a device's OS or unlocked keychain has
  that device's keys, exactly as with any end-to-end encrypted system. Your
  remedy is revocation from a surviving device.
- **Revocation does not change the passphrase.** The roster key derives from
  the passphrase, so a revoked device can still find the group, read the
  roster (labels, public keys, sealed wraps) and send frames that others
  refuse. It cannot read or write user data. Where that residue matters,
  [rotate the passphrase](guides/rotate-the-passphrase.md) after revoking.
- **Replay is harmless by construction.** There is no anti-replay nonce
  because none is needed: records merge idempotently by
  [HLC](concepts/glossary.md#hlc), so a replayed frame changes nothing and
  forges nothing. Inside a session, a frame whose key the chain has moved
  past does not open at all.
- **Roster trust is pinned locally and handed over at pairing.** Each device
  pins the founder, every member key it has validated, and every revocation
  it has seen; the pins are monotone and persist in the key store, so a
  revoked device cannot rewrite pre-revocation history against a restarted
  peer. Unreadable pins refuse to open (`RosterPinsCorruptException`) rather
  than fall back to trusting anew. A paired device starts from its sponsor's
  pins. Only a device restored from a recovery phrase, which has no sponsor,
  trusts the first roster snapshot it receives. Roster rows are also vetted
  at merge time: a row whose writer is not a known, non-revoked member is
  dropped before it touches storage, so a revoked device (which keeps the
  roster key) cannot fill peers' disks with junk rows either. The CPU spent
  refusing such frames is bounded by the inbound rate limiter, in the same
  hygiene class.
- **Pairing can be disrupted, not subverted.** The rendezvous is app-wide so
  that every guess reaches the sponsor and is counted. The flip side is that
  anyone on the network can spend a code's tries or answer in the sponsor's
  place; neither completes a join without the code, and the user can start a
  new one.
- **Side channels on the device.** The SPAKE2 implementation uses
  variable-time big-integer arithmetic. Code running on the same device could
  in principle time it; the code is one-time and expires with the exchange,
  and a co-resident attacker is already inside the device boundary.
- **Rate limiting is hygiene, not a boundary.** A noisy peer's excess frames
  are dropped (`maxInboundFramesPerSecond`, default 100/s) so it cannot starve
  the event loop, and the frames a peer may have waiting to be handled are
  bounded (32 MiB per peer, 128 MiB in total) so it cannot exhaust memory,
  key or no key. Authorisation comes from keys, not from rate limits, and a
  keyed peer is inside the trust boundary by definition.
- **Snapshots follow the key.** Rotating a key rewrites the recovery
  snapshot under the new key straight away. A store quarantined as corrupt
  keeps the key it had; delete it once inspected.
- **Earlier keys stay on the device.** A store that was not open during a
  rotation still has the earlier key, so a device keeps what it needs to open
  it: up to 8 earlier passphrase keys in its key store, and its own sealed
  wraps of earlier group keys in the roster. Opening such a store re-keys it
  at once. An attacker holding the unlocked key store gains nothing beyond
  the compromised-device case above; `leave` and `forget` clear the earlier
  passphrase keys.

## Cryptographic details

| Aspect | Choice |
| --- | --- |
| Symmetric cipher | XChaCha20-Poly1305 (24-byte random nonce, 16-byte tag) |
| Frame layout | `nonce ‖ ciphertext ‖ tag` |
| Passphrase KDF | BIP39 seed, then Argon2id (19 MiB, 2 passes, 1 lane); PBKDF2-HMAC-SHA256 available for FIPS |
| Device identity | X25519 (key agreement) + Ed25519 (signatures) |
| Key wrap | X25519 ephemeral agreement, HKDF-SHA256 bound to both public keys, AES-256-GCM; low-order points refused |
| Pairing | SPAKE2 over P-256 (RFC 9382), nine-digit one-time code, HKDF-derived channel key |
| Session | Ephemeral X25519 per connection, Ed25519-signed by each device; root HKDF-SHA256(group key ‖ agreement) |
| Forward secrecy | Ephemeral keys wiped at session start, then an HMAC-SHA256 hash-chain ratchet, one key per frame |
| Roster rows | Ed25519 signature per row, trust chain from the founder |
| At rest | SQLCipher (whole-file), `cipher_version`-verified on open |
| Room tag | truncated SHA-256 of key material, domain-separated |

Every primitive is pinned by published known-answer
[test vectors](reference/crypto-vectors.md), asserted in CI.

## Recommendations

- Use the generated 24-word passphrase unless you have a strong reason not to.
- Normalise a passphrase the user types before passing it in: Passnote
  derives the key from the exact string, so trim it, collapse runs of
  whitespace to one space, and for a mnemonic lower-case it and apply Unicode
  NFKD. Do the same on every device, from the first; changing it later
  changes the key. The generated words joined with single spaces need
  nothing.
- Choose a stable, app-specific `salt` (like `"myapp:v1"`) and never reuse it
  across unrelated apps.
- Show pairing codes and recovery phrases to the user once; never store them.
- Revoke lost devices promptly, from any surviving device, and rotate the
  passphrase afterwards if the device may be in hostile hands.
- Do not log plaintext documents or derived keys.

## Reporting a vulnerability

Report privately, not in a public issue. See
[`SECURITY.md`](https://github.com/nodsoftware/passnote/blob/main/SECURITY.md)
for the process.
