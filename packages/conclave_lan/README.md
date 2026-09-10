# conclave_lan

LAN transport for [Conclave](https://github.com/nodsoftware/conclave): mDNS service
discovery plus WebSocket data connections, in pure Dart. This is the default
transport used by the [`conclave`](https://pub.dev/packages/conclave) umbrella's
`conclaveBuilder`.

It implements the `Transport` port from `conclave`, discovering same-app
peers on the local network and exchanging already-encrypted frames between them.

## What's inside

- **`LanTransport`** — advertises `_conclave-<appId>._tcp` over mDNS, browses for
  peers, and connects them over WebSocket. Exactly one connection forms per pair
  (the lexicographically smaller node id dials), with ping/pong health checks and
  exponential-backoff reconnect.
- **`FrameCodec`** — length-prefixed binary encoding of `(room, bytes)` frames.

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

- **LAN-only.** No NAT traversal, relay, or internet sync — devices must share a
  local network.
- The transport ships opaque, encrypted bytes; it knows nothing about CRDTs or
  keys.

## Testing

This is the only socket-bound package in Conclave. Its loopback integration test
is tagged `integration` and excluded from the default unit run:

```sh
dart test --run-skipped -t integration packages/conclave_lan
```

`FrameCodec` has fast, socket-free unit tests that always run. See
[Transport adapters](https://nodsoftware.github.io/conclave/adapters/transport/).
