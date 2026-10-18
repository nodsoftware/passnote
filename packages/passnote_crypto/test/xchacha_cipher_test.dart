import 'package:passnote/passnote.dart';
import 'package:passnote_crypto/passnote_crypto.dart';
import 'package:test/test.dart';

void main() {
  final key = List<int>.filled(32, 7);

  group('XChaChaPoly1305Cipher', () {
    test('round-trips plaintext', () async {
      final cipher = XChaChaPoly1305Cipher(key);
      final message = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
      final sealed = await cipher.encrypt(message);
      expect(await cipher.decrypt(sealed), message);
    });

    test('frame is nonce(24) + ciphertext(n) + tag(16)', () async {
      final cipher = XChaChaPoly1305Cipher(key);
      final sealed = await cipher.encrypt([9, 9, 9, 9, 9]);
      expect(sealed.length, 24 + 5 + 16);
    });

    test('uses a fresh nonce per encryption', () async {
      final cipher = XChaChaPoly1305Cipher(key);
      final a = await cipher.encrypt([0]);
      final b = await cipher.encrypt([0]);
      expect(a.sublist(0, 24), isNot(b.sublist(0, 24)));
    });

    test('wrong key fails closed with CipherAuthError', () async {
      final sealed = await XChaChaPoly1305Cipher(key).encrypt([1, 2, 3]);
      final wrong = XChaChaPoly1305Cipher(List<int>.filled(32, 8));
      await expectLater(
        wrong.decrypt(sealed),
        throwsA(isA<CipherAuthError>()),
      );
    });

    test('tampered ciphertext throws CipherAuthError', () async {
      final cipher = XChaChaPoly1305Cipher(key);
      final sealed = List<int>.of(await cipher.encrypt([1, 2, 3, 4]));
      sealed[sealed.length - 1] ^= 0xff;
      await expectLater(
          cipher.decrypt(sealed), throwsA(isA<CipherAuthError>()));
    });

    test('truncated frame throws CipherAuthError', () async {
      final cipher = XChaChaPoly1305Cipher(key);
      await expectLater(
        cipher.decrypt([1, 2, 3]),
        throwsA(isA<CipherAuthError>()),
      );
    });

    test('rejects keys that are not 32 bytes', () {
      expect(
        () => XChaChaPoly1305Cipher([1, 2, 3]),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
