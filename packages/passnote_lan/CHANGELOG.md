# Changelog

## 1.1.1

- No changes of its own; released with the 1.1.1 security patch of
  `passnote`, which it now requires. See the repository `CHANGELOG.md`.

## 1.1.0

- `WebSocketTransport` accepts a frame only from a peer its own connection
  carries, and only a connection it dialed may announce further peers; an
  inbound connection introduces itself once. The reference relay drops
  envelopes whose sender is not the client's registered id.
- `LanTransport` and `WebSocketTransport` listeners take
  `maxInboundConnections` (64), `helloTimeout` (10 s) and `maxFrameBytes`
  (4 MiB), and refuse node ids longer than 128 characters.
- Requires `passnote` 1.1.0.

## 1.0.0

First release.

- `LanTransport` (`package:passnote_lan/discovery.dart`, native only):
  zero-configuration peer discovery and sync over mDNS on the local network.
- `WebSocketTransport` (web-safe): sync over explicit `ws(s)://` addresses,
  with inbound listening on native platforms and reconnection with
  exponential backoff.
- `WebSocketRelay` (`package:passnote_lan/relay.dart` and `bin/relay.dart`):
  a self-hostable reference relay that routes ciphertext between peers that
  cannot reach each other directly. It never holds keys.
