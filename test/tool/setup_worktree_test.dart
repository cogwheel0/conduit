import 'dart:async';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/setup_worktree.dart';

class _FakeProcess extends Fake implements Process {
  final Completer<int> exit = Completer<int>();
  final List<ProcessSignal> signals = <ProcessSignal>[];

  @override
  Future<int> get exitCode => exit.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    signals.add(signal);
    return true;
  }
}

void main() {
  test('stopAll kills a program that ignores the signal, and waits for it', () {
    fakeAsync((async) {
      final stubborn = _FakeProcess();
      var returned = false;
      stopAll(
        [stubborn],
        ProcessSignal.sigterm,
        grace: const Duration(seconds: 10),
      ).then((_) => returned = true);

      async.elapse(const Duration(seconds: 9));
      check(stubborn.signals).deepEquals([ProcessSignal.sigterm]);

      async.elapse(const Duration(seconds: 1));
      check(stubborn.signals)
          .deepEquals([ProcessSignal.sigterm, ProcessSignal.sigkill]);
      // Killed, but still exiting: the caller must not write its marker yet.
      check(returned).isFalse();

      stubborn.exit.complete(-9);
      async.flushMicrotasks();
      check(returned).isTrue();
    });
  });

  test('stop also stops a program that was still starting', () {
    fakeAsync((async) {
      final starting = Completer<Process>();
      final launcher = Launcher((_, _, _) => starting.future);
      launcher.start('generator', const [], '.').ignore();
      var stopped = false;
      launcher.stop(ProcessSignal.sigterm).then((_) => stopped = true);
      async.flushMicrotasks();
      check(stopped).isFalse();

      final late = _FakeProcess();
      starting.complete(late);
      async.flushMicrotasks();
      check(late.signals).deepEquals([ProcessSignal.sigterm]);
      check(stopped).isFalse();

      late.exit.complete(-15);
      async.flushMicrotasks();
      check(stopped).isTrue();

      Object? refused;
      launcher.start('generator', const [], '.').catchError((Object error) {
        refused = error;
        return late;
      });
      async.flushMicrotasks();
      check(refused).isA<StateError>();
    });
  });
}
