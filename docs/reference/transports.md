# Transports

Conclave ships two transports in `conclave_lan`, plus an in-memory pair for
tests. All of them move opaque, already-encrypted frames; a transport never
sees plaintext.

## LanTransport (mDNS, native)

The default on iOS, Android, macOS, Windows, and Linux. Zero configuration
in code: devices on the same network find each other. Each OS gates local
network access, though; do
[Set up platforms](../guides/set-up-platforms.md) once per
platform you ship to.

```dart
import 'package:conclave_lan/discovery.dart';

final transport = LanTransport();
```

1. **Advertise.** On start it binds a WebSocket listener on an ephemeral port
   and advertises `_conclave-<appId>._tcp` over mDNS with its node id and
   port.
2. **Discover.** It browses the same service type periodically.
3. **Connect once per pair.** The device with the smaller node id dials; the
   other accepts.
4. **Stay healthy.** Ping/pong detects dead links; the dialing side reconnects
   with exponential backoff.

`LanTransport` lives in the native-only entry
`package:conclave_lan/discovery.dart` because mDNS needs `dart:io`.

## WebSocketTransport (explicit addresses, everywhere)

For browsers, and for peers outside mDNS reach. It dials one or more
`ws(s)://` addresses; on native platforms it can also listen.

```dart
import 'package:conclave_lan/conclave_lan.dart'; // web-safe entry

// A web app connecting to a known peer or a relay:
Conclave.builder(appId: 'shopping', salt: 'shopping:v1')
    .transport(() => WebSocketTransport(
          connectTo: [Uri.parse('wss://relay.example:9473')],
        ))
    .open();

// A native peer that also accepts inbound connections:
WebSocketTransport(listenPort: 9473, connectTo: []);
```

One connection can carry many peers: a relay announces its clients to each
other and routes addressed envelopes between them, so a direct peer-to-peer
connection is just the two-party case. Payloads stay end-to-end encrypted
either way. Dropped connections re-dial with exponential backoff. A browser
cannot listen (`listenPort` throws there); it only dials out.

## The reference relay

`WebSocketRelay` (in `package:conclave_lan/relay.dart`) is a minimal frame
relay for peers that cannot reach each other directly:

```sh
dart run conclave_lan:relay --port 9473
```

It sees node ids, public [room tags](../concepts/glossary.md#room-tag), and
ciphertext, never plaintext. It is a reference, not a product: one port, no
authentication, no persistence. Host it yourself.

**"No authentication" means anyone may become anyone.** A stranger who can
reach the relay can claim any node id that is not connected at that moment:
the real node is then refused service (indistinguishable, to it, from an
outage) and every envelope addressed to it goes to the squatter instead —
still ciphertext, but the full metadata graph (who talks to that node, frame
sizes, timing). Run the relay only on a network you control, or behind an
authenticating proxy. Client count and frame size are capped
(`maxClients`, `maxFrameBytes`) as hygiene, not as protection.

## Writing your own

Implement the five members of `Transport` (see [Ports](ports.md)): emit
`PeerConnected`/`PeerLost` on `events`, deliver `InboundFrame`s on `inbound`,
ship a `Frame` in `send`. Anything that can discover peers and move bytes
works: Bluetooth, WebRTC, a message queue. `InMemoryTransport` over an
`InMemoryBus` is the minimal reference used by the engine tests.
