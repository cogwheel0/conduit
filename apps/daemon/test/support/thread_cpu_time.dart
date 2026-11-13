import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Microseconds of the calling thread's CPU time
/// (`clock_gettime(CLOCK_THREAD_CPUTIME_ID)` on macOS and Linux), or of
/// wall-clock time where that clock is missing ([threadCpuTimeAvailable]).
///
/// Synchronous code stays on one thread, so two readings around it give the
/// work it did however busy the machine is; wall-clock time also counts the
/// waits for a core, which a loaded machine (CI's, say) makes long. The
/// desktop's frame tests measure the same way.
int threadCpuMicros() {
  final clockGettime = _clockGettime;
  if (clockGettime == null || clockGettime(_clockId, _time) != 0) {
    return _wall.elapsedMicroseconds;
  }
  return _time.ref.seconds * Duration.microsecondsPerSecond +
      _time.ref.nanoseconds ~/ 1000;
}

/// Whether [threadCpuMicros] reads CPU time on this machine.
bool get threadCpuTimeAvailable {
  final clockGettime = _clockGettime;
  return clockGettime != null && clockGettime(_clockId, _time) == 0;
}

final class _Timespec extends Struct {
  @Long()
  external int seconds;

  @Long()
  external int nanoseconds;
}

typedef _ClockGettimeC = Int32 Function(Int32, Pointer<_Timespec>);
typedef _ClockGettime = int Function(int, Pointer<_Timespec>);

/// CLOCK_THREAD_CPUTIME_ID: 16 in Darwin's `time.h`, 3 in Linux's.
final int _clockId = Platform.isMacOS ? 16 : 3;

final _ClockGettime? _clockGettime = () {
  if (!Platform.isMacOS && !Platform.isLinux) return null;
  try {
    return DynamicLibrary.process()
        .lookupFunction<_ClockGettimeC, _ClockGettime>('clock_gettime');
  } on Object {
    return null;
  }
}();

/// One reading's buffer, kept for the test process's life.
final Pointer<_Timespec> _time = calloc<_Timespec>();

final Stopwatch _wall = Stopwatch()..start();
