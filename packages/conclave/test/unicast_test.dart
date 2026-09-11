import 'dart:async';

import 'package:conclave/engine.dart';
import 'package:test/test.dart';

void main() {
  test('InMemoryTransport delivers a frame only to the addressed peer',
      () async {
    final bus = InMemoryBus();
    final a = InMemoryTransport(bus);
    final b = InMemoryTransport(bus);
    final c = InMemoryTransport(bus);

    await a.start(self: 'a', appId: 'test');
    await b.start(self: 'b', appId: 'test');
    await c.start(self: 'c', appId: 'test');

    final bFrames = <InboundFrame>[];
    final cFrames = <InboundFrame>[];
    b.inbound.listen(bFrames.add);
    c.inbound.listen(cFrames.add);

    // A sends a frame addressed to B only.
    await a.send('b', const Frame('room1', [1, 2, 3]));

    // Let the broadcast-stream microtasks flush.
    await Future<void>.delayed(Duration.zero);

    expect(bFrames, hasLength(1), reason: 'B is the addressee');
    expect(bFrames.single.from, equals('a'));
    expect(cFrames, isEmpty,
        reason: 'C was not addressed and must not receive it');

    await a.stop();
    await b.stop();
    await c.stop();
  });
}
