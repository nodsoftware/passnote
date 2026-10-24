# Changelog

## 1.2.0

- `deriveKey`, `deriveKeyPbkdf2` and `deriveRecoverySecret` use
  `bip39Seed`: PBKDF2-HMAC-SHA512 over the NFKD-normalised UTF-8 phrase, as
  BIP39 specifies. Unchanged for ASCII. `deriveKeyLegacy` and
  `deriveKeyPbkdf2Legacy` keep the 1.1 derivation for non-ASCII
  passphrases. New dependency: `unorm_dart`.
- Vectors: `derive_key.json` adds BIP39 seeds and non-ASCII cases with their
  `legacy_key`.

## 1.1.2

- `generateMnemonic` draws its entropy uniformly from `Random.secure`; bip39's
  default generator never produced the byte 0xFF.

## 1.1.1

- No changes of its own; released with the 1.1.1 security patch of
  `passnote`, which it now requires. See the repository `CHANGELOG.md`.

## 1.1.0

- `DeviceIdentity` key wraps bind the ephemeral and the recipient public keys
  (`passnote-key-wrap-v2`); wraps written by 1.0 still open. Wrapping to, or
  unwrapping from, a low-order X25519 key is refused.
- Vectors: `key_wrap.json` pins the v2 wrap and `ratchet.json` the v2 session
  root (ephemeral X25519 agreement); the 1.0 wrap is kept, frozen, as
  `key_wrap_v1.json`.
- Requires `passnote` 1.1.0.

## 1.0.0

First release.

- `XChaChaPoly1305Cipher`: authenticated encryption for every frame and
  record (24-byte random nonce, 16-byte tag).
- Key derivation from a BIP39 passphrase: BIP39 seed then Argon2id, with a
  PBKDF2-HMAC-SHA256 alternative for FIPS environments, plus passphrase
  generation and validation.
- `DeviceIdentity`: X25519 and Ed25519 device keypairs with key wrap
  (X25519 ephemeral agreement, HKDF-SHA256, AES-256-GCM), signing and
  verification, and a deterministic identity derived from a recovery phrase.
- `Spake2`: the pairing exchange (P-256, RFC 9382) behind the nine-digit
  one-time code.
- `roomTag`: the one-way discovery tag.
- Known-answer test vectors for every primitive in `test/vectors/`,
  asserted in CI and regenerable with `tool/generate_vectors.dart`.
