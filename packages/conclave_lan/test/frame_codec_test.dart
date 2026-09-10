import 'package:conclave/conclave.dart';
import 'package:conclave_lan/conclave_lan.dart';
import 'package:test/test.dart';

void main() {
  group('FrameCodec', () {
    test('round-trips a frame', () {
      final frame = Frame('room-abc', [1, 2, 3, 4, 5]);
      final encoded = FrameCodec.encode(frame);
      final decoded = FrameCodec.decode(encoded)!;

      expect(decoded.room, equals('room-abc'));
      expect(decoded.bytes, equals([1, 2, 3, 4, 5]));
    });

    test('round-trips an empty payload', () {
      final frame = Frame('r', const []);
      final decoded = FrameCodec.decode(FrameCodec.encode(frame))!;
      expect(decoded.room, equals('r'));
      expect(decoded.bytes, isEmpty);
    });

    test('round-trips a unicode room tag', () {
      final frame = Frame('café-room-✓', [9]);
      final decoded = FrameCodec.decode(FrameCodec.encode(frame))!;
      expect(decoded.room, equals('café-room-✓'));
      expect(decoded.bytes, equals([9]));
    });

    test('returns null for a truncated buffer', () {
      expect(FrameCodec.decode([0]), isNull);
      // Declares a 5-byte room but provides none.
      expect(FrameCodec.decode([0, 5]), isNull);
    });
  });
}
