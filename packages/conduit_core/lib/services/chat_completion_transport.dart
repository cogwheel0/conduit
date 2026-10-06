import 'dart:async';

/// The transport mode chosen by the server for a chat completion request.
enum ChatCompletionTransport { httpStream, taskSocket, jsonCompletion }

/// One answer a single completion request asks the server to generate: the
/// model, the assistant message that will hold it, and the column (`modelIdx`)
/// it occupies. Equal model ids in different columns are different answers.
final class ChatCompletionTarget {
  const ChatCompletionTarget({
    required this.modelId,
    required this.messageId,
    required this.modelIdx,
  });

  final String modelId;
  final String messageId;
  final int modelIdx;

  /// The `message_ids` entry Open WebUI's backend reads.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'model_id': modelId,
    'message_id': messageId,
    'modelIdx': modelIdx,
  };
}

/// A typed session describing how the server resolved a chat completion
/// request.
///
/// Constructed by [ApiService.sendMessageSession] after inspecting the real
/// HTTP response. The orchestrator layer uses this to bind the correct
/// streaming transport.
final class ChatCompletionSession {
  const ChatCompletionSession._({
    required this.transport,
    required this.messageId,
    this.sessionId,
    this.conversationId,
    this.taskId,
    this.taskIds = const <String>[],
    this.byteStream,
    this.jsonPayload,
    this.abort,
  });

  /// Direct HTTP streamed completion.
  factory ChatCompletionSession.httpStream({
    required String messageId,
    String? sessionId,
    String? conversationId,
    required Stream<List<int>> byteStream,
    required Future<void> Function() abort,
  }) => ChatCompletionSession._(
    transport: ChatCompletionTransport.httpStream,
    messageId: messageId,
    sessionId: sessionId,
    conversationId: conversationId,
    byteStream: byteStream,
    abort: abort,
  );

  /// Task/socket-based completion where content arrives via WebSocket events.
  factory ChatCompletionSession.taskSocket({
    required String messageId,
    String? sessionId,
    String? conversationId,
    required String taskId,

    /// Every task the server created for this one request, in the order of the
    /// request's `message_ids`. Defaults to just [taskId].
    List<String>? taskIds,
    Future<void> Function()? abort,
  }) => ChatCompletionSession._(
    transport: ChatCompletionTransport.taskSocket,
    messageId: messageId,
    sessionId: sessionId,
    conversationId: conversationId,
    taskId: taskId,
    taskIds: List<String>.unmodifiable(taskIds ?? <String>[taskId]),
    abort: abort,
  );

  /// Socket-only resume of an in-flight chat that is still generating on the
  /// server (mirrors Open WebUI reopening a streaming chat).
  ///
  /// A named, intent-revealing alias for the socket-only [taskSocket] shape:
  /// [byteStream] is `null` (no HTTP body to forward — the existing taskSocket
  /// dispatch closes the HTTP side immediately and waits for the socket `done`)
  /// and [abort] is `null` (resume does not own an HTTP request to cancel;
  /// cancellation goes through the task registry via `taskId`).
  ///
  /// [sessionId] is intentionally `null` so the streaming helper's session
  /// matching stays permissive and binds the server's (possibly foreign)
  /// `message_id` to the local [messageId] on the first `chat:completion`.
  factory ChatCompletionSession.resumeSocket({
    required String messageId,
    String? conversationId,
    String? taskId,
  }) => ChatCompletionSession._(
    transport: ChatCompletionTransport.taskSocket,
    messageId: messageId,
    // Always null: resume must keep session matching permissive so a foreign
    // server-assigned message_id can still bind. No caller may override it.
    sessionId: null,
    conversationId: conversationId,
    taskId: taskId,
    taskIds: taskId == null ? const <String>[] : <String>[taskId],
  );

  /// Direct JSON completion (non-streamed).
  factory ChatCompletionSession.jsonCompletion({
    required String messageId,
    String? sessionId,
    String? conversationId,
    required Map<String, dynamic> jsonPayload,
  }) => ChatCompletionSession._(
    transport: ChatCompletionTransport.jsonCompletion,
    messageId: messageId,
    sessionId: sessionId,
    conversationId: conversationId,
    jsonPayload: jsonPayload,
  );

  /// Which transport mode the server chose.
  final ChatCompletionTransport transport;

  /// The assistant message ID for this completion.
  final String messageId;

  /// The socket session ID used for this request, or `null` when the socket
  /// was not connected at request time (httpStream fallback).
  final String? sessionId;

  /// The conversation (chat) ID, if available.
  final String? conversationId;

  /// Task ID returned by the server for task/socket mode. For a multi-answer
  /// request this is the first of [taskIds].
  final String? taskId;

  /// Every task ID the server returned, in request order. One per answer of a
  /// multi-model request; empty outside task/socket mode.
  final List<String> taskIds;

  /// The raw byte stream for direct HTTP streaming.
  final Stream<List<int>>? byteStream;

  /// The parsed JSON payload for direct JSON completions.
  final Map<String, dynamic>? jsonPayload;

  /// Abort handle to cancel the active HTTP request.
  final Future<void> Function()? abort;
}
