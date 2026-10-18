import 'dart:async';

/// Builds the periodic timer [AntiEntropy] runs on. Injectable so tests can
/// drive ticks by hand; defaults to [Timer.periodic].
typedef AntiEntropyTimerFactory = Timer Function(
  Duration interval,
  void Function() tick,
);

/// The periodic state exchange that heals a dropped frame without a manual
/// `forceSync`.
///
/// Sync is push-based: a frame lost to a flaky link or the inbound rate
/// limiter would otherwise stay lost until the next reconnect. Every
/// [interval], [exchange] runs — a `Hello` to each connected peer, whose
/// state/delta replies carry anything either side is missing. `Duration.zero`
/// disables it ("push only" stays a valid configuration).
///
/// Owned by a `Database`; [stop] is called on close and leave, after which no
/// further exchange runs.
class AntiEntropy {
  /// Creates the exchange driver. Call [start] to begin ticking.
  AntiEntropy({
    required this.interval,
    required Future<void> Function() exchange,
    AntiEntropyTimerFactory timerFactory = _periodic,
  })  : _exchange = exchange,
        _timerFactory = timerFactory;

  static Timer _periodic(Duration interval, void Function() tick) =>
      Timer.periodic(interval, (_) => tick());

  /// Time between exchanges. [Duration.zero] disables the timer entirely.
  final Duration interval;

  final Future<void> Function() _exchange;
  final AntiEntropyTimerFactory _timerFactory;

  Timer? _timer;
  bool _ticking = false;

  /// Whether the periodic timer is currently armed.
  bool get isRunning => _timer?.isActive ?? false;

  /// Arms the timer. A zero (or negative) [interval] is a no-op. Idempotent.
  void start() {
    if (interval <= Duration.zero || _timer != null) return;
    _timer = _timerFactory(interval, tick);
  }

  /// Cancels the timer; no exchange runs after this. Idempotent.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Runs one exchange now. Overlapping ticks collapse: a tick that fires
  /// while the previous exchange is still running is skipped, so a slow peer
  /// cannot pile up exchanges.
  void tick() {
    if (_ticking) return;
    _ticking = true;
    _exchange().whenComplete(() => _ticking = false);
  }
}
