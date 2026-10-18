// Compile-only: proves the main passnote_lan entry builds for the web (no
// dart:io leak) — a browser app can use WebSocketTransport directly.
import 'package:passnote_lan/passnote_lan.dart';

void main() {
  WebSocketTransport(connectTo: [Uri.parse('ws://relay.example:9473')]);
}
