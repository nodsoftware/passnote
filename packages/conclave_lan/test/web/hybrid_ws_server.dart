import 'package:conclave/conclave.dart';
import 'package:conclave_lan/conclave_lan.dart';
import 'package:stream_channel/stream_channel.dart';

/// The native half of the browser WebSocket test: hosts a listening
/// [WebSocketTransport] in a hybrid (VM) isolate, reports its port over the
/// [channel], and echoes every inbound frame back with the payload reversed.
Future<void> hybridMain(StreamChannel<Object?> channel) async {
  final transport = WebSocketTransport(listenPort: 0);
  await transport.start(self: 'native-node', appId: 'wsweb');

  transport.inbound.listen((inbound) {
    transport.send(
      inbound.from,
      Frame(inbound.frame.room, inbound.frame.bytes.reversed.toList()),
    );
  });

  channel.sink.add(transport.boundPort);
}
