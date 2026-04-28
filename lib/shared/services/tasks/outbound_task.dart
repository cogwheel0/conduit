import 'package:freezed_annotation/freezed_annotation.dart';

part 'outbound_task.freezed.dart';
part 'outbound_task.g.dart';

enum TaskStatus { queued, running, succeeded, failed, cancelled }

@freezed
abstract class OutboundTask with _$OutboundTask {
  const OutboundTask._();

  const factory OutboundTask.sendTextMessage({
    required String id,
    String? conversationId,
    required String text,
    @Default(<String>[]) List<String> attachments,
    @Default(<String>[]) List<String> toolIds,
    @Default(TaskStatus.queued) TaskStatus status,
    @Default(0) int attempt,
    @Default(8) int maxAttempts,
    DateTime? nextAttemptAt,
    String? idempotencyKey,
    DateTime? enqueuedAt,
    DateTime? startedAt,
    DateTime? completedAt,
    String? error,
  }) = SendTextMessageTask;

  const factory OutboundTask.uploadMedia({
    required String id,
    String? conversationId,
    required String filePath,
    required String fileName,
    int? fileSize,
    String? mimeType,
    String? checksum,
    @Default(TaskStatus.queued) TaskStatus status,
    @Default(0) int attempt,
    @Default(8) int maxAttempts,
    DateTime? nextAttemptAt,
    String? idempotencyKey,
    DateTime? enqueuedAt,
    DateTime? startedAt,
    DateTime? completedAt,
    String? error,
  }) = UploadMediaTask;

  const factory OutboundTask.executeToolCall({
    required String id,
    String? conversationId,
    required String toolName,
    @Default(<String, dynamic>{}) Map<String, dynamic> arguments,
    @Default(TaskStatus.queued) TaskStatus status,
    @Default(0) int attempt,
    @Default(8) int maxAttempts,
    DateTime? nextAttemptAt,
    String? idempotencyKey,
    DateTime? enqueuedAt,
    DateTime? startedAt,
    DateTime? completedAt,
    String? error,
  }) = ExecuteToolCallTask;

  const factory OutboundTask.generateImage({
    required String id,
    String? conversationId,
    required String prompt,
    @Default(TaskStatus.queued) TaskStatus status,
    @Default(0) int attempt,
    @Default(8) int maxAttempts,
    DateTime? nextAttemptAt,
    String? idempotencyKey,
    DateTime? enqueuedAt,
    DateTime? startedAt,
    DateTime? completedAt,
    String? error,
  }) = GenerateImageTask;

  const factory OutboundTask.imageToDataUrl({
    required String id,
    String? conversationId,
    required String filePath,
    required String fileName,
    @Default(TaskStatus.queued) TaskStatus status,
    @Default(0) int attempt,
    @Default(8) int maxAttempts,
    DateTime? nextAttemptAt,
    String? idempotencyKey,
    DateTime? enqueuedAt,
    DateTime? startedAt,
    DateTime? completedAt,
    String? error,
  }) = ImageToDataUrlTask;

  factory OutboundTask.fromJson(Map<String, dynamic> json) =>
      _$OutboundTaskFromJson(json);

  // Provide a unified nullable conversationId across variants
  String? get maybeConversationId => map(
    sendTextMessage: (t) => t.conversationId,
    uploadMedia: (t) => t.conversationId,
    executeToolCall: (t) => t.conversationId,
    generateImage: (t) => t.conversationId,
    imageToDataUrl: (t) => t.conversationId,
  );

  String get threadKey =>
      (maybeConversationId == null || maybeConversationId!.isEmpty)
      ? 'new'
      : maybeConversationId!;

  /// Unified accessor for the next-attempt timestamp across variants. Used by
  /// [TaskQueue] to defer pickup of tasks that have been scheduled for retry
  /// after exponential backoff.
  DateTime? get scheduledNextAttemptAt => map(
    sendTextMessage: (t) => t.nextAttemptAt,
    uploadMedia: (t) => t.nextAttemptAt,
    executeToolCall: (t) => t.nextAttemptAt,
    generateImage: (t) => t.nextAttemptAt,
    imageToDataUrl: (t) => t.nextAttemptAt,
  );

  /// Maximum number of attempts before a task is treated as terminally failed.
  int get attemptBudget => map(
    sendTextMessage: (t) => t.maxAttempts,
    uploadMedia: (t) => t.maxAttempts,
    executeToolCall: (t) => t.maxAttempts,
    generateImage: (t) => t.maxAttempts,
    imageToDataUrl: (t) => t.maxAttempts,
  );

  /// Unified accessor for the failure reason string, populated by
  /// [TaskQueue] when a task transitions to retry/failed.
  String? get failureError => map(
    sendTextMessage: (t) => t.error,
    uploadMedia: (t) => t.error,
    executeToolCall: (t) => t.error,
    generateImage: (t) => t.error,
    imageToDataUrl: (t) => t.error,
  );

  /// True when the most recent failure was a [PermanentTaskError] (4xx
  /// validation/auth) — i.e. retrying won't help. Network/transport errors
  /// return false even after the queue has exhausted its budget.
  ///
  /// The discriminator is the stringified prefix written by
  /// [PermanentTaskError.toString], avoiding the need to thread an extra
  /// flag through every freezed variant.
  bool get failedPermanently {
    final err = failureError;
    if (err == null) return false;
    return err.startsWith('PermanentTaskError');
  }
}

/// Marker exception thrown by [TaskWorker] when a task fails in a way that
/// will not succeed on retry (e.g. 4xx auth/validation errors). The queue
/// catches this and skips backoff scheduling, marking the task as failed.
class PermanentTaskError implements Exception {
  PermanentTaskError(this.message);

  final String message;

  @override
  String toString() => 'PermanentTaskError: $message';
}
