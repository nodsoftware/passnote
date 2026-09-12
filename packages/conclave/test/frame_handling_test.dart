// Pins the inbound-frame error contract: a handler that throws on a frame
// must neither escalate to an unhandled async error nor vanish silently — it
// surfaces as a [FrameHandlingFailed] event, and the node keeps running.
import 'dart:async';

import 'package:conclave/conclave.dart';
import 'package:conclave/engine.dart';
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

class _NoopCipher implements Cipher {
  @override
  Future<List<int>> encrypt(List<int> plaintext) async => plaintext;
  @override
  Future<List<int>> decrypt(List<int> ciphertext) async => ciphertext;
}

/// Fault injection through the engine port: merging into `notes` throws, the
/// way an unforeseen engine bug would.
class _ExplodingTable extends MapCrdtTable {
  _ExplodingTable(super.name);

  @override
  Future<void> merge(Map<String, List<Map<String, Object?>>> changeset) {
    if (changeset.containsKey('notes')) {
      throw StateError('injected engine fault');
    }
    return super.merge(changeset);
  }
}

final _noteCodec = JsonCodec<Map<String, dynamic>>(
  toMap: (m) => m,
  fromMap: (m) => m,
  idOf: (m) => m['id'] as String,
);

Future<void> _settle() => pumpEventQueue(times: 40);

void main() {
  test('a throwing frame handler surfaces FrameHandlingFailed and nothing dies',
      () async {
    final bus = InMemoryBus();
    Future<Conclave> node({required bool faulty}) => conclaveLowLevel(
          config: const ConclaveConfig(
            appId: 'fh',
            salt: 'fh:v1',
            snapshotInterval: Duration.zero,
          ),
          keyStore: _MemKeyStore(),
          transport: InMemoryTransport(bus),
          deriveKey: (_, __) async => List<int>.filled(32, 42),
          roomTag: (_) => 'room',
          cipher: (_) => _NoopCipher(),
          mnemonicGenerator: (n) => List.filled(n, 'abandon'),
          validateMnemonic: (_) => true,
          engine: (dbId, collection, _) =>
              faulty ? _ExplodingTable(collection) : MapCrdtTable(collection),
        );

    final healthy = await node(faulty: false);
    final broken = await node(faulty: true);
    addTearDown(() async {
      await healthy.close();
      await broken.close();
    });

    final failures = <FrameHandlingFailed>[];
    broken.events.listen((e) {
      if (e is FrameHandlingFailed) failures.add(e);
    });

    final dbH = await healthy.openDatabase('d', passphrase: 'p');
    final dbB = await broken.openDatabase('d', passphrase: 'p');
    final notesH = dbH.collection<Map<String, dynamic>>('notes', _noteCodec);
    dbB.collection<Map<String, dynamic>>('notes', _noteCodec);

    await notesH.put({'id': 'k', 'v': 1});
    await healthy.forceSync();
    await _settle();

    expect(failures, isNotEmpty,
        reason: 'the injected engine fault must surface as an event, not be '
            'swallowed or become an unhandled async error');
    expect(failures.first.databaseId, 'd');
    expect(failures.first.error, isA<StateError>());

    // The node survives: a later frame for a healthy collection still lands.
    final otherH = dbH.collection<Map<String, dynamic>>('other', _noteCodec);
    final otherB = dbB.collection<Map<String, dynamic>>('other', _noteCodec);
    await otherH.put({'id': 'x', 'v': 2});
    await healthy.forceSync();
    await _settle();
    expect((await otherB.get('x'))?['v'], 2);
  });
}
