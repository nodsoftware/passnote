part of 'conclave.dart';

/// The platform factories [ConclaveBuilder] fills in for any slot the caller
/// does not override.
///
/// The `conclave` umbrella package installs a production bundle (OS keychain,
/// LAN transport, AES-GCM) when its `conclaveBuilder` is first used. Code that
/// depends on `conclave` directly installs its own with
/// [ConclaveBuilder.installDefaults].
final class ConclaveDefaults {
  /// Creates a default bundle. Every factory is required except [identity],
  /// which only the device-pairing paths need.
  const ConclaveDefaults({
    required this.engine,
    required this.keyStore,
    required this.transport,
    required this.cipher,
    required this.deriveKey,
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

  /// Derives the public discovery room tag from a key.
  final String Function(List<int> key) roomTag;

  /// Generates a mnemonic passphrase of the given word count.
  final List<String> Function(int words) mnemonicGenerator;

  /// Returns whether a passphrase is a recognised mnemonic.
  final bool Function(String phrase) validateMnemonic;

  /// Loads (generating on first use) this device's [Identity], given the app's
  /// key store. `null` when the host does not provide one; [Conclave.identity]
  /// then throws until an identity is configured.
  final Future<Identity> Function(KeyStore keyStore)? identity;

  /// Derives the deterministic keypair behind a recovery phrase, for
  /// [Conclave.enableRecovery] / [Conclave.recoverFrom]. `null` when the host
  /// does not provide one; the recovery APIs then throw even when the app
  /// opted in with [ConclaveBuilder.recovery].
  final Future<Identity> Function(String phrase, String salt)? recoveryIdentity;

  /// Builds the PAKE used to authenticate device pairing. `null` when the host
  /// does not provide one; [Conclave.startPairing] / [Conclave.pairWith] then
  /// throw. Default (umbrella): SPAKE2.
  final Pake Function()? pake;
}

/// Staged configuration for a [Conclave] instance.
///
/// Obtain one from [Conclave.builder], set any overrides (each at most once, in
/// any order), then `await` [open]. Any slot left unset is filled from the
/// installed [ConclaveDefaults].
///
/// ```dart
/// // Minimal: every default from the umbrella.
/// final conclave = await Conclave.builder(
///   appId: 'shopping',
///   salt: 'shopping:v1',
/// ).open();
///
/// // Customised: override only what you need, in any order.
/// final conclave = await Conclave.builder(appId: 'shopping', salt: 'shopping:v1')
///     .transport(LanTransport.new)
///     .passphrase(words: 12)
///     .compactionHorizon(const Duration(days: 60))
///     .open();
/// ```
final class ConclaveBuilder {
  ConclaveBuilder._(this._appId, this._salt);

  final String _appId;
  final String _salt;

  FutureOr<CrdtTable> Function(String collection)? _engineOverride;
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

  static ConclaveDefaults? _defaults;

  /// Installs the [ConclaveDefaults] every builder falls back to. The `conclave`
  /// umbrella calls this on import; call it directly only when depending on
  /// `conclave` without the umbrella. The last call wins.
  static void installDefaults(ConclaveDefaults defaults) =>
      _defaults = defaults;

  /// Overrides the storage engine. Default: a SQLite-backed disk engine.
  /// Pass `MapCrdtTable.new` for an in-memory, non-persistent engine.
  ConclaveBuilder engine(
    FutureOr<CrdtTable> Function(String collection) factory,
  ) {
    _once('engine', _engineOverride != null);
    _engineOverride = factory;
    return this;
  }

  /// Overrides the transport. Default: the umbrella's LAN transport (mDNS
  /// discovery — native only).
  ///
  /// A web app, or a peer outside mDNS reach, uses the WebSocket transport
  /// with explicit addresses instead:
  ///
  /// ```dart
  /// Conclave.builder(appId: 'shopping', salt: 'shopping:v1')
  ///     .transport(() => WebSocketTransport(
  ///           connectTo: [Uri.parse('wss://relay.example:9473')],
  ///         ))
  ///     .open();
  /// ```
  ConclaveBuilder transport(Transport Function() factory) {
    _once('transport', _transport != null);
    _transport = factory();
    return this;
  }

  /// Overrides the key store. Default: the umbrella's OS-keychain store,
  /// namespaced by `appId`.
  ConclaveBuilder keyStore(KeyStore Function() factory) {
    _once('keyStore', _keyStore != null);
    _keyStore = factory();
    return this;
  }

  /// Overrides the cipher. Default: the umbrella's AES-256-GCM cipher.
  ConclaveBuilder cipher(Cipher Function(List<int> key) factory) {
    _once('cipher', _cipher != null);
    _cipher = factory;
    return this;
  }

  /// Overrides this device's [Identity]. The factory is handed the resolved key
  /// store. Default: the umbrella's X25519 + Ed25519 device identity.
  ConclaveBuilder identity(
    Future<Identity> Function(KeyStore keyStore) factory,
  ) {
    _once('identity', _identity != null);
    _identity = factory;
    return this;
  }

  /// Overrides the pairing PAKE. Default: the umbrella's SPAKE2.
  /// Opts this app into a written recovery phrase: [Conclave.enableRecovery]
  /// mints one and [Conclave.recoverFrom] restores access with it. Default:
  /// disabled — "no recovery" is a valid product choice, and a lost phrase
  /// plus lost devices then mean lost access by design.
  ConclaveBuilder recovery({required bool enabled}) {
    _once('recovery', _recoverySet);
    _recoverySet = true;
    _recoveryEnabled = enabled;
    return this;
  }

  ConclaveBuilder pake(Pake Function() factory) {
    _once('pake', _pake != null);
    _pake = factory;
    return this;
  }

  /// Sets the generated-passphrase word count (12, 15, 18, 21, or 24; default
  /// 24) and how a non-mnemonic passphrase is treated (default
  /// [PassphraseStrictness.warn]).
  ConclaveBuilder passphrase({
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
  ConclaveBuilder compactionHorizon(Duration horizon) {
    _once('compactionHorizon', _compactionHorizon != null);
    _compactionHorizon = horizon;
    return this;
  }

  /// Overrides the per-peer inbound frame rate limit. Default: 100 per second.
  ConclaveBuilder maxInboundFramesPerSecond(int limit) {
    _once('maxInboundFramesPerSecond', _maxInboundFramesPerSecond != null);
    _maxInboundFramesPerSecond = limit;
    return this;
  }

  /// Builds and starts the [Conclave] instance.
  ///
  /// Throws [StateError] if a slot is unset and no [ConclaveDefaults] has been
  /// installed (depend on `package:conclave`, or call [installDefaults]).
  Future<Conclave> open() async {
    final defaults = _defaults;
    if (defaults == null) {
      throw StateError(
        'ConclaveBuilder has no defaults installed. Depend on package:conclave '
        '(which installs them on import), or call '
        'ConclaveBuilder.installDefaults(...).',
      );
    }

    final keyStore = _keyStore ?? defaults.keyStore(_appId);
    final identityFactory = _identity ?? defaults.identity;
    final identity =
        identityFactory == null ? null : await identityFactory(keyStore);

    final override = _engineOverride;
    return Conclave.lowLevel(
      engine: override != null
          ? (_, collection, __) => override(collection)
          : defaults.engine,
      config: ConclaveConfig(
        appId: _appId,
        salt: _salt,
        passphrasePolicy: PassphrasePolicy(
          words: _words,
          strictness: _strictness,
        ),
        compactionHorizon: _compactionHorizon ?? const Duration(days: 30),
        maxInboundFramesPerSecond: _maxInboundFramesPerSecond ?? 100,
        recoveryEnabled: _recoveryEnabled,
      ),
      keyStore: keyStore,
      transport: _transport ?? defaults.transport(),
      cipher: _cipher ?? defaults.cipher,
      deriveKey: defaults.deriveKey,
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
      throw StateError('ConclaveBuilder.$slot was already set; set it once.');
    }
  }
}
