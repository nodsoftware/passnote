// Guards the two public libraries. `passnote.dart` is the app-facing
// surface; `engine.dart` is the advanced surface. The exported symbol sets
// are computed from each library's resolved export namespace, so a symbol
// leaking into or out of either library breaks this test on purpose —
// comparing the source of `lib/passnote.dart` against itself would not.
@TestOn('vm')
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:passnote/passnote.dart' as api;
import 'package:passnote/engine.dart' as engine;
import 'package:test/test.dart';

/// The complete set of public symbols in the export namespace of the library
/// at `lib/<name>.dart` (setters folded into their getter name).
Future<Set<String>> surfaceOf(
  AnalysisContextCollection collection,
  String name,
) async {
  final path = '${Directory.current.path}/lib/$name.dart';
  final session = collection.contextFor(path).currentSession;
  final result = await session.getResolvedLibrary(path);
  if (result is! ResolvedLibraryResult) {
    fail('could not resolve lib/$name.dart: $result');
  }
  return result.element.exportNamespace.definedNames2.keys
      .where((n) => !n.endsWith('='))
      .toSet();
}

void main() {
  late AnalysisContextCollection collection;

  setUpAll(() {
    collection =
        AnalysisContextCollection(includedPaths: [Directory.current.path]);
  });

  // Semver freeze (VERSIONING.md): adding a symbol here is a deliberate API
  // decision; removing or renaming one after v1.0.0 is a major version.
  const frozenSurface = {
    'Cipher',
    'CipherAuthError',
    'Codec',
    'Collection',
    'CollectionQuery',
    'Passnote',
    'PassnoteBuilder',
    'PassnoteConfig',
    'PassnoteDefaults',
    'PassnoteEvent',
    'Crdt',
    'CrdtRecovery',
    'CrdtRecoverySource',
    'CrdtTable',
    'CrdtType',
    'Database',
    'DeepMergeStrategy',
    'DeviceInfo',
    'DevicePublicKey',
    'DeviceRecord',
    'DeviceRosterEntry',
    'DeviceState',
    'DiscoveryRestored',
    'DiscoveryUnavailable',
    'Document',
    'DocumentId',
    'FieldSpec',
    'FieldValue',
    'Frame',
    'FrameHandlingFailed',
    'Identity',
    'InboundFrame',
    'JsonCodec',
    'KeyRotation',
    'KeyStore',
    'LwwRegister',
    'MergeStrategy',
    'NodeId',
    'ObjectMergeStrategy',
    'OrSet',
    'PairingBundle',
    'PairingCode',
    'PairingRejected',
    'PairingTimeout',
    'Pake',
    'PakeResult',
    'PakeSession',
    'PassphrasePolicy',
    'PassphraseStrictness',
    'PeerAppeared',
    'PeerConnected',
    'PeerDisappeared',
    'PeerDiscoveryRestored',
    'PeerDiscoveryUnavailable',
    'PeerEvent',
    'PeerId',
    'PeerIncompatible',
    'PeerLost',
    'PnCounter',
    'QueryCursor',
    'QueryOp',
    'QueryPage',
    'QueryPredicate',
    'QueryRow',
    'QuerySpec',
    'RangeDigest',
    'RangeDigestBuilder',
    'SchemaMergeStrategy',
    'ShallowMergeStrategy',
    'SnapshotCapable',
    'SqlCipherUnavailableException',
    'StoreRecovered',
    'Transport',
    'WeakPassphraseException',
    'WrappedGroupKey',
    'WrappedKey',
    'WrongPassphraseException',
    'crdtTypeFromTag',
    'kDeviceCollection',
    'newId',
  };

  // The advanced surface: may change within a minor version with a CHANGELOG
  // note (see lib/engine.dart).
  const engineSurface = {
    'AntiEntropy',
    'AntiEntropyTimerFactory',
    'Cipher',
    'CipherAuthError',
    'Passnote',
    'PassnoteEvent',
    'CrdtRecovery',
    'CrdtRecoverySource',
    'CrdtTable',
    'CrdtType',
    'DeviceInfo',
    'DevicePublicKey',
    'DeviceRecord',
    'DeviceRosterEntry',
    'DeviceState',
    'DiscoveryRestored',
    'DiscoveryUnavailable',
    'FieldSpec',
    'FieldValue',
    'Frame',
    'FrameWindow',
    'Identity',
    'InMemoryBus',
    'InMemoryTransport',
    'InboundFrame',
    'KeyRotation',
    'KeyStore',
    'LwwRegister',
    'MapCrdtTable',
    'MergeStrategy',
    'NodeId',
    'OrSet',
    'PairingBundle',
    'PairingCode',
    'PairingRejected',
    'PairingTimeout',
    'Pake',
    'PakeResult',
    'PakeSession',
    'PeerAppeared',
    'PeerConnected',
    'PeerDisappeared',
    'PeerEvent',
    'PeerId',
    'PeerLost',
    'PnCounter',
    'QueryCursor',
    'QueryOp',
    'QueryPredicate',
    'QueryRow',
    'QuerySpec',
    'RangeDigest',
    'RangeDigestBuilder',
    'RangeProbe',
    'RangeRequest',
    'RatchetEphemeral',
    'RatchetSession',
    'ReconcilePlan',
    'Reconciler',
    'SnapshotCapable',
    'SqlCipherUnavailableException',
    'SqliteCrdtTable',
    'StoreRecovered',
    'Transport',
    'TypedCrdtTable',
    'WrappedGroupKey',
    'WrappedKey',
    'WrongPassphraseException',
    'passnoteLowLevel',
    'crdtTypeFromTag',
    'deriveRatchetRoot',
    'kDeviceCollection',
    'negotiate',
    'newRatchetNonce',
    'reconCapability',
    'supportedWireVersions',
  };

  test('the frozen library exports exactly the curated symbol set', () async {
    expect(
      await surfaceOf(collection, 'passnote'),
      frozenSurface,
      reason: 'package:passnote/passnote.dart symbol set changed: update the '
          'allow list only as a deliberate semver decision',
    );
  });

  test('the advanced wiring stays off the frozen library', () async {
    final frozen = await surfaceOf(collection, 'passnote');
    expect(frozen, isNot(contains('passnoteLowLevel')),
        reason: 'passnoteLowLevel belongs to engine.dart only');
    expect(frozen, isNot(contains('SqliteCrdtTable')));
    expect(frozen, isNot(contains('MapCrdtTable')));
  });

  test('the engine library exports exactly the advanced symbol set', () async {
    expect(
      await surfaceOf(collection, 'engine'),
      engineSurface,
      reason: 'package:passnote/engine.dart symbol set changed: deliberate '
          'changes need a CHANGELOG note and an update here',
    );
  });

  test('passnote.dart surfaces the app-facing API', () {
    // Builder entry and its config types.
    expect(api.Passnote.builder, isA<Function>());
    expect(api.PassnoteBuilder, isNotNull);
    expect(api.PassnoteDefaults, isNotNull);
    expect(const api.PassnoteConfig(appId: 'a', salt: 's').appId, 'a');
    expect(const api.PassphrasePolicy().words, 24);
    expect(api.PassphraseStrictness.warn, isNotNull);

    // Data model.
    expect(api.Database, isNotNull);
    expect(api.Collection, isNotNull);

    // Identity port.
    expect(api.Identity, isNotNull);
    expect(
      const api.DevicePublicKey(keyExchange: [], signing: []),
      isNotNull,
    );
    expect(api.WrappedKey, isNotNull);

    // Device roster.
    expect(api.kDeviceCollection, '__passnote_devices');
    expect(api.DeviceState.needsPairing, isNotNull);
    expect(
      api.DeviceRecord(
        deviceId: 'd',
        publicKey: const [],
        label: 'l',
        pairedAt: DateTime.utc(2026),
      ),
      isA<api.DeviceRosterEntry>(),
    );
    expect(
      const api.WrappedGroupKey(
        deviceId: 'd',
        keyEpoch: 0,
        wrappedBytes: [],
      ),
      isA<api.DeviceRosterEntry>(),
    );
    expect(
      const api.KeyRotation(
        keyEpoch: 1,
        byDeviceId: 'a',
        revokedDeviceId: 'c',
        keyDigest: [],
      ),
      isA<api.DeviceRosterEntry>(),
    );
    expect(
      api.DeviceInfo(
        id: 'd',
        label: 'l',
        pairedAt: DateTime.utc(2026),
        revoked: false,
        isThisDevice: true,
      ).isThisDevice,
      isTrue,
    );

    // Device pairing.
    expect(api.Pake, isNotNull);
    expect(api.PairingCode.generate().digits, hasLength(9));
    expect(
        const api.PairingRejected('x').toString(), contains('PairingRejected'));
    expect(const api.PairingTimeout().toString(), contains('PairingTimeout'));

    expect(api.newId(), isNotEmpty);
    expect(const api.ObjectMergeStrategy(), isA<api.MergeStrategy>());
    expect(const api.ShallowMergeStrategy(), isA<api.MergeStrategy>());
    expect(const api.DeepMergeStrategy(), isA<api.MergeStrategy>());
    expect(const api.SchemaMergeStrategy({'qty': api.PnCounter()}),
        isA<api.MergeStrategy>());

    // Typed queries.
    expect(api.CollectionQuery, isNotNull);
    expect(api.QueryPage, isNotNull);
    expect(const api.QueryCursor(orderValue: 1, docId: 'd'), isNotNull);

    // Per-field CRDT types.
    expect(const api.LwwRegister(), isA<api.CrdtType>());
    expect(const api.OrSet(), isA<api.CrdtType>());
    expect(const api.PnCounter(), isA<api.CrdtType>());
    expect(api.crdtTypeFromTag('pn_counter'), equals(const api.PnCounter()));
    expect(api.crdtTypeFromTag(null), equals(const api.LwwRegister()));

    // Observable events.
    expect(api.PassnoteEvent, isNotNull);
    expect(const api.PeerAppeared('p'), isA<api.PassnoteEvent>());
    expect(const api.PeerDisappeared('p'), isA<api.PassnoteEvent>());
    expect(
      const api.StoreRecovered(
        databaseId: 'd',
        collection: 'c',
        source: api.CrdtRecoverySource.reset,
        quarantinePath: '/tmp/x',
      ),
      isA<api.PassnoteEvent>(),
    );

    // Exceptions.
    expect(const api.WrongPassphraseException().toString(),
        contains('passphrase'));
    expect(
        const api.WeakPassphraseException().toString(), contains('mnemonic'));
    expect(const api.SqlCipherUnavailableException().toString(),
        contains('SQLCipher'));
    expect(const api.CipherAuthError().toString(), contains('authentication'));
  });

  test('engine.dart surfaces the advanced wiring and ports', () {
    expect(engine.passnoteLowLevel, isA<Function>());
    expect(engine.MapCrdtTable('t'), isA<engine.CrdtTable>());
    expect(engine.InMemoryTransport(engine.InMemoryBus()),
        isA<engine.Transport>());
    // Port types resolve.
    expect(engine.Cipher, isNotNull);
    expect(engine.KeyStore, isNotNull);
    expect(engine.MergeStrategy, isNotNull);
    expect(engine.CrdtType, isNotNull);
    // Query port types.
    expect(engine.TypedCrdtTable(engine.MapCrdtTable('t')),
        isA<engine.CrdtTable>());
    expect(const engine.QuerySpec(predicates: []), isNotNull);
    expect(
      const engine.QueryPredicate(
        path: 'p',
        op: engine.QueryOp.equals,
        value: 1,
        type: engine.LwwRegister(),
      ),
      isNotNull,
    );
    expect(const engine.QueryRow(docId: 'd', orderValue: null), isNotNull);
  });
}
