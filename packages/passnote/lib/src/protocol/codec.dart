/// Binary wire codec for [ProtocolMessage]s.
///
/// Every frame is `magic (0xC7) ‖ version (0x02) ‖ type ‖ body`, with all
/// variable-length fields length-prefixed by a varint — no delimiters to
/// escape and no application-level chunking. Record values are arbitrary
/// JSON-shaped data, encoded with a compact tagged encoding ([_writeValue]).
///
/// Varints use arithmetic (`~/`, `%`) rather than bit shifts: compiled to
/// JavaScript, bitwise operators truncate to 32 bits, and values such as
/// microsecond timestamps do not fit.
///
/// [decodeMessage] is fail-closed: malformed, truncated, unknown, or
/// wrong-version input returns `null`, never throws. See the fuzz cases in
/// `protocol_codec_test.dart`.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crdt/crdt.dart';

import 'messages.dart';

/// The first byte of every binary frame. Rejects foreign payloads (JSON
/// starts with `{`) before any parsing work.
const int _magic = 0xC7;

/// Wire protocol version carried in every frame.
const int wireVersion = 2;

/// The frame version a [HandshakeMessage] is always written with. Its layout
/// has not changed since version 1, and keeping it readable by version-1 peers
/// is what lets them see this build's versions and report `PeerIncompatible`
/// instead of silently never syncing.
const int _handshakeFrameVersion = 1;

// Message type tags.
const int _tagHello = 1;
const int _tagState = 2;
const int _tagDelta = 3;
const int _tagPoke = 4;
const int _tagRatchetHello = 5;
const int _tagHandshake = 6;
const int _tagReconcile = 7;

// Value type tags for the tagged value encoding.
const int _valNull = 0;
const int _valFalse = 1;
const int _valTrue = 2;
const int _valInt = 3;
const int _valDouble = 4;
const int _valString = 5;
const int _valList = 6;
const int _valMap = 7;

/// Deeper nesting than this in a value is rejected on decode: real documents
/// never approach it, and it keeps a hostile frame from overflowing the stack.
const int _maxValueDepth = 64;

/// Encodes a [ProtocolMessage] to its binary frame.
List<int> encodeMessage(ProtocolMessage msg) {
  final w = _Writer()
    ..byte(_magic)
    ..byte(msg is HandshakeMessage ? _handshakeFrameVersion : wireVersion);
  switch (msg) {
    case HelloMessage(:final node):
      w
        ..byte(_tagHello)
        ..string(node);
    case StateMessage(:final cols):
      w
        ..byte(_tagState)
        ..varint(cols.length);
      for (final entry in cols.entries) {
        w
          ..string(entry.key)
          ..string(entry.value);
      }
    case DeltaMessage(:final col, :final records):
      w
        ..byte(_tagDelta)
        ..string(col)
        ..varint(records.length);
      for (final record in records) {
        _writeRecord(w, record);
      }
    case PokeMessage():
      w.byte(_tagPoke);
    case RatchetHelloMessage(
        :final node,
        :final to,
        :final deviceId,
        :final ephemeral,
        :final keyTag,
        :final signature
      ):
      w
        ..byte(_tagRatchetHello)
        ..string(node)
        ..string(to)
        ..string(deviceId)
        ..bytes(ephemeral)
        ..bytes(keyTag)
        ..bytes(signature);
    case HandshakeMessage(
        :final node,
        :final versions,
        :final capabilities,
        :final devicePublicKey
      ):
      w
        ..byte(_tagHandshake)
        ..string(node)
        ..varint(versions.length);
      for (final version in versions) {
        w.varint(version);
      }
      w.varint(capabilities.length);
      for (final capability in capabilities) {
        w.string(capability);
      }
      if (devicePublicKey == null) {
        w.byte(0);
      } else {
        w
          ..byte(1)
          ..bytes(devicePublicKey);
      }
    case ReconcileMessage(:final col, :final probes, :final sendRanges):
      w
        ..byte(_tagReconcile)
        ..string(col)
        ..varint(probes.length);
      for (final (from, to, depth, count, fingerprint) in probes) {
        _writeBound(w, from);
        _writeBound(w, to);
        w
          ..varint(depth)
          ..varint(count)
          ..bytes(fingerprint);
      }
      w.varint(sendRanges.length);
      for (final (from, to) in sendRanges) {
        _writeBound(w, from);
        _writeBound(w, to);
      }
  }
  return w.take();
}

