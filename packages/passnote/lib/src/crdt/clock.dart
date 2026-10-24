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
