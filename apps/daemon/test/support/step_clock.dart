import 'dart:async';

/// A clock for [TurnsService]'s waits (its `now` and `pause`) that moves
/// only while the test awaits a step ([during]), never with the wall clock.
///
/// A pause asked during a step ends through the event loop, with the clock
/// at its end, so a loop of pauses lets sockets and timers run between
/// them. Outside a step, pauses stay pending. A pause of a second or more
/// caps a wait on something else and never ends: what it caps decides.
final class StepClock {
  DateTime _now = DateTime.utc(2026, 11, 20, 9);
  final List<({DateTime end, Completer<void> done})> _paused = [];
  int _steps = 0;
  bool _releasing = false;

  DateTime now() => _now;

  Future<void> pause(Duration duration) {
    final done = Completer<void>();
    if (duration < const Duration(seconds: 1)) {
      _paused.add((end: _now.add(duration), done: done));
      _releaseSoon();
    }
    return done.future;
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
