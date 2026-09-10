import 'dart:convert';

import 'package:conclave/src/protocol/messages.dart';
import 'package:test/test.dart';

void main() {
  group('decodeMessage', () {
    List<int> enc(Object json) => utf8.encode(jsonEncode(json));

    test('returns null for non-JSON bytes', () {
      expect(decodeMessage([0xff, 0x00, 0x01]), isNull);
    });

    test('returns null for an unknown type', () {
      expect(decodeMessage(enc({'type': 'mystery'})), isNull);
    });

    test('does not throw on a wrong-typed state.cols', () {
      // Was a crash before the fix: cols is a String, not a Map.
      expect(
          decodeMessage(enc({'type': 'state', 'cols': 'not-a-map'})), isNull);
    });

    test('does not throw on wrong-typed delta records', () {
      expect(
        decodeMessage(enc({'type': 'delta', 'col': 'c', 'records': 'nope'})),
        isNull,
      );
      expect(
        decodeMessage(enc({
          'type': 'delta',
          'col': 'c',
          'records': [1, 2, 3]
        })),
        isNull,
      );
    });

    test('still decodes well-formed messages', () {
      expect(decodeMessage(enc({'type': 'hello', 'node': 'n1'})),
          isA<HelloMessage>());
      expect(
        decodeMessage(enc({
          'type': 'state',
          'cols': {'items': 'hlc'}
        })),
        isA<StateMessage>(),
      );
    });

    test('round-trips a ratchet-hello with its nonce', () {
      final decoded = decodeMessage(encodeMessage(
        RatchetHelloMessage(
            node: 'n1', nonce: List<int>.generate(16, (i) => i)),
      ));
      expect(decoded, isA<RatchetHelloMessage>());
      expect((decoded as RatchetHelloMessage).node, 'n1');
      expect(decoded.nonce, List<int>.generate(16, (i) => i));
    });
  });
}
