# Changelog

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
