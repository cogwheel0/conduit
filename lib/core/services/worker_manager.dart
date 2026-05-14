import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../utils/debug_logger.dart';

part 'worker_manager.g.dart';

/// Signature of a task that can be executed by [WorkerManager].
typedef WorkerTask<Q, R> = ComputeCallback<Q, R>;

/// Coordinates CPU intensive work off the UI isolate with lightweight pooling.
///
/// The manager throttles concurrent isolate usage to avoid overwhelming the
/// platform while still enabling parallel work. On web the callback executes
/// synchronously because secondary isolates are not supported.
class WorkerManager {
  WorkerManager({int maxConcurrentTasks = _defaultMaxConcurrentTasks})
    : _maxConcurrentTasks = math.max(1, maxConcurrentTasks);

  static const int _defaultMaxConcurrentTasks = 2;

  final int _maxConcurrentTasks;
  final Queue<_EnqueuedJob> _pendingJobs = Queue<_EnqueuedJob>();
  bool _disposed = false;
  int _activeJobs = 0;
  int _jobCounter = 0;

  /// Schedule [callback] with [message] to run on a worker isolate.
  ///
  /// The [callback] must be a top-level or static function, mirroring the
  /// constraints of `compute`. Errors from the task are propagated to the
  /// returned [Future].
  Future<R> schedule<Q, R>(
    WorkerTask<Q, R> callback,
    Q message, {
    String? debugLabel,
  }) {
    if (_disposed) {
      return Future.error(StateError('WorkerManager has been disposed'));
    }

    final jobId = ++_jobCounter;
    final completer = Completer<R>();
    final job = _EnqueuedJob(
      id: jobId,
      debugLabel: debugLabel,
      run: () {
        if (kIsWeb) {
          return Future<R>.sync(() => callback(message));
        }
        return compute(callback, message);
      },
      onComplete: (value) {
        if (!completer.isCompleted) {
          completer.complete(value as R);
        }
      },
      onError: (error, stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      },
    );

    _pendingJobs.add(job);
    _processQueue();

    return completer.future;
  }

  /// Dispose the manager and reject all pending work.
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;

    while (_pendingJobs.isNotEmpty) {
      final job = _pendingJobs.removeFirst();
      job.cancel(
        StateError('WorkerManager disposed before job ${job.id} started'),
      );
    }
  }

  void _processQueue() {
    if (_disposed) {
      return;
    }

    while (_activeJobs < _maxConcurrentTasks && _pendingJobs.isNotEmpty) {
      final job = _pendingJobs.removeFirst();
      _startJob(job);
    }
  }

  void _startJob(_EnqueuedJob job) {
    _activeJobs++;
    unawaited(_runJob(job));
  }

  Future<void> _runJob(_EnqueuedJob job) async {
    try {
      final result = await job.run();
      job.onComplete(result);
    } catch (error, stackTrace) {
      job.onError(error, stackTrace);

      DebugLogger.error(
        'failed',
        scope: 'worker',
        error: error,
        stackTrace: stackTrace,
        data: {
          'id': job.id,
          if (job.debugLabel != null) 'label': job.debugLabel,
        },
      );
    } finally {
      _activeJobs = math.max(0, _activeJobs - 1);
      _processQueue();
    }
  }
}

/// Keep a single [WorkerManager] alive across the app.
@Riverpod(keepAlive: true)
class WorkerManagerNotifier extends _$WorkerManagerNotifier {
  @override
  WorkerManager build() {
    final concurrency = kIsWeb ? 1 : WorkerManager._defaultMaxConcurrentTasks;
    final manager = WorkerManager(maxConcurrentTasks: concurrency);
    ref.onDispose(manager.dispose);
    return manager;
  }
}

class _EnqueuedJob {
  _EnqueuedJob({
    required this.id,
    required this.run,
    required this.onComplete,
    required this.onError,
    this.debugLabel,
  });

  final int id;
  final FutureOr<dynamic> Function() run;
  final void Function(dynamic value) onComplete;
  final void Function(Object error, StackTrace stackTrace) onError;
  final String? debugLabel;
  final DateTime queuedAt = DateTime.now();

  void cancel(Object error) {
    onError(error, StackTrace.current);
  }
}
