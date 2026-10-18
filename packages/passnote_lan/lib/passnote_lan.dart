/// WebSocket transports for Passnote. This entry is web-safe: it pulls no
/// `dart:io`, so a browser build can use [WebSocketTransport] directly.
///
/// mDNS LAN discovery (`LanTransport`) is native-only and lives in
/// `package:passnote_lan/discovery.dart`; the reference relay in
/// `package:passnote_lan/relay.dart`.
library;

export 'src/frame_codec.dart';
export 'src/websocket_transport.dart';
