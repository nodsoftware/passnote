# Changelog

## 1.0.0

First release.

- `XChaChaPoly1305Cipher`: authenticated encryption for every frame and
  record (24-byte random nonce, 16-byte tag).
- Key derivation from a BIP39 passphrase: BIP39 seed then Argon2id, with a
  PBKDF2-HMAC-SHA256 alternative for FIPS environments, plus passphrase
  generation and validation.
- `DeviceIdentity`: X25519 and Ed25519 device keypairs with key wrap
  (X25519 ephemeral agreement, HKDF-SHA256, AES-256-GCM), signatures, and a
  deterministic identity derived from a recovery phrase.
- `Spake2`: the pairing exchange (P-256, RFC 9382) behind the nine-digit
  one-time code.
- `roomTag`: the one-way discovery tag.
- Known-answer test vectors for every primitive in `test/vectors/`,
  asserted in CI and regenerable with `tool/generate_vectors.dart`.
