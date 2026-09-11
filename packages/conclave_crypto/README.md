# conclave_crypto

Cryptographic adapters for [Conclave](https://github.com/nodsoftware/conclave):
XChaCha20-Poly1305 encryption, Argon2id key derivation, BIP39 passphrases,
SPAKE2 pairing, and the per-device identity keypair.

Implements the `Cipher`, `Identity`, and `Pake` ports from `conclave` and
provides the key-derivation and mnemonic helpers installed by
`conclave_flutter`'s `conclaveBuilder`.

## What's inside

- **`XChaChaPoly1305Cipher`**: the default `Cipher`, using XChaCha20-Poly1305.
  Frame layout is `nonce (24) ‖ ciphertext ‖ tag (16)`, with a fresh random
  192-bit nonce per message. Authentication failures surface as
  `CipherAuthError`. `AesGcmCipher` remains available for callers who need AES.
- **`DeviceIdentity`**: the X25519 + Ed25519 device keypair behind pairing,
  key wrapping, and revocation, including `fromRecoveryPhrase` for the
  recovery flow.
- **`Spake2Pake`**: SPAKE2 over P-256 (RFC 9382), the exchange behind the
  nine-digit pairing code.
- **`generateMnemonic` / `validateMnemonic`**: BIP39 passphrases at 12, 15,
  18, 21, or 24 words (128 to 256 bits of entropy).
- **`deriveKey`**: BIP39 seed, then Argon2id (19 MiB, 2 passes, 1 lane), to a
  32-byte key. `deriveKeyPbkdf2` keeps a PBKDF2-HMAC-SHA256 pipeline for FIPS
  callers.
- **`roomTag`**: a one-way, truncated SHA-256 of key material used for
  discovery; it reveals nothing about the key or data.

## Install

```yaml
dependencies:
  conclave_crypto: ^0.1.0
```

## Usage

```dart
import 'package:conclave_crypto/conclave_crypto.dart';

final words = generateMnemonic(words: 24).join(' ');
final key = await deriveKey(words, 'myapp:v1');
final cipher = XChaChaPoly1305Cipher(key);

final sealed = await cipher.encrypt([1, 2, 3]);
final opened = await cipher.decrypt(sealed); // throws CipherAuthError if tampered
```

## Documentation

See the [Conclave security model](https://nodsoftware.github.io/conclave/security/)
for cryptographic details and the threat model.
