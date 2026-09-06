# Changelog

## 0.1.0

First public version.

- AES-256-GCM `Cipher` implementation with a fresh 12-byte random nonce per
  message and a 16-byte authentication tag.
- BIP39 mnemonic generation and validation, plus helpers to estimate the entropy
  of a free-form passphrase.
- PBKDF2-HMAC-SHA256 key derivation at the OWASP 2023 iteration count.
- Keyed room-tag derivation for discovery and a keyed id masker for at-rest
  document-id blinding.
