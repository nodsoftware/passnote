# Run on the web

Conclave runs in the browser: the engine compiles to JavaScript and wasm, the
SQLite store runs on `sqlite3/wasm`, and sync uses `WebSocketTransport`.

Two things differ from native:

**1. Point the engine at `sqlite3.wasm`.** Serve a `sqlite3.wasm` matching
your `sqlite3` package version (from its GitHub releases) and register it
before opening anything:

```dart
SqliteCrdtTable.configureWeb(wasmUri: Uri.parse('sqlite3.wasm'));
```

**2. Give the transport an address.** A browser cannot join mDNS or listen for
connections, so it dials an explicit address: a native peer that listens, or a
relay.

```dart
final conclave = await Conclave.builder(appId: 'shopping', salt: 'shopping:v1')
    .transport(() => WebSocketTransport(
          connectTo: [Uri.parse('wss://relay.example:9473')],
        ))
    .open();
```

A native peer can accept browser connections directly:

```dart
// On the native device:
WebSocketTransport(listenPort: 9473, connectTo: []);
```

Or run the reference relay somewhere both can reach:

```sh
dart run conclave_lan:relay --port 9473
```

The relay routes encrypted envelopes between its clients and can read only
node ids, [room tags](../concepts/glossary.md#room-tag), and ciphertext. It is
a reference (no auth, no persistence); front it with TLS (`wss://`) in any
real deployment.

Everything else (pairing, queries, revocation, recovery) works identically in
the browser. Current web caveats: the wasm store persists per browser storage
rules rather than a file you manage, and at-rest SQLCipher encryption is not
yet wired on wasm; treat browser storage accordingly.
