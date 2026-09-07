/// Convenience umbrella package for Conclave.
///
/// Re-exports the public surface of every Conclave package and provides
/// [conclaveBuilder] for batteries-included setup: a SQLite storage engine in
/// the app support directory, OS-keychain key storage, LAN (mDNS + WebSocket)
/// transport, and AES-GCM encryption.
library conclave;

export 'package:conclave_core/conclave_core.dart';
export 'package:conclave_crypto/conclave_crypto.dart';
export 'package:conclave_flutter/conclave_flutter.dart';
export 'package:conclave_lan/conclave_lan.dart';

import 'dart:io';

import 'package:conclave_core/conclave_core.dart';
import 'package:conclave_core/engine.dart' show SqliteCrdtTable;
import 'package:conclave_crypto/conclave_crypto.dart';
import 'package:conclave_flutter/conclave_flutter.dart';
import 'package:conclave_lan/conclave_lan.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Returns a [ConclaveBuilder] with the production adapters installed as its
/// defaults:
///
/// - keys: [KeychainKeyStore] backed by the OS keychain
/// - transport: [LanTransport] (mDNS discovery + WebSocket frames)
/// - crypto: AES-256-GCM cipher with PBKDF2 / BIP39 key derivation
///
/// Override any of them with the builder's methods, then `await` [ConclaveBuilder.open].
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
      cipher: AesGcmCipher.new,
      deriveKey: deriveKey,
      roomTag: roomTag,
      mnemonicGenerator: (words) => generateMnemonic(words: words),
      validateMnemonic: isValidMnemonic,
      identity: (keyStore) => DeviceIdentity.load(keyStore: keyStore),
      pake: Spake2Pake.new,
    ),
  );
}
