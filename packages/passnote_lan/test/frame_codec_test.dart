import 'package:passnote/passnote.dart' show Frame;
import 'package:passnote_lan/src/frame_codec.dart';
import 'package:test/test.dart';

void main() {
  test('encode/decode round-trips room and payload', () {
    final frame = Frame('ROOMTAG16CHARSAB', [0, 1, 2, 255, 42]);
    final decoded = FrameCodec.decode(FrameCodec.encode(frame))!;
    expect(decoded.room, frame.room);
    expect(decoded.bytes, frame.bytes);
  });

  test('empty payload and empty room round-trip', () {
    final decoded = FrameCodec.decode(FrameCodec.encode(Frame('', [])))!;
    expect(decoded.room, '');
    expect(decoded.bytes, isEmpty);
  });

  test('a multi-byte UTF-8 room tag round-trips', () {
    final frame = Frame('salle-à-manger-☂', [7]);
    final decoded = FrameCodec.decode(FrameCodec.encode(frame))!;
    expect(decoded.room, frame.room);
  });

  test('a truncated buffer decodes to null, never throws', () {
    final full = FrameCodec.encode(Frame('room', [1, 2, 3]));
    for (var cut = 0; cut < full.length; cut++) {
      // Cutting inside the payload still yields a frame (the payload is the
      // remainder by design); cutting inside the header or room must be null.
      final result = FrameCodec.decode(full.sublist(0, cut));
      if (cut < 2 + 'room'.length) {
        expect(result, isNull, reason: 'cut at $cut');
      }
    }
    expect(FrameCodec.decode(const []), isNull);
    expect(FrameCodec.decode(const [0]), isNull);
  });

  test('a room-length prefix past the buffer decodes to null', () {
    expect(FrameCodec.decode([0xff, 0xff, 1, 2, 3]), isNull);
  });

  test('a room tag that is not valid UTF-8 decodes to null', () {
    // Length 2, then an invalid UTF-8 sequence (lone continuation bytes).
    expect(FrameCodec.decode([0, 2, 0x80, 0x80, 1, 2]), isNull);
  });

  test('an oversize room tag is refused at encode time', () {
    expect(
      () => FrameCodec.encode(Frame('r' * 0x10000, const [])),
      throwsArgumentError,
    );
  });
}
