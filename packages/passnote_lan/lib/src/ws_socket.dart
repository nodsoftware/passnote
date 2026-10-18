/// The platform-independent face of one WebSocket connection, as
/// `WebSocketTransport` sees it. Backed by `dart:io` on native and
/// `package:web` in the browser (see the conditional import in
/// `websocket_transport.dart`).
abstract interface class WsConnection {
  /// Inbound messages: a [String] for a text message, a `List<int>` for a
  /// binary one. Closes when the connection does.
  Stream<Object> get messages;

  /// Sends a text message.
  void sendText(String text);

  /// Sends a binary message.
  void sendBytes(List<int> bytes);

  /// Closes the connection.
  Future<void> close();
}

/// A bound listening socket (native only).
abstract interface class WsServerHandle {
  /// The port the server is listening on.
  int get port;

  /// Stops listening and drops pending upgrades.
  Future<void> close();
}
