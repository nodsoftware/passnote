// Constructs the two transports. A transport is handed to the Passnote
// builder (`.transport(...)`), which starts and stops it; this example only
// shows the configuration surface.
import 'package:passnote_lan/discovery.dart';

void main() {
  // Zero-configuration discovery and sync on the local network (native only).
  final lan = LanTransport();

  // Explicit addresses, for browsers and peers beyond mDNS reach. The
  // addresses point at peers listening with `listenPort:`, or at a relay
  // (`dart run passnote_lan:relay`).
  final ws = WebSocketTransport(
    connectTo: [Uri.parse('wss://relay.example.com')],
  );

  print('transports ready: $lan, $ws');
}
