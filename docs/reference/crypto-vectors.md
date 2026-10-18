# Crypto test vectors

Known-answer vectors for every cryptographic primitive live in
[`packages/passnote_crypto/test/vectors/`](https://github.com/nodsoftware/passnote/tree/main/packages/passnote_crypto/test/vectors)
as human-readable JSON, asserted by `vectors_test.dart` in the default CI run.
They pin the primitives against accidental change and give an auditor or an
independent implementation a concrete target.

| File | Pins |
| --- | --- |
| `derive_key.json` | Passphrase and recovery-secret derivation: BIP39 seed, then Argon2id (19456 KiB, 2 passes, 1 lane), with the domain-separated salt hashing recorded in the file. |
| `room_tag.json` | The discovery tag: truncated base32 SHA-256 under the `passnote-room` domain. |
| `xchacha.json` | XChaCha20-Poly1305 frames (`nonce ‖ ciphertext ‖ tag`) for fixed key, nonce, and plaintext. |
| `spake2.json` | A full SPAKE2 (P-256, RFC 9382) exchange with fixed scalars: both messages, the transcript, the shared secret, both confirmation MACs. |
| `key_wrap.json` | The X25519 → HKDF-SHA256 → AES-256-GCM key wrap with a fixed ephemeral seed and GCM nonce, recipient derived from a recorded recovery phrase. |
| `ratchet.json` | The session root derivation and the first message keys of the send chain for fixed inputs. |

## Reproducing independently

Each file's `primitive` field states the exact construction and parameters.
Randomness is fixed through test-only seams (`encryptWithNonce`,
`wrapForWithEphemeralSeed`, the SPAKE2 `scalarOverride`); production paths
always use fresh randomness. An independent implementation that follows the
stated construction must reproduce every output byte for byte.

To regenerate after a deliberate primitive change (a breaking change by
definition, see
[`VERSIONING.md`](https://github.com/nodsoftware/passnote/blob/main/VERSIONING.md)):

```sh
cd packages/passnote_crypto
dart run tool/generate_vectors.dart
```

The diff of the vector files is the review artefact.
