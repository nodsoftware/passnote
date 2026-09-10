import 'dart:io';

import 'package:conclave_lan/relay.dart';

/// Runs the reference relay: `dart run conclave_lan:relay [--port 9473]`.
///
/// See `WebSocketRelay` for what it does (and deliberately does not do).
Future<void> main(List<String> args) async {
  var port = 9473;
  final portFlag = args.indexOf('--port');
  if (portFlag >= 0 && portFlag + 1 < args.length) {
    port = int.tryParse(args[portFlag + 1]) ?? port;
  }
  final relay = await WebSocketRelay.bind(port: port);
  stdout.writeln('conclave relay listening on ws://0.0.0.0:${relay.port}');
  stdout.writeln('press ctrl-c to stop');
  await ProcessSignal.sigint.watch().first;
  await relay.close();
}
