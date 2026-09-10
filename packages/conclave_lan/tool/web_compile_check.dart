// Compile-only: proves the main conclave_lan entry builds for the web (no
// dart:io leak) — a browser app can use WebSocketTransport directly.
import 'package:conclave_lan/conclave_lan.dart';

void main() {
  WebSocketTransport(connectTo: [Uri.parse('ws://relay.example:9473')]);
}
