import 'dart:convert';
import 'dart:typed_data';

import 'package:conclave_crypto/conclave_crypto.dart';
import 'package:test/test.dart';

/// RFC 9382 Appendix B, first vector: `A='server'`, `B='client'`,
/// `P256-SHA256-HKDF-HMAC`.
const _rfc = (
  w: '2ee57912099d31560b3a44b1184b9b4866e904c49d12ac5042c97dca461b1a5f',
  x: '43dd0fd7215bdcb482879fca3220c6a968e66d70b1356cac18bb26c84a78d729',
  y: 'dcb60106f276b02606d8ef0a328c02e4b629f84f89786af5befb0bc75b6e66be',
  pA: '04a56fa807caaa53a4d28dbb9853b9815c61a411118a6fe516a8798434751470f'
      '9010153ac33d0d5f2047ffdb1a3e42c9b4e6be662766e1eeb4116988ede5f912c',
  pB: '0406557e482bd03097ad0cbaa5df82115460d951e3451962f1eaf4367a420676d'
      '09857ccbc522686c83d1852abfa8ed6e4a1155cf8f1543ceca528afb591a1e0b7',
  k: '0412af7e89717850671913e6b469ace67bd90a4df8ce45c2af19010175e37eed6'
      '9f75897996d539356e2fa6a406d528501f907e04d97515fbe83db277b715d3325',
  tt: '06000000000000007365727665720600000000000000636c69656e7441000000'
      '0000000004a56fa807caaa53a4d28dbb9853b9815c61a411118a6fe516a87984'
      '34751470f9010153ac33d0d5f2047ffdb1a3e42c9b4e6be662766e1eeb411698'
      '8ede5f912c41000000000000000406557e482bd03097ad0cbaa5df82115460d9'
      '51e3451962f1eaf4367a420676d09857ccbc522686c83d1852abfa8ed6e4a115'
      '5cf8f1543ceca528afb591a1e0b741000000000000000412af7e897178506719'
      '13e6b469ace67bd90a4df8ce45c2af19010175e37eed69f75897996d539356e2'
      'fa6a406d528501f907e04d97515fbe83db277b715d332520000000000000002e'
      'e57912099d31560b3a44b1184b9b4866e904c49d12ac5042c97dca461b1a5f',
  ke: '0e0672dc86f8e45565d338b0540abe69',
  kcA: '00c12546835755c86d8c0db7851ae86f',
  kcB: 'a9fa3406c3b781b93d804485430ca27a',
  cA: '58ad4aa88e0b60d5061eb6b5dd93e80d9c4f00d127c65b3b35b1b5281fee38f0',
  cB: 'd3e2e547f1ae04f2dbdbf0fc4b79f8ecff2dff314b5d32fe9fcef2fb26dc459b',
);

Uint8List _hex(String s) {
  final padded = s.length.isOdd ? '0$s' : s;
  final out = Uint8List(padded.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(padded.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _hexOf(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

BigInt _bigInt(String hex) => BigInt.parse(hex, radix: 16);

void main() {
  final serverId = utf8.encode('server');
  final clientId = utf8.encode('client');

  group('RFC 9382 Appendix B vector (P256-SHA256-HKDF-HMAC)', () {
    late Spake2Result prover;
    late Spake2Result verifier;
    late Spake2 a;
    late Spake2 b;

    setUp(() {
      a = Spake2.start(
        role: Spake2Role.prover,
        w: _hex(_rfc.w),
        proverId: serverId,
        verifierId: clientId,
        scalarOverride: _bigInt(_rfc.x),
      );
      b = Spake2.start(
        role: Spake2Role.verifier,
        w: _hex(_rfc.w),
        proverId: serverId,
        verifierId: clientId,
        scalarOverride: _bigInt(_rfc.y),
      );
      prover = a.finish(b.outboundMessage);
      verifier = b.finish(a.outboundMessage);
    });

    test('pA and pB match the vector', () {
      expect(_hexOf(a.outboundMessage), _rfc.pA);
      expect(_hexOf(b.outboundMessage), _rfc.pB);
    });

    test('transcript TT matches the vector', () {
      expect(_hexOf(prover.transcript), _rfc.tt);
      expect(_hexOf(verifier.transcript), _rfc.tt);
    });

    test('shared secret Ke matches the vector on both sides', () {
      expect(_hexOf(prover.sharedSecret), _rfc.ke);
      expect(_hexOf(verifier.sharedSecret), _rfc.ke);
    });

    test('confirmation MACs match the vector', () {
      expect(_hexOf(prover.localConfirmation), _rfc.cA);
      expect(_hexOf(verifier.localConfirmation), _rfc.cB);
      expect(_hexOf(prover.expectedPeerConfirmation), _rfc.cB);
      expect(_hexOf(verifier.expectedPeerConfirmation), _rfc.cA);
    });

    test('each side accepts the other confirmation', () {
      expect(
        spake2ConstantTimeEquals(
          prover.expectedPeerConfirmation,
          verifier.localConfirmation,
        ),
        isTrue,
      );
      expect(
        spake2ConstantTimeEquals(
          verifier.expectedPeerConfirmation,
          prover.localConfirmation,
        ),
        isTrue,
      );
    });
  });

  test('a fresh run with random scalars still agrees', () {
    final w = utf8.encode('correct horse battery staple');
    final a = Spake2.start(role: Spake2Role.prover, w: w);
    final b = Spake2.start(role: Spake2Role.verifier, w: w);
    final ra = a.finish(b.outboundMessage);
    final rb = b.finish(a.outboundMessage);

    expect(ra.sharedSecret, rb.sharedSecret);
    expect(
      spake2ConstantTimeEquals(
          ra.localConfirmation, rb.expectedPeerConfirmation),
      isTrue,
    );
    expect(
      spake2ConstantTimeEquals(
          rb.localConfirmation, ra.expectedPeerConfirmation),
      isTrue,
    );
  });

  test('mismatched passwords produce non-matching confirmations', () {
    final a = Spake2.start(role: Spake2Role.prover, w: utf8.encode('one'));
    final b = Spake2.start(role: Spake2Role.verifier, w: utf8.encode('two'));
    final ra = a.finish(b.outboundMessage);
    final rb = b.finish(a.outboundMessage);

    expect(ra.sharedSecret, isNot(rb.sharedSecret));
    expect(
      spake2ConstantTimeEquals(
          ra.localConfirmation, rb.expectedPeerConfirmation),
      isFalse,
    );
  });

  test('a garbage peer message is rejected', () {
    final a = Spake2.start(role: Spake2Role.prover, w: utf8.encode('pw'));
    expect(
      () => a.finish(Uint8List(65)),
      throwsA(isA<Spake2ProtocolError>()),
    );
    expect(
      () => a.finish(utf8.encode('not a point')),
      throwsA(isA<Spake2ProtocolError>()),
    );
  });
}
