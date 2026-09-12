// The shared pieces of the pure-Dart logbook: the document model, a
// file-backed KeyStore, and the production adapter wiring that
// `conclave_flutter`'s `conclaveBuilder` performs for Flutter apps.
import 'dart:convert';
import 'dart:io';

import 'package:conclave/conclave.dart';
import 'package:conclave/engine.dart' show SqliteCrdtTable;
import 'package:conclave_crypto/conclave_crypto.dart';
import 'package:conclave_lan/discovery.dart';

part 'logbook.g.dart';

// --- Model -------------------------------------------------------------

@Document()
class Entry {
  const Entry({required this.id, required this.text, this.stars = 0});

  @DocumentId()
  final String id;

  final String text;

  /// Stars from different devices all count: the field merges as a counter,
  /// changed only through `Collection.increment`.
  @Crdt(PnCounter())
  final num stars;
}

/// The generated codec and per-field merge strategy. Pass BOTH when creating
/// the collection — the codec maps the type; the merge strategy is what gives
/// `stars` its counter semantics, and it is not wired automatically:
///
/// ```dart
/// db.collection<Entry>('entries', entryCodec, merge: entryMerge);
/// ```
final Codec<Entry> entryCodec = _$EntryCodec;

/// See [entryCodec].
const MergeStrategy entryMerge = _$EntryMergeStrategy;

// --- Pure-Dart defaults --------------------------------------------------

/// Installs production adapters for a plain Dart process, mirroring what
/// `conclave_flutter` installs for Flutter apps: the SQLCipher-backed SQLite
/// engine, the mDNS LAN transport, XChaCha20-Poly1305, Argon2id key
/// derivation from a BIP39 passphrase, the X25519/Ed25519 device identity,
/// SPAKE2 pairing, and the recovery-phrase derivation. Local state (database
/// files and the key file) lives under [dataDir].
void installLogbookDefaults(Directory dataDir) {
  ConclaveBuilder.installDefaults(
    ConclaveDefaults(
      engine: (databaseId, collection, key) {
        final dir = Directory('${dataDir.path}/$databaseId')
          ..createSync(recursive: true);
        return SqliteCrdtTable(
          '${dir.path}/$collection.sqlite',
          encryptionKey: key,
        );
      },
      keyStore: (appId) =>
          FileKeyStore(File('${dataDir.path}/$appId.keys.json')),
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

// --- Key store -----------------------------------------------------------

/// A `KeyStore` backed by one JSON file, for environments without an OS
/// keychain.
///
/// Example-grade: the file is made owner-only (mode 600) on POSIX systems,
/// but anyone who can read it holds the keys. A production app uses the
/// platform's secret storage instead — `KeychainKeyStore` from
/// `conclave_flutter`, or an adapter over the OS secret service.
class FileKeyStore implements KeyStore {
  FileKeyStore(this._file);

  final File _file;

  Map<String, String> _read() {
    if (!_file.existsSync()) return {};
    try {
      return (jsonDecode(_file.readAsStringSync()) as Map)
          .cast<String, String>();
    } catch (_) {
      return {};
    }
  }

  void _write(Map<String, String> entries) {
    _file.parent.createSync(recursive: true);
    _file.writeAsStringSync(jsonEncode(entries));
    if (!Platform.isWindows) {
      Process.runSync('chmod', ['600', _file.path]);
    }
  }

  @override
  Future<List<int>?> getKey(String id) async {
    final stored = _read()[id];
    return stored == null ? null : base64.decode(stored);
  }

  @override
  Future<void> setKey(String id, List<int> key) async =>
      _write(_read()..[id] = base64.encode(key));

  @override
  Future<void> clear(String id) async => _write(_read()..remove(id));
}
