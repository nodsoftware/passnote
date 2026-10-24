part of 'passnote.dart';

/// The platform factories [PassnoteBuilder] fills in for any slot the caller
/// does not override.
///
/// `passnoteBuilder` from `package:passnote_flutter` installs a production
/// bundle (SQLite storage, OS keychain, LAN transport, XChaCha20-Poly1305)
/// on its first call. A pure-Dart app that depends on `package:passnote`
/// directly installs its own with [PassnoteBuilder.installDefaults].
final class PassnoteDefaults {
  /// Creates a default bundle. Every factory is required except [identity],
  /// which only the device-pairing paths need.
  const PassnoteDefaults({
    required this.engine,
    required this.keyStore,
    required this.transport,
    required this.cipher,
    required this.deriveKey,
    this.legacyDeriveKey,
    required this.roomTag,
    required this.mnemonicGenerator,
    required this.validateMnemonic,
    this.identity,
    this.pake,
    this.recoveryIdentity,
  });

  /// Builds the backing [CrdtTable] for a collection in a database.
  final FutureOr<CrdtTable> Function(
      String databaseId, String collection, List<int> key) engine;

  /// Builds the key store for an app, given the app id.
  final KeyStore Function(String appId) keyStore;

  /// Builds a fresh transport.
  final Transport Function() transport;

  /// Builds a cipher bound to a derived key.
  final Cipher Function(List<int> key) cipher;

  /// Derives a symmetric key from a passphrase and an app salt.
  final Future<List<int>> Function(String passphrase, String salt) deriveKey;

  /// Derives the key Passnote 1.0 and 1.1 derived from a passphrase with
  /// characters outside ASCII, so data and groups made then still open.
  /// `null` when the host has no such earlier derivation.
  final Future<List<int>> Function(String passphrase, String salt)?
      legacyDeriveKey;

  /// Derives the public discovery room tag from a key.
  final String Function(List<int> key) roomTag;

  /// Generates a mnemonic passphrase of the given word count.
  final List<String> Function(int words) mnemonicGenerator;

  /// Returns whether a passphrase is a recognised mnemonic.
  final bool Function(String phrase) validateMnemonic;

  /// Loads (generating on first use) this device's [Identity], given the app's
  /// key store. `null` when the host does not provide one; [Passnote.identity]
  /// then throws until an identity is configured.
  final Future<Identity> Function(KeyStore keyStore)? identity;

  /// Derives the deterministic keypair behind a recovery phrase, for
  /// [Passnote.enableRecovery] / [Passnote.recoverFrom]. `null` when the host
  /// does not provide one; the recovery APIs then throw even when the app
  /// opted in with [PassnoteBuilder.recovery].
  final Future<Identity> Function(String phrase, String salt)? recoveryIdentity;

  /// Builds the PAKE used to authenticate device pairing. `null` when the host
  /// does not provide one; [Passnote.startPairing] / [Passnote.pairWith] then
  /// throw. Default (umbrella): SPAKE2.
  final Pake Function()? pake;
}

/// Staged configuration for a [Passnote] instance.
///
/// Obtain one from [Passnote.builder], set any overrides (each at most once, in
/// any order), then `await` [open]. Any slot left unset is filled from the
/// installed [PassnoteDefaults].
///
/// ```dart
/// // Minimal: every default from the umbrella.
/// final passnote = await Passnote.builder(
///   appId: 'shopping',
///   salt: 'shopping:v1',
/// ).open();
///
/// // Customised: override only what you need, in any order.
/// final passnote = await Passnote.builder(appId: 'shopping', salt: 'shopping:v1')
///     .transport(LanTransport.new)
///     .passphrase(words: 12)
///     .compactionHorizon(const Duration(days: 60))
///     .open();
/// ```
final class PassnoteBuilder {
  PassnoteBuilder._(this._appId, this._salt);

  final String _appId;
  final String _salt;

