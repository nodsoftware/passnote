# conclave

Umbrella package for [Conclave](https://github.com/nodsoftware/conclave) — an
end-to-end encrypted, server-less, local-first CRDT sync engine for Dart and
Flutter.

This package re-exports the entire Conclave public surface and provides
`conclaveBuilder`, a batteries-included setup that wires the production adapters:

- **Storage** — `SembastStore`
- **Keys** — `KeychainKeyStore` (OS keychain)
- **Transport** — `LanTransport` (mDNS discovery + WebSocket frames)
- **Crypto** — AES-256-GCM with BIP39/PBKDF2 key derivation

## Install

```yaml
dependencies:
  conclave: ^0.1.0
```

## Usage

```dart
import 'package:conclave/conclave.dart';

final conclave = await conclaveBuilder(appId: 'shopping', salt: 'shopping:v1').open();

// Pair devices with a passphrase:
final words = conclave.generatePassphrase().join(' ');
final db = await conclave.openDatabase('home', passphrase: words);

final items = db.collection<Item>('items', itemCodec);
await items.put(Item(id: newId(), name: 'Milk'));
items.watch().listen((all) => print('now ${all.length} items'));
```

For custom wiring (alternative storage, transport, or crypto), use
`Conclave.open` directly with adapters from the individual packages.

## Documentation

See the [Conclave documentation](https://nodsoftware.github.io/conclave/) and the
[Getting started guide](https://nodsoftware.github.io/conclave/getting-started/).

## Security

Conclave has not been independently audited and the passphrase is the root of
all security. Read the [security model](https://nodsoftware.github.io/conclave/security/)
before shipping.
