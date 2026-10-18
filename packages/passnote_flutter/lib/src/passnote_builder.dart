import 'dart:io';

import 'package:passnote/passnote.dart';
import 'package:passnote/engine.dart' show SqliteCrdtTable;
import 'package:passnote_crypto/passnote_crypto.dart';
import 'package:passnote_lan/discovery.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'keychain_key_store.dart';

/// Returns a [PassnoteBuilder] with the production adapters installed as its
/// defaults:
///
/// - keys: [KeychainKeyStore] backed by the OS keychain
/// - transport: [LanTransport] (mDNS discovery + WebSocket frames)
/// - crypto: XChaCha20-Poly1305 cipher with Argon2id / BIP39 key derivation
///
/// Override any of them with the builder's methods, then `await`
/// [PassnoteBuilder.open].
///
/// ```dart
/// final passnote = await passnoteBuilder(
///   appId: 'shopping',
///   salt: 'shopping:v1',
/// ).open();
/// ```
///
/// This is [Passnote.builder] with [PassnoteDefaults] pre-installed. Calling it
/// more than once is harmless; the defaults install exactly once.
PassnoteBuilder passnoteBuilder({required String appId, required String salt}) {
  _ensureDefaults();
  return Passnote.builder(appId: appId, salt: salt);
}

var _defaultsInstalled = false;

void _ensureDefaults() {
  if (_defaultsInstalled) return;
  _defaultsInstalled = true;
  PassnoteBuilder.installDefaults(
    PassnoteDefaults(
      engine: (databaseId, collection, key) async {
        final base = await getApplicationSupportDirectory();
        final dir = Directory(p.join(base.path, 'passnote', databaseId));
        await dir.create(recursive: true);
        return SqliteCrdtTable(
          p.join(dir.path, '$collection.sqlite'),
          encryptionKey: key,
        );
      },
      keyStore: (appId) => KeychainKeyStore(namespace: appId),
      transport: LanTransport.new,
      cipher: XChaChaPoly1305Cipher.new,
      deriveKey: deriveKey,
      roomTag: roomTag,
      mnemonicGenerator: (words) => generateMnemonic(words: words),
      validateMnemonic: isValidMnemonic,
      identity: (keyStore) => DeviceIdentity.load(keyStore: keyStore),
      pake: Spake2Pake.new,
      recoveryIdentity: (phrase, salt) =>
          DeviceIdentity.fromRecoveryPhrase(phrase, salt: salt),
    ),
  );
}
