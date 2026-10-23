# passnote_lan

Transports for [Passnote](https://github.com/nodsoftware/passnote): mDNS LAN
discovery (native) and WebSockets (everywhere, including the browser), plus a
reference relay. `LanTransport` is the default installed by
`passnote_flutter`'s `passnoteBuilder`.

Both implement the `Transport` port from `passnote` and move already-encrypted
frames; a transport never sees plaintext.

## What's inside

- **`LanTransport`** (`package:passnote_lan/discovery.dart`, native only):
  advertises `_passnote-<appId>._tcp` over mDNS, browses for peers, and
  connects them over WebSocket. Exactly one connection forms per pair (the
  smaller node id dials), with ping/pong health checks and exponential-backoff
  reconnect.
- **`WebSocketTransport`** (the main, web-safe entry): dials explicit
  `ws(s)://` addresses (a peer's listener or a relay) and, on native
  platforms, accepts inbound connections. One connection can multiplex many
  peers.
- **`WebSocketRelay`** (`package:passnote_lan/relay.dart`) and the
  `dart run passnote_lan:relay` runner: a reference frame relay that routes
  addressed envelopes and can read only node ids, room tags, and ciphertext.
  It is unauthenticated: anyone who reaches it can claim any node id that is
  not currently connected, silencing that node and receiving its (encrypted)
  traffic and metadata. Run it only on a network you control, or behind an
  authenticating proxy.
- **`FrameCodec`**: binary encoding of `(room, bytes)` frames.

## Install

```yaml
dependencies:
  passnote_lan: ^1.1.1
```

## Usage

```dart
import 'package:passnote_lan/passnote_lan.dart';

final transport = LanTransport();
// Pass to passnoteLowLevel(transport: transport, ...), or rely on passnoteBuilder.
```

## Scope and limits

- `LanTransport` is LAN-only: no NAT traversal or internet sync; devices must
  share a network. `WebSocketTransport` reaches anything you can address,
  including through the relay.
- A transport ships opaque, encrypted bytes; it knows nothing about CRDTs or
  keys.

## Testing

This is the only socket-bound package in Passnote. Its loopback integration test
is tagged `integration` and excluded from the default unit run:

```sh
dart test --run-skipped -t integration packages/passnote_lan
```

The WebSocket transport and relay have loopback tests that always run, plus a
headless-Chrome test where a browser peer converges with a native one. See
[Transports](https://nodsoftware.github.io/passnote/reference/transports/).