/// An optional HLC bound: presence byte, then the string.
void _writeBound(_Writer w, String? bound) {
  if (bound == null) {
    w.byte(0);
  } else {
    w
      ..byte(1)
      ..string(bound);
  }
}

String? _readBound(_Reader r) => r.byte() == 0 ? null : r.string();

/// Decodes a binary frame back into a [ProtocolMessage].
///
/// Returns `null` — never throws — for anything that is not a well-formed
/// frame of a known type and version, so a peer that holds the key but sends
/// garbage cannot crash the receiving node.
ProtocolMessage? decodeMessage(List<int> bytes) {
  try {
    final r = _Reader(bytes);
    if (r.byte() != _magic) return null;
    final version = r.byte();
    final tag = r.byte();
    final expected =
        tag == _tagHandshake ? _handshakeFrameVersion : wireVersion;
    if (version != expected) return null;
    final ProtocolMessage? message = switch (tag) {
      _tagHello => HelloMessage(node: r.string()),
      _tagState => StateMessage(cols: {
          for (var i = r.varint(); i > 0; i--) r.string(): r.string(),
        }),
      _tagDelta => DeltaMessage(
          col: r.string(),
          records: [
            for (var i = r.varint(); i > 0; i--) _readRecord(r),
          ],
        ),
      _tagPoke => const PokeMessage(),
      _tagRatchetHello => RatchetHelloMessage(
          node: r.string(),
          to: r.string(),
          deviceId: r.string(),
          ephemeral: r.bytesField(),
          keyTag: r.bytesField(),
          signature: r.bytesField(),
        ),
      _tagHandshake => HandshakeMessage(
          node: r.string(),
          versions: [
            for (var i = r.varint(); i > 0; i--) r.varint(),
          ],
          capabilities: [
            for (var i = r.varint(); i > 0; i--) r.string(),
          ],
          devicePublicKey: r.byte() == 0 ? null : r.bytesField(),
        ),
      _tagReconcile => ReconcileMessage(
          col: r.string(),
          probes: [
            for (var i = r.varint(); i > 0; i--)
              (
                _readBound(r),
                _readBound(r),
                r.varint(),
                r.varint(),
                r.bytesField()
              ),
          ],
          sendRanges: [
            for (var i = r.varint(); i > 0; i--) (_readBound(r), _readBound(r)),
          ],
        ),
      _ => null,
    };
    if (message == null || !r.atEnd) return null;
    return message;
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Records

const int _flagDeleted = 0x01;
const int _flagHasCrdtType = 0x02;

/// Record layout: flags ‖ key ‖ hlc ‖ [crdt_type] ‖ value. The HLC travels in
/// its string form and is parsed back to an [Hlc] on decode, matching what
/// `parseCrdtChangeset` produces.
void _writeRecord(_Writer w, Map<String, dynamic> record) {
  final crdtType = record['crdt_type'] as String?;
  var flags = 0;
  if (record['is_deleted'] == true) flags |= _flagDeleted;
  if (crdtType != null) flags |= _flagHasCrdtType;
  w
    ..byte(flags)
    ..string(record['key'] as String)
    ..string(record['hlc'].toString());
  if (crdtType != null) w.string(crdtType);
  _writeValue(w, record['value']);
}

Map<String, dynamic> _readRecord(_Reader r) {
  final flags = r.byte();
  final key = r.string();
  final hlc = Hlc.parse(r.string());
  final crdtType = (flags & _flagHasCrdtType) != 0 ? r.string() : null;
  return {
    'key': key,
    'value': r.value(),
    'is_deleted': (flags & _flagDeleted) != 0,
    'hlc': hlc,
    if (crdtType != null) 'crdt_type': crdtType,
  };
}

// ---------------------------------------------------------------------------
// Tagged value encoding

void _writeValue(_Writer w, Object? value, [int depth = 0]) {
  if (depth > _maxValueDepth) {
    throw ArgumentError('value nests deeper than $_maxValueDepth levels');
  }
  switch (value) {
    case null:
      w.byte(_valNull);
    case false:
      w.byte(_valFalse);
    case true:
      w.byte(_valTrue);
    case final int n:
      w
        ..byte(_valInt)
        ..zigzag(n);
    case final double d:
      w.byte(_valDouble);
      final data = ByteData(8)..setFloat64(0, d);
      w.raw(data.buffer.asUint8List());
    case final String s:
      w
        ..byte(_valString)
        ..string(s);
    case final List<dynamic> list:
      w
        ..byte(_valList)
        ..varint(list.length);
      for (final element in list) {
        _writeValue(w, element, depth + 1);
      }
    case final Map<dynamic, dynamic> map:
      w
        ..byte(_valMap)
        ..varint(map.length);
      for (final entry in map.entries) {
        w.string(entry.key as String);
        _writeValue(w, entry.value, depth + 1);
      }
    default:
      throw ArgumentError(
        'value of type ${value.runtimeType} is not JSON-shaped',
      );
  }
}

// ---------------------------------------------------------------------------
// Byte plumbing

class _Writer {
  final _out = BytesBuilder(copy: false);

  void byte(int b) => _out.addByte(b);

  void raw(List<int> bytes) => _out.add(bytes);

  /// Unsigned LEB128, written with arithmetic so it survives dart2js.
  void varint(int n) {
    assert(n >= 0);
    var rest = n;
    while (rest >= 0x80) {
      _out.addByte(0x80 + rest % 0x80);
      rest ~/= 0x80;
    }
    _out.addByte(rest);
  }

  /// Signed integer as a zigzag-mapped varint (small magnitudes stay small).
  ///
  /// The zigzag doubling bounds the domain to |n| < 2^62 — beyond every value
  /// that survives a JSON round-trip or a JavaScript runtime anyway.
  void zigzag(int n) {
    if (n >= 0x4000000000000000 || n < -0x4000000000000000) {
      throw ArgumentError.value(n, 'n', 'integer too large for the wire');
    }
    varint(n >= 0 ? n * 2 : -n * 2 - 1);
  }

  void string(String s) => bytes(utf8.encode(s));

  void bytes(List<int> b) {
    varint(b.length);
    _out.add(b);
  }

  List<int> take() => _out.takeBytes();
}

class _Reader {
  _Reader(List<int> bytes)
      : _bytes = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);

  final Uint8List _bytes;
  int _pos = 0;

  bool get atEnd => _pos == _bytes.length;

  int byte() {
    if (_pos >= _bytes.length) throw RangeError('truncated frame');
    return _bytes[_pos++];
  }

  int varint() {
    var value = 0;
    var scale = 1;
    // 9 groups × 7 bits = 63 bits, the full non-negative int range.
    for (var i = 0; i < 9; i++) {
      final b = byte();
      value += (b % 0x80) * scale;
      if (b < 0x80) return value;
      scale *= 0x80;
    }
    throw const FormatException('varint too long');
  }

  int zigzag() {
    final raw = varint();
    return raw.isEven ? raw ~/ 2 : -(raw + 1) ~/ 2;
  }

  Uint8List bytesField() {
    final length = varint();
    if (_pos + length > _bytes.length) throw RangeError('truncated frame');
    final view = Uint8List.sublistView(_bytes, _pos, _pos + length);
    _pos += length;
    return view;
  }

  String string() => utf8.decode(bytesField());

  Object? value([int depth = 0]) {
    if (depth > _maxValueDepth) {
      throw const FormatException('value nests too deep');
    }
    return switch (byte()) {
      _valNull => null,
      _valFalse => false,
      _valTrue => true,
      _valInt => zigzag(),
      _valDouble => _double(),
      _valString => string(),
      _valList => [
          for (var i = varint(); i > 0; i--) value(depth + 1),
        ],
      _valMap => <String, dynamic>{
          for (var i = varint(); i > 0; i--) string(): value(depth + 1),
        },
      final tag => throw FormatException('unknown value tag $tag'),
    };
  }

  double _double() {
    if (_pos + 8 > _bytes.length) throw RangeError('truncated frame');
    final result = ByteData.sublistView(_bytes, _pos, _pos + 8).getFloat64(0);
    _pos += 8;
    return result;
  }
}
