import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/persistence/persistence_providers.dart';
import '../../../core/persistence/hive_boxes.dart';
import '../../../core/services/connectivity_service.dart';
import 'outbound_task.dart';
import 'task_worker.dart';
import '../../../core/utils/debug_logger.dart';

final taskQueueProvider =
    NotifierProvider<TaskQueueNotifier, List<OutboundTask>>(
      TaskQueueNotifier.new,
    );

class TaskQueueNotifier extends Notifier<List<OutboundTask>> {
  static const _storageKey = HiveStoreKeys.taskQueue;
  final _uuid = const Uuid();
  bool _bootstrapScheduled = false;
  Timer? _drainTimer;

  // Phase 2.3 backoff schedule (indexed by attempt count). Beyond the last
  // entry the final value is reused so the cap is one hour.
  static const List<Duration> _backoff = <Duration>[
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 5),
    Duration(minutes: 15),
    Duration(hours: 1),
  ];

  @override
  List<OutboundTask> build() {
    if (!_bootstrapScheduled) {
      _bootstrapScheduled = true;
      Future.microtask(_load);
    }
    // Phase 2.3: periodic drain so tasks scheduled for delayed retry resume
    // even when nothing else triggers a queue tick. The timer is keepAlive-d
    // by the Notifier lifecycle and torn down on dispose.
    _drainTimer ??= Timer.periodic(const Duration(seconds: 30), (_) {
      _process();
    });
    ref.onDispose(() {
      _drainTimer?.cancel();
      _drainTimer = null;
    });
    // Phase 2.4: kick the queue immediately when connectivity flips back to
    // online so queued sends don't have to wait up to 30s for the drain
    // timer. Combined with the per-task backoff window, this means a recent
    // network blip recovers within a couple of seconds of reconnect.
    //
    // Local-first reconnect semantics:
    //   - Queued tasks scheduled for a future retry have their backoff
    //     window cancelled. The user just regained connectivity — the
    //     intent of the backoff (don't hammer a flaky server) is moot.
    //   - Tasks that hit `failed` solely because retries were exhausted
    //     while offline are revived back to `queued`. Without this, a
    //     phone in airplane mode for ~3.5h hits the 8-attempt cap and the
    //     user has to manually tap retry on every queued message after
    //     reconnecting.
    //   - Permanent failures (PermanentTaskError → 4xx auth/validation)
    //     are left alone. Reconnecting won't fix those.
    ref.listen<ConnectivityStatus>(
      connectivityStatusProvider,
      (prev, next) {
        if (next == ConnectivityStatus.online &&
            prev != ConnectivityStatus.online) {
          DebugLogger.log(
            'connectivity-online: kicking queue drain',
            scope: 'tasks/queue',
          );
          _onConnectivityRestored();
        }
      },
    );
    return const [];
  }

  /// Called when connectivity flips from offline → online. Cancels pending
  /// backoff windows and revives `failed` tasks that ran out of retries
  /// while the network was down. See the [ref.listen] block in [build] for
  /// the full rationale.
  Future<void> _onConnectivityRestored() async {
    var changed = false;
    final next = <OutboundTask>[
      for (final task in state)
        switch (task.status) {
          // Queued + scheduled for future retry → cancel the backoff.
          TaskStatus.queued
              when task.scheduledNextAttemptAt != null &&
                  DateTime.now().isBefore(task.scheduledNextAttemptAt!) =>
            () {
              changed = true;
              return _withClearedNextAttempt(task);
            }(),
          // Failed via retry exhaustion (not via PermanentTaskError) →
          // re-queue with attempt counter reset so it gets the full
          // backoff schedule again from scratch.
          TaskStatus.failed when !task.failedPermanently => () {
            changed = true;
            return _revivedFromExhaustion(task);
          }(),
          _ => task,
        },
    ];

    if (changed) {
      state = next;
      await _save();
    }
    _process();
  }

  OutboundTask _withClearedNextAttempt(OutboundTask task) => task.map(
    uploadMedia: (t) => t.copyWith(nextAttemptAt: null),
    executeToolCall: (t) => t.copyWith(nextAttemptAt: null),
    generateImage: (t) => t.copyWith(nextAttemptAt: null),
    imageToDataUrl: (t) => t.copyWith(nextAttemptAt: null),
  );

  OutboundTask _revivedFromExhaustion(OutboundTask task) => task.map(
    uploadMedia: (t) => t.copyWith(
      status: TaskStatus.queued,
      attempt: 0,
      error: null,
      startedAt: null,
      completedAt: null,
      nextAttemptAt: null,
    ),
    executeToolCall: (t) => t.copyWith(
      status: TaskStatus.queued,
      attempt: 0,
      error: null,
      startedAt: null,
      completedAt: null,
      nextAttemptAt: null,
    ),
    generateImage: (t) => t.copyWith(
      status: TaskStatus.queued,
      attempt: 0,
      error: null,
      startedAt: null,
      completedAt: null,
      nextAttemptAt: null,
    ),
    imageToDataUrl: (t) => t.copyWith(
      status: TaskStatus.queued,
      attempt: 0,
      error: null,
      startedAt: null,
      completedAt: null,
      nextAttemptAt: null,
    ),
  );

  bool _processing = false;
  final Set<String> _activeThreads = <String>{};
  final int _maxParallel = 2; // bounded parallelism across conversations

  /// Manually pump the queue. Called from connectivity-online transitions
  /// (Phase 2.4) and from the reachability banner so deferred tasks resume
  /// immediately when the user reconnects.
  void kickProcessing() {
    _process();
  }

  Duration _backoffFor(int attempt) {
    if (attempt <= 0) return _backoff.first;
    final clamped = attempt - 1;
    if (clamped >= _backoff.length) return _backoff.last;
    return _backoff[clamped];
  }

  Future<void> _load() async {
    try {
      final boxes = ref.read(hiveBoxesProvider);
      final stored = boxes.caches.get(_storageKey);
      if (stored == null) return;

      List<Map<String, dynamic>> raw;
      if (stored is String && stored.isNotEmpty) {
        raw = (jsonDecode(stored) as List).cast<Map<String, dynamic>>();
      } else if (stored is List) {
        raw = stored
            .map((entry) => Map<String, dynamic>.from(entry as Map))
            .toList(growable: false);
      } else {
        return;
      }
      final tasks = raw.map(OutboundTask.fromJson).toList();
      // Restore non-completed tasks. We keep:
      //   - queued / running (running is reset to queued — anything
      //     in-flight at app death didn't actually finish)
      //   - failed-via-exhaustion (so a 4h-airplane-mode + app restart
      //     doesn't silently lose the user's queued send; the next
      //     online transition revives them via _onConnectivityRestored)
      // We drop:
      //   - succeeded (already delivered)
      //   - cancelled (user-intentional)
      //   - permanently failed (4xx — retrying won't help, leave as
      //     historical "Tap to retry" hint until the message bubble is
      //     dismissed; in practice these are user-driven so they don't
      //     accumulate)
      state = tasks.where((t) {
        switch (t.status) {
          case TaskStatus.queued:
          case TaskStatus.running:
            return true;
          case TaskStatus.failed:
            return !t.failedPermanently;
          case TaskStatus.succeeded:
          case TaskStatus.cancelled:
            return false;
        }
      }).map((t) {
        // Reset running back to queued — anything that was mid-flight
        // when the app died needs to be retried from scratch.
        if (t.status == TaskStatus.running) {
          return _withResetForRetry(t);
        }
        return t;
      }).toList();
      // Kick processing after load
      _process();
    } catch (e) {
      DebugLogger.log('Failed to load task queue: $e', scope: 'tasks/queue');
    }
  }

  Future<void> _save() async {
    try {
      final boxes = ref.read(hiveBoxesProvider);
      // Persist anything that might still be revived later. See [_load] for
      // the matching read-side filter.
      final retained = [
        for (final task in state)
          if (_shouldRetain(task)) task,
      ];

      if (retained.length != state.length) {
        // Remove completed/dropped entries from state to keep the queue lean.
        state = retained;
      }

      final raw = retained.map((t) => t.toJson()).toList(growable: false);
      await boxes.caches.put(_storageKey, raw);
    } catch (e) {
      DebugLogger.log('Failed to persist task queue: $e', scope: 'tasks/queue');
    }
  }

  bool _shouldRetain(OutboundTask task) {
    switch (task.status) {
      case TaskStatus.queued:
      case TaskStatus.running:
        return true;
      case TaskStatus.failed:
        // Keep transient failures so reconnect can revive them.
        return !task.failedPermanently;
      case TaskStatus.succeeded:
      case TaskStatus.cancelled:
        return false;
    }
  }

  OutboundTask _withResetForRetry(OutboundTask task) => task.map(
    uploadMedia: (t) =>
        t.copyWith(status: TaskStatus.queued, startedAt: null, completedAt: null),
    executeToolCall: (t) =>
        t.copyWith(status: TaskStatus.queued, startedAt: null, completedAt: null),
    generateImage: (t) =>
        t.copyWith(status: TaskStatus.queued, startedAt: null, completedAt: null),
    imageToDataUrl: (t) =>
        t.copyWith(status: TaskStatus.queued, startedAt: null, completedAt: null),
  );

  Future<void> cancel(String id) async {
    state = [
      for (final t in state)
        if (t.id == id)
          t.copyWith(status: TaskStatus.cancelled, completedAt: DateTime.now())
        else
          t,
    ];
    await _save();
  }

  Future<void> cancelUploadsForFile(String filePath) async {
    bool updated = false;
    state = [
      for (final task in state)
        task.maybeMap(
          uploadMedia: (upload) {
            if ((upload.status == TaskStatus.queued ||
                    upload.status == TaskStatus.running) &&
                upload.filePath == filePath) {
              updated = true;
              return upload.copyWith(
                status: TaskStatus.cancelled,
                completedAt: DateTime.now(),
              );
            }
            return upload;
          },
          imageToDataUrl: (image) {
            if ((image.status == TaskStatus.queued ||
                    image.status == TaskStatus.running) &&
                image.filePath == filePath) {
              updated = true;
              return image.copyWith(
                status: TaskStatus.cancelled,
                completedAt: DateTime.now(),
              );
            }
            return image;
          },
          orElse: () => task,
        ),
    ];
    if (updated) {
      await _save();
    }
  }

  Future<void> cancelByConversation(String conversationId) async {
    state = [
      for (final t in state)
        if ((t.maybeConversationId ?? '') == conversationId &&
            (t.status == TaskStatus.queued || t.status == TaskStatus.running))
          t.copyWith(status: TaskStatus.cancelled, completedAt: DateTime.now())
        else
          t,
    ];
    await _save();
  }

  Future<void> retry(String id) async {
    state = [
      for (final t in state)
        if (t.id == id)
          t.copyWith(
            status: TaskStatus.queued,
            attempt: (t.attempt + 1),
            error: null,
            startedAt: null,
            completedAt: null,
            // Manual retry bypasses the backoff window — the user explicitly
            // asked us to try again right now.
            nextAttemptAt: null,
          )
        else
          t,
    ];
    await _save();
    _process();
  }

  Future<String> enqueueGenerateImage({
    required String? conversationId,
    required String prompt,
    String? idempotencyKey,
  }) async {
    final id = _uuid.v4();
    final task = OutboundTask.generateImage(
      id: id,
      conversationId: conversationId,
      prompt: prompt,
      idempotencyKey: idempotencyKey,
      enqueuedAt: DateTime.now(),
    );
    state = [...state, task];
    await _save();
    _process();
    return id;
  }

  Future<String> enqueueExecuteToolCall({
    required String? conversationId,
    required String toolName,
    Map<String, dynamic> arguments = const <String, dynamic>{},
    String? idempotencyKey,
  }) async {
    final id = _uuid.v4();
    final task = OutboundTask.executeToolCall(
      id: id,
      conversationId: conversationId,
      toolName: toolName,
      arguments: arguments,
      idempotencyKey: idempotencyKey,
      enqueuedAt: DateTime.now(),
    );
    state = [...state, task];
    await _save();
    _process();
    return id;
  }

  Future<void> _process() async {
    if (_processing) return;
    _processing = true;
    try {
      // Pump while there is capacity and queued tasks remain
      while (true) {
        // Filter runnable tasks: queued AND past their nextAttemptAt window.
        final now = DateTime.now();
        final queued = state.where((t) {
          if (t.status != TaskStatus.queued) return false;
          final nextAt = t.scheduledNextAttemptAt;
          return nextAt == null || !now.isBefore(nextAt);
        }).toList();
        if (queued.isEmpty) break;

        // Respect parallelism and one-per-thread
        final availableCapacity = _maxParallel - _activeThreads.length;
        if (availableCapacity <= 0) break;

        OutboundTask? next;
        for (final t in queued) {
          final thread = t.threadKey;
          if (!_activeThreads.contains(thread)) {
            next = t;
            break;
          }
        }

        // If no eligible task (all threads busy), exit loop
        if (next == null) break;

        // Mark running and launch without awaiting (parallel across threads)
        final threadKey = next.threadKey;
        _activeThreads.add(threadKey);
        state = [
          for (final t in state)
            if (t.id == next.id)
              next.copyWith(
                status: TaskStatus.running,
                startedAt: DateTime.now(),
              )
            else
              t,
        ];
        await _save();

        // Launch worker
        unawaited(
          _run(next).whenComplete(() {
            _activeThreads.remove(threadKey);
            // After a task completes, try to schedule more
            _process();
          }),
        );
      }
    } finally {
      _processing = false;
    }
  }

  Future<void> _run(OutboundTask task) async {
    try {
      await TaskWorker(ref).perform(task);
      state = [
        for (final t in state)
          if (t.id == task.id)
            t.copyWith(
              status: TaskStatus.succeeded,
              completedAt: DateTime.now(),
            )
          else
            t,
      ];
    } catch (e, st) {
      DebugLogger.log(
        'Task failed (${task.runtimeType}): $e\n$st',
        scope: 'tasks/queue',
      );

      // Phase 2.3: classify failure. Permanent errors stop retrying; transient
      // ones get exponential backoff up to maxAttempts.
      final isPermanent = e is PermanentTaskError;
      final nextAttempt = task.attempt + 1;
      final shouldRetry = !isPermanent && nextAttempt < task.attemptBudget;

      if (shouldRetry) {
        final delay = _backoffFor(nextAttempt);
        final scheduledFor = DateTime.now().add(delay);
        DebugLogger.log(
          'Task scheduled for retry in ${delay.inSeconds}s '
          '(attempt $nextAttempt/${task.attemptBudget})',
          scope: 'tasks/queue',
        );
        state = [
          for (final t in state)
            if (t.id == task.id)
              t.copyWith(
                status: TaskStatus.queued,
                attempt: nextAttempt,
                error: e.toString(),
                startedAt: null,
                completedAt: null,
                nextAttemptAt: scheduledFor,
              )
            else
              t,
        ];
      } else {
        state = [
          for (final t in state)
            if (t.id == task.id)
              t.copyWith(
                status: TaskStatus.failed,
                attempt: nextAttempt,
                error: e.toString(),
                completedAt: DateTime.now(),
              )
            else
              t,
        ];
      }
    } finally {
      await _save();
    }
  }

  Future<String> enqueueUploadMedia({
    required String? conversationId,
    required String filePath,
    required String fileName,
    int? fileSize,
    String? mimeType,
    String? checksum,
  }) async {
    final id = _uuid.v4();
    final task = OutboundTask.uploadMedia(
      id: id,
      conversationId: conversationId,
      filePath: filePath,
      fileName: fileName,
      fileSize: fileSize,
      mimeType: mimeType,
      checksum: checksum,
      enqueuedAt: DateTime.now(),
    );
    state = [...state, task];
    await _save();
    _process();
    return id;
  }

  // Removed: enqueueSaveConversation — mobile app no longer persists chats to server.

  Future<String> enqueueImageToDataUrl({
    required String? conversationId,
    required String filePath,
    required String fileName,
    String? idempotencyKey,
  }) async {
    final id = _uuid.v4();
    final task = OutboundTask.imageToDataUrl(
      id: id,
      conversationId: conversationId,
      filePath: filePath,
      fileName: fileName,
      idempotencyKey: idempotencyKey,
      enqueuedAt: DateTime.now(),
    );
    state = [...state, task];
    await _save();
    _process();
    return id;
  }
}
