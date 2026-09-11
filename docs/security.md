# Security

Conclave encrypts everything, everywhere, with modern primitives and real
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
    [private reporting process](https://github.com/nodsoftware/conclave/blob/main/SECURITY.md).

## What Conclave protects

- **Confidentiality, at rest and in transit.** Every record is encrypted with
  XChaCha20-Poly1305 before it touches disk or network. User data travels
  under the [group key](concepts/glossary.md#group-key); the device
  [roster](concepts/glossary.md#roster) under a key derived from the
  passphrase (BIP39 seed, then Argon2id). On Flutter, keys live in the OS
  keychain.
- **Integrity and authenticity.** Authenticated encryption everywhere: a
  tampered, truncated, or wrong-key frame fails authentication and is dropped.
  Malformed frames cannot crash a device either; the decoder is fail-closed
  and fuzzed in CI.
- **Membership you can manage.** Each device has an X25519 + Ed25519 keypair
  whose private halves never leave it. Joining requires a live pairing: a
  nine-digit one-time code runs a PAKE, so guesses cost one visible failure
  each and the sponsor stops after three. Revoking a device rotates the group
  key to everyone else; the revoked device can read nothing written after.
- **Yesterday's traffic, tomorrow's theft.** Each connection encrypts every
  frame with a one-use key from a hash chain and destroys the previous key.
  Recording traffic now and stealing a device later does not decrypt the
  recording.
- **Unlinkable discovery.** The room tag peers advertise is a one-way hash.
  It grants no access and reveals nothing about keys or content.
- **At-rest opacity.** SQLCipher encrypts the whole database file: schema, row
  counts, and content are all ciphertext to whoever has only the file.

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
- **Metadata is visible to the network.** An observer sees that a Conclave
  service exists, its opaque room tag, and the sizes and timing of encrypted
  frames. Traffic analysis of volume and timing is possible; contents are not.
- **A compromised device is out of scope.** Conclave protects data between
  devices. An attacker who controls a device's OS or unlocked keychain has
  that device's keys, exactly as with any end-to-end encrypted system. Your
  remedy is revocation from a surviving device.
- **Replay is harmless by construction.** There is no anti-replay nonce
  because none is needed: records merge idempotently by
  [HLC](concepts/glossary.md#hlc), so a replayed frame changes nothing and
  forges nothing.
- **Rate limiting is hygiene, not a boundary.** A noisy peer's excess frames
  are dropped (`maxInboundFramesPerSecond`, default 100/s) so it cannot starve
  the event loop. Authorisation comes from keys, not from rate limits, and a
  keyed peer is inside the trust boundary by definition.

## Cryptographic details

| Aspect | Choice |
| --- | --- |
| Symmetric cipher | XChaCha20-Poly1305 (24-byte random nonce, 16-byte tag) |
| Frame layout | `nonce ‖ ciphertext ‖ tag` |
| Passphrase KDF | BIP39 seed, then Argon2id (19 MiB, 2 passes, 1 lane); PBKDF2-HMAC-SHA256 available for FIPS |
| Device identity | X25519 (key agreement) + Ed25519 (signatures) |
| Key wrap | X25519 ephemeral agreement, HKDF-SHA256, AES-256-GCM |
| Pairing | SPAKE2 over P-256 (RFC 9382), nine-digit one-time code |
| Forward secrecy | HKDF/HMAC-SHA256 hash-chain ratchet, one key per frame |
| At rest | SQLCipher (whole-file) |
| Room tag | truncated SHA-256 of key material, domain-separated |

Published test vectors for the primitives accompany the crypto package (see
the repository's `packages/conclave_crypto/test/`).

## Recommendations

- Use the generated 24-word passphrase unless you have a strong reason not to.
- Choose a stable, app-specific `salt` (like `"myapp:v1"`) and never reuse it
  across unrelated apps.
- Show pairing codes and recovery phrases to the user once; never store them.
- Revoke lost devices promptly, from any surviving device.
- Do not log plaintext documents or derived keys.

## Reporting a vulnerability

Report privately, not in a public issue. See
[`SECURITY.md`](https://github.com/nodsoftware/conclave/blob/main/SECURITY.md)
for the process.
