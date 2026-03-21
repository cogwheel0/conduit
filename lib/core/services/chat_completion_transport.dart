import 'dart:async';

/// The transport mode chosen by the server for a chat completion request.
enum ChatCompletionTransport { httpStream, taskSocket, jsonCompletion }

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
    Future<void> Function()? abort,
  }) => ChatCompletionSession._(
    transport: ChatCompletionTransport.taskSocket,
    messageId: messageId,
    sessionId: sessionId,
    conversationId: conversationId,
    taskId: taskId,
    abort: abort,
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

  /// Task ID returned by the server for task/socket mode.
  final String? taskId;

  /// The raw byte stream for direct HTTP streaming.
  final Stream<List<int>>? byteStream;

  /// The parsed JSON payload for direct JSON completions.
  final Map<String, dynamic>? jsonPayload;

  /// Abort handle to cancel the active HTTP request.
  final Future<void> Function()? abort;
}
