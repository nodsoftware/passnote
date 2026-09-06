/// Convenience umbrella package for Conclave.
///
/// Re-exports the public surface of every Conclave package and provides
/// [openDefault] for batteries-included setup: Sembast storage, OS-keychain
/// key storage, LAN (mDNS + WebSocket) transport, and AES-GCM encryption.
library conclave;

export 'package:conclave_core/conclave_core.dart';
export 'package:conclave_crypto/conclave_crypto.dart';
export 'package:conclave_flutter/conclave_flutter.dart';
export 'package:conclave_lan/conclave_lan.dart';
export 'package:conclave_sembast/conclave_sembast.dart';

import 'package:conclave_core/conclave_core.dart';
import 'package:conclave_crypto/conclave_crypto.dart';
import 'package:conclave_flutter/conclave_flutter.dart';
import 'package:conclave_lan/conclave_lan.dart';
import 'package:conclave_sembast/conclave_sembast.dart';

/// Opens a fully-wired [Conclave] using the default production adapters:
///
/// - storage: [SembastStore], namespaced `'<appId>/<databaseId>'`
/// - keys: [KeychainKeyStore] backed by the OS keychain
/// - transport: [LanTransport] (mDNS discovery + WebSocket frames)
/// - crypto: AES-GCM cipher with PBKDF2/BIP39 key derivation
///
/// ```dart
/// final conclave = await openDefault(appId: 'shopping', salt: 'shopping:v1');
/// final list = await conclave.openDatabase('home', passphrase: words);
/// ```
Future<Conclave> openDefault({
  required String appId,
  required String salt,
  PassphrasePolicy passphrasePolicy = const PassphrasePolicy(),
}) {
  return Conclave.open(
    config: ConclaveConfig(
        appId: appId, salt: salt, passphrasePolicy: passphrasePolicy),
    store: (databaseId) => SembastStore(namespace: '$appId/$databaseId'),
    keyStore: KeychainKeyStore(namespace: appId),
    transport: LanTransport(),
    deriveKey: deriveKey,
    roomTag: roomTag,
    cipher: AesGcmCipher.new,
    mnemonicGenerator: (words) => generateMnemonic(words: words),
    idMaskerFactory: createIdMasker,
    validateMnemonic: isValidMnemonic,
  );
}
