# The builder

`passnoteBuilder(appId:, salt:)` (from `passnote_flutter`) returns a
`PassnoteBuilder` with the production pieces installed; chain overrides, then
`await .open()`. Each override may be set at most once.

```dart
final passnote = await passnoteBuilder(appId: 'shopping', salt: 'shopping:v1')
    .passphrase(words: 12)
    .compactionHorizon(const Duration(days: 60))
    .open();
```

The frozen surface and its guarantees are described in
[`VERSIONING.md`](https://github.com/nodsoftware/passnote/blob/main/VERSIONING.md).

## Pure Dart (no Flutter)

A plain Dart process uses `Passnote.builder(appId:, salt:)` from
`package:passnote` after installing defaults once with
`PassnoteBuilder.installDefaults`, filling every `PassnoteDefaults` slot with
the production adapters from `passnote_crypto` and `passnote_lan`:

```dart
PassnoteBuilder.installDefaults(PassnoteDefaults(
  engine: (databaseId, collection, key) => SqliteCrdtTable(
      '$dataDir/$databaseId/$collection.sqlite', encryptionKey: key),
  keyStore: (appId) => FileKeyStore(File('$dataDir/$appId.keys.json')),
  transport: LanTransport.new,
  cipher: XChaChaPoly1305Cipher.new,
  deriveKey: deriveKey,
  roomTag: roomTag,
  mnemonicGenerator: (words) => generateMnemonic(words: words),
  validateMnemonic: isValidMnemonic,
  identity: (keyStore) => DeviceIdentity.load(keyStore: keyStore),
  pake: Spake2Pake.new,
  recoveryIdentity: (phrase, salt) =>
      DeviceIdentity.fromRecoveryPhrase(phrase, salt: salt),
));
```

There is no OS keychain in a bare process, so bring your own `KeyStore`. The
runnable version of all of this — including an example-grade file-backed
`FileKeyStore` and a generated per-field merge strategy in use — is
[`examples/cli_logbook`](https://github.com/nodsoftware/passnote/tree/main/examples/cli_logbook),
a two-device terminal logbook. To skip the builder entirely, wire every
dependency explicitly with `passnoteLowLevel` (see [Ports](ports.md)).

## Overrides

| Method | Default | Purpose |
| --- | --- | --- |
| `.storage(factory)` | SQLite files (SQLCipher at rest) | Storage per collection, built from `(databaseId, collection, key)`. `(_, c, __) => MapCrdtTable(c)` selects in-memory, unpersisted. Replaces the deprecated `.engine(factory)`, which was handed the collection name only. |
| `.transport(factory)` | `LanTransport` (mDNS, native only) | How peers are found and frames move. `WebSocketTransport` for web or explicit addresses; see [Transports](transports.md). |
| `.keyStore(factory)` | OS keychain | Where derived keys and the device identity persist. |
| `.cipher(factory)` | XChaCha20-Poly1305 | The authenticated cipher, built per key. |
| `.identity(factory)` | X25519 + Ed25519 device identity | The device keypair backing pairing and revocation. |
| `.pake(factory)` | SPAKE2 (P-256, RFC 9382) | The exchange behind the pairing code. |
| `.recovery(enabled:)` | `false` | Opt in to the recovery phrase APIs. |
| `.passphrase(words:, strictness:)` | 24 words, `warn` | Generated passphrase length; whether non-mnemonic passphrases are rejected. |
| `.compactionHorizon(duration)` | 30 days | How old a tombstone must be before `compact` removes it. |
| `.maxInboundFramesPerSecond(n)` | 100 | Per-peer inbound rate limit. |
| `.antiEntropyInterval(duration)` | 3 minutes | How often each database runs an anti-entropy round with every peer; `Duration.zero` turns the timer off. |

## PassnoteConfig

`passnoteLowLevel` takes the same knobs as a `PassnoteConfig`:

| Field | Default | Meaning |
| --- | --- | --- |
| `appId` | required | Namespaces discovery and storage. |
| `salt` | required | Stable app-specific key-derivation salt (`"myapp:v1"`). Changing it invalidates every derived key. |
| `passphrasePolicy` | 24 words, `warn` | See `.passphrase()`. |
| `compactionHorizon` | 30 days | See `.compactionHorizon()`. |
| `maxInboundFramesPerSecond` | 100 | See `.maxInboundFramesPerSecond()`. |
| `snapshotInterval` | 30 minutes | How often the disk engine writes its recovery snapshot; `Duration.zero` disables. |
| `antiEntropyInterval` | 3 minutes | How often the repair exchange runs; `Duration.zero` disables. |
| `maxInFlightFrames` | 16 | Send-window bound per peer. |
| `maxClockDrift` | 10 minutes | How far ahead of the local clock a received record may be stamped; documents beyond it are refused until the clock catches up. |
| `recoveryEnabled` | `false` | See `.recovery()`. |

## Main handle operations

| Member | Purpose |
| --- | --- |
| `openDatabase(id, passphrase:)` | Open (or create) a database; stores the derived key for `reopenDatabase`. |
| `reopenDatabase(id)` | Reopen without the passphrase, using the stored key. |
| `forget(id)` | Drop the stored key and stop syncing the database. |
| `generatePassphrase()` | A fresh BIP39 word list per the policy. |
| `startPairing(id)` / `pairWith(id, code)` / `cancelPairing()` | The pairing flow. |
| `devices(id)` / `renameDevice` / `revokeDevice` | Roster management. |
| `enableRecovery(id)` / `recoverFrom(id, phrase, passphrase:)` | The opt-in recovery phrase. |
| `forceSync()` | Full exchange with every connected peer, now. |
| `reconcileNow()` | One anti-entropy round on every database with every connected peer, now. |
| `events` | `PeerAppeared`, `PeerDisappeared`, `PeerIncompatible`, `StoreRecovered`. |
| `close()` | Close every database and stop the transport. |
