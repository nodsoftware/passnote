# Security Policy

## Reporting a vulnerability

If you believe you have found a security vulnerability in Conclave, please report
it **privately**. Do not open a public issue, pull request, or discussion for
security problems.

- Use GitHub's [private vulnerability reporting](https://github.com/nodsoftware/conclave/security/advisories/new)
  for this repository, or
- Contact the maintainers directly through the address listed on the repository
  profile.

Please include enough detail to reproduce the issue: affected package and
version, a description of the impact, and a minimal proof of concept if possible.
We will acknowledge your report, work with you on a fix, and credit you in the
disclosure unless you prefer to remain anonymous.

## Supported versions

Conclave is pre-1.0 (`0.x`). Security fixes are applied to the latest released
`0.x` version. Pin to a specific version and upgrade promptly when fixes ship.

## Threat model summary

Conclave provides end-to-end encryption between devices on a local network. The
**passphrase is the root of all security**: anyone who has it can read and write
the data, and there is no server-side revocation or recovery.

**Conclave protects:**

- Confidentiality of data at rest and in transit (AES-256-GCM).
- Integrity and authenticity of synced records (authenticated encryption;
  tampered frames are rejected).
- Room membership by key possession — peers without the key cannot read or
  identify a database's traffic.

**Conclave does _not_ protect against:**

- A leaked passphrase (it grants full read/write access).
- Anything beyond the local network — there is no relay, NAT traversal, or
  internet sync.
- Local-network metadata: an observer can see that a Conclave service exists, its
  opaque room tag, and the size/timing of encrypted frames.
- A compromised device or OS, or an unlocked keychain.
- Denial-of-service from a malicious peer on the LAN.

> ⚠️ Conclave has **not** undergone an independent security audit. Evaluate it
> carefully against your own threat model before using it for sensitive data.

For the full discussion, see [`docs/security.md`](docs/security.md).
