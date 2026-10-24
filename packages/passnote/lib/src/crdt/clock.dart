import 'package:crdt/crdt.dart';

/// The local clock advanced for one write, with counter overflow handled.
///
/// [Hlc.increment] keeps the time and raises the counter while the wall clock
/// has not passed the clock, and throws once the counter would exceed 0xFFFF.
/// A clock that adopted a received record at the counter limit, slightly
/// ahead of the wall clock, would then fail every local write until the wall
/// clock caught up. Moving to the next microsecond with a fresh counter keeps
/// the clock monotonic and the write possible. Every Passnote implementation
/// applies this same rule so their clocks advance identically.
Hlc incrementClock(Hlc clock, {DateTime? wallTime}) {
  try {
    return clock.increment(wallTime: wallTime);
  } on OverflowException {
    return Hlc(
      clock.dateTime.add(const Duration(microseconds: 1)),
      0,
      clock.nodeId,
    );
  }
}

/// [text] parsed as an HLC, refusing what `Hlc.parse` would accept but
/// misread: a date without a time zone (read in the receiver's local zone, so
/// two devices would see different instants) and a counter above 0xFFFF (the
/// `Hlc` constructor checks that only in debug builds, and a clock that
/// adopts one can no longer advance).
Hlc parseStrictHlc(String text) {
  final counterDash = text.indexOf('-', text.lastIndexOf(':'));
  final nodeIdDash = counterDash < 0 ? -1 : text.indexOf('-', counterDash + 1);
  if (counterDash < 0 || nodeIdDash < 0) {
    throw const FormatException('malformed HLC');
  }
  if (!text.substring(0, counterDash).endsWith('Z')) {
    throw const FormatException('HLC without a time zone');
  }
  final counterText = text.substring(counterDash + 1, nodeIdDash);
  final counter = int.tryParse(counterText, radix: 16);
  if (counterText.isEmpty ||
      counterText.length > 4 ||
      counter == null ||
      counter < 0) {
    throw const FormatException('HLC counter out of range');
  }
  return Hlc.parse(text);
}
