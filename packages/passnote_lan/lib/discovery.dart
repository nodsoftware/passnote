/// The native-only entry of `passnote_lan`: [LanTransport], which discovers
/// same-app peers over mDNS and connects them with WebSockets.
///
/// Importing this pulls `dart:io`; a web build uses the main
/// `package:passnote_lan/passnote_lan.dart` entry ([WebSocketTransport])
/// instead.
library;

export 'passnote_lan.dart';
export 'src/lan_transport.dart';
