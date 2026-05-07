import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/persistence/persistence_providers.dart';
import '../../../core/persistence/hive_boxes.dart';
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

  @override
  List<OutboundTask> build() {
    if (!_bootstrapScheduled) {
      _bootstrapScheduled = true;
      Future.microtask(_load);
    }
    return const [];
  }

  bool _processing = false;
  final Set<String> _activeThreads = <String>{};
  final int _maxParallel = 2; // bounded parallelism across conversations

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
      // Only restore non-completed tasks
      state = tasks
          .where(
            (t) =>
                t.status == TaskStatus.queued || t.status == TaskStatus.running,
          )
          .map(
            (t) => t.copyWith(
              status: TaskStatus.queued,
              startedAt: null,
              completedAt: null,
            ),
          )
          .toList();
      // Kick processing after load
      _process();
    } catch (e) {
      DebugLogger.log('Failed to load task queue: $e', scope: 'tasks/queue');
    }
  }

  Future<void> _save() async {
    try {
      final boxes = ref.read(hiveBoxesProvider);
      final retained = [
        for (final task in state)
          if (task.status == TaskStatus.queued ||
              task.status == TaskStatus.running)
            task,
      ];

      if (retained.length != state.length) {
        // Remove completed entries from state to keep the in-memory queue lean.
        state = retained;
      }

      final raw = retained.map((t) => t.toJson()).toList(growable: false);
      await boxes.caches.put(_storageKey, raw);
    } catch (e) {
      DebugLogger.log('Failed to persist task queue: $e', scope: 'tasks/queue');
    }
  }

  Future<String> enqueueSendText({
    required String? conversationId,
    String? pendingFolderId,
    required String text,
    List<String>? attachments,
    List<String>? toolIds,
    String? idempotencyKey,
  }) async {
    final id = _uuid.v4();
    final task = OutboundTask.sendTextMessage(
      id: id,
      conversationId: conversationId,
      pendingFolderId: pendingFolderId,
      text: text,
      attachments: attachments ?? const [],
      toolIds: toolIds ?? const [],
      idempotencyKey: idempotencyKey,
      enqueuedAt: DateTime.now(),
    );
    state = [...state, task];
    await _save();
    _process();
    return id;
  }

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
        // Filter runnable tasks
        final queued = state
            .where((t) => t.status == TaskStatus.queued)
            .toList();
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
      state = [
        for (final t in state)
          if (t.id == task.id)
            t.copyWith(
              status: TaskStatus.failed,
              error: e.toString(),
              completedAt: DateTime.now(),
            )
          else
            t,
      ];
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
