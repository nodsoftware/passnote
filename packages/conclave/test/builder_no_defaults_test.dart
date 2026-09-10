import 'package:conclave/conclave.dart';
import 'package:test/test.dart';

// Runs in its own isolate, so ConclaveBuilder has no defaults installed here.
void main() {
  test('open() without installed defaults throws StateError', () {
    expect(
      Conclave.builder(appId: 'a', salt: 'a:v1').open,
      throwsStateError,
    );
  });
}
