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
    String? pendingFolderId,
    required String text,
    @Default(<String>[]) List<String> attachments,
    @Default(<String>[]) List<String> toolIds,
    @Default(TaskStatus.queued) TaskStatus status,
    @Default(0) int attempt,
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
}
