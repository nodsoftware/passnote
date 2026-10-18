import 'dart:async';
import 'dart:collection';

/// A per-peer send window: frames go out strictly in order, and at most
/// [capacity] may be queued or in flight at once.
///
/// [enqueue] returns once the frame is *admitted* — immediately while the
/// window has room, otherwise only after enough earlier frames have completed.
/// That await is the backpressure: a producer streaming a large changeset to a
/// slow peer pauses instead of buffering without bound.
///
/// The strict FIFO order also protects the transport ratchet, whose hash chain
/// assumes frames arrive in the order they were sealed.
class FrameWindow {
  /// Creates a window admitting at most [capacity] outstanding frames.
  FrameWindow({required this.capacity}) {
    if (capacity < 1) {
      throw ArgumentError.value(capacity, 'capacity', 'must be at least 1');
    }
  }

  /// Maximum queued-or-in-flight frames.
  final int capacity;

  int _outstanding = 0;
  Future<void> _chain = Future<void>.value();
  final Queue<Completer<void>> _gates = Queue();

  /// Frames admitted but not yet completed.
  int get outstanding => _outstanding;

  /// Admits [send] into the window, awaiting room first, and runs it after
  /// every previously admitted frame has completed.
  ///
  /// A [send] failure is contained: it neither breaks the chain for later
  /// frames nor surfaces here (the transport layer owns delivery errors).
  Future<void> enqueue(Future<void> Function() send) async {
    while (_outstanding >= capacity) {
      final gate = Completer<void>();
      _gates.add(gate);
      await gate.future;
    }
    _outstanding++;
    _chain = _chain.then((_) async {
      try {
        await send();
      } catch (_) {
        // Delivery errors belong to the transport; the stream continues.
      } finally {
        _outstanding--;
        if (_gates.isNotEmpty) _gates.removeFirst().complete();
      }
    });
  }

  /// Completes when every admitted frame has finished sending.
  Future<void> get drained => _chain;
}
