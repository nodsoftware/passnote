import 'package:conclave/conclave.dart';
import 'package:test/test.dart';

void main() {
  group('newId', () {
    test('returns distinct values across rapid successive calls', () {
      final ids = {for (var i = 0; i < 10000; i++) newId()};
      expect(ids.length, 10000);
    });

    test('never contains the NUL character', () {
      for (var i = 0; i < 1000; i++) {
        expect(newId().contains('\x00'), isFalse);
      }
    });

    test('is non-empty and contains a hyphen separator', () {
      final id = newId();
      expect(id, isNotEmpty);
      expect(id.contains('-'), isTrue);
    });
  });
}
