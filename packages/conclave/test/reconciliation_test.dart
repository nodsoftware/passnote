import 'dart:async';

import 'package:conclave/conclave.dart';
import 'package:conclave/engine.dart';
import 'package:crdt/crdt.dart' show Hlc;
import 'package:test/test.dart';

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

class _MemKeyStore implements KeyStore {
  final _keys = <String, List<int>>{};
  @override
  Future<List<int>?> getKey(String id) async => _keys[id];
  @override
  Future<void> setKey(String id, List<int> key) async => _keys[id] = key;
  @override
  Future<void> clear(String id) async => _keys.remove(id);
}

/// Counts frames and bytes so a test can prove "no full resync".
class _MeteredTransport implements Transport {
  _MeteredTransport(this._inner);
  final Transport _inner;
  int frames = 0;
  int bytes = 0;

  void reset() {
    frames = 0;
    bytes = 0;
  }

  @override
  Stream<PeerEvent> get events => _inner.events;
  @override
  Stream<InboundFrame> get inbound => _inner.inbound;
  @override
  Future<void> start({required NodeId self, required String appId}) =>
      _inner.start(self: self, appId: appId);
  @override
  Future<void> stop() => _inner.stop();
  @override
  Future<void> send(PeerId to, Frame frame) {
    frames++;
    bytes += frame.bytes.length;
    return _inner.send(to, frame);
  }
}

final _codec = JsonCodec<Map<String, dynamic>>(
  toMap: (m) => m,
  fromMap: (m) => m,
  idOf: (m) => m['id'] as String,
);

const _passphrase = 'w0 w1 w2 w3 w4 w5 w6 w7 w8 w9 w10 w11';

/// Fabricates [count] records spread over a year of HLC time, plus their
/// existence registers — a converged history much faster than put() calls.
Map<String, List<Map<String, dynamic>>> _history(String col, int count) {
  final base = DateTime.utc(2025, 1, 1).microsecondsSinceEpoch;
  const spreadUs = 365 * 24 * 3600 * 1000000;
  return {
    col: [
      for (var i = 0; i < count; i++) ...[
        {
          'key': 'd$i',
          'value': true,
          'is_deleted': false,
          'hlc': Hlc(
            DateTime.fromMicrosecondsSinceEpoch(
                base + (i * (spreadUs ~/ count)),
                isUtc: true),
            0,
            'seednode00000001',
          ),
        },
        {
          'key': 'd$i\x1F',
          'value': {'id': 'd$i', 'n': i},
          'is_deleted': false,
          'hlc': Hlc(
            DateTime.fromMicrosecondsSinceEpoch(
                base + (i * (spreadUs ~/ count)) + 1,
                isUtc: true),
            0,
            'seednode00000001',
          ),
        },
      ],
    ],
  };
}

