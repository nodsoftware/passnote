# Changelog

## Unreleased

- Added `DeviceIdentity.fromRecoveryPhrase(phrase, salt:)` and
  `deriveRecoverySecret`: the deterministic keypair behind a recovery phrase
  (BIP39 seed → Argon2id under a recovery-specific domain → per-keypair
  seeds), so a wrap sealed to the phrase opens on a fresh install years later.
- **The default cipher is now `XChaChaPoly1305Cipher`** (XChaCha20-Poly1305),
  frame layout `nonce(24) ‖ ciphertext ‖ tag(16)`. The 192-bit nonce removes any
  practical random-nonce collision concern. `AesGcmCipher` stays available.
- **`deriveKey` now uses Argon2id** (19 MiB, 2 passes, 1 lane — the OWASP 2023
  interactive minimum) instead of PBKDF2. `deriveKeyPbkdf2` keeps the old
  PBKDF2-HMAC-SHA256 pipeline for FIPS callers. BIP39 phrase encoding is
  unchanged.
- Added `Spake2`, an implementation of SPAKE2 (RFC 9382,
  `P256-SHA256-HKDF-HMAC`) on `package:pointycastle`, pinned to the RFC's
  published test vectors. `Spake2Pake` adapts it to the `conclave` `Pake`
  port for device pairing.
- Added `DeviceIdentity`, the default `Identity` implementation: an X25519
  key-exchange keypair and an Ed25519 signing keypair generated once and kept
  in the injected `KeyStore`. `wrapFor` / `unwrap` seal a symmetric key with
  X25519 → HKDF-SHA256 → AES-256-GCM; `deviceId` (and `fingerprintOf` for a
  peer's public key) is a 16-character base32 fingerprint of the public keys.

## 0.1.0

First public version.

- AES-256-GCM `Cipher` implementation with a fresh 12-byte random nonce per
  message and a 16-byte authentication tag.
- BIP39 mnemonic generation and validation, plus helpers to estimate the entropy
  of a free-form passphrase.
- PBKDF2-HMAC-SHA256 key derivation at the OWASP 2023 iteration count.
- Keyed room-tag derivation for discovery and a keyed id masker for at-rest
  document-id blinding.
