# conclave_lan

Transports for [Conclave](https://github.com/nodsoftware/conclave): mDNS LAN
discovery (native) and WebSockets (everywhere, including the browser), plus a
reference relay. `LanTransport` is the default installed by
`conclave_flutter`'s `conclaveBuilder`.

Both implement the `Transport` port from `conclave` and move already-encrypted
frames; a transport never sees plaintext.

## What's inside

- **`LanTransport`** (`package:conclave_lan/discovery.dart`, native only):
  advertises `_conclave-<appId>._tcp` over mDNS, browses for peers, and
  connects them over WebSocket. Exactly one connection forms per pair (the
  smaller node id dials), with ping/pong health checks and exponential-backoff
  reconnect.
- **`WebSocketTransport`** (the main, web-safe entry): dials explicit
  `ws(s)://` addresses (a peer's listener or a relay) and, on native
  platforms, accepts inbound connections. One connection can multiplex many
  peers.
- **`WebSocketRelay`** (`package:conclave_lan/relay.dart`) and the
  `dart run conclave_lan:relay` runner: a reference frame relay that routes
  addressed envelopes and can read only node ids, room tags, and ciphertext.
- **`FrameCodec`**: binary encoding of `(room, bytes)` frames.

## Install

```yaml
dependencies:
  conclave_lan: ^0.1.0
```

## Usage

```dart
import 'package:conclave_lan/conclave_lan.dart';

final transport = LanTransport();
// Pass to Conclave.lowLevel(transport: transport, ...), or rely on conclaveBuilder.
```

## Scope and limits

- `LanTransport` is LAN-only: no NAT traversal or internet sync; devices must
  share a network. `WebSocketTransport` reaches anything you can address,
  including through the relay.
- A transport ships opaque, encrypted bytes; it knows nothing about CRDTs or
  keys.

## Testing

This is the only socket-bound package in Conclave. Its loopback integration test
is tagged `integration` and excluded from the default unit run:

```sh
dart test --run-skipped -t integration packages/conclave_lan
```

The WebSocket transport and relay have loopback tests that always run, plus a
headless-Chrome test where a browser peer converges with a native one. See
[Transports](https://nodsoftware.github.io/conclave/reference/transports/).