void main() {
  group('Reconciler (pure)', () {
    /// A digest function over an in-memory record list.
    Future<RangeDigest> Function(String?, String?) digestOf(
        Map<String, Hlc> records) {
      return (from, to) async {
        final fromHlc = from == null ? null : Hlc.parse(from);
        final toHlc = to == null ? null : Hlc.parse(to);
        final builder = RangeDigestBuilder();
        for (final entry in records.entries) {
          if (fromHlc != null && entry.value <= fromHlc) continue;
          if (toHlc != null && entry.value > toHlc) continue;
          builder.add(entry.key, entry.value);
        }
        return builder.build();
      };
    }

    Map<String, Hlc> makeRecords(int count, {int startUs = 0}) => {
          for (var i = 0; i < count; i++)
            'k$i': Hlc(
              DateTime.fromMicrosecondsSinceEpoch(startUs + i * 1000000,
                  isUtc: true),
              0,
              'node0000000000001',
            ),
        };

    test('identical sets: the initial probe matches and the plan is empty',
        () async {
      final records = makeRecords(500);
      final a = Reconciler(digest: digestOf(records));
      final b = Reconciler(digest: digestOf(Map.of(records)));

      final probe = await a.initialProbe();
      final plan = await b.handleProbes([probe!]);
      expect(plan.isEmpty, isTrue, reason: 'only fingerprints, no records');
    });

    test('one missing old record is found in O(log n) rounds', () async {
      final full = makeRecords(4096);
      final missingOne = Map.of(full)..remove('k3'); // Old: near the start.
      final holder = Reconciler(digest: digestOf(full));
      final seeker = Reconciler(digest: digestOf(missingOne));

      var probes = [(await holder.initialProbe())!];
      var rounds = 0;
      var requested = false;
      var side = seeker;
      var other = holder;
      while (probes.isNotEmpty && rounds < 40) {
        rounds++;
        final plan = await side.handleProbes(probes);
        if (plan.requestRanges.isNotEmpty || plan.shipRanges.isNotEmpty) {
          requested = true;
          break;
        }
        probes = plan.replyProbes;
        final swap = side;
        side = other;
        other = swap;
      }
      expect(requested, isTrue);
      expect(rounds, lessThanOrEqualTo(30),
          reason: 'time-bisection over the span, not a full walk');
    });

    test('probe fan-out per reply is capped; overflow ranges leaf-ship',
        () async {
      // Two completely disjoint sets: every split mismatches.
      final a = makeRecords(4096);
      final b = makeRecords(4096, startUs: 7); // Offset: nothing lines up.
      final reconciler = Reconciler(digest: digestOf(b));

      var probes = [
        (await Reconciler(digest: digestOf(a)).initialProbe())!,
      ];
      for (var round = 0; round < 12 && probes.isNotEmpty; round++) {
        final plan = await reconciler.handleProbes(probes);
        expect(plan.replyProbes.length,
            lessThanOrEqualTo(reconciler.maxProbesPerReply));
        probes = plan.replyProbes;
      }
    });

    test('the depth cap turns any range into a leaf', () async {
      final records = makeRecords(4096);
      final other = Map.of(records)..remove('k100');
      final reconciler = Reconciler(digest: digestOf(other), maxDepth: 3);
      final deep = RangeProbe(
        from: null,
        to: null,
        depth: 3,
        count: records.length,
        fingerprint: (await digestOf(records)(null, null)).fingerprint,
      );
      final plan = await reconciler.handleProbes([deep]);
      expect(plan.replyProbes, isEmpty, reason: 'no splits past the cap');
      expect(plan.requestRanges, isNotEmpty);
      expect(plan.shipRanges, isNotEmpty);
    });
  });

  group('end to end', () {
    Future<Conclave> openNode(
      InMemoryBus bus, {
      Transport Function(Transport inner)? wrapTransport,
      Duration antiEntropy = Duration.zero,
      List<String>? capabilities,
    }) {
      final inner = InMemoryTransport(bus);
      return Conclave.lowLevel(
        config: ConclaveConfig(
          appId: 'recon',
          salt: 'recon:v1',
          antiEntropyInterval: antiEntropy,
          maxInboundFramesPerSecond: 100000,
        ),
        keyStore: _MemKeyStore(),
        transport: wrapTransport == null ? inner : wrapTransport(inner),
        deriveKey: (p, _) async =>
            List<int>.generate(32, (i) => p.codeUnitAt(i % p.length)),
        roomTag: (_) => 'room',
        cipher: _XorCipher.new,
        mnemonicGenerator: (n) => List.generate(n, (i) => 'word$i'),
        validateMnemonic: (_) => true,
        engine: (dbId, collection, _) => MapCrdtTable(collection),
        wireCapabilities: capabilities ?? const ['recon1'],
      );
    }

    test('an old record below both watermarks heals without a full resync',
        () async {
      final bus = InMemoryBus();
      _MeteredTransport? meterA;
      final a = await openNode(
        bus,
        wrapTransport: (t) => meterA = _MeteredTransport(t),
        antiEntropy: const Duration(milliseconds: 100),
      );
      final b = await openNode(
        bus,
        antiEntropy: const Duration(milliseconds: 100),
      );
      addTearDown(() async {
        await a.close();
        await b.close();
      });

      final dbA = await a.openDatabase('d', passphrase: _passphrase);
      final dbB = await b.openDatabase('d', passphrase: _passphrase);
      final colA = dbA.collection<Map<String, dynamic>>('docs', _codec);
      final colB = dbB.collection<Map<String, dynamic>>('docs', _codec);
      await colA.ready;
      await colB.ready;

      // A converged past: seed A and let the protocol bring B up to the same
      // 20k records, then let the exchange go quiet.
      const docs = 10000;
      await colA.mergeChangeset(_history('docs', docs));
      expect(colA.length, docs);
      for (var i = 0; i < 400 && colB.length < docs; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(colB.length, docs);
      await Future<void>.delayed(const Duration(milliseconds: 400));

      // A alone holds one OLD record — older than everything above, so both
      // watermarks are past it and a state exchange can never ship it.
      final oldHlc = Hlc(DateTime.utc(2024, 6, 1), 0, 'seednode00000001');
      await colA.mergeChangeset({
        'docs': [
          {'key': 'lost', 'value': true, 'is_deleted': false, 'hlc': oldHlc},
          {
            'key': 'lost\x1F',
            'value': {'id': 'lost', 'v': 'found again'},
            'is_deleted': false,
            'hlc':
                Hlc(DateTime.utc(2024, 6, 1, 0, 0, 1), 0, 'seednode00000001'),
          },
        ],
      });

      meterA!.reset();
      // No forceSync: reconciliation-driven anti-entropy must find it.
      Map<String, dynamic>? healed;
      for (var i = 0; i < 200 && healed == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        healed = await colB.get('lost');
      }
      expect(healed?['v'], 'found again');

      // "Without a full resync": the whole history is ~20k records; shipping
      // it would be megabytes. The heal is fingerprints plus one leaf.
      expect(meterA!.bytes, lessThan(200 * 1024),
          reason: 'healed with ${meterA!.bytes} bytes, not a full resync');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('identical peers exchange only fingerprints', () async {
      final bus = InMemoryBus();
      _MeteredTransport? meterA;
      final a = await openNode(
        bus,
        wrapTransport: (t) => meterA = _MeteredTransport(t),
        antiEntropy: const Duration(milliseconds: 50),
      );
      final b =
          await openNode(bus, antiEntropy: const Duration(milliseconds: 50));
      addTearDown(() async {
        await a.close();
        await b.close();
      });

      final dbA = await a.openDatabase('d', passphrase: _passphrase);
      final dbB = await b.openDatabase('d', passphrase: _passphrase);
      final colA = dbA.collection<Map<String, dynamic>>('docs', _codec);
      final colB = dbB.collection<Map<String, dynamic>>('docs', _codec);
      await colA.ready;
      await colB.ready;
      final history = _history('docs', 2000);
      await colA.mergeChangeset(history);
      await colB.mergeChangeset(history);

      // Let the topology settle, then measure a quiet period.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      meterA!.reset();
      await Future<void>.delayed(const Duration(milliseconds: 500));

      // ~10 anti-entropy ticks of a whole-range probe each: fingerprints
      // only. 4000 records would be hundreds of KB.
      expect(meterA!.bytes, lessThan(20 * 1024),
          reason: '${meterA!.bytes} bytes of pure fingerprint traffic');
    });

    test(
        'a peer without the capability falls back to the state exchange '
        'and still converges', () async {
      final bus = InMemoryBus();
      final a = await openNode(
        bus,
        antiEntropy: const Duration(milliseconds: 50),
      );
      final b = await openNode(
        bus,
        antiEntropy: const Duration(milliseconds: 50),
        capabilities: const [], // An older build: no reconciliation.
      );
      addTearDown(() async {
        await a.close();
        await b.close();
      });

      final dbA = await a.openDatabase('d', passphrase: _passphrase);
      final dbB = await b.openDatabase('d', passphrase: _passphrase);
      final colA = dbA.collection<Map<String, dynamic>>('docs', _codec);
      final colB = dbB.collection<Map<String, dynamic>>('docs', _codec);
      await colB.ready;

      await colA.put({'id': 'x', 'v': 'plain path'});
      Map<String, dynamic>? synced;
      for (var i = 0; i < 100 && synced == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        synced = await colB.get('x');
      }
      expect(synced?['v'], 'plain path');
    });
  });
}
