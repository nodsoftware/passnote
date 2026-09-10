import 'package:conclave/conclave.dart';
import 'package:conclave_crypto/conclave_crypto.dart';
import 'package:test/test.dart';

void main() {
  group('AesGcmCipher', () {
    final key = List<int>.generate(32, (i) => i);

    test('round-trips plaintext', () async {
      final cipher = AesGcmCipher(key);
      final plaintext = [for (var i = 0; i < 100; i++) i % 256];

      final ciphertext = await cipher.encrypt(plaintext);
      final decrypted = await cipher.decrypt(ciphertext);

      expect(decrypted, equals(plaintext));
    });

    test('ciphertext differs from plaintext', () async {
      final cipher = AesGcmCipher(key);
      final plaintext = [1, 2, 3, 4, 5];

      final ciphertext = await cipher.encrypt(plaintext);

      expect(ciphertext, isNot(equals(plaintext)));
      // nonce(12) + ciphertext(5) + tag(16) = 33
      expect(ciphertext.length, equals(33));
    });

    test('uses a fresh nonce per encryption', () async {
      final cipher = AesGcmCipher(key);
      final plaintext = [9, 9, 9];

      final a = await cipher.encrypt(plaintext);
      final b = await cipher.encrypt(plaintext);

      expect(a, isNot(equals(b)));
      // First 12 bytes are the nonce — they must differ.
      expect(a.sublist(0, 12), isNot(equals(b.sublist(0, 12))));
    });

    test('wrong key throws CipherAuthError', () async {
      final cipher = AesGcmCipher(key);
      final wrongKey = List<int>.generate(32, (i) => i + 1);
      final wrongCipher = AesGcmCipher(wrongKey);

      final ciphertext = await cipher.encrypt([1, 2, 3]);

      expect(
        () => wrongCipher.decrypt(ciphertext),
        throwsA(isA<CipherAuthError>()),
      );
    });

    test('tampered ciphertext throws CipherAuthError', () async {
      final cipher = AesGcmCipher(key);
      final ciphertext = await cipher.encrypt([1, 2, 3, 4]);

      // Flip a bit in the ciphertext body.
      ciphertext[15] ^= 0x01;

      expect(
        () => cipher.decrypt(ciphertext),
        throwsA(isA<CipherAuthError>()),
      );
    });

    test('truncated frame throws CipherAuthError', () async {
      final cipher = AesGcmCipher(key);
      expect(
        () => cipher.decrypt([1, 2, 3]),
        throwsA(isA<CipherAuthError>()),
      );
    });

    test('rejects keys that are not 32 bytes', () {
      expect(() => AesGcmCipher([1, 2, 3]), throwsA(isA<AssertionError>()));
    });
  });

  group('generateMnemonic', () {
    test('produces the requested word count', () {
      for (final words in [12, 15, 18, 21, 24]) {
        final mnemonic = generateMnemonic(words: words);
        expect(mnemonic, hasLength(words));
        expect(validateMnemonic(mnemonic.join(' ')), isTrue);
      }
    });

    test('defaults to 24 words', () {
      expect(generateMnemonic(), hasLength(24));
    });

    test('rejects invalid word counts', () {
      expect(() => generateMnemonic(words: 13), throwsArgumentError);
    });

    test('produces distinct mnemonics', () {
      final a = generateMnemonic();
      final b = generateMnemonic();
      expect(a, isNot(equals(b)));
    });
  });

  group('isValidMnemonic', () {
    test('accepts a generated mnemonic', () {
      final mnemonic = generateMnemonic().join(' ');
      expect(isValidMnemonic(mnemonic), isTrue);
    });

    test('rejects a plain word', () {
      expect(isValidMnemonic('password'), isFalse);
    });

    test('rejects empty string', () {
      expect(isValidMnemonic(''), isFalse);
    });
  });

  group('estimatePassphraseBits', () {
    test('returns 0 for empty string', () {
      expect(estimatePassphraseBits(''), equals(0.0));
    });

    test('estimates bits for a lowercase phrase', () {
      // 8 lowercase chars: 8 * log2(26) ≈ 8 * 4.7 = 37.6
      final bits = estimatePassphraseBits('password');
      expect(bits, greaterThan(30));
      expect(bits, lessThan(45));
    });

    test('estimates higher bits for mixed-case with digits', () {
      final lower = estimatePassphraseBits('password');
      final mixed = estimatePassphraseBits('Password1');
      expect(mixed, greaterThan(lower));
    });
  });

  group('deriveKey', () {
    const phrase =
        'abandon abandon abandon abandon abandon abandon abandon abandon '
        'abandon abandon abandon about';

    test('returns a 32-byte key', () async {
      final key = await deriveKey(phrase, 'app:v1');
      expect(key, hasLength(32));
    });

    test('is deterministic for the same passphrase and salt', () async {
      final a = await deriveKey(phrase, 'app:v1');
      final b = await deriveKey(phrase, 'app:v1');
      expect(a, equals(b));
    });

    test('depends on the salt', () async {
      final a = await deriveKey(phrase, 'app:v1');
      final b = await deriveKey(phrase, 'app:v2');
      expect(a, isNot(equals(b)));
    });

    test('depends on the passphrase', () async {
      final a = await deriveKey(phrase, 'app:v1');
      final b = await deriveKey(
        'legal winner thank year wave sausage worth useful legal '
            'winner thank yellow',
        'app:v1',
      );
      expect(a, isNot(equals(b)));
    });
  });

  group('deriveKeyPbkdf2 (FIPS fallback)', () {
    const phrase =
        'abandon abandon abandon abandon abandon abandon abandon abandon '
        'abandon abandon abandon about';

    test('returns a 32-byte key, deterministic and salt-dependent', () async {
      final a = await deriveKeyPbkdf2(phrase, 'app:v1');
      final b = await deriveKeyPbkdf2(phrase, 'app:v1');
      final c = await deriveKeyPbkdf2(phrase, 'app:v2');
      expect(a, hasLength(32));
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });

    test('is a different pipeline from the Argon2id default', () async {
      final argon = await deriveKey(phrase, 'app:v1');
      final pbkdf2 = await deriveKeyPbkdf2(phrase, 'app:v1');
      expect(argon, isNot(equals(pbkdf2)));
    });
  });

  group('roomTag', () {
    test('is 16 base32 characters', () async {
      final key = await deriveKey(
        'abandon abandon abandon abandon abandon abandon abandon abandon '
            'abandon abandon abandon about',
        'app:v1',
      );
      final tag = roomTag(key);
      expect(tag, hasLength(16));
      expect(tag, matches(RegExp(r'^[A-Z2-7]+$')));
    });

    test('is deterministic for the same key', () {
      final key = List<int>.generate(32, (i) => i);
      expect(roomTag(key), equals(roomTag(key)));
    });

    test('differs for different keys', () {
      final a = roomTag(List<int>.generate(32, (i) => i));
      final b = roomTag(List<int>.generate(32, (i) => i + 1));
      expect(a, isNot(equals(b)));
    });
  });
}
