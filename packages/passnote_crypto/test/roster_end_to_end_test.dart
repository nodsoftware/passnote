// Joins the two halves other suites test in isolation: the device roster's
// signed-row trust chain (packages/passnote) running over the REAL
// cryptography — Ed25519 signatures via [DeviceIdentity.sign]/[verify],
// X25519 key wraps, and the XChaCha20-Poly1305 cipher on the wire.
import 'package:passnote/passnote.dart';
import 'package:passnote/engine.dart';
import 'package:passnote_crypto/passnote_crypto.dart';
import 'package:test/test.dart';

class _MemKeyStore implements KeyStore {
  final _keys = <String, List<int>>{};
  @override
  Future<List<int>?> getKey(String id) async => _keys[id];
  @override
  Future<void> setKey(String id, List<int> key) async => _keys[id] = key;
  @override
  Future<void> clear(String id) async => _keys.remove(id);
}

final _noteCodec = JsonCodec<Map<String, dynamic>>(
  toMap: (m) => m,
  fromMap: (m) => m,
  idOf: (m) => m['id'] as String,
);

Future<void> _settle() => pumpEventQueue(times: 60);

void main() {
  // The KDF is stubbed (this test is about the identity/roster seam, not
  // Argon2id, which has its own vectors); everything else is production
  // crypto.
  Future<Passnote> openNode(InMemoryBus bus, DeviceIdentity identity) =>
      passnoteLowLevel(
        config: const PassnoteConfig(
          appId: 'e2e',
          salt: 'e2e:v1',
          snapshotInterval: Duration.zero,
        ),
        keyStore: _MemKeyStore(),
        transport: InMemoryTransport(bus),
        deriveKey: (_, __) async => List<int>.filled(32, 42),
        roomTag: roomTag,
        cipher: XChaChaPoly1305Cipher.new,
        mnemonicGenerator: (n) => List.filled(n, 'abandon'),
        validateMnemonic: (_) => true,
        engine: (dbId, collection, _) => MapCrdtTable(collection),
        identity: identity,
      );

  test(
      'found, admit, sync, and revoke converge over real Ed25519 signatures '
      'and X25519 wraps', () async {
    final bus = InMemoryBus();
    final a = await openNode(bus, await DeviceIdentity.generate());
    final b = await openNode(bus, await DeviceIdentity.generate());
    final c = await openNode(bus, await DeviceIdentity.generate());
    addTearDown(() async {
      await a.close();
      await b.close();
      await c.close();
    });

    final dbA = await a.openDatabase('d', passphrase: 'p');
    if (dbA.deviceState != DeviceState.ready) {
      await dbA.foundGroup(label: 'A');
    }

    for (final (node, label) in [(b, 'B'), (c, 'C')]) {
      await _settle();
      final db = await node.openDatabase('d', passphrase: 'p');
      await dbA.admitDevice(await node.identity.publicKey, label: label);
      await a.forceSync();
      await _settle();
      await db.refreshDeviceState();
    }

    final dbB = await b.reopenDatabase('d');
    final dbC = await c.reopenDatabase('d');
    expect(dbB.deviceState, DeviceState.ready,
        reason: 'B validated A-signed roster rows with real Ed25519');
    expect(dbC.deviceState, DeviceState.ready);

    // Data flows under the group key.
    final notesA = dbA.collection<Map<String, dynamic>>('notes', _noteCodec);
    final notesB = dbB.collection<Map<String, dynamic>>('notes', _noteCodec);
    final notesC = dbC.collection<Map<String, dynamic>>('notes', _noteCodec);
    await notesA.put({'id': 'k', 'v': 'before'});
    await a.forceSync();
    await _settle();
    expect((await notesB.get('k'))?['v'], 'before');
    expect((await notesC.get('k'))?['v'], 'before');

    // Revocation rotates the key away from C.
    await a.revokeDevice('d', c.identity.deviceId);
    await a.forceSync();
    await _settle();
    await dbB.refreshDeviceState();
    await dbC.refreshDeviceState();
    expect(dbB.deviceState, DeviceState.ready);
    expect(dbC.deviceState, DeviceState.revoked);

    await notesA.put({'id': 'k', 'v': 'after'});
    await a.forceSync();
    await _settle();
    expect((await notesB.get('k'))?['v'], 'after');
    expect((await notesC.get('k'))?['v'], 'before',
        reason: 'C never receives a wrap for the rotated key');

    final rosterA = {for (final d in await a.devices('d')) d.id: d.revoked};
    expect(rosterA[c.identity.deviceId], isTrue);
    expect(rosterA[b.identity.deviceId], isFalse);
    expect(rosterA[a.identity.deviceId], isFalse);
  });
}