  FutureOr<CrdtTable> Function(String collection)? _engineOverride;
  FutureOr<CrdtTable> Function(
      String databaseId, String collection, List<int> key)? _storage;
  Duration? _antiEntropyInterval;
  KeyStore? _keyStore;
  Transport? _transport;
  Cipher Function(List<int> key)? _cipher;
  Future<Identity> Function(KeyStore keyStore)? _identity;
  Pake Function()? _pake;
  bool _recoveryEnabled = false;
  bool _recoverySet = false;
  int _words = 24;
  PassphraseStrictness _strictness = PassphraseStrictness.warn;
  bool _passphraseSet = false;
  Duration? _compactionHorizon;
  int? _maxInboundFramesPerSecond;

  static PassnoteDefaults? _defaults;

  /// Installs the [PassnoteDefaults] every builder falls back to.
  /// `passnoteBuilder` from `package:passnote_flutter` calls this for a Flutter
  /// app; call it directly in a pure-Dart app. The last call wins.
  static void installDefaults(PassnoteDefaults defaults) =>
      _defaults = defaults;

  /// Overrides the storage engine with one built per collection from the
  /// collection name alone. Default: a SQLite-backed disk engine.
  ///
  /// The factory is not told which database the collection belongs to, so two
  /// databases with a collection of the same name share whatever it returns,
  /// nor the key to encrypt it with. Use [storage], which is.
  @Deprecated('Use storage(), which also passes the database id and the '
      'key to encrypt the store with. Removed in 2.0.')
  PassnoteBuilder engine(
    FutureOr<CrdtTable> Function(String collection) factory,
  ) {
    _once('engine', _engineOverride != null || _storage != null);
    _engineOverride = factory;
    return this;
  }

  /// Overrides the storage engine. Default: a SQLite-backed disk engine.
  ///
  /// [factory] builds the store for one collection of one database, and is
  /// handed the local database id, the collection name, and the 32-byte key
  /// the store is to be encrypted with at rest. Keep one store per
  /// `(databaseId, collection)` pair. For an in-memory, non-persistent engine:
  ///
  /// ```dart
  /// .storage((_, collection, __) => MapCrdtTable(collection))
  /// ```
  PassnoteBuilder storage(
    FutureOr<CrdtTable> Function(
            String databaseId, String collection, List<int> key)
        factory,
  ) {
    _once('storage', _engineOverride != null || _storage != null);
    _storage = factory;
    return this;
  }

  /// Overrides the transport. Default: the umbrella's LAN transport (mDNS
  /// discovery — native only).
  ///
  /// A web app, or a peer outside mDNS reach, uses the WebSocket transport
  /// with explicit addresses instead:
  ///
  /// ```dart
  /// Passnote.builder(appId: 'shopping', salt: 'shopping:v1')
  ///     .transport(() => WebSocketTransport(
  ///           connectTo: [Uri.parse('wss://relay.example:9473')],
  ///         ))
  ///     .open();
  /// ```
  PassnoteBuilder transport(Transport Function() factory) {
    _once('transport', _transport != null);
    _transport = factory();
    return this;
  }

  /// Overrides the key store. Default: the umbrella's OS-keychain store,
  /// namespaced by `appId`.
  PassnoteBuilder keyStore(KeyStore Function() factory) {
    _once('keyStore', _keyStore != null);
    _keyStore = factory();
    return this;
  }

  /// Overrides the cipher. Default: the installed bundle's cipher
  /// (XChaCha20-Poly1305 with `passnote_flutter`).
  PassnoteBuilder cipher(Cipher Function(List<int> key) factory) {
    _once('cipher', _cipher != null);
    _cipher = factory;
    return this;
  }

  /// Overrides this device's [Identity]. The factory is handed the resolved key
  /// store. Default: the umbrella's X25519 + Ed25519 device identity.
  PassnoteBuilder identity(
    Future<Identity> Function(KeyStore keyStore) factory,
  ) {
    _once('identity', _identity != null);
    _identity = factory;
    return this;
  }

  /// Overrides the pairing PAKE. Default: the umbrella's SPAKE2.
  /// Opts this app into a written recovery phrase: [Passnote.enableRecovery]
  /// mints one and [Passnote.recoverFrom] restores access with it. Default:
  /// disabled — "no recovery" is a valid product choice, and a lost phrase
  /// plus lost devices then mean lost access by design.
  PassnoteBuilder recovery({required bool enabled}) {
    _once('recovery', _recoverySet);
    _recoverySet = true;
    _recoveryEnabled = enabled;
    return this;
  }

