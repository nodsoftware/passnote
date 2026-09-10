import 'dart:io';

import 'package:conclave/conclave.dart';
import 'package:conclave/engine.dart' show SqliteCrdtTable;
import 'package:conclave_crypto/conclave_crypto.dart';
import 'package:conclave_lan/conclave_lan.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'keychain_key_store.dart';

/// Returns a [ConclaveBuilder] with the production adapters installed as its
/// defaults:
///
/// - keys: [KeychainKeyStore] backed by the OS keychain
/// - transport: [LanTransport] (mDNS discovery + WebSocket frames)
/// - crypto: XChaCha20-Poly1305 cipher with Argon2id / BIP39 key derivation
///
/// Override any of them with the builder's methods, then `await`
/// [ConclaveBuilder.open].
///
/// ```dart
/// final conclave = await conclaveBuilder(
///   appId: 'shopping',
///   salt: 'shopping:v1',
/// ).open();
/// ```
///
/// This is [Conclave.builder] with [ConclaveDefaults] pre-installed. Calling it
/// more than once is harmless; the defaults install exactly once.
ConclaveBuilder conclaveBuilder({required String appId, required String salt}) {
  _ensureDefaults();
  return Conclave.builder(appId: appId, salt: salt);
}

var _defaultsInstalled = false;

void _ensureDefaults() {
  if (_defaultsInstalled) return;
  _defaultsInstalled = true;
  ConclaveBuilder.installDefaults(
    ConclaveDefaults(
      engine: (databaseId, collection, key) async {
        final base = await getApplicationSupportDirectory();
        final dir = Directory(p.join(base.path, 'conclave', databaseId));
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
    ),
  );
}
