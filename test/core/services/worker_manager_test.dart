import 'dart:async';

import 'package:conduit/core/services/worker_manager.dart';
import 'package:flutter_test/flutter_test.dart';

_ControlledWorkerHarness? _controlledWorkerHarness;

Future<String> _controlledWorkerTask(int jobId) {
  final harness = _controlledWorkerHarness;
  if (harness == null) {
    throw StateError('Controlled worker harness is not configured');
  }
  return harness.run(jobId);
}

String _failingWorkerTask(String _) {
  throw StateError('worker task failed');
}

class _ControlledWorkerHarness {
  final List<int> startOrder = <int>[];
  final Map<int, Completer<String>> _completions = <int, Completer<String>>{};
  int activeJobs = 0;
  int maxActiveJobs = 0;

  Future<String> run(int jobId) async {
    startOrder.add(jobId);
    activeJobs++;
    if (activeJobs > maxActiveJobs) {
      maxActiveJobs = activeJobs;
    }

    try {
      return await _completions
          .putIfAbsent(jobId, Completer<String>.new)
          .future;
    } finally {
      activeJobs--;
    }
  }

  void complete(int jobId, [String? value]) {
    _completions
        .putIfAbsent(jobId, Completer<String>.new)
        .complete(value ?? 'job:$jobId');
  }
}

Future<void> _drainMicrotasks() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  tearDown(() {
    _controlledWorkerHarness = null;
  });

  group('WorkerManager', () {
    test('limits concurrency and preserves FIFO start order', () async {
      final harness = _ControlledWorkerHarness();
      _controlledWorkerHarness = harness;
      final manager = WorkerManager(
        maxConcurrentTasks: 2,
        debugIsWebOverride: true,
      );
      addTearDown(manager.dispose);

      final first = manager.schedule<int, String>(_controlledWorkerTask, 1);
      final second = manager.schedule<int, String>(_controlledWorkerTask, 2);
      final third = manager.schedule<int, String>(_controlledWorkerTask, 3);

      expect(harness.startOrder, <int>[1, 2]);
      expect(harness.activeJobs, 2);
      expect(harness.maxActiveJobs, 2);

      harness.complete(1, 'first');
      expect(await first, 'first');
      await _drainMicrotasks();

      expect(harness.startOrder, <int>[1, 2, 3]);
      expect(harness.activeJobs, 2);

      harness.complete(2, 'second');
      harness.complete(3, 'third');

      expect(await second, 'second');
      expect(await third, 'third');
    });

    test('dispose rejects queued jobs that have not started', () async {
      final harness = _ControlledWorkerHarness();
      _controlledWorkerHarness = harness;
      final manager = WorkerManager(
        maxConcurrentTasks: 1,
        debugIsWebOverride: true,
      );

      final first = manager.schedule<int, String>(_controlledWorkerTask, 1);
      final second = manager.schedule<int, String>(_controlledWorkerTask, 2);

      expect(harness.startOrder, <int>[1]);

      manager.dispose();

      await expectLater(
        second,
        throwsA(
          isA<StateError>().having(
            (error) => error.toString(),
            'message',
            contains('disposed before job 2 started'),
          ),
        ),
      );

      harness.complete(1, 'first');
      expect(await first, 'first');
    });

    test('schedule rejects new jobs after dispose', () async {
      final manager = WorkerManager(debugIsWebOverride: true);
      manager.dispose();

      await expectLater(
        manager.schedule<String, String>((message) => message, 'value'),
        throwsA(
          isA<StateError>().having(
            (error) => error.toString(),
            'message',
            contains('WorkerManager has been disposed'),
          ),
        ),
      );
    });

    test('propagates task errors', () async {
      final manager = WorkerManager(debugIsWebOverride: true);
      addTearDown(manager.dispose);

      await expectLater(
        manager.schedule<String, String>(_failingWorkerTask, 'ignored'),
        throwsA(
          isA<StateError>().having(
            (error) => error.toString(),
            'message',
            contains('worker task failed'),
          ),
        ),
      );
    });

    test('runs the callback synchronously on the web fallback path', () async {
      final manager = WorkerManager(debugIsWebOverride: true);
      addTearDown(manager.dispose);
      var invoked = false;

      final result = await manager.schedule<String, String>((message) {
        invoked = true;
        return 'done:$message';
      }, 'value');

      expect(invoked, isTrue);
      expect(result, 'done:value');
    });
  });
}
