# Security

Conclave is built so that **the encryption key — and therefore the passphrase —
is the only thing that protects your data**. This page describes what Conclave
defends against, what it does not, and the limits you must respect when shipping.

!!! danger "Read this before shipping"
    Conclave has **not** been independently security-audited. Treat the
    guarantees below as best-effort engineering, not a certified guarantee.

## What Conclave protects

- **Confidentiality at rest and in transit.** Every document is encrypted with
  **AES-256-GCM** before it is written to disk or sent over the network. Keys are
  derived from a passphrase via BIP39 → PBKDF2-HMAC-SHA256 and never leave the
  device. On Flutter, keys are stored in the OS keychain
  (`flutter_secure_storage`).
- **Integrity and authenticity of data.** AES-GCM is authenticated encryption: a
  tampered or truncated frame fails authentication and is dropped
  (`CipherAuthError`). A peer cannot forge or silently alter records without the
  key.
- **Membership by key possession.** Devices join a "room" only by deriving the
  same key from the same passphrase. The room tag broadcast over mDNS is a
  one-way function of the key and reveals nothing about it or the data. Peers
  without the key cannot read or even identify a database's traffic.

## What Conclave does **not** protect

- **The passphrase is everything.** Anyone who learns the passphrase can read and
  write the data. Share it only over a trusted channel; treat it like a password.
  There is no recovery and no server-side revocation — rotating means choosing a
  new passphrase and re-pairing devices.
- **Custom passphrases weaken the model.** Conclave's security assumes a
  high-entropy passphrase. The generated BIP39 mnemonic (default 24 words,
  256-bit) provides this. If you supply your own passphrase string, its entropy —
  not the KDF iteration count — sets the security ceiling. A human-memorable
  phrase can be brute-forced regardless of PBKDF2 work factor. Prefer the
  generated mnemonic; if you must accept user input, require a BIP39 mnemonic or
  a long random string.
- **LAN-only, by design.** Discovery and sync happen over the local network
  (mDNS + WebSocket). Conclave does not traverse NAT, relay through a server, or
  sync over the internet. Devices must share a network to sync.
- **Metadata on the local network.** A network observer can see that *some*
  Conclave service exists, its room tag, and the size/timing of encrypted
  frames. The room tag does not reveal the key or contents, but traffic analysis
  of volume and timing is possible.
- **Compromised devices.** Conclave protects data between devices, not against a
  device that is already compromised. If an attacker controls the OS or has the
  unlocked keychain, they have the key.
- **Replay.** Conclave does not add an anti-replay nonce at the protocol layer.
  Replaying a captured encrypted frame is **harmless**: deltas are CRDT records
  reconciled last-write-wins by HLC, so a replayed (older or equal) record never
  overwrites a newer value — it is idempotent. A replayed frame cannot forge new
  data (it is authenticated by the key it was encrypted under).
- **Denial of service.** A malicious peer on the LAN can attempt to flood
  connections. Conclave applies **per-peer inbound rate limiting**
  (`ConclaveConfig.maxInboundFramesPerSecond`, default 100/s) to stop a single
  noisy peer from starving the event loop. This is defence-in-depth, **not** a
  security boundary: a peer with the key is already inside the trust boundary.
  Conclave does not authenticate peers beyond key possession.

## Cryptographic details

| Aspect | Choice |
| --- | --- |
| Symmetric cipher | AES-256-GCM (12-byte random nonce, 16-byte tag) |
| Frame layout | `nonce ‖ ciphertext ‖ tag` |
| Key derivation | BIP39 seed → PBKDF2-HMAC-SHA256, 600 000 iterations |
| Passphrase | BIP39 mnemonic, 128–256 bits of entropy (12–24 words) |
| Room tag | truncated SHA-256 of the key with a domain-separation label |
| Nonce policy | a fresh random nonce per message |

## At-rest storage layout

With per-document persistence (the default), the storage layout is:

- **Blob values** are AES-256-GCM ciphertext.
- **Collection names** appear as plaintext storage keys (`"<collection>/d/<blinded-id>"`).
- **Document ids and field paths** are **blinded** via keyed HMAC-SHA256 so they do
  not appear in plaintext on disk.

An attacker with disk access can still observe:

- The **number of documents** per collection (one blob per document).
- The approximate **size of each document** (per-blob ciphertext length).
- **Which documents change over time** (update patterns from blob rewrites).

This is acceptable under the LAN-only threat model (an attacker with disk access
already controls the device), but it is stated honestly here so you can evaluate
your own threat model.

## Recommendations

- Use the default 24-word passphrase (256-bit entropy) unless you have a strong
  reason not to.
- Choose a stable, app-specific `salt` (e.g. `"myapp:v1"`) and never reuse it
  across unrelated apps.
- Show the generated passphrase to the user once and instruct them to share it
  only over a trusted channel.
- Do not log plaintext documents or derived keys.

## Reporting a vulnerability

Please report security issues privately rather than opening a public issue. See
[`SECURITY.md`](https://github.com/nodsoftware/conclave/blob/main/SECURITY.md) in the
repository for the disclosure process.
