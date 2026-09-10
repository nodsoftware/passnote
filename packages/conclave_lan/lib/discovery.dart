/// The native-only entry of `conclave_lan`: [LanTransport], which discovers
/// same-app peers over mDNS and connects them with WebSockets.
///
/// Importing this pulls `dart:io`; a web build uses the main
/// `package:conclave_lan/conclave_lan.dart` entry ([WebSocketTransport])
/// instead.
library;

export 'conclave_lan.dart';
export 'src/lan_transport.dart';
