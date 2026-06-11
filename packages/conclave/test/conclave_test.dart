import 'package:conclave/conclave.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('conclave umbrella', () {
    test('re-exports the core, crypto, sembast, lan and flutter surfaces', () {
      // Core
      expect(const ConclaveConfig(appId: 'a', salt: 's').appId, equals('a'));
      expect(const PassphrasePolicy().words, equals(24));
      expect(Frame('room', const [1]).room, equals('room'));
      // Crypto
      expect(generateMnemonic(words: 12).length, equals(12));
      expect(validateMnemonic(generateMnemonic().join(' ')), isTrue);
      // Sembast
      expect(SembastStore(namespace: 'demo'), isA<BlobStore>());
      // Flutter
      expect(KeychainKeyStore(namespace: 'demo'), isA<KeyStore>());
      // LAN
      expect(LanTransport(), isA<Transport>());
    });

    test('openDefault is available as a top-level function', () {
      expect(openDefault, isA<Function>());
    });
  });
}
