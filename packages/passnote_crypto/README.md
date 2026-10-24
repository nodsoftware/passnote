# passnote_crypto

Cryptographic adapters for [Passnote](https://github.com/nodsoftware/passnote):
XChaCha20-Poly1305 encryption, Argon2id key derivation, BIP39 passphrases,
SPAKE2 pairing, and the per-device identity keypair.

Implements the `Cipher`, `Identity`, and `Pake` ports from `passnote` and
provides the key-derivation and mnemonic helpers installed by
`passnote_flutter`'s `passnoteBuilder`.

## What's inside

- **`XChaChaPoly1305Cipher`**: the default `Cipher`, using XChaCha20-Poly1305.
  Frame layout is `nonce (24) ‖ ciphertext ‖ tag (16)`, with a fresh random
  192-bit nonce per message. Authentication failures surface as
  `CipherAuthError`. `AesGcmCipher` is available for callers who need AES.
- **`DeviceIdentity`**: the X25519 + Ed25519 device keypair behind pairing,
  key wrapping, and revocation, including `fromRecoveryPhrase` for the
  recovery flow.
- **`Spake2Pake`**: SPAKE2 over P-256 (RFC 9382), the exchange behind the
  nine-digit pairing code.
- **`generateMnemonic` / `isValidMnemonic`**: BIP39 passphrases at 12, 15,
  18, 21, or 24 words (128 to 256 bits of entropy).
- **`deriveKey`**: BIP39 seed, then Argon2id (19 MiB, 2 passes, 1 lane), to a
  32-byte key. `deriveKeyPbkdf2` keeps a PBKDF2-HMAC-SHA256 pipeline for FIPS
  callers.
- **`roomTag`**: a one-way, truncated SHA-256 of key material used for
  discovery; it reveals nothing about the key or data.

## Install

```yaml
dependencies:
  passnote_crypto: ^1.2.0
```

## Usage

```dart
import 'package:passnote_crypto/passnote_crypto.dart';

final words = generateMnemonic(words: 24).join(' ');
final key = await deriveKey(words, 'myapp:v1');
final cipher = XChaChaPoly1305Cipher(key);

final sealed = await cipher.encrypt([1, 2, 3]);
final opened = await cipher.decrypt(sealed); // throws CipherAuthError if tampered
```

## Documentation

See the [Passnote security model](https://nodsoftware.github.io/passnote/security/)
for cryptographic details and the threat model.
