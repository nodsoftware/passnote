import 'package:passnote/passnote.dart';
import 'package:passnote/engine.dart';
import 'package:test/test.dart';

// Runs in its own isolate, so PassnoteBuilder has no defaults installed here.
void main() {
  test('open() without installed defaults throws StateError', () {
    expect(
      Passnote.builder(appId: 'a', salt: 'a:v1').open,
      throwsStateError,
    );
  });
}
