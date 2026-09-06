# Changelog

## 0.1.0

First public version.

- LAN `Transport` that discovers same-app peers over mDNS / DNS-SD and exchanges
  frames over WebSocket connections.
- One connection per peer pair (the lexicographically smaller node id dials), a
  15-second WebSocket heartbeat, and exponential-backoff reconnect.
- A socket-bound loopback integration test, excluded from the default run.
