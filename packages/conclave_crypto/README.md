# conclave_crypto

Cryptographic adapters for [Conclave](https://github.com/nodsoftware/conclave):
AES-256-GCM encryption, BIP39 passphrase generation, and PBKDF2 key derivation.

Implements the `Cipher` port from `conclave_core` and provides the key-derivation
and mnemonic helpers used by the [`conclave`](https://pub.dev/packages/conclave)
umbrella's `conclaveBuilder`.

## What's inside

- **`XChaChaPoly1305Cipher`** — the default `Cipher`, using XChaCha20-Poly1305.
  Frame layout is `nonce (24) ‖ ciphertext ‖ tag (16)`, with a fresh random
  192-bit nonce per message. Authentication failures surface as `CipherAuthError`.
  `AesGcmCipher` remains available for callers who need AES.
- **`generateMnemonic` / `validateMnemonic`** — BIP39 passphrases at 12, 15, 18,
  21, or 24 words (128–256 bits of entropy).
- **`deriveKey`** — BIP39 seed → Argon2id (19 MiB, 2 passes, 1 lane) → 32-byte
  key. `deriveKeyPbkdf2` keeps the PBKDF2-HMAC-SHA256 pipeline for FIPS callers.
- **`roomTag`** — a one-way, truncated SHA-256 of the key for mDNS discovery that
  reveals nothing about the key or data.

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
final cipher = AesGcmCipher(key);

final sealed = await cipher.encrypt([1, 2, 3]);
final opened = await cipher.decrypt(sealed); // throws CipherAuthError if tampered
```

## Documentation

See the [Conclave security model](https://nodsoftware.github.io/conclave/security/)
for cryptographic details and the threat model.
