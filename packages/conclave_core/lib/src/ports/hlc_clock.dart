import 'package:crdt/crdt.dart';

/// Provides Hybrid Logical Clock timestamps.
abstract interface class HlcClock {
  /// Returns the current logical timestamp.
  Hlc now();
}

/// System-clock-backed [HlcClock] that delegates to [Hlc.now].
final class SystemHlcClock implements HlcClock {
  /// Creates a clock that tags timestamps with [nodeId].
  SystemHlcClock(this._nodeId);

  final String _nodeId;

  @override
  Hlc now() => Hlc.now(_nodeId);
}
