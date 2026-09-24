import 'dart:async';

/// A simple activity-based watchdog.
///
/// Call [ping] whenever activity occurs. If no activity happens
/// within [window], [onTimeout] fires. Optionally, an [absoluteCap]
/// enforces a maximum total duration regardless of activity.
///
/// The [onTimeout] callback can be sync or async - if async, it will be
/// awaited before the watchdog considers itself fully stopped.
class InactivityWatchdog {
  InactivityWatchdog({
    required Duration window,
    required this.onTimeout,
    Duration? absoluteCap,
  }) : _window = window,
       _absoluteCap = absoluteCap;

  final FutureOr<void> Function() onTimeout;

  Duration _window;
  Duration? _absoluteCap;
  Timer? _timer;
  Timer? _absoluteTimer;
  bool _started = false;
  bool _firing = false;

  Duration get window => _window;

  /// Whether the timeout callback is currently executing.
  bool get isFiring => _firing;

  void setWindow(Duration newWindow) {
    _window = newWindow;
    if (_started) {
      // Restart timer with new window
      _restart();
    }
  }

  void setAbsoluteCap(Duration? cap) {
    _absoluteCap = cap;
    if (_started) {
      _absoluteTimer?.cancel();
      if (_absoluteCap != null) {
        _absoluteTimer = Timer(_absoluteCap!, _fire);
      }
    }
  }

  void start() {
    if (_started) return;
    // Prevent restart while callback is still executing to avoid double-fire
    if (_firing) return;
    _started = true;
    _restart();
    if (_absoluteCap != null) {
      _absoluteTimer = Timer(_absoluteCap!, _fire);
    }
  }

  void ping() {
    // Prevent restart while callback is still executing to avoid double-fire
    if (_firing) return;
    if (!_started) {
      start();
      return;
    }
    _restart();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _absoluteTimer?.cancel();
    _absoluteTimer = null;
    _started = false;
  }

  void dispose() => stop();

  void _restart() {
    _timer?.cancel();
    _timer = Timer(_window, _fire);
  }

  /// Synchronous entry point called by Timer. Kicks off async work.
  void _fire() {
    if (_firing) return; // Prevent re-entry
    _firing = true;
    stop();
    // Execute the callback asynchronously. We don't await because Timer
    // expects a sync callback, but the async work will complete in background.
    _executeCallback();
  }

  /// Executes the timeout callback asynchronously.
  Future<void> _executeCallback() async {
    try {
      await onTimeout();
    } catch (_) {
      // Swallow errors to prevent unhandled exceptions
    } finally {
      _firing = false;
    }
  }
}
