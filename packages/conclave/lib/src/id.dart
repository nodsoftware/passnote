import 'dart:math';

final Random _rng = Random.secure();

/// Generates a collision-resistant document id.
///
/// Combines a microsecond timestamp with 64 bits of secure randomness, so ids
/// are practically unique across devices without coordination and sort roughly
/// by creation time. Document ids must not contain the NUL character (`\x00`);
/// this generator never produces one.
String newId() {
  final ts = DateTime.now().microsecondsSinceEpoch;
  // 2^32 as a literal: `1 << 32` wraps to 0 when compiled to JavaScript.
  final r = _rng.nextInt(0x100000000);
  final r2 = _rng.nextInt(0x100000000);
  return '$ts-${r.toRadixString(16)}${r2.toRadixString(16)}';
}
