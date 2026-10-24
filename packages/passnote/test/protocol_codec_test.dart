import 'dart:convert';
import 'dart:math';

import 'package:passnote/src/protocol/messages.dart';
import 'package:crdt/crdt.dart';
import 'package:test/test.dart';

Hlc get _hlc => Hlc.parse('2026-09-10T12:00:00.000Z-0000-abcdef0123456789');

/// A realistic delta record: a typed state value, a nested map, and the
/// `crdt_type` tag the SQLite engine sends.
Map<String, dynamic> _record(int i) => {
      'key': 'doc$i\x1Fqty',
      'value': {
        '__t': 'pn_counter',
        'p': {'abcdef0123456789': i, 'fedcba9876543210': 2 * i},
        'n': {'abcdef0123456789': 1},
      },
      'is_deleted': i % 7 == 0,
      'hlc': _hlc,
      'crdt_type': 'pn_counter',
    };

void main() {
  group('round-trips', () {
    ProtocolMessage rt(ProtocolMessage m) => decodeMessage(encodeMessage(m))!;

    test('hello', () {
      final m = rt(const HelloMessage(node: 'node-1')) as HelloMessage;
      expect(m.node, 'node-1');
    });

    test('state, including an empty one', () {
      final m = rt(const StateMessage(cols: {
        'items': '2026-09-10T12:00:00.000Z-0000-abcdef0123456789',
        'empty': '',
      })) as StateMessage;
      expect(m.cols, {
        'items': '2026-09-10T12:00:00.000Z-0000-abcdef0123456789',
        'empty': '',
      });
      expect((rt(const StateMessage(cols: {})) as StateMessage).cols, isEmpty);
    });

    test('poke', () {
      expect(rt(const PokeMessage()), isA<PokeMessage>());
    });

    test('ratchet-hello with its signed ephemeral key', () {
      final m = rt(RatchetHelloMessage(
        node: 'n1',
        to: 'n2',
        deviceId: 'DEVICE0123456789',
        ephemeral: List<int>.generate(32, (i) => i),
        keyTag: List<int>.generate(8, (i) => 0xF0 + i),
        signature: List<int>.generate(64, (i) => 0x80 + i),
      )) as RatchetHelloMessage;
      expect(m.node, 'n1');
      expect(m.to, 'n2');
      expect(m.deviceId, 'DEVICE0123456789');
      expect(m.ephemeral, List<int>.generate(32, (i) => i));
      expect(m.keyTag, List<int>.generate(8, (i) => 0xF0 + i));
      expect(m.signature, List<int>.generate(64, (i) => 0x80 + i));
    });

    test('handshake with versions, capabilities, and a device key', () {
      final m = rt(HandshakeMessage(
        node: 'n1',
        versions: const [2, 3],
        capabilities: const ['recon1', 'future-thing'],
        devicePublicKey: List<int>.generate(64, (i) => i),
      )) as HandshakeMessage;
      expect(m.node, 'n1');
      expect(m.versions, [2, 3]);
      expect(m.capabilities, ['recon1', 'future-thing']);
      expect(m.devicePublicKey, List<int>.generate(64, (i) => i));

      final bare = rt(const HandshakeMessage(node: 'n2', versions: [1]))
          as HandshakeMessage;
      expect(bare.capabilities, isEmpty);
      expect(bare.devicePublicKey, isNull);
    });

    test('reconcile with probes and send-ranges, including open bounds', () {
      const a = '2026-01-01T00:00:00.000Z-0000-node-a';
      const b = '2026-01-02T00:00:00.000Z-002A-node-b';
      final m = rt(ReconcileMessage(
        col: 'docs',
        probes: [
          (null, b, 0, 41, List<int>.filled(16, 7)),
          (a, null, 3, 0, List<int>.filled(16, 0)),
        ],
        sendRanges: const [(null, null), (a, b)],
      )) as ReconcileMessage;
      expect(m.col, 'docs');
      expect(m.probes, hasLength(2));
      expect(m.probes[0].$1, isNull);
      expect(m.probes[0].$2, b);
      expect(m.probes[0].$4, 41);
      expect(m.probes[1].$3, 3);
      expect(m.sendRanges, [(null, null), (a, b)]);
    });

    test('delta with every value shape', () {
      final records = <Map<String, dynamic>>[
        {
          'key': 'a',
          'value': {
            'title': 'milk 🥛',
            'done': false,
            'qty': 3,
            'negative': -42,
            'big': 4503599627370495, // 2^52 - 1: exact even as a JS double.
            'ratio': 0.25,
            'nothing': null,
            'tags': ['a', 1, true, null, 2.5],
            'nested': {
              'deep': {'er': 'still here'},
            },
          },
          'is_deleted': false,
          'hlc': _hlc,
        },
        {
          'key': 'b',
          'value': true,
          'is_deleted': true,
          'hlc': _hlc,
          'crdt_type': 'lww',
        },
      ];
      final m =
          rt(DeltaMessage(col: 'items', records: records)) as DeltaMessage;
      expect(m.col, 'items');
      expect(m.records, hasLength(2));
      // The HLC comes back parsed, everything else byte-identical in meaning.
      expect(m.records[0]['hlc'], isA<Hlc>());
      expect(m.records[0]['hlc'].toString(), _hlc.toString());
      expect(m.records[0]['value'], records[0]['value']);
      expect(m.records[0].containsKey('crdt_type'), isFalse);
      expect(m.records[1]['is_deleted'], isTrue);
      expect(m.records[1]['crdt_type'], 'lww');

      // And the changeset parser accepts the decoded records directly.
      final changeset = parseDeltaChangeset(m.col, m.records);
      expect(changeset['items'], hasLength(2));
    });
  });

  test('a delta frame is materially smaller than the JSON it replaced', () {
    final records = [for (var i = 0; i < 50; i++) _record(i)];
    final binary = encodeMessage(DeltaMessage(col: 'items', records: records));

    // The v1 JSON encoding of the same message, reconstructed for comparison.
    final json = utf8.encode(jsonEncode({
      'v': 1,
      'type': 'delta',
      'col': 'items',
      'records': [
        for (final r in records) {...r, 'hlc': r['hlc'].toString()},
      ],
    }));

    expect(
      binary.length,
      lessThan((json.length * 0.75).round()),
      reason: 'binary ${binary.length}B vs JSON ${json.length}B',
    );
  });

  group('decodeMessage fails closed', () {
    test('on a JSON payload', () {
      expect(
        decodeMessage(utf8.encode(jsonEncode({
          'type': 'hello',
          'node': 'n1',
        }))),
        isNull,
      );
    });

    test('on a wrong version byte', () {
      final frame = encodeMessage(const PokeMessage());
      expect(decodeMessage([frame[0], 99, ...frame.skip(2)]), isNull);
    });

    test('on a version-1 frame other than the handshake', () {
      // A 1.0 peer's sync frames must never be acted on.
      final frame = encodeMessage(const PokeMessage());
      expect(frame[1], 2);
      expect(decodeMessage([frame[0], 1, ...frame.skip(2)]), isNull);
    });

    test('the handshake stays readable by version-1 peers', () {
      // Its layout is unchanged; frame version 1 is what lets a 1.0 peer read
      // this build's versions and report PeerIncompatible.
      final frame =
          encodeMessage(const HandshakeMessage(node: 'n', versions: [2]));
      expect(frame[1], 1);
      expect(decodeMessage([frame[0], 2, ...frame.skip(2)]), isNull);
    });

    test('on an HLC that would be misread', () {
      // A zone-less date is read in the receiver's local zone, and a counter
      // above 0xFFFF leaves a clock that adopts it unable to advance.
      for (final hlc in [
        '2026-01-01T00:00:00.000-0000-node',
        '2026-01-01T00:00:00.000Z-10000-node',
        '2026-01-01T00:00:00.000Z-node',
        'garbage',
      ]) {
        final record = {..._record(1), 'hlc': hlc};
        final frame = encodeMessage(DeltaMessage(col: 'c', records: [record]));
        expect(decodeMessage(frame), isNull, reason: hlc);
        expect(
          decodeMessage(encodeMessage(StateMessage(cols: {'c': hlc}))),
          isNull,
          reason: hlc,
        );
      }
      // The counter limit itself is fine.
      final edge = {..._record(1), 'hlc': '2026-01-01T00:00:00.000Z-FFFF-n'};
      expect(
        decodeMessage(encodeMessage(DeltaMessage(col: 'c', records: [edge]))),
        isNotNull,
      );
    });

    test('on trailing garbage after a valid frame', () {
      final frame = encodeMessage(const HelloMessage(node: 'n'));
      expect(decodeMessage([...frame, 0x00]), isNull);
    });

    test('on every truncation of valid frames', () {
      final frames = [
        encodeMessage(const HelloMessage(node: 'node-1')),
        encodeMessage(const StateMessage(
            cols: {'items': '2026-09-10T12:00:00.000Z-0000-n'})),
        encodeMessage(DeltaMessage(col: 'c', records: [_record(1)])),
        encodeMessage(RatchetHelloMessage(
          node: 'n',
          to: 'm',
          deviceId: 'd',
          ephemeral: List<int>.filled(32, 7),
          keyTag: List<int>.filled(8, 3),
          signature: List<int>.filled(64, 9),
        )),
        encodeMessage(const HandshakeMessage(
          node: 'n',
          versions: [1],
          capabilities: ['recon1'],
        )),
        encodeMessage(ReconcileMessage(
          col: 'c',
          probes: [
            (
              '2026-01-01T00:00:00.000Z-0000-a',
              null,
              1,
              5,
              List<int>.filled(16, 1),
            ),
          ],
          sendRanges: const [
            (
              '2026-01-01T00:00:00.000Z-0000-a',
              '2026-01-02T00:00:00.000Z-0000-b',
            ),
          ],
        )),
      ];
      for (final frame in frames) {
        expect(decodeMessage(frame), isNotNull);
        for (var cut = 0; cut < frame.length; cut++) {
          expect(decodeMessage(frame.sublist(0, cut)), isNull,
              reason: 'truncated at $cut of ${frame.length}');
        }
      }
    });

    test('on random bytes (fuzz, fixed seed)', () {
      final rng = Random(20260910);
      for (var i = 0; i < 5000; i++) {
        final bytes = List<int>.generate(
          rng.nextInt(300),
          (_) => rng.nextInt(256),
        );
        // Must not throw; a lucky random valid frame is fine.
        decodeMessage(bytes);
      }
    });

    test('on random single-byte corruptions of a valid frame (fuzz)', () {
      final frame =
          encodeMessage(DeltaMessage(col: 'items', records: [_record(3)]));
      final rng = Random(42);
      for (var i = 0; i < 2000; i++) {
        final corrupted = List<int>.of(frame);
        corrupted[rng.nextInt(corrupted.length)] = rng.nextInt(256);
        // Must not throw; decoding may return null or a differing message.
        decodeMessage(corrupted);
      }
    });

    test('on a deep nesting bomb', () {
      // A frame claiming a 500-deep list must be rejected, not recursed into.
      final bomb = <int>[
        0xC7, 2, 3, // magic, version, delta
        1, 'c'.codeUnitAt(0), // col 'c'
        1, // one record
        0, // flags
        1, 'k'.codeUnitAt(0), // key
        1, '0'.codeUnitAt(0), // hlc (invalid, but nesting is checked first)
        ...List.filled(500, 6), // list-of-list-of-list...
      ];
      expect(decodeMessage(bomb), isNull);
    });
  });
}
