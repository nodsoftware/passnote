import 'dart:async';
import 'dart:io';

import 'ws_socket.dart';

/// Native (`dart:io`) WebSocket backend for `WebSocketTransport`.

/// Dials [uri] and adapts the socket.
Future<WsConnection> connectWs(Uri uri) async =>
    _IoConnection(await WebSocket.connect(uri.toString()));

/// Whether this platform can accept inbound connections.
const bool canServe = true;

/// Binds an HTTP server on [port] (0 = ephemeral) that upgrades every
/// WebSocket request and hands the connection to [onConnection].
Future<WsServerHandle> serveWs(
  int port,
  void Function(WsConnection connection) onConnection,
) async {
  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  server.listen((request) async {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }
    onConnection(_IoConnection(await WebSocketTransformer.upgrade(request)));
  });
  return _IoServerHandle(server);
}

class _IoConnection implements WsConnection {
  _IoConnection(this._socket) {
    _socket.pingInterval = const Duration(seconds: 15);
    _socket.listen(
      (data) {
        if (data is String) _messages.add(data);
        if (data is List<int>) _messages.add(data);
      },
      onDone: _messages.close,
      onError: (Object _) => _messages.close(),
    );
  }

  final WebSocket _socket;
  final _messages = StreamController<Object>();

  @override
  Stream<Object> get messages => _messages.stream;

  @override
  void sendText(String text) => _socket.add(text);

  @override
  void sendBytes(List<int> bytes) => _socket.add(bytes);

  @override
  Future<void> close() => _socket.close();
}

class _IoServerHandle implements WsServerHandle {
  _IoServerHandle(this._server);
  final HttpServer _server;

  @override
  int get port => _server.port;

  @override
  Future<void> close() => _server.close(force: true);
}
