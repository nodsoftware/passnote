# Changelog

## Unreleased

- Added `WebSocketTransport`: a transport over explicit `ws(s)://` addresses,
  for browsers and peers outside mDNS reach. It dials one or more addresses
  (a peer's listener or a relay), accepts inbound connections on native
  platforms (`listenPort:`), and reconnects with exponential backoff. The
  wire protocol multiplexes many peers over one connection, so a relay is
  just another address; payloads stay end-to-end encrypted either way.
- Added `WebSocketRelay` (`package:conclave_lan/relay.dart`) and the
  `dart run conclave_lan:relay` runner: a reference frame relay that routes
  addressed envelopes between its clients. It sees node ids, public room tags,
  and ciphertext — never plaintext. No auth, no persistence: a reference, not
  a product.
- **Breaking:** the main `package:conclave_lan/conclave_lan.dart` entry is now
  web-safe (no `dart:io`): it exports `WebSocketTransport` and `FrameCodec`.
  `LanTransport` (mDNS discovery, native only) moved to
  `package:conclave_lan/discovery.dart`.

## 0.1.0

First public version.

- LAN `Transport` that discovers same-app peers over mDNS / DNS-SD and exchanges
  frames over WebSocket connections.
- One connection per peer pair (the lexicographically smaller node id dials), a
  15-second WebSocket heartbeat, and exponential-backoff reconnect.
- A socket-bound loopback integration test, excluded from the default run.
