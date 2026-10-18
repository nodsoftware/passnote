import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'ws_socket.dart';

/// Browser (`package:web`) WebSocket backend for `WebSocketTransport`.

/// Dials [uri] and completes once the socket is open.
Future<WsConnection> connectWs(Uri uri) {
  final socket = web.WebSocket(uri.toString())..binaryType = 'arraybuffer';
  final completer = Completer<WsConnection>();
  final connection = _WebConnection(socket);
  socket.onopen = ((web.Event _) {
    if (!completer.isCompleted) completer.complete(connection);
  }).toJS;
  socket.onerror = ((web.Event _) {
    if (!completer.isCompleted) {
      completer.completeError(StateError('WebSocket connect to $uri failed'));
    }
  }).toJS;
  return completer.future;
}

/// A browser cannot accept inbound connections.
const bool canServe = false;

/// Unsupported in the browser: a web peer only dials out (to another peer's
/// listener or to a relay).
Future<WsServerHandle> serveWs(
  int port,
  void Function(WsConnection connection) onConnection,
) async {
  throw UnsupportedError(
    'A browser cannot listen for WebSocket connections; configure '
    'connectTo: with the address of a native peer or a relay.',
  );
}

class _WebConnection implements WsConnection {
  _WebConnection(this._socket) {
    _socket.onmessage = ((web.MessageEvent event) {
      final data = event.data;
      if (data.isA<JSString>()) {
        _messages.add((data as JSString).toDart);
      } else if (data.isA<JSArrayBuffer>()) {
        _messages.add((data as JSArrayBuffer).toDart.asUint8List());
      }
    }).toJS;
    _socket.onclose = ((web.Event _) {
      if (!_messages.isClosed) _messages.close();
    }).toJS;
  }

  final web.WebSocket _socket;
  final _messages = StreamController<Object>();

  @override
  Stream<Object> get messages => _messages.stream;

  @override
  void sendText(String text) => _socket.send(text.toJS);

  @override
  void sendBytes(List<int> bytes) =>
      _socket.send(Uint8List.fromList(bytes).toJS);

  @override
  Future<void> close() async => _socket.close();
}
