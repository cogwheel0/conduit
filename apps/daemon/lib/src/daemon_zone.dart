import 'dart:async';

/// Runs [body], the whole daemon, in one guarded error zone, and returns
/// whatever [body] returns.
///
/// Two failures made this necessary. In both, the daemon exited 255 when
/// the server could not be reached at launch:
///
/// * An asynchronous error that nothing handles ends a plain Dart
///   process. An example is a fire-and-forget refresh inside the core that
///   fails. Flutter only logs such errors, so mobile never noticed them.
///   The daemon now does the same: each one goes to [onStray], and the
///   daemon keeps serving.
/// * Dart never delivers a future's error across error zones. It reports
///   the error as uncaught in the future's own zone instead. When shelf is
///   started from the root zone, it runs every request in a guarded zone of
///   its own. So an RPC handler that awaited a provider's future could not
///   receive the error when that future failed in the core's root zone:
///   `models.list` read the model list just as the refresh behind the
///   cached list failed, and the error was uncaught at the root. When
///   shelf is started inside this zone, it adds no zone of its own, so
///   handlers receive errors as they should.
///
/// The real fatal paths are unaffected. A bad bootstrap line, a port that
/// cannot be bound or an unreadable secure store are not stray errors:
/// [body] returns an exit code for each of those.
Future<T> runDaemonZone<T>(
  Future<T> Function() body, {
  required void Function(Object error, StackTrace stack) onStray,
}) {
  // Made outside the zone, so whoever awaits it, outside too, gets the
  // result, and an error from [body] arrives as an error, not as a stray one.
  final result = Completer<T>();
  runZonedGuarded(
    () {
      body().then(result.complete, onError: result.completeError);
    },
    (error, stack) {
      try {
        onStray(error, stack);
      } on Object {
        // Reporting a stray error must never raise another one.
      }
    },
  );
  return result.future;
}

/// The first [maxFrames] lines of [stack], for a log line about a stray
/// error: enough to find the code, without a page of async plumbing.
String trimStack(StackTrace stack, {int maxFrames = 24}) {
  final lines = stack
      .toString()
      .split('\n')
      .where((line) => line.trim().isNotEmpty)
      .toList(growable: false);
  if (lines.length <= maxFrames) return lines.join('\n');
  return <String>[
    ...lines.take(maxFrames),
    '… ${lines.length - maxFrames} more',
  ].join('\n');
}
