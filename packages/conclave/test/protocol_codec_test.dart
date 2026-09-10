import 'dart:convert';
import 'dart:math';

import 'package:conclave/src/protocol/messages.dart';
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

    test('ratchet-hello with its nonce', () {
      final m = rt(RatchetHelloMessage(
        node: 'n1',
        nonce: List<int>.generate(16, (i) => i),
        keyTag: List<int>.generate(8, (i) => 0xF0 + i),
      )) as RatchetHelloMessage;
      expect(m.node, 'n1');
      expect(m.nonce, List<int>.generate(16, (i) => i));
      expect(m.keyTag, List<int>.generate(8, (i) => 0xF0 + i));
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
    test('on the old JSON (wire version 1) frames', () {
      expect(
        decodeMessage(utf8.encode(jsonEncode({
          'v': 1,
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

    test('on trailing garbage after a valid frame', () {
      final frame = encodeMessage(const HelloMessage(node: 'n'));
      expect(decodeMessage([...frame, 0x00]), isNull);
    });

    test('on every truncation of valid frames', () {
      final frames = [
        encodeMessage(const HelloMessage(node: 'node-1')),
        encodeMessage(const StateMessage(cols: {'items': 'x'})),
        encodeMessage(DeltaMessage(col: 'c', records: [_record(1)])),
        encodeMessage(RatchetHelloMessage(
          node: 'n',
          nonce: List<int>.filled(16, 7),
          keyTag: List<int>.filled(8, 3),
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
