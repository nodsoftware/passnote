# Security Policy

## Reporting a vulnerability

If you believe you have found a security vulnerability in Passnote, please report
it **privately**. Do not open a public issue, pull request, or discussion for
security problems.

- Use GitHub's [private vulnerability reporting](https://github.com/nodsoftware/passnote/security/advisories/new)
  for this repository, or
- Email [wouter@nodsoftware.net](mailto:wouter@nodsoftware.net).

Please include enough detail to reproduce the issue: affected package and
version, a description of the impact, and a minimal proof of concept if possible.
We will acknowledge your report, work with you on a fix, and credit you in the
disclosure unless you prefer to remain anonymous.

## Supported versions

Security fixes go into the latest `1.x` release. All five packages release
together with matching versions (see [`VERSIONING.md`](VERSIONING.md)), so
upgrade them together and promptly when a fix ships.

| Version | Supported |
| --- | --- |
| 1.x (latest) | Yes |
| Older 1.x releases | No: upgrade to the latest |

## Threat model summary

Passnote provides authenticated end-to-end encryption between a group of
devices, with per-device identity keys, PAKE-authenticated pairing, device
revocation by group-key rotation, and a forward-secrecy ratchet on every
connection.

**Passnote protects:**

- Confidentiality and integrity of data at rest (SQLCipher) and in transit
  (XChaCha20-Poly1305); tampered frames are rejected.
- Membership: devices join by a PAKE-authenticated pairing and are removed by
  key rotation. Peers outside the group cannot read or identify a database's
  traffic, and only non-revoked members can write user data: knowing the
  passphrase, or having been a member once, is not enough.
- Past traffic against future device compromise (per-connection sessions
  rooted in signed ephemeral X25519 keys, then a hash-chain ratchet).

**Boundaries (deliberate scope):**

- A compromised device or OS, or an unlocked keychain, holds that device's
  keys; the remedy is revocation from a surviving device.
- Local-network metadata: an observer sees that a Passnote service exists, its
  opaque room tag, and frame sizes and timing.
- Recovery is opt-in; by default, losing every device loses the data.
- Denial-of-service by a network neighbour is rate-limited, not prevented;
  that includes disturbing a pairing in progress.
- A revoked device keeps the passphrase-derived roster key until the
  passphrase is rotated: it can still see the roster, though no user data.

Passnote has not yet had an independent security audit; one is planned. For the
full discussion, see [`docs/security.md`](docs/security.md).
