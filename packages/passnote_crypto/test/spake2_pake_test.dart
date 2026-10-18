import 'dart:convert';

import 'package:passnote/passnote.dart';
import 'package:passnote_crypto/passnote_crypto.dart';
import 'package:test/test.dart';

/// [Spake2Pake] behind the `passnote` [Pake] port: the same run the pairing
/// state machine drives. The wire-level RFC 9382 vectors are in `spake2_test`.
void main() {
  final pake = const Spake2Pake();

  bool eq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  test('matching secrets agree and confirmations cross-check', () {
    final code = utf8.encode('471 902 336');
    final initiator = pake.start(initiator: true, secret: code);
    final responder = pake.start(initiator: false, secret: code);

    final ri = initiator.finish(responder.message);
    final rr = responder.finish(initiator.message);

    expect(ri.sharedSecret, rr.sharedSecret);
    expect(eq(ri.localConfirmation, rr.expectedPeerConfirmation), isTrue);
    expect(eq(rr.localConfirmation, ri.expectedPeerConfirmation), isTrue);
  });

  test('a wrong code yields a different secret and failing confirmations', () {
    final initiator = pake.start(initiator: true, secret: utf8.encode('111'));
    final responder = pake.start(initiator: false, secret: utf8.encode('222'));

    final ri = initiator.finish(responder.message);
    final rr = responder.finish(initiator.message);

    expect(ri.sharedSecret, isNot(rr.sharedSecret));
    expect(eq(ri.localConfirmation, rr.expectedPeerConfirmation), isFalse);
    expect(eq(rr.localConfirmation, ri.expectedPeerConfirmation), isFalse);
  });

  test('a malformed peer message is rejected', () {
    final session = pake.start(initiator: true, secret: utf8.encode('x'));
    expect(() => session.finish(const [1, 2, 3]), throwsA(anything));
  });
}
