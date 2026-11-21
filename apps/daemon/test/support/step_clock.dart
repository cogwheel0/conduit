import 'dart:async';

/// A clock for [TurnsService]'s waits (its `now` and `pause`) that moves
/// only while the test awaits a step ([during]), never with the wall clock.
///
/// A pause asked during a step ends through the event loop, with the clock
/// at its end, so a loop of pauses lets sockets and timers run between
/// them. Outside a step, pauses stay pending. A pause of a second or more
/// caps a wait on something else and ends only when the test moves the
/// clock past it ([advance]): until then, what it caps decides.
final class StepClock {
  DateTime _now = DateTime.utc(2026, 11, 20, 9);
  final List<({DateTime end, Completer<void> done})> _paused = [];
  final List<({DateTime end, Completer<void> done})> _long = [];
  int _steps = 0;
  bool _releasing = false;

  DateTime now() => _now;

  Future<void> pause(Duration duration) {
    final done = Completer<void>();
    if (duration < const Duration(seconds: 1)) {
      _paused.add((end: _now.add(duration), done: done));
      _releaseSoon();
    } else {
      _long.add((end: _now.add(duration), done: done));
    }
    return done.future;
  }

  /// Moves the clock on by [by], ending the long pauses that end by then.
  void advance(Duration by) {
    _now = _now.add(by);
    final due = [
      for (final pause in _long)
        if (!pause.end.isAfter(_now)) pause,
    ];
    for (final pause in due) {
      _long.remove(pause);
      pause.done.complete();
    }
  }

  /// Awaits [step], with the clock moving until it ends.
  Future<T> during<T>(Future<T> step) async {
    _steps++;
    _releaseSoon();
    try {
      return await step;
    } finally {
      _steps--;
    }
  }

  void _releaseSoon() {
    if (_steps == 0 || _releasing || _paused.isEmpty) return;
    _releasing = true;
    Timer.run(() {
      _releasing = false;
      if (_steps == 0) return;
      final due = [..._paused];
      _paused.clear();
      for (final pause in due) {
        if (pause.end.isAfter(_now)) _now = pause.end;
        pause.done.complete();
      }
    });
  }
}