  /// Overrides the PAKE behind pairing codes. Default: the umbrella's
  /// SPAKE2 (P-256, RFC 9382).
  PassnoteBuilder pake(Pake Function() factory) {
    _once('pake', _pake != null);
    _pake = factory;
    return this;
  }

  /// Sets the generated-passphrase word count (12, 15, 18, 21, or 24; default
  /// 24) and how a non-mnemonic passphrase is treated (default
  /// [PassphraseStrictness.warn]).
  PassnoteBuilder passphrase({
    int words = 24,
    PassphraseStrictness strictness = PassphraseStrictness.warn,
  }) {
    _once('passphrase', _passphraseSet);
    _passphraseSet = true;
    _words = words;
    _strictness = strictness;
    return this;
  }

  /// Overrides the tombstone compaction horizon. Default: 30 days.
  PassnoteBuilder compactionHorizon(Duration horizon) {
    _once('compactionHorizon', _compactionHorizon != null);
    _compactionHorizon = horizon;
    return this;
  }

  /// Overrides how often each database runs an anti-entropy round with every
  /// connected peer, healing frames that were dropped. Default: 3 minutes.
  /// [Duration.zero] turns the timer off; sync then relies on pushes, the
  /// round each connection runs when it opens, and `Database.reconcileNow`.
  PassnoteBuilder antiEntropyInterval(Duration interval) {
    _once('antiEntropyInterval', _antiEntropyInterval != null);
    if (interval.isNegative) {
      throw ArgumentError.value(interval, 'interval', 'must not be negative');
    }
    _antiEntropyInterval = interval;
    return this;
  }

  /// Overrides the per-peer inbound frame rate limit. Default: 100 per second.
  PassnoteBuilder maxInboundFramesPerSecond(int limit) {
    _once('maxInboundFramesPerSecond', _maxInboundFramesPerSecond != null);
    _maxInboundFramesPerSecond = limit;
    return this;
  }

  /// Builds and starts the [Passnote] instance.
  ///
  /// Throws [StateError] if a slot is unset and no [PassnoteDefaults] has been
  /// installed (depend on `package:passnote`, or call [installDefaults]).
  Future<Passnote> open() async {
    final defaults = _defaults;
    if (defaults == null) {
      throw StateError(
        'PassnoteBuilder has no defaults installed. Use passnoteBuilder() '
        'from package:passnote_flutter, which installs them, or call '
        'PassnoteBuilder.installDefaults(...) yourself (see the cli_logbook '
        'example).',
      );
    }

    final keyStore = _keyStore ?? defaults.keyStore(_appId);
    final identityFactory = _identity ?? defaults.identity;
    final identity =
        identityFactory == null ? null : await identityFactory(keyStore);

    final override = _engineOverride;
    return passnoteLowLevel(
      engine: _storage ??
          (override != null
              ? (_, collection, __) => override(collection)
              : defaults.engine),
      config: PassnoteConfig(
        appId: _appId,
        salt: _salt,
        passphrasePolicy: PassphrasePolicy(
          words: _words,
          strictness: _strictness,
        ),
        compactionHorizon: _compactionHorizon ?? const Duration(days: 30),
        maxInboundFramesPerSecond: _maxInboundFramesPerSecond ?? 100,
        antiEntropyInterval: _antiEntropyInterval ?? const Duration(minutes: 3),
        recoveryEnabled: _recoveryEnabled,
      ),
      keyStore: keyStore,
      transport: _transport ?? defaults.transport(),
      cipher: _cipher ?? defaults.cipher,
      deriveKey: defaults.deriveKey,
      legacyDeriveKey: defaults.legacyDeriveKey,
      roomTag: defaults.roomTag,
      mnemonicGenerator: defaults.mnemonicGenerator,
      validateMnemonic: defaults.validateMnemonic,
      identity: identity,
      pake: (_pake ?? defaults.pake)?.call(),
      recoveryIdentity: defaults.recoveryIdentity,
    );
  }

  void _once(String slot, bool alreadySet) {
    if (alreadySet) {
      throw StateError('PassnoteBuilder.$slot was already set; set it once.');
    }
  }
}
