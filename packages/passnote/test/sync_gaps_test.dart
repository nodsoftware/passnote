// Records that reach a device outside sync, and differences the watermark
// exchange cannot see.
import 'package:crdt/crdt.dart' show CrdtChangeset, Hlc;
import 'package:passnote/engine.dart';
import 'package:passnote/passnote.dart';
import 'package:test/test.dart';

/// A bus that can drop frames, and drop a node and bring it back.
class _LossyBus extends InMemoryBus {
  bool dropping = false;

  @override
  void route(NodeId from, NodeId to, Frame frame) {
    if (!dropping) super.route(from, to, frame);
  }

  /// [transport] leaves and rejoins, each side seeing the other go and come
  /// back.
  void reconnect(InMemoryTransport transport, InMemoryTransport other) {
    unregister(transport.nodeId!);
    transport.injectPeerLost(other.nodeId!);
    register(transport);
  }
}

class _MemKeyStore implements KeyStore {
  final _keys = <String, List<int>>{};
  @override
  Future<List<int>?> getKey(String id) async => _keys[id];
  @override
  Future<void> setKey(String id, List<int> key) async => _keys[id] = key;
  @override
  Future<void> clear(String id) async => _keys.remove(id);
}

class _XorCipher implements Cipher {
  _XorCipher(List<int> key)
      : _k = key.isEmpty ? 0x5A : key.fold(0, (a, b) => (a + b) & 0xff);
  final int _k;
  @override
  Future<List<int>> encrypt(List<int> p) async =>
      [0xAC ^ _k, 0xED ^ _k, ...p.map((b) => b ^ _k)];
  @override
  Future<List<int>> decrypt(List<int> c) async {
    if (c.length < 2 || (c[0] ^ _k) != 0xAC || (c[1] ^ _k) != 0xED) {
      throw const CipherAuthError();
    }
    return c.skip(2).map((b) => b ^ _k).toList();
  }
}

final _key = List<int>.generate(32, (i) => i);

final _codec = JsonCodec<Map<String, dynamic>>(
  toMap: (m) => m,
  fromMap: (m) => m,
  idOf: (m) => m['id'] as String,
);

Future<Passnote> _node(InMemoryTransport transport) => passnoteLowLevel(
      config: const PassnoteConfig(
        appId: 'sg',
        salt: 'sg:v1',
        snapshotInterval: Duration.zero,
        antiEntropyInterval: Duration.zero,
      ),
      keyStore: _MemKeyStore(),
      transport: transport,
      deriveKey: (_, __) async => _key,
      roomTag: (key) => 'room-${key.take(4).join("-")}',
      cipher: _XorCipher.new,
      mnemonicGenerator: (n) => List.filled(n, 'abandon'),
      validateMnemonic: (_) => true,
      engine: (dbId, collection, _) => MapCrdtTable(collection),
    );

/// The records of one whole-document note, stamped at [at].
CrdtChangeset _note(String id, String text, DateTime at) {
  final hlc = Hlc(at.toUtc(), 0, 'elsewhere');
  return {
    'notes': [
      {'key': id, 'value': true, 'is_deleted': false, 'hlc': hlc},
      {
        'key': '$id\x1F',
        'value': {'id': id, 'text': text},
        'is_deleted': false,
        'hlc': hlc,
      },
    ],
  };
}

void main() {
  late _LossyBus bus;
  late InMemoryTransport ta, tb;
  late Passnote a, b;
  late Collection<Map<String, dynamic>> notesA, notesB;

  setUp(() async {
    bus = _LossyBus();
    ta = InMemoryTransport(bus);
    tb = InMemoryTransport(bus);
    a = await _node(ta);
    b = await _node(tb);
    notesA = (await a.openDatabase('d', passphrase: 'p'))
        .collection('notes', _codec);
    notesB = (await b.openDatabase('d', passphrase: 'p'))
        .collection('notes', _codec);
    await pumpEventQueue(times: 50);
  });
  tearDown(() async {
    await a.close();
    await b.close();
  });

  group('adoptRecords', () {
    test('merges exported records and offers them to peers', () async {
      final adopted = await notesA.adoptRecords(_note(
          'n', 'imported', DateTime.now().subtract(const Duration(days: 1))));
      expect(adopted, 2);
      expect((await notesA.get('n'))?['text'], 'imported');
      await pumpEventQueue(times: 100);
      expect((await notesB.get('n'))?['text'], 'imported');
    });

    test('round-trips what getChangeset exports', () async {
      await notesA.put({'id': 'n', 'text': 'original'});
      final exported = await notesA.getChangeset();
      final other = (await b.openDatabase('other', passphrase: 'q'))
          .collection('notes', _codec);
      expect(await other.adoptRecords(exported), greaterThan(0));
      expect((await other.get('n'))?['text'], 'original');
    });

    test('loses to what is newer, and changes nothing when re-adopted',
        () async {
      await notesA.put({'id': 'n', 'text': 'current'});
      await notesA.adoptRecords(_note(
          'n', 'stale', DateTime.now().subtract(const Duration(days: 1))));
      expect((await notesA.get('n'))?['text'], 'current');
    });

    test('leaves out a document stamped beyond the clock bound', () async {
      expect(
          await notesA.adoptRecords(_note('f', 'future', DateTime.utc(2999))),
          0);
      expect(await notesA.get('f'), isNull);
    });

    test('refuses another table and malformed records', () async {
      expect(() => notesA.adoptRecords({'other': []}), throwsArgumentError);
      expect(
        () => notesA.adoptRecords({
          'notes': [
            {'key': 'n', 'value': true, 'is_deleted': false, 'hlc': 'nonsense'},
          ],
        }),
        throwsArgumentError,
      );
      expect(
        () => notesA.adoptRecords({
          'notes': [
            {
              'key': 'n',
              'value': true,
              'is_deleted': false,
              // No time zone: two devices would read different instants.
              'hlc': '2026-01-01T00:00:00.000-0000-x',
            },
          ],
        }),
        throwsArgumentError,
      );
    });
  });

  group('reconciliation', () {
    test('a reconnect finds a record older than both watermarks', () async {
      // While frames are lost, A writes something new and B comes to hold
      // something old that A never saw.
      bus.dropping = true;
      await notesA.put({'id': 'new', 'text': 'from A'});
      await notesB.adoptRecords(_note(
          'old', 'from B', DateTime.now().subtract(const Duration(hours: 1))));
      await pumpEventQueue(times: 50);
      bus.dropping = false;

      // A's watermark is now ahead of B's old record, so the state exchange
      // alone never offers it.
      bus.reconnect(tb, ta);
      await pumpEventQueue(times: 400);
      expect((await notesB.get('new'))?['text'], 'from A');
      expect((await notesA.get('old'))?['text'], 'from B');
    });

    test('reconcileNow finds it without a reconnect', () async {
      bus.dropping = true;
      await notesA.put({'id': 'new', 'text': 'from A'});
      await notesB.adoptRecords(_note(
          'old', 'from B', DateTime.now().subtract(const Duration(hours: 1))));
      await pumpEventQueue(times: 50);
      bus.dropping = false;
      await a.forceSync();
      await pumpEventQueue(times: 200);
      expect(await notesA.get('old'), isNull,
          reason: 'the watermark exchange cannot see it');

      await a.reconcileNow();
      await pumpEventQueue(times: 400);
      expect((await notesA.get('old'))?['text'], 'from B');
    });
  });
}
