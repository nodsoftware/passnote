import 'dart:async';

import 'package:conclave/conclave.dart';
import 'package:conclave/engine.dart' show AntiEntropy, FrameWindow;
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

/// Counts outbound frames, and optionally drops a deterministic range of them
/// once — a repeatable stand-in for a flaky link or a rate-limited window.
class _FlakyTransport implements Transport {
  _FlakyTransport(this._inner, {this.dropFrom = -1, this.dropTo = -1});

  final Transport _inner;
  final int dropFrom;
  final int dropTo;
  int sent = 0;
  int dropped = 0;

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
    final index = sent++;
    if (index >= dropFrom && index <= dropTo) {
      dropped++;
      return Future.value(); // Lost on the wire.
    }
    return _inner.send(to, frame);
  }
}

final _codec = JsonCodec<Map<String, dynamic>>(
  toMap: (m) => m,
  fromMap: (m) => m,
  idOf: (m) => m['id'] as String,
);

const _passphrase = 'w0 w1 w2 w3 w4 w5 w6 w7 w8 w9 w10 w11';

Future<void> _settle([int times = 40]) => pumpEventQueue(times: times);

void main() {
  Future<Conclave> openNode(
    InMemoryBus bus, {
    Transport Function(Transport inner)? wrapTransport,
    Duration antiEntropy = Duration.zero,
    int maxInboundFramesPerSecond = 100,
  }) {
    final inner = InMemoryTransport(bus);
    return Conclave.lowLevel(
      config: ConclaveConfig(
        appId: 'stream',
        salt: 'stream:v1',
        antiEntropyInterval: antiEntropy,
        maxInboundFramesPerSecond: maxInboundFramesPerSecond,
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
    );
  }

  test('a 100k-record first sync streams as bounded frames and converges',
      () async {
    final bus = InMemoryBus();
    _FlakyTransport? counter;
    final a = await openNode(bus, wrapTransport: (inner) {
      return counter = _FlakyTransport(inner);
    });
    addTearDown(a.close);
    final dbA = await a.openDatabase('big', passphrase: _passphrase);
    final colA = dbA.collection<Map<String, dynamic>>('docs', _codec);
    await colA.ready;

    // 100k records (50k documents of existence register + one field),
    // fabricated as a merge from a synthetic seed node: orders of magnitude
    // faster than 50k put() calls and identical on the wire.
    const docs = 50000;
    final hlc = Hlc.parse('2026-09-10T10:00:00.000Z-0000-seednode00000001');
    await colA.mergeChangeset({
      'docs': [
        for (var i = 0; i < docs; i++) ...[
          {'key': 'd$i', 'value': true, 'is_deleted': false, 'hlc': hlc},
          {
            'key': 'd$i\x1F',
            'value': {'id': 'd$i', 'n': i},
            'is_deleted': false,
            'hlc': hlc,
          },
        ],
      ],
    });
    expect(colA.length, docs);

    final before = counter!.sent;
    // The inbound rate limiter is a DoS guard, not part of streaming; in
    // production a first sync at default limits is completed by anti-entropy
    // over a few intervals. Lift it here to observe the stream itself.
    final b = await openNode(bus, maxInboundFramesPerSecond: 1000000);
    addTearDown(b.close);
    final dbB = await b.openDatabase('big', passphrase: _passphrase);
    final colB = dbB.collection<Map<String, dynamic>>('docs', _codec);

    for (var i = 0; i < 200 && colB.length < docs; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(colB.length, docs, reason: 'the receiver ends with every record');

    final dataFrames = counter!.sent - before;
    expect(dataFrames, greaterThanOrEqualTo(200),
        reason: '100k records at 500 records/frame is at least 200 frames');
    expect(dataFrames, lessThan(300),
        reason: 'and not wildly more (handshake/state overhead only)');
  }, timeout: const Timeout(Duration(minutes: 2)));

  group('FrameWindow', () {
    test('admits immediately below capacity and preserves order', () async {
      final window = FrameWindow(capacity: 4);
      final sent = <int>[];
      final gates = [for (var i = 0; i < 3; i++) Completer<void>()];
      for (var i = 0; i < 3; i++) {
        await window.enqueue(() async {
          await gates[i].future;
          sent.add(i);
        });
      }
      expect(window.outstanding, 3);
      // Completing out of order still delivers in order.
      gates[2].complete();
      gates[0].complete();
      gates[1].complete();
      await window.drained;
      expect(sent, [0, 1, 2]);
      expect(window.outstanding, 0);
    });

    test('a full window blocks the producer until a frame completes', () async {
      final window = FrameWindow(capacity: 2);
      final gate = Completer<void>();
      await window.enqueue(() => gate.future);
      await window.enqueue(() async {});

      var admitted = false;
      final third = window.enqueue(() async {}).then((_) => admitted = true);
      await _settle();
      expect(admitted, isFalse, reason: 'window full: producer must wait');

      gate.complete(); // First frame completes; the window frees up.
      await third;
      expect(admitted, isTrue);
      await window.drained;
    });

    test('a failing send does not break the stream', () async {
      final window = FrameWindow(capacity: 2);
      final sent = <int>[];
      await window.enqueue(() async => throw StateError('boom'));
      await window.enqueue(() async => sent.add(1));
      await window.drained;
      expect(sent, [1]);
      expect(window.outstanding, 0);
    });
  });

  group('anti-entropy', () {
    test('heals frames dropped on the wire without a forceSync', () async {
      final bus = InMemoryBus();
      // Drop a window of A's outbound frames (the push broadcasts), once.
      _FlakyTransport? flaky;
      final a = await openNode(
        bus,
        wrapTransport: (inner) =>
            flaky = _FlakyTransport(inner, dropFrom: 8, dropTo: 40),
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
      final colA = dbA.collection<Map<String, dynamic>>('notes', _codec);
      final colB = dbB.collection<Map<String, dynamic>>('notes', _codec);
      await colB.ready;

      for (var i = 0; i < 10; i++) {
        await colA.put({'id': 'n$i', 'v': i});
      }
      expect(flaky!.dropped, greaterThan(0), reason: 'the fault fired');

      // No forceSync: the periodic exchange must close the gap by itself.
      for (var i = 0; i < 100 && colB.length < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(colB.length, 10);
    });

    test('interval zero never arms the timer', () {
      var ticks = 0;
      final ae = AntiEntropy(
        interval: Duration.zero,
        exchange: () async => ticks++,
        timerFactory: (_, __) => fail('must not create a timer'),
      );
      ae.start();
      expect(ae.isRunning, isFalse);
      expect(ticks, 0);
    });

    test('start arms, stop cancels, ticks collapse while one runs', () async {
      void Function()? tick;
      var cancelled = false;
      final timer = _FakeTimer(() => cancelled = true);
      var exchanges = 0;
      final gate = Completer<void>();
      final ae = AntiEntropy(
        interval: const Duration(minutes: 3),
        exchange: () {
          exchanges++;
          return gate.future;
        },
        timerFactory: (_, onTick) {
          tick = onTick;
          return timer;
        },
      );

      ae.start();
      expect(ae.isRunning, isTrue);

      tick!();
      tick!(); // Overlapping tick while the first exchange is still running.
      expect(exchanges, 1, reason: 'overlapping ticks collapse');
      gate.complete();
      await _settle();
      tick!();
      expect(exchanges, 2);

      ae.stop();
      expect(cancelled, isTrue);
      expect(ae.isRunning, isFalse);
    });

    test('a closed database sends nothing more', () async {
      final bus = InMemoryBus();
      _FlakyTransport? counter;
      final a = await openNode(
        bus,
        wrapTransport: (inner) => counter = _FlakyTransport(inner),
        antiEntropy: const Duration(milliseconds: 20),
      );
      final b = await openNode(bus);
      addTearDown(() async {
        await a.close();
        await b.close();
      });
      final dbA = await a.openDatabase('d', passphrase: _passphrase);
      await b.openDatabase('d', passphrase: _passphrase);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await dbA.close();
      await _settle();
      final after = counter!.sent;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(counter!.sent, after,
          reason: 'the anti-entropy timer is stopped on close');
    });
  });
}

class _FakeTimer implements Timer {
  _FakeTimer(this._onCancel);
  final void Function() _onCancel;
  var _active = true;

  @override
  void cancel() {
    _active = false;
    _onCancel();
  }

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}
