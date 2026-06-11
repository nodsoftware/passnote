# conclave_crypto

Cryptographic adapters for [Conclave](https://github.com/wouterd/conclave):
AES-256-GCM encryption, BIP39 passphrase generation, and PBKDF2 key derivation.

Implements the `Cipher` port from `conclave_core` and provides the key-derivation
and mnemonic helpers used by the [`conclave`](https://pub.dev/packages/conclave)
umbrella's `openDefault`.

## What's inside

- **`AesGcmCipher`** — `Cipher` implementation using AES-256-GCM. Frame layout is
  `nonce (12) ‖ ciphertext ‖ tag (16)`, with a fresh random nonce per message.
  Authentication failures surface as `CipherAuthError`.
- **`generateMnemonic` / `validateMnemonic`** — BIP39 passphrases at 12, 15, 18,
  21, or 24 words (128–256 bits of entropy).
- **`deriveKey`** — BIP39 seed → PBKDF2-HMAC-SHA256 (100 000 iterations) → 32-byte
  key.
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

See the [Conclave security model](https://wouterd.github.io/conclave/security/)
for cryptographic details and the threat model.
