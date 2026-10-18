import 'dart:convert';
import 'dart:typed_data';

import 'package:passnote/passnote.dart' show Frame;

/// Serialises [Frame]s to and from the binary form sent over a WebSocket.
///
/// Layout: a 2-byte big-endian room-tag length, the UTF-8 room tag, then the
/// raw payload bytes. WebSocket preserves message boundaries, so no overall
/// length prefix is needed — only the split between room tag and payload.
class FrameCodec {
  const FrameCodec._();

  /// Encodes [frame] into a single binary WebSocket message.
  static Uint8List encode(Frame frame) {
    final room = utf8.encode(frame.room);
    if (room.length > 0xffff) {
      throw ArgumentError('Room tag too long: ${room.length} bytes');
    }
    final out = BytesBuilder(copy: false);
    out.addByte((room.length >> 8) & 0xff);
    out.addByte(room.length & 0xff);
    out.add(room);
    out.add(frame.bytes);
    return out.toBytes();
  }

  /// Decodes a binary WebSocket message produced by [encode], or returns
  /// `null` if the buffer is too short to be a valid frame or its room tag is
  /// not valid UTF-8. Fail-closed: malformed network input never throws.
  static Frame? decode(List<int> bytes) {
    if (bytes.length < 2) return null;
    final roomLen = (bytes[0] << 8) | bytes[1];
    if (bytes.length < 2 + roomLen) return null;
    final String room;
    try {
      room = utf8.decode(bytes.sublist(2, 2 + roomLen));
    } on FormatException {
      return null;
    }
    final payload = bytes.sublist(2 + roomLen);
    return Frame(room, payload);
  }
}
