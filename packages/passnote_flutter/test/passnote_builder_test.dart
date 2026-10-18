import 'package:passnote_flutter/passnote_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('passnote_flutter', () {
    test('re-exports the engine, crypto, lan and flutter surfaces', () {
      // Engine
      expect(const PassnoteConfig(appId: 'a', salt: 's').appId, equals('a'));
      expect(const PassphrasePolicy().words, equals(24));
      expect(Frame('room', const [1]).room, equals('room'));
      // Crypto
      expect(generateMnemonic(words: 12).length, equals(12));
      expect(isValidMnemonic(generateMnemonic().join(' ')), isTrue);
      // Flutter
      expect(KeychainKeyStore(namespace: 'demo'), isA<KeyStore>());
      // LAN
      expect(LanTransport(), isA<Transport>());
    });

    test('passnoteBuilder returns a builder with defaults installed', () {
      final builder = passnoteBuilder(appId: 'demo', salt: 'demo:v1');
      expect(builder, isA<PassnoteBuilder>());
    });
  });
}
