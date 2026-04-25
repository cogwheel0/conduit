import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/material.dart';

import '../../core/models/chat_message.dart';
import '../../core/providers/app_providers.dart' show isTemporaryChat;
import '../../core/services/socket_service.dart';
import '../../core/utils/tool_calls_parser.dart';
import 'background_streaming_handler.dart';
import 'chat_completion_transport.dart';
import 'navigation_service.dart';

import '../../shared/widgets/themed_dialogs.dart';
import '../../shared/theme/theme_extensions.dart';
import '../utils/debug_logger.dart';
import '../utils/embed_utils.dart';
import '../utils/openwebui_source_parser.dart';
import 'openwebui_stream_parser.dart';
import 'streaming_response_controller.dart';
import 'api_service.dart';
import 'worker_manager.dart';

// Keep local verbosity toggle for socket logs
const bool kSocketVerboseLogging = false;

// Pre-compiled regex patterns for image extraction (performance optimization)
final _base64ImagePattern = RegExp(
  r'data:image/[^;\s]+;base64,[A-Za-z0-9+/]+=*',
);
final _urlImagePattern = RegExp(
  r'https?://[^\s<>\"]+\.(jpg|jpeg|png|gif|webp)',
  caseSensitive: false,
);
final _jsonImagePattern = RegExp(
  r'\{[^}]*"url"[^}]*:[^}]*"(data:image/[^"]+|https?://[^"]+\.(jpg|jpeg|png|gif|webp))"[^}]*\}',
  caseSensitive: false,
);
final _jsonUrlExtractPattern = RegExp(r'"url"[^:]*:[^"]*"([^"]+)"');
final _partialResultsPattern = RegExp(
  r'(result|files)="([^"]*(?:data:image/[^"]*|https?://[^"]*\.(jpg|jpeg|png|gif|webp))[^"]*)"',
  caseSensitive: false,
);
final _imageFilePattern = RegExp(
  r'https?://[^\s]+\.(jpg|jpeg|png|gif|webp)$',
  caseSensitive: false,
);
const HtmlEscape _htmlContentEscape = HtmlEscape();

String _buildStreamingReasoningDetails(
  String reasoningContent, {
  required bool done,
  int duration = 0,
}) {
  final normalizedReasoning = reasoningContent.trim();
  final escapedDisplay = normalizedReasoning.isEmpty
      ? ''
      : _htmlContentEscape.convert(
          LineSplitter.split(
            normalizedReasoning,
          ).map((line) => line.startsWith('>') ? line : '> $line').join('\n'),
        );
  if (done) {
    return '<details type="reasoning" done="true" duration="$duration">\n'
        '<summary>Thought for $duration seconds</summary>\n'
        '$escapedDisplay\n'
        '</details>\n';
  }
  return '<details type="reasoning" done="false">\n'
      '<summary>Thinking…</summary>\n'
      '$escapedDisplay\n'
      '</details>\n';
}

String _prependReasoningDetails(String prefix, String reasoningDetails) {
  if (prefix.isEmpty || prefix.endsWith('\n')) {
    return '$prefix$reasoningDetails';
  }
  return '$prefix\n$reasoningDetails';
}

List<Map<String, dynamic>> _collectImageReferencesWorker(String content) {
  final collected = <Map<String, dynamic>>[];
  if (content.isEmpty) {
    return collected;
  }

  if (content.contains('<details') && content.contains('</details>')) {
    final parsed = ToolCallsParser.parse(content);
    if (parsed != null) {
      for (final entry in parsed.toolCalls) {
        if (entry.files != null && entry.files!.isNotEmpty) {
          collected.addAll(_extractFilesFromResult(entry.files));
        }
        if (entry.result != null) {
          collected.addAll(_extractFilesFromResult(entry.result));
        }
      }
    }
  }

  if (collected.isNotEmpty) {
    return collected;
  }

  final base64Matches = _base64ImagePattern.allMatches(content);
  for (final match in base64Matches) {
    final url = match.group(0);
    if (url != null && url.isNotEmpty) {
      collected.add({'type': 'image', 'url': url});
    }
  }

  final urlMatches = _urlImagePattern.allMatches(content);
  for (final match in urlMatches) {
    final url = match.group(0);
    if (url != null && url.isNotEmpty) {
      collected.add({'type': 'image', 'url': url});
    }
  }

  final jsonMatches = _jsonImagePattern.allMatches(content);
  for (final match in jsonMatches) {
    final url = _jsonUrlExtractPattern
        .firstMatch(match.group(0) ?? '')
        ?.group(1);
    if (url != null && url.isNotEmpty) {
      collected.add({'type': 'image', 'url': url});
    }
  }

  final partialMatches = _partialResultsPattern.allMatches(content);
  for (final match in partialMatches) {
    final attrValue = match.group(2);
    if (attrValue == null) continue;
    try {
      final decoded = json.decode(attrValue);
      collected.addAll(_extractFilesFromResult(decoded));
    } catch (_) {
      if (attrValue.startsWith('data:image/') ||
          _imageFilePattern.hasMatch(attrValue)) {
        collected.add({'type': 'image', 'url': attrValue});
      }
    }
  }

  return collected;
}

class ActiveChatStream {
  ActiveChatStream({
    required this.controller,
    required this.socketSubscriptions,
    required this.disposeWatchdog,
  });

  final StreamingResponseController? controller;
  final List<VoidCallback> socketSubscriptions;
  final VoidCallback disposeWatchdog;
}

typedef _ServerMessageSnapshot = ({
  String content,
  List<String> followUps,
  bool isDone,
  String? errorContent,
});

/// Helper to handle reconnect recovery asynchronously with proper error handling.
/// Extracted to avoid async callback in Timer which silently drops the Future.
Future<void> _handleReconnectRecovery({
  required bool Function() hasFinished,
  required List<ChatMessage> Function() getMessages,
  required Future<_ServerMessageSnapshot?> Function() pollServerForMessage,
  required bool Function(
    String,
    List<String>, {
    required bool finishIfDone,
    required bool isDone,
    required String source,
    String? errorContent,
  })
  applyServerContent,
  required void Function() syncImages,
}) async {
  try {
    if (hasFinished()) return;

    final msgs = getMessages();
    if (msgs.isEmpty ||
        msgs.last.role != 'assistant' ||
        !msgs.last.isStreaming) {
      return;
    }

    final result = await pollServerForMessage();
    if (hasFinished()) return;

    if (result != null) {
      final applied = applyServerContent(
        result.content,
        result.followUps,
        finishIfDone: true,
        isDone: result.isDone,
        source: 'Reconnect recovery',
        errorContent: result.errorContent,
      );
      if (applied) {
        syncImages();
      }
    }
  } catch (e) {
    // Log error but don't crash - reconnect recovery is best-effort
    DebugLogger.log('Reconnect recovery failed: $e', scope: 'streaming/helper');
  }
}

/// Unified streaming helper for chat send/regenerate flows.
///
/// This attaches WebSocket event handlers and manages background search/image-gen
/// UI updates. It operates via callbacks to avoid tight coupling with provider files
/// for easier reuse and testing.
ActiveChatStream attachUnifiedChunkedStreaming({
  required ChatCompletionSession session,
  required bool webSearchEnabled,
  required String assistantMessageId,
  required String modelId,
  required Map<String, dynamic> modelItem,

  /// The socket session ID for event matching. Null when the socket was
  /// not connected at request time (httpStream fallback).
  String? sessionId,
  required String? activeConversationId,
  required ApiService api,
  required SocketService? socketService,
  required WorkerManager workerManager,

  /// Filter IDs for the outlet filter pass in chatCompleted.
  List<String>? filterIds,
  // Message update callbacks
  required void Function(String) appendToLastMessage,
  required void Function(String) replaceLastMessageContent,
  required void Function(ChatMessage Function(ChatMessage))
  updateLastMessageWith,
  required void Function(String messageId, ChatStatusUpdate update)
  appendStatusUpdate,
  required void Function(String messageId, List<String> followUps) setFollowUps,
  required void Function(String messageId, ChatCodeExecution execution)
  upsertCodeExecution,
  required void Function(String messageId, ChatSourceReference reference)
  appendSourceReference,
  required void Function(
    String messageId,
    ChatMessage Function(ChatMessage current),
  )
  updateMessageById,
  void Function(String newTitle)? onChatTitleUpdated,
  void Function()? onChatTagsUpdated,

  /// Called when a `chat:active` event is received, indicating a background
  /// task has started (active=true) or completed (active=false).
  void Function(String? chatId, bool active)? onChatActiveChanged,
  required void Function() completeStreamingUi,
  required void Function() finishStreaming,
  required List<ChatMessage> Function() getMessages,
  void Function()? onObsoleteStreamRetired,

  /// Flushes buffered streaming content into state so
  /// [getMessages] returns up-to-date content. Must be
  /// called before checking content on completion.
  required void Function() flushStreamingBuffer,

  /// Whether the model uses reasoning/thinking (needs longer watchdog window).
  bool modelUsesReasoning = false,

  /// Whether tools are enabled (needs longer watchdog window).
  bool toolsEnabled = false,
}) {
  // Track if streaming has been finished to avoid duplicate cleanup
  bool hasFinished = false;
  bool hasCompletedStreamingUi = false;
  bool isObsoleteStream = false;
  bool backgroundExecutionStopped = false;
  var currentStreamSessionId = sessionId;
  String? boundRemoteMessageId;
  StreamingResponseController? streamController;
  late void Function(String reason, {String? incomingMessageId})
  retireObsoleteStream;

  bool isTerminalFinishReason(String? finishReason) {
    return finishReason == 'stop' ||
        finishReason == 'length' ||
        finishReason == 'content_filter';
  }

  // Start background execution to keep app alive during streaming (iOS/Android)
  // Uses the assistantMessageId as a unique stream identifier
  final streamId = 'chat-stream-$assistantMessageId';
  if (Platform.isIOS || Platform.isAndroid) {
    // Fire-and-forget: background execution is best-effort and shouldn't block streaming
    BackgroundStreamingHandler.instance
        .startBackgroundExecution([streamId])
        .catchError((Object e) {
          DebugLogger.error(
            'background-start-failed',
            scope: 'streaming/helper',
            error: e,
          );
        });
  }

  String? currentAssistantTargetId() {
    final messages = getMessages();
    for (final message in messages.reversed) {
      if (message.role == 'assistant') {
        return message.id;
      }
    }
    return null;
  }

  List<String> currentServerMessageIds() {
    final ids = <String>[assistantMessageId];
    final remoteMessageId = boundRemoteMessageId;
    if (remoteMessageId != null &&
        remoteMessageId.isNotEmpty &&
        remoteMessageId != assistantMessageId) {
      ids.add(remoteMessageId);
    }
    return ids;
  }

  bool matchesCurrentStreamSession(String? incomingSessionId) {
    if (incomingSessionId == null || incomingSessionId.isEmpty) {
      return true;
    }
    if (currentStreamSessionId == null || currentStreamSessionId!.isEmpty) {
      return true;
    }
    return incomingSessionId == currentStreamSessionId;
  }

  String? extractEventSessionId(Map<String, dynamic> event) {
    String? candidate =
        event['session_id']?.toString() ?? event['sessionId']?.toString();

    final data = event['data'];
    if (candidate == null && data is Map) {
      candidate =
          data['session_id']?.toString() ?? data['sessionId']?.toString();

      final inner = data['data'];
      if (candidate == null && inner is Map) {
        candidate =
            inner['session_id']?.toString() ?? inner['sessionId']?.toString();
      }
    }

    return candidate;
  }

  bool streamHasBeenSuperseded() {
    final currentTargetId = currentAssistantTargetId();
    return currentTargetId != null && currentTargetId != assistantMessageId;
  }

  String? resolveTargetMessageIdForStream(
    String? incomingMessageId, {
    required String eventType,
    String? incomingSessionId,
    bool allowBindingForeignMessage = false,
  }) {
    final currentTargetId = currentAssistantTargetId();
    if (currentTargetId == null || currentTargetId != assistantMessageId) {
      return null;
    }

    if (!matchesCurrentStreamSession(incomingSessionId)) {
      DebugLogger.log(
        'Ignoring $eventType for foreign-session message: '
        '${incomingMessageId ?? "<none>"} '
        '(session=${incomingSessionId ?? "<none>"}, '
        'expected=${currentStreamSessionId ?? "<none>"})',
        scope: 'streaming/helper',
      );
      return null;
    }

    if (incomingMessageId == null || incomingMessageId.isEmpty) {
      return currentTargetId;
    }

    if (incomingMessageId == assistantMessageId ||
        incomingMessageId == boundRemoteMessageId) {
      return currentTargetId;
    }

    if (!allowBindingForeignMessage) {
      final boundMessageId = boundRemoteMessageId;
      DebugLogger.log(
        boundMessageId == null
            ? 'Ignoring $eventType for wrong message: '
                  '$incomingMessageId (expected $assistantMessageId)'
            : 'Ignoring $eventType for unexpected message: '
                  '$incomingMessageId '
                  '(expected $assistantMessageId or $boundMessageId)',
        scope: 'streaming/helper',
      );
      return null;
    }

    if (boundRemoteMessageId == null) {
      boundRemoteMessageId = incomingMessageId;
      DebugLogger.log(
        'Binding $eventType server message $incomingMessageId '
        'to local assistant $assistantMessageId',
        scope: 'streaming/helper',
      );
      return currentTargetId;
    }

    DebugLogger.log(
      'Ignoring $eventType for unexpected message: $incomingMessageId '
      '(bound=${boundRemoteMessageId ?? "<none>"}, '
      'local=$assistantMessageId)',
      scope: 'streaming/helper',
    );
    return null;
  }

  void stopBackgroundExecution() {
    if (backgroundExecutionStopped) {
      return;
    }
    backgroundExecutionStopped = true;
    if (Platform.isIOS || Platform.isAndroid) {
      BackgroundStreamingHandler.instance
          .stopBackgroundExecution([streamId])
          .catchError((Object e) {
            DebugLogger.error(
              'background-stop-failed',
              scope: 'streaming/helper',
              error: e,
            );
          });
    }
  }

  // Wrap finishStreaming to always clear the cancel token and stop background execution
  void wrappedFinishStreaming() {
    if (hasFinished) return;
    hasFinished = true;
    hasCompletedStreamingUi = true;
    api.clearStreamCancelToken(assistantMessageId);

    // Stop background execution when streaming completes
    stopBackgroundExecution();

    finishStreaming();
  }

  // Reference to image sync functions - initialized to no-op and reassigned
  // after the real implementation is defined. Must not be `late` to avoid
  // LateInitializationError if callbacks fire early.
  void Function() syncImages = () {};
  void Function() updateImagesFromCurrentContent = () {};

  var renderedStreamingContent = (() {
    final messages = getMessages();
    if (messages.isEmpty || messages.last.role != 'assistant') {
      return '';
    }
    return messages.last.content;
  })();
  var inReasoningBlock = false;
  var reasoningPrefix = '';
  var reasoningContent = '';

  void resetStreamingReasoning() {
    inReasoningBlock = false;
    reasoningPrefix = '';
    reasoningContent = '';
  }

  void syncRenderedStreamingContentFromState() {
    final messages = getMessages();
    if (messages.isEmpty || messages.last.role != 'assistant') {
      renderedStreamingContent = '';
      return;
    }
    renderedStreamingContent = messages.last.content;
  }

  void replaceVisibleAssistantContent(
    String content, {
    bool updateImages = true,
  }) {
    resetStreamingReasoning();
    renderedStreamingContent = content;
    replaceLastMessageContent(content);
    if (updateImages) {
      updateImagesFromCurrentContent();
    }
  }

  void finalizeStreamingReasoning({
    int duration = 0,
    bool updateImages = false,
  }) {
    if (!inReasoningBlock) {
      if (updateImages) {
        updateImagesFromCurrentContent();
      }
      return;
    }

    renderedStreamingContent = _prependReasoningDetails(
      reasoningPrefix,
      _buildStreamingReasoningDetails(
        reasoningContent,
        done: true,
        duration: duration,
      ),
    );
    replaceLastMessageContent(renderedStreamingContent);
    resetStreamingReasoning();

    if (updateImages) {
      updateImagesFromCurrentContent();
    }
  }

  void appendVisibleAssistantChunk(String chunk, {bool updateImages = true}) {
    if (chunk.isEmpty) return;

    if (inReasoningBlock) {
      renderedStreamingContent =
          _prependReasoningDetails(
            reasoningPrefix,
            _buildStreamingReasoningDetails(reasoningContent, done: true),
          ) +
          chunk;
      replaceLastMessageContent(renderedStreamingContent);
      resetStreamingReasoning();
    } else {
      renderedStreamingContent += chunk;
      appendToLastMessage(chunk);
    }

    if (updateImages) {
      updateImagesFromCurrentContent();
    }
  }

  void applyStreamingReasoningDelta(String chunk) {
    if (chunk.isEmpty) return;

    if (!inReasoningBlock) {
      syncRenderedStreamingContentFromState();
      inReasoningBlock = true;
      reasoningPrefix = renderedStreamingContent;
      reasoningContent = '';
    }

    reasoningContent += chunk;
    renderedStreamingContent = _prependReasoningDetails(
      reasoningPrefix,
      _buildStreamingReasoningDetails(reasoningContent, done: false),
    );
    replaceLastMessageContent(renderedStreamingContent);
  }

  void handleStreamingChoiceDelta(Map<dynamic, dynamic> delta) {
    final reasoning = delta['reasoning_content']?.toString() ?? '';
    if (reasoning.isNotEmpty) {
      applyStreamingReasoningDelta(reasoning);
    }

    final content = delta['content']?.toString() ?? '';
    if (content.isNotEmpty) {
      appendVisibleAssistantChunk(content);
    }
  }

  void handleToolCallStatus(String name) {
    if (name.isEmpty) return;
    final status =
        '\n<details type="tool_calls" done="false" '
        'name="$name"><summary>Executing...</summary>\n</details>\n';
    appendVisibleAssistantChunk(status, updateImages: false);
  }

  void completeVisibleStreaming() {
    if (hasCompletedStreamingUi) return;
    finalizeStreamingReasoning();
    hasCompletedStreamingUi = true;
    completeStreamingUi();
  }

  // For taskSocket transport, we still need a StreamController so the
  // StreamingResponseController can manage the stream lifecycle.
  // For httpStream/jsonCompletion, these are unused.
  StreamSubscription<dynamic>? httpSubscription;

  // Socket subscriptions list - starts empty so non-socket flows can finish via onComplete.
  // HTTP subscription is tracked separately and cleaned up in disposeSocketSubscriptions.
  final socketSubscriptions = <VoidCallback>[];
  final hasSocketSignals = socketService != null;

  // Shared helper to poll server for message content with exponential backoff.
  // Used by watchdog timeout and reconnection handler to recover from missed events.
  // Returns (content, followUps, isDone, errorContent) or null if fetch fails
  // or the message is not found.
  String? extractServerErrorContent(dynamic rawError) {
    if (rawError == null) {
      return null;
    }
    if (rawError is String && rawError.isNotEmpty) {
      return rawError;
    }
    final errorMap = _asStringMap(rawError);
    if (errorMap == null) {
      return null;
    }
    final content = errorMap['content']?.toString().trim();
    if (content != null && content.isNotEmpty) {
      return content;
    }
    final message = errorMap['message']?.toString().trim();
    if (message != null && message.isNotEmpty) {
      return message;
    }
    final detail = errorMap['detail']?.toString().trim();
    if (detail != null && detail.isNotEmpty) {
      return detail;
    }
    final nestedError = _asStringMap(errorMap['error']);
    final nestedMessage = nestedError?['message']?.toString().trim();
    if (nestedMessage != null && nestedMessage.isNotEmpty) {
      return nestedMessage;
    }
    return '';
  }

  Map<String, dynamic>? findServerMessageInList(dynamic rawMessages) {
    if (rawMessages is! List) {
      return null;
    }
    final targetIds = currentServerMessageIds().toSet();
    final serverMsg = rawMessages.firstWhere(
      (m) => m is Map && targetIds.contains(m['id']?.toString()),
      orElse: () => null,
    );
    return _asStringMap(serverMsg);
  }

  Future<_ServerMessageSnapshot?> pollServerForMessage({
    int attempt = 0,
    int maxAttempts = 3,
  }) async {
    if (isObsoleteStream) {
      return null;
    }
    try {
      final chatId = activeConversationId;
      if (chatId == null || chatId.isEmpty || isTemporaryChat(chatId)) {
        return null;
      }

      final resp = await api.dio.get('/api/v1/chats/$chatId');
      if (isObsoleteStream) {
        return null;
      }
      final data = resp.data as Map<String, dynamic>?;
      final chatObj = data?['chat'] as Map<String, dynamic>?;
      if (chatObj == null && data == null) return null;

      final history = _asStringMap(chatObj?['history']);
      final historyMessages = _asStringMap(history?['messages']);
      Map<String, dynamic>? serverMsg;
      for (final targetId in currentServerMessageIds()) {
        serverMsg = _asStringMap(historyMessages?[targetId]);
        if (serverMsg != null) {
          break;
        }
      }
      serverMsg ??=
          findServerMessageInList(chatObj?['messages']) ??
          findServerMessageInList(data?['messages']);
      if (serverMsg == null) return null;

      // Extract content
      final serverContent = serverMsg['content'];
      String content = '';
      if (serverContent is String) {
        content = serverContent;
      } else if (serverContent is List) {
        final textItem = serverContent.firstWhere(
          (i) => i is Map && i['type'] == 'text',
          orElse: () => null,
        );
        if (textItem != null) {
          content = textItem['text']?.toString() ?? '';
        }
      }

      // Extract follow-ups (check both camelCase and snake_case keys)
      // Use _parseFollowUpsField for consistent parsing with socket handler
      final followUpsRaw = serverMsg['followUps'] ?? serverMsg['follow_ups'];
      final followUps = _parseFollowUpsField(followUpsRaw);
      final errorContent = extractServerErrorContent(serverMsg['error']);

      // Check completion status
      final isDone =
          serverMsg['done'] == true ||
          errorContent != null ||
          (serverMsg['isStreaming'] != true && content.isNotEmpty);

      return (
        content: content,
        followUps: followUps,
        isDone: isDone,
        errorContent: errorContent,
      );
    } catch (e) {
      DebugLogger.log(
        'Server poll failed (attempt ${attempt + 1}/$maxAttempts): $e',
        scope: 'streaming/helper',
      );

      // Linear backoff retry (1s, 2s, 3s)
      if (attempt < maxAttempts - 1) {
        final backoffMs = (attempt + 1) * 1000;
        await Future.delayed(Duration(milliseconds: backoffMs));
        if (isObsoleteStream) {
          return null;
        }
        return pollServerForMessage(
          attempt: attempt + 1,
          maxAttempts: maxAttempts,
        );
      }

      return null;
    }
  }

  // Helper to apply server content if it's better than local.
  // Returns true if content was applied, so caller can trigger image sync.
  bool applyServerContent(
    String content,
    List<String> followUps, {
    required bool finishIfDone,
    required bool isDone,
    required String source,
    String? errorContent,
  }) {
    if (isObsoleteStream) {
      return false;
    }
    final msgs = getMessages();
    if (msgs.isEmpty || msgs.last.role != 'assistant') return false;

    var applied = false;

    if (errorContent != null) {
      DebugLogger.log(
        '$source: adopting server error',
        scope: 'streaming/helper',
      );
      updateLastMessageWith(
        (m) => m.copyWith(
          error: errorContent.isNotEmpty
              ? ChatMessageError(content: errorContent)
              : const ChatMessageError(content: null),
        ),
      );
      applied = true;
    }

    if (content.isNotEmpty && content.length >= msgs.last.content.length) {
      DebugLogger.log(
        '$source: adopting server content (${content.length} chars)',
        scope: 'streaming/helper',
      );
      replaceVisibleAssistantContent(content);
      applied = true;

      if (followUps.isNotEmpty) {
        setFollowUps(assistantMessageId, followUps);
      }

      if (finishIfDone && isDone && msgs.last.isStreaming) {
        wrappedFinishStreaming();
      }
      return true;
    }

    if (followUps.isNotEmpty) {
      setFollowUps(assistantMessageId, followUps);
      applied = true;
    }

    if (finishIfDone && isDone) {
      wrappedFinishStreaming();
      return true;
    }

    return applied;
  }

  bool refreshingSnapshot = false;
  Future<void> refreshConversationSnapshot() async {
    if (isObsoleteStream || refreshingSnapshot) return;
    final chatId = activeConversationId;
    if (chatId == null || chatId.isEmpty || isTemporaryChat(chatId)) {
      return;
    }
    refreshingSnapshot = true;
    try {
      final conversation = await api.getConversation(chatId);
      if (isObsoleteStream) {
        return;
      }

      if (conversation.title.isNotEmpty && conversation.title != 'New Chat') {
        onChatTitleUpdated?.call(conversation.title);
      }

      if (conversation.messages.isEmpty) {
        return;
      }

      ChatMessage? foundAssistant;
      for (final message in conversation.messages.reversed) {
        if (message.role == 'assistant') {
          foundAssistant = message;
          break;
        }
      }

      final assistant = foundAssistant;
      if (assistant == null) {
        return;
      }

      setFollowUps(assistant.id, assistant.followUps);
      updateMessageById(assistant.id, (current) {
        // Preserve existing usage if server doesn't have it yet (issue #274)
        // Usage is captured from streaming but may not be persisted on server
        final effectiveUsage = assistant.usage ?? current.usage;
        return current.copyWith(
          followUps: List<String>.from(assistant.followUps),
          statusHistory: assistant.statusHistory,
          sources: assistant.sources,
          metadata: {...?current.metadata, ...?assistant.metadata},
          usage: effectiveUsage,
        );
      });
    } catch (_) {
      // Best-effort refresh; ignore failures.
    } finally {
      refreshingSnapshot = false;
    }
  }

  bool finishFromLocalState({required bool allowContentOnlyTerminal}) {
    if (isObsoleteStream) {
      return false;
    }
    flushStreamingBuffer();

    final msgs = getMessages();
    if (msgs.isEmpty || msgs.last.role != 'assistant') {
      return false;
    }

    final last = msgs.last;
    if (!last.isStreaming) {
      return true;
    }

    final hasTerminalState =
        last.error != null ||
        (allowContentOnlyTerminal && last.content.trim().isNotEmpty);
    if (!hasTerminalState) {
      return false;
    }

    wrappedFinishStreaming();
    return true;
  }

  Future<void> recoverTaskSocketTerminalState({
    required String source,
    bool allowContentOnlyTerminal = false,
  }) async {
    if (isObsoleteStream) {
      return;
    }
    try {
      final result = await pollServerForMessage();
      if (hasFinished || isObsoleteStream) {
        return;
      }

      if (result != null) {
        final applied = applyServerContent(
          result.content,
          result.followUps,
          finishIfDone: true,
          isDone: result.isDone,
          source: source,
          errorContent: result.errorContent,
        );
        if (applied) {
          syncImages();
        }
        if (hasFinished || isObsoleteStream) {
          return;
        }
      }
    } catch (e) {
      DebugLogger.log('$source failed: $e', scope: 'streaming/helper');
    }

    if (finishFromLocalState(
      allowContentOnlyTerminal: allowContentOnlyTerminal,
    )) {
      Future.microtask(refreshConversationSnapshot);
    }
  }

  if (hasSocketSignals) {
    // Handle socket reconnection - update session IDs and check for missed events
    StreamSubscription<void>? reconnectSub;
    Timer? reconnectDelayTimer;

    reconnectSub = socketService.onReconnect.listen((_) {
      DebugLogger.log(
        'Socket reconnected - updating session ID',
        scope: 'streaming/helper',
      );

      // Update handler registrations with new session ID (issue #172 fix)
      final newSessionId = socketService.sessionId;
      final convId = activeConversationId;
      if (newSessionId != null && convId != null && convId.isNotEmpty) {
        currentStreamSessionId = newSessionId;
        socketService.updateSessionIdForConversation(convId, newSessionId);
      }

      // Brief delay then check server for missed completion
      reconnectDelayTimer?.cancel();
      reconnectDelayTimer = Timer(const Duration(milliseconds: 500), () {
        // Wrap async work in unawaited to handle errors properly
        unawaited(
          _handleReconnectRecovery(
            hasFinished: () => hasFinished || isObsoleteStream,
            getMessages: getMessages,
            pollServerForMessage: pollServerForMessage,
            applyServerContent: applyServerContent,
            syncImages: syncImages,
          ),
        );
      });
    });

    socketSubscriptions.add(() {
      reconnectDelayTimer?.cancel();
      reconnectSub?.cancel();
    });
  }

  Timer? imageCollectionDebounce;
  String? pendingImageContent;
  String? pendingImageMessageId;
  String? pendingImageSignature;
  String? lastProcessedImageSignature;
  int imageCollectionRequestId = 0;

  void disposeSocketSubscriptions() {
    // Cancel HTTP subscription (if any — only taskSocket path creates one)
    try {
      httpSubscription?.cancel();
    } catch (_) {}

    // Cancel socket subscriptions
    for (final dispose in socketSubscriptions) {
      try {
        dispose();
      } catch (_) {}
    }
    socketSubscriptions.clear();

    imageCollectionDebounce?.cancel();
    imageCollectionDebounce = null;
    pendingImageContent = null;
    pendingImageMessageId = null;
    pendingImageSignature = null;
    lastProcessedImageSignature = null;
    imageCollectionRequestId = 0;
  }

  retireObsoleteStream = (String reason, {String? incomingMessageId}) {
    if (isObsoleteStream) {
      return;
    }
    isObsoleteStream = true;
    hasFinished = true;
    hasCompletedStreamingUi = true;

    DebugLogger.log(
      '$reason: retiring obsolete stream '
      '(assistant=$assistantMessageId, '
      'incoming=${incomingMessageId ?? '<none>'}, '
      'current=${currentAssistantTargetId() ?? '<none>'})',
      scope: 'streaming/helper',
    );

    disposeSocketSubscriptions();

    final controller = streamController;
    if (controller != null) {
      unawaited(controller.cancel().catchError((Object _) {}));
    }

    final abort = session.abort;
    if (abort != null) {
      unawaited(abort().catchError((Object _) {}));
    }

    api.clearStreamCancelToken(assistantMessageId);
    stopBackgroundExecution();
    try {
      onObsoleteStreamRetired?.call();
    } catch (_) {}
  };

  bool isSearching = false;

  void runPendingImageCollection() {
    if (isObsoleteStream) {
      return;
    }
    imageCollectionDebounce?.cancel();
    imageCollectionDebounce = null;

    final content = pendingImageContent;
    final targetMessageId = pendingImageMessageId;
    final signature = pendingImageSignature;
    if (content == null || targetMessageId == null || signature == null) {
      return;
    }

    pendingImageContent = null;
    pendingImageMessageId = null;
    pendingImageSignature = null;

    final requestId = ++imageCollectionRequestId;
    unawaited(
      workerManager
          .schedule<String, List<Map<String, dynamic>>>(
            _collectImageReferencesWorker,
            content,
            debugLabel: 'stream_collect_images',
          )
          .then((collected) {
            if (isObsoleteStream) {
              return;
            }
            if (requestId != imageCollectionRequestId) {
              return;
            }

            final currentMessages = getMessages();
            if (currentMessages.isEmpty) {
              return;
            }
            final last = currentMessages.last;
            if (last.id != targetMessageId || last.role != 'assistant') {
              return;
            }

            lastProcessedImageSignature = signature;

            if (collected.isEmpty) {
              return;
            }

            final existing = last.files ?? <Map<String, dynamic>>[];
            final seen = <String>{
              for (final f in existing)
                if (f['url'] is String) (f['url'] as String) else '',
            }..removeWhere((e) => e.isEmpty);

            final merged = <Map<String, dynamic>>[...existing];
            for (final f in collected) {
              final url = f['url'] as String?;
              if (url != null && url.isNotEmpty && !seen.contains(url)) {
                merged.add({'type': 'image', 'url': url});
                seen.add(url);
              }
            }

            if (merged.length != existing.length) {
              updateLastMessageWith((m) => m.copyWith(files: merged));
            }
          })
          .catchError((_) {}),
    );
  }

  updateImagesFromCurrentContent = () {
    if (isObsoleteStream) {
      return;
    }
    try {
      final msgs = getMessages();
      if (msgs.isEmpty || msgs.last.role != 'assistant') return;
      final last = msgs.last;
      final content = last.content;
      if (content.isEmpty) return;

      final targetMessageId = last.id;
      final signature =
          '$targetMessageId:${content.hashCode}:${content.length}';

      if (signature == lastProcessedImageSignature &&
          pendingImageSignature == null) {
        return;
      }
      if (signature == pendingImageSignature) {
        return;
      }

      pendingImageMessageId = targetMessageId;
      pendingImageContent = content;
      pendingImageSignature = signature;

      final shouldDelay = last.isStreaming;

      imageCollectionDebounce?.cancel();
      if (shouldDelay) {
        imageCollectionDebounce = Timer(
          const Duration(milliseconds: 200),
          runPendingImageCollection,
        );
      } else {
        runPendingImageCollection();
      }
    } catch (_) {}
  };

  // Bind the late reference now that updateImagesFromCurrentContent is defined
  syncImages = updateImagesFromCurrentContent;

  /// Sends the chatCompleted notification to the backend and processes any
  /// outlet-filter modifications returned by the server.
  ///
  /// Mirrors OpenWebUI's `chatCompletedHandler` in Chat.svelte:
  /// 1. POST to `/api/chat/completed` with the full message list
  /// 2. Merge any filter-modified messages back into local state
  ///
  /// Persisted chats intentionally avoid a follow-up full-history sync here.
  /// OpenWebUI 0.9.1+ already persists outlet changes server-side, and
  /// pushing the local buffer back can truncate chats when the client only
  /// has a partial history snapshot in memory.
  void sendChatCompletedAndSync() {
    unawaited(
      Future(() async {
        if (isObsoleteStream) {
          return;
        }
        try {
          // Build message list for the completed notification
          final currentMessages = getMessages();
          final messagesForCompleted = currentMessages.map((m) {
            final msgMap = <String, dynamic>{
              'id': m.id,
              'role': m.role,
              'content': m.content,
              'timestamp': m.timestamp.millisecondsSinceEpoch ~/ 1000,
            };
            if (m.role == 'assistant' && m.usage != null) {
              msgMap['usage'] = m.usage;
            }
            if (m.sources.isNotEmpty) {
              msgMap['sources'] = m.sources.map((s) => s.toJson()).toList();
            }
            return msgMap;
          }).toList();

          // 1. Send chatCompleted and AWAIT the response (outlet filters may
          //    modify messages). OpenWebUI awaits this before saving.
          final completedResp = await api.sendChatCompleted(
            chatId: activeConversationId ?? '',
            messageId: assistantMessageId,
            messages: messagesForCompleted,
            model: modelId,
            modelItem: modelItem,
            sessionId: currentStreamSessionId,
            filterIds: filterIds,
          );
          if (isObsoleteStream) {
            return;
          }

          // 2. Apply outlet filter modifications if any.
          // OpenWebUI does a full object spread; we merge all returned fields.
          final modifiedMsgs = completedResp?['messages'];
          if (modifiedMsgs is List) {
            for (final msg in modifiedMsgs) {
              if (msg is! Map) continue;
              final id = msg['id']?.toString();
              if (id == null) continue;
              updateMessageById(id, (current) {
                final newContent = msg['content']?.toString();
                if (newContent == null) return current;
                if (current.content == newContent) return current;
                // Preserve original content before filter modification
                final meta = <String, dynamic>{
                  ...?current.metadata,
                  'originalContent': current.content,
                };
                return current.copyWith(content: newContent, metadata: meta);
              });
            }
          }
        } catch (_) {}
      }),
    );
  }

  void channelLineHandlerFactory(String channel) {
    void onChannelDone() {
      try {
        socketService?.offEvent(channel);
      } catch (_) {}
      if (isObsoleteStream) {
        return;
      }
      finalizeStreamingReasoning();
      if (!isTemporaryChat(activeConversationId)) {
        sendChatCompletedAndSync();
      }
      wrappedFinishStreaming();
    }

    void handler(dynamic line) {
      if (isObsoleteStream || streamHasBeenSuperseded()) {
        retireObsoleteStream(
          'Superseded by channel stream $channel',
          incomingMessageId: null,
        );
        return;
      }
      try {
        if (line is String) {
          final s = line.trim();
          // Enhanced completion detection matching OpenWebUI patterns
          if (s == '[DONE]' || s == 'DONE' || s == 'data: [DONE]') {
            onChannelDone();
            return;
          }
          if (s.startsWith('data:')) {
            final dataStr = s.substring(5).trim();
            if (dataStr == '[DONE]') {
              onChannelDone();
              return;
            }
            try {
              final Map<String, dynamic> j = jsonDecode(dataStr);

              // Capture usage statistics from OpenAI-style streaming (issue #274)
              // Usage is sent in the final chunk with stream_options.include_usage
              final usageData = j['usage'];
              if (usageData is Map<String, dynamic> && usageData.isNotEmpty) {
                updateLastMessageWith((m) => m.copyWith(usage: usageData));
              }

              final choices = j['choices'];
              if (choices is List && choices.isNotEmpty) {
                final choice = choices.first;
                final delta = choice is Map ? choice['delta'] : null;
                if (delta is Map) {
                  if (delta.containsKey('tool_calls')) {
                    final tc = delta['tool_calls'];
                    if (tc is List) {
                      for (final call in tc) {
                        if (call is Map<String, dynamic>) {
                          final fn = call['function'];
                          final name = (fn is Map && fn['name'] is String)
                              ? fn['name'] as String
                              : null;
                          if (name is String && name.isNotEmpty) {
                            final exists = renderedStreamingContent.contains(
                              'name="$name"',
                            );
                            if (!exists) {
                              handleToolCallStatus(name);
                            }
                          }
                        }
                      }
                    }
                  }
                  handleStreamingChoiceDelta(delta);
                }
              }
            } catch (_) {
              if (s.isNotEmpty) {
                appendVisibleAssistantChunk(s);
              }
            }
          } else {
            if (s.isNotEmpty) {
              appendVisibleAssistantChunk(s);
            }
          }
        } else if (line is Map) {
          if (line['done'] == true) {
            onChannelDone();
            return;
          }
        }
      } catch (_) {}
    }

    try {
      socketService?.onEvent(channel, handler);
    } catch (_) {}
    // Increased timeout to match our more generous streaming timeouts
    // OpenWebUI doesn't have such aggressive channel timeouts
    // Use Timer instead of Future.delayed so it can be cancelled on cleanup
    final channelTimeoutTimer = Timer(const Duration(minutes: 12), () {
      try {
        socketService?.offEvent(channel);
      } catch (_) {}
    });
    // Register cleanup for socket subscriptions
    socketSubscriptions.add(() {
      channelTimeoutTimer.cancel();
      try {
        socketService?.offEvent(channel);
      } catch (_) {}
    });
  }

  void chatHandler(
    Map<String, dynamic> ev,
    void Function(dynamic response)? ack,
  ) {
    try {
      final data = ev['data'];
      if (data == null) return;
      final type = data['type'];

      final payload = data['data'];
      final messageId = ev['message_id']?.toString();
      final incomingSessionId = extractEventSessionId(ev);

      if (isObsoleteStream) {
        return;
      }
      if (streamHasBeenSuperseded()) {
        retireObsoleteStream(
          'Superseded by socket event ${type ?? 'unknown'}',
          incomingMessageId: messageId,
        );
        return;
      }

      if (kSocketVerboseLogging && payload is Map) {
        DebugLogger.log(
          'socket delta type=$type session=$currentStreamSessionId '
          'message=$messageId keys=${payload.keys.toList()}',
          scope: 'socket/chat',
        );
      }

      if (type == 'chat:completion' && payload != null) {
        if (payload is Map<String, dynamic>) {
          final completionTargetId = resolveTargetMessageIdForStream(
            messageId,
            eventType: 'chat:completion',
            incomingSessionId: incomingSessionId,
            allowBindingForeignMessage: true,
          );
          String? terminalFinishReason;

          // Store the structured output[] array from the backend middleware.
          // This contains OR-aligned items (message, reasoning,
          // code_interpreter, function_call, function_call_output).
          final outputItems = payload['output'];
          if (completionTargetId != null &&
              outputItems is List &&
              outputItems.isNotEmpty) {
            updateMessageById(completionTargetId, (current) {
              return current.copyWith(
                output: outputItems.whereType<Map<String, dynamic>>().toList(
                  growable: false,
                ),
              );
            });
          }

          // Capture the selected_model_id for arena/routing flows.
          final selectedModelId = payload['selected_model_id']?.toString();
          if (completionTargetId != null &&
              selectedModelId != null &&
              selectedModelId.isNotEmpty) {
            updateMessageById(completionTargetId, (current) {
              return current.copyWith(
                metadata: {
                  ...?current.metadata,
                  'selectedModelId': selectedModelId,
                  'arena': true,
                },
              );
            });
          }

          // Capture usage statistics whenever they appear (issue #274)
          // Usage may come in a separate payload before the done:true payload
          final usageData = payload['usage'];
          if (completionTargetId != null &&
              usageData is Map<String, dynamic> &&
              usageData.isNotEmpty) {
            updateMessageById(completionTargetId, (current) {
              return current.copyWith(usage: usageData);
            });
          }

          final rawSources = payload['sources'] ?? payload['citations'];
          final normalizedSources = _normalizeSourcesPayload(rawSources);
          if (completionTargetId != null &&
              normalizedSources != null &&
              normalizedSources.isNotEmpty) {
            final parsedSources = parseOpenWebUISourceList(normalizedSources);
            if (parsedSources.isNotEmpty) {
              for (final source in parsedSources) {
                appendSourceReference(completionTargetId, source);
              }
            }
          }
          if (payload.containsKey('tool_calls')) {
            if (completionTargetId != null) {
              final tc = payload['tool_calls'];
              if (tc is List) {
                for (final call in tc) {
                  if (call is Map<String, dynamic>) {
                    final fn = call['function'];
                    final name = (fn is Map && fn['name'] is String)
                        ? fn['name'] as String
                        : null;
                    if (name is String && name.isNotEmpty) {
                      final exists = renderedStreamingContent.contains(
                        'name="$name"',
                      );
                      if (!exists) {
                        handleToolCallStatus(name);
                      }
                    }
                  }
                }
              }
            }
          }
          if (completionTargetId != null && payload.containsKey('choices')) {
            final choices = payload['choices'];
            if (choices is List && choices.isNotEmpty) {
              final choice = choices.first;
              final delta = choice is Map ? choice['delta'] : null;
              final finishReason = choice is Map
                  ? choice['finish_reason']?.toString()
                  : null;
              if (isTerminalFinishReason(finishReason)) {
                terminalFinishReason = finishReason;
              }
              if (delta is Map) {
                if (delta.containsKey('tool_calls')) {
                  final tc = delta['tool_calls'];
                  if (tc is List) {
                    for (final call in tc) {
                      if (call is Map<String, dynamic>) {
                        final fn = call['function'];
                        final name = (fn is Map && fn['name'] is String)
                            ? fn['name'] as String
                            : null;
                        if (name is String && name.isNotEmpty) {
                          final exists = renderedStreamingContent.contains(
                            'name="$name"',
                          );
                          if (!exists) {
                            handleToolCallStatus(name);
                          }
                        }
                      }
                    }
                  }
                }
                handleStreamingChoiceDelta(delta);
              }
            }
          }
          if (completionTargetId != null && payload.containsKey('content')) {
            final raw = payload['content']?.toString() ?? '';
            if (raw.isNotEmpty) {
              replaceVisibleAssistantContent(raw);
            }
          }
          if (terminalFinishReason != null && !hasFinished) {
            flushStreamingBuffer();
            final msgs = getMessages();
            if (msgs.isNotEmpty && msgs.last.role == 'assistant') {
              final last = msgs.last;
              final hasTerminalContent =
                  last.content.trim().isNotEmpty ||
                  last.error != null ||
                  (last.files?.isNotEmpty ?? false) ||
                  last.codeExecutions.isNotEmpty ||
                  last.sources.isNotEmpty;
              if (hasTerminalContent) {
                DebugLogger.log(
                  'Terminal finish_reason=$terminalFinishReason '
                  '- closing visible streaming state',
                  scope: 'streaming/helper',
                );
                completeVisibleStreaming();
              }
            }
          }
          if (payload['done'] == true) {
            if (completionTargetId == null) {
              return;
            }
            // The done payload may carry a title (OpenWebUI includes
            // the auto-generated chat title in the final completion
            // event). Surface it the same way as a chat:title event.
            final doneTitle = payload['title'];
            if (doneTitle is String && doneTitle.isNotEmpty) {
              onChatTitleUpdated?.call(doneTitle);
            }
            try {
              if (!isTemporaryChat(activeConversationId)) {
                sendChatCompletedAndSync();
              }
            } catch (_) {
              // Non-critical - continue if sync fails
            }

            // Delay snapshot refresh to allow backend to persist data
            Future.delayed(
              const Duration(milliseconds: 500),
              refreshConversationSnapshot,
            );

            finalizeStreamingReasoning();

            // Flush buffer and check if we have content
            flushStreamingBuffer();
            final msgs = getMessages();
            if (msgs.isNotEmpty && msgs.last.role == 'assistant') {
              final lastContent = msgs.last.content.trim();
              DebugLogger.log(
                'Done signal received: content length=${lastContent.length}',
                scope: 'streaming/helper',
              );
              if (lastContent.isEmpty) {
                // No content from deltas or done event. Schedule a delayed
                // server fetch as a last-resort recovery. The 2s delay gives
                // the server time to persist the response.
                final chatId = activeConversationId;
                if (chatId != null &&
                    chatId.isNotEmpty &&
                    !isTemporaryChat(chatId)) {
                  Future.delayed(const Duration(seconds: 2), () async {
                    if (hasFinished || isObsoleteStream) {
                      // Already finished via another path
                      return;
                    }
                    try {
                      final result = await pollServerForMessage();
                      if (!isObsoleteStream &&
                          result != null &&
                          result.content.isNotEmpty) {
                        replaceVisibleAssistantContent(result.content);
                        if (result.followUps.isNotEmpty) {
                          setFollowUps(assistantMessageId, result.followUps);
                        }
                      }
                    } catch (e) {
                      DebugLogger.log(
                        'Server recovery failed: $e',
                        scope: 'streaming/helper',
                      );
                    } finally {
                      wrappedFinishStreaming();
                    }
                  });
                  return;
                }
              }
            }
            wrappedFinishStreaming();
          }
        }
      } else if (type == 'status' && payload != null) {
        final statusMap = _asStringMap(payload);
        final targetId = resolveTargetMessageIdForStream(
          messageId,
          eventType: 'status',
          incomingSessionId: incomingSessionId,
          allowBindingForeignMessage: true,
        );
        if (statusMap != null && targetId != null) {
          try {
            final statusUpdate = ChatStatusUpdate.fromJson(statusMap);
            appendStatusUpdate(targetId, statusUpdate);
            updateMessageById(targetId, (current) {
              final metadata = {
                ...?current.metadata,
                'status': statusUpdate.toJson(),
              };
              return current.copyWith(metadata: metadata);
            });
          } catch (_) {}
        }
      } else if (type == 'chat:tasks:cancel') {
        final targetId = resolveTargetMessageIdForStream(
          messageId,
          eventType: 'chat:tasks:cancel',
          incomingSessionId: incomingSessionId,
          allowBindingForeignMessage: true,
        );
        if (targetId == null) {
          return;
        }
        updateMessageById(targetId, (current) {
          final metadata = {...?current.metadata, 'tasksCancelled': true};
          return current.copyWith(metadata: metadata, isStreaming: false);
        });
        disposeSocketSubscriptions();
        wrappedFinishStreaming();
      } else if (type == 'chat:message:follow_ups' && payload != null) {
        DebugLogger.log('Received follow-ups event', scope: 'streaming/helper');
        final followMap = _asStringMap(payload);
        if (followMap != null) {
          final followUpsRaw =
              followMap['follow_ups'] ?? followMap['followUps'];
          final suggestions = _parseFollowUpsField(followUpsRaw);
          final targetId = resolveTargetMessageIdForStream(
            messageId,
            eventType: 'chat:message:follow_ups',
            incomingSessionId: incomingSessionId,
            allowBindingForeignMessage: true,
          );
          DebugLogger.log(
            'Follow-ups: ${suggestions.length} suggestions for message $targetId',
            scope: 'streaming/helper',
          );
          if (targetId != null) {
            setFollowUps(targetId, suggestions);
            updateMessageById(targetId, (current) {
              final metadata = {...?current.metadata, 'followUps': suggestions};
              return current.copyWith(metadata: metadata);
            });
            DebugLogger.log(
              'Follow-ups set successfully',
              scope: 'streaming/helper',
            );

            // OpenWebUI persists follow-ups server-side. Avoid writing the
            // entire local chat history back here because the local buffer may
            // still be incomplete for large persisted conversations.
          } else {
            final isForeignSession =
                incomingSessionId != null &&
                incomingSessionId.isNotEmpty &&
                !matchesCurrentStreamSession(incomingSessionId);
            final isUnexpectedMessage =
                messageId != null &&
                messageId.isNotEmpty &&
                messageId != assistantMessageId &&
                messageId != boundRemoteMessageId;
            if (isForeignSession && isUnexpectedMessage) {
              retireObsoleteStream(
                'Foreign-session follow-ups superseded local stream',
                incomingMessageId: messageId,
              );
              return;
            }
            DebugLogger.log(
              'Follow-ups: targetId is null',
              scope: 'streaming/helper',
            );
          }
        } else {
          DebugLogger.log(
            'Follow-ups: failed to parse payload',
            scope: 'streaming/helper',
          );
        }
      } else if (type == 'chat:title' && payload != null) {
        final title = payload.toString();
        if (title.isNotEmpty) {
          onChatTitleUpdated?.call(title);
        }
      } else if (type == 'chat:tags') {
        onChatTagsUpdated?.call();
      } else if ((type == 'source' || type == 'citation') && payload != null) {
        final map = _asStringMap(payload);
        if (map != null) {
          if (map['type']?.toString() == 'code_execution') {
            try {
              final exec = ChatCodeExecution.fromJson(map);
              final targetId = resolveTargetMessageIdForStream(
                messageId,
                eventType: type.toString(),
                incomingSessionId: incomingSessionId,
                allowBindingForeignMessage: true,
              );
              if (targetId != null) {
                upsertCodeExecution(targetId, exec);
              }
            } catch (_) {}
          } else {
            try {
              final sources = parseOpenWebUISourceList([map]);
              if (sources.isNotEmpty) {
                final targetId = resolveTargetMessageIdForStream(
                  messageId,
                  eventType: type.toString(),
                  incomingSessionId: incomingSessionId,
                  allowBindingForeignMessage: true,
                );
                if (targetId != null) {
                  for (final source in sources) {
                    appendSourceReference(targetId, source);
                  }
                }
              }
            } catch (_) {}
          }
        }
      } else if (type == 'notification' && payload != null) {
        if (!matchesCurrentStreamSession(incomingSessionId)) {
          return;
        }
        final map = _asStringMap(payload);
        if (map != null) {
          final notifType = map['type']?.toString() ?? 'info';
          final content = map['content']?.toString() ?? '';
          _showSocketNotification(notifType, content);
        }
      } else if (type == 'confirmation' && payload != null) {
        if (!matchesCurrentStreamSession(incomingSessionId)) {
          return;
        }
        if (ack != null) {
          final map = _asStringMap(payload);
          if (map != null) {
            () async {
              final confirmed = await _showConfirmationDialog(map);
              try {
                ack(confirmed);
              } catch (_) {}
            }();
          } else {
            ack(false);
          }
        }
      } else if (type == 'execute' && payload != null) {
        if (!matchesCurrentStreamSession(incomingSessionId)) {
          return;
        }
        // The backend sends JavaScript code for the web client to eval.
        // Flutter can't execute JS, so we return null (not an error object)
        // to let the pipe/function continue with its default behavior.
        if (ack != null) {
          try {
            // Return empty string result (mimics JS code evaluating to
            // undefined). Returning null or {error:...} causes pipes to abort.
            ack('');
          } catch (_) {}
        }
      } else if (type == 'input' && payload != null) {
        if (!matchesCurrentStreamSession(incomingSessionId)) {
          return;
        }
        if (ack != null) {
          final map = _asStringMap(payload);
          if (map != null) {
            () async {
              final response = await _showInputDialog(map);
              try {
                ack(response);
              } catch (_) {}
            }();
          } else {
            ack(null);
          }
        }
      } else if (type == 'chat:message:error' && payload != null) {
        // Server reports an error for the current assistant message
        try {
          final targetId = resolveTargetMessageIdForStream(
            messageId,
            eventType: 'chat:message:error',
            incomingSessionId: incomingSessionId,
            allowBindingForeignMessage: true,
          );
          if (targetId == null) {
            return;
          }
          dynamic err = payload is Map ? payload['error'] : null;
          String errorContent = '';
          if (err is Map) {
            final c = err['content'];
            if (c is String) {
              errorContent = c;
            } else if (c != null) {
              errorContent = c.toString();
            }
          } else if (err is String) {
            errorContent = err;
          } else if (payload is Map && payload['message'] is String) {
            errorContent = payload['message'];
          }
          // Set the error field on the message for proper OpenWebUI round-trip
          // Also drop search-only status rows so the error feels cleaner
          updateMessageById(targetId, (message) {
            final filtered = message.statusHistory
                .where((status) => status.action != 'knowledge_search')
                .toList(growable: false);
            return message.copyWith(
              error: errorContent.isNotEmpty
                  ? ChatMessageError(content: errorContent)
                  : const ChatMessageError(content: null),
              statusHistory: filtered,
            );
          });
        } catch (_) {}
        // Ensure UI exits streaming state
        wrappedFinishStreaming();
      } else if ((type == 'chat:message:delta' || type == 'message') &&
          payload != null) {
        if (resolveTargetMessageIdForStream(
              messageId,
              eventType: type.toString(),
              incomingSessionId: incomingSessionId,
              allowBindingForeignMessage: true,
            ) !=
            null) {
          final content = payload['content']?.toString() ?? '';
          if (content.isNotEmpty) {
            appendVisibleAssistantChunk(content);
          }
        }
      } else if ((type == 'chat:message' || type == 'replace') &&
          payload != null) {
        if (resolveTargetMessageIdForStream(
              messageId,
              eventType: type.toString(),
              incomingSessionId: incomingSessionId,
              allowBindingForeignMessage: true,
            ) !=
            null) {
          final content = payload['content']?.toString() ?? '';
          if (content.isNotEmpty) {
            replaceVisibleAssistantContent(content);
          }
        }
      } else if ((type == 'chat:message:files') && payload != null) {
        // Alias for files event used by web client
        try {
          final targetId = resolveTargetMessageIdForStream(
            messageId,
            eventType: 'chat:message:files',
            incomingSessionId: incomingSessionId,
            allowBindingForeignMessage: true,
          );
          if (targetId == null) {
            return;
          }
          final files = _extractFilesFromResult(payload['files'] ?? payload);
          final msgs = getMessages();
          ChatMessage? target;
          for (final message in msgs) {
            if (message.id == targetId) {
              target = message;
              break;
            }
          }
          if (target != null && target.role == 'assistant') {
            final merged = _mergeNormalizedFiles(
              incoming: files,
              existing: target.files ?? <Map<String, dynamic>>[],
            );
            if (merged != null) {
              updateMessageById(targetId, (m) => m.copyWith(files: merged));
            }
          }
        } catch (_) {}
      } else if ((type == 'chat:message:embeds' || type == 'embeds') &&
          payload != null) {
        // Rich UI embed objects attached to this message (e.g. HTML tool
        // results). Mirrors OpenWebUI's Chat.svelte handler.
        try {
          final rawEmbeds = payload is Map ? payload['embeds'] : payload;
          final shouldReplaceEmbeds = rawEmbeds is List;
          final embeds = normalizeEmbedList(rawEmbeds);
          if (shouldReplaceEmbeds || embeds.isNotEmpty) {
            final targetId = resolveTargetMessageIdForStream(
              messageId,
              eventType: 'chat:message:embeds',
              incomingSessionId: incomingSessionId,
              allowBindingForeignMessage: true,
            );
            if (targetId != null) {
              updateMessageById(targetId, (current) {
                return current.copyWith(embeds: embeds);
              });
            }
          }
        } catch (_) {}
      } else if (type == 'chat:message:favorite' && payload != null) {
        // Favorite/unfavorite toggle from the server.
        try {
          final favorite = payload['favorite'];
          if (favorite is bool) {
            final targetId = resolveTargetMessageIdForStream(
              messageId,
              eventType: 'chat:message:favorite',
              incomingSessionId: incomingSessionId,
              allowBindingForeignMessage: true,
            );
            if (targetId != null) {
              updateMessageById(targetId, (current) {
                return current.copyWith(
                  metadata: {...?current.metadata, 'favorite': favorite},
                );
              });
            }
          }
        } catch (_) {}
      } else if (type == 'chat:active' && payload != null) {
        // Task lifecycle indicator: {active: true} when a background task
        // starts and {active: false} when it completes. Used by the sidebar
        // in OpenWebUI to show activity indicators.
        // We propagate via onChatActiveChanged if provided.
        try {
          final active = payload['active'];
          if (active is bool) {
            if (!matchesCurrentStreamSession(incomingSessionId)) {
              return;
            }
            onChatActiveChanged?.call(activeConversationId, active);
            if (!active && !hasFinished) {
              unawaited(
                recoverTaskSocketTerminalState(
                  source: 'taskSocket inactive recovery',
                  allowContentOnlyTerminal: true,
                ),
              );
            }
          }
        } catch (_) {}
      } else if (type == 'execute:python' && payload != null) {
        if (!matchesCurrentStreamSession(incomingSessionId)) {
          return;
        }
        // Pyodide code execution request. Flutter can't run Python,
        // so return an empty result (not an error) to let the pipe
        // continue with its default behavior.
        if (ack != null) {
          try {
            ack({'stdout': '', 'stderr': '', 'result': null});
          } catch (_) {}
        }
      } else if (type == 'request:chat:completion' && payload != null) {
        if (resolveTargetMessageIdForStream(
              messageId,
              eventType: 'request:chat:completion',
              incomingSessionId: incomingSessionId,
              allowBindingForeignMessage: true,
            ) ==
            null) {
          return;
        }
        final channel = payload['channel'];
        if (channel is String && channel.isNotEmpty) {
          channelLineHandlerFactory(channel);
        }
        // Acknowledge the RPC call so the server can proceed immediately.
        // Without this, sio.call() waits for the 60s timeout (issue #378).
        if (ack != null) {
          ack({'status': true});
        }
      } else if (type == 'execute:tool' && payload != null) {
        // Show an executing tile immediately; also surface any inline files/result
        try {
          if (resolveTargetMessageIdForStream(
                messageId,
                eventType: 'execute:tool',
                incomingSessionId: incomingSessionId,
                allowBindingForeignMessage: true,
              ) ==
              null) {
            return;
          }
          final name = payload['name']?.toString() ?? 'tool';
          handleToolCallStatus(name);
          try {
            final filesA = _extractFilesFromResult(payload['files']);
            final filesB = _extractFilesFromResult(payload['result']);
            final all = [...filesA, ...filesB];
            if (all.isNotEmpty) {
              final msgs = getMessages();
              if (msgs.isNotEmpty && msgs.last.role == 'assistant') {
                final existing = msgs.last.files ?? <Map<String, dynamic>>[];
                final seen = <String>{
                  for (final f in existing)
                    if (f['url'] is String) (f['url'] as String) else '',
                }..removeWhere((e) => e.isEmpty);
                final merged = <Map<String, dynamic>>[...existing];
                for (final f in all) {
                  final url = f['url'] as String?;
                  if (url != null && url.isNotEmpty && !seen.contains(url)) {
                    merged.add({'type': 'image', 'url': url});
                    seen.add(url);
                  }
                }
                if (merged.length != existing.length) {
                  updateLastMessageWith((m) => m.copyWith(files: merged));
                }
              }
            }
          } catch (_) {}
        } catch (_) {}
      } else if (type == 'files' && payload != null) {
        if (!matchesCurrentStreamSession(incomingSessionId)) {
          return;
        }
        // Handle raw files event (image generation results)
        try {
          final files = _extractFilesFromResult(payload);
          final msgs = getMessages();
          if (msgs.isNotEmpty && msgs.last.role == 'assistant') {
            final merged = _mergeNormalizedFiles(
              incoming: files,
              existing: msgs.last.files ?? <Map<String, dynamic>>[],
            );
            if (merged != null) {
              updateLastMessageWith((m) => m.copyWith(files: merged));
            }
          }
        } catch (_) {}
      } else if (type == 'event:status' && payload != null) {
        final map = _asStringMap(payload);
        final targetId = resolveTargetMessageIdForStream(
          messageId,
          eventType: 'event:status',
          incomingSessionId: incomingSessionId,
          allowBindingForeignMessage: true,
        );
        if (map != null && targetId != null) {
          try {
            final status = map['status']?.toString() ?? '';
            if (status.isNotEmpty) {
              updateMessageById(targetId, (message) {
                return message.copyWith(
                  metadata: {...?message.metadata, 'status': status},
                );
              });
            }
            final statusUpdate = ChatStatusUpdate.fromJson(map);
            appendStatusUpdate(targetId, statusUpdate);
          } catch (_) {}
        }
      } else if (type == 'event:tool' && payload != null) {
        if (!matchesCurrentStreamSession(incomingSessionId)) {
          return;
        }
        // Accept files from both 'result' and 'files'
        final files = [
          ..._extractFilesFromResult(payload['files']),
          ..._extractFilesFromResult(payload['result']),
        ];
        if (files.isNotEmpty) {
          final msgs = getMessages();
          if (msgs.isNotEmpty && msgs.last.role == 'assistant') {
            final existing = msgs.last.files ?? <Map<String, dynamic>>[];
            final merged = [...existing, ...files];
            updateLastMessageWith((m) => m.copyWith(files: merged));
          }
        }
      } else if (type == 'event:message:delta' && payload != null) {
        if (resolveTargetMessageIdForStream(
              messageId,
              eventType: 'event:message:delta',
              incomingSessionId: incomingSessionId,
              allowBindingForeignMessage: true,
            ) !=
            null) {
          final content = payload['content']?.toString() ?? '';
          if (content.isNotEmpty) {
            appendVisibleAssistantChunk(content);
          }
        }
      } else {
        // Log unknown event types to catch any follow-up events we might be missing
        if (type != null && type.toString().contains('follow')) {
          DebugLogger.log(
            'Unknown follow-up related event: $type',
            scope: 'streaming/helper',
          );
        }
      }
    } catch (_) {}
  }

  void channelEventsHandler(
    Map<String, dynamic> ev,
    void Function(dynamic response)? ack,
  ) {
    try {
      final data = ev['data'];
      if (data == null) return;
      final type = data['type'];
      final payload = data['data'];
      if (isObsoleteStream) {
        return;
      }
      if (streamHasBeenSuperseded()) {
        retireObsoleteStream(
          'Superseded by channel event ${type ?? 'unknown'}',
          incomingMessageId: null,
        );
        return;
      }
      if (type == 'message' && payload is Map) {
        final content = payload['content']?.toString() ?? '';
        if (content.isNotEmpty) {
          appendVisibleAssistantChunk(content);
        }
      } else {
        // Log channel events that might include follow-ups
        if (type != null && type.toString().contains('follow')) {
          DebugLogger.log(
            'Channel follow-up event: $type',
            scope: 'streaming/helper',
          );
        }
      }
    } catch (_) {}
  }

  // Register socket handlers directly. Events buffered before registration
  // are replayed synchronously via addChatEventHandler's built-in replay.
  if (socketService != null) {
    final chatSub = socketService.addChatEventHandler(
      conversationId: activeConversationId,
      sessionId: sessionId,
      messageId: assistantMessageId,
      requireFocus: false,
      handler: chatHandler,
    );
    socketSubscriptions.add(chatSub.dispose);

    final channelSub = socketService.addChannelEventHandler(
      conversationId: activeConversationId,
      sessionId: sessionId,
      requireFocus: false,
      handler: channelEventsHandler,
    );
    socketSubscriptions.add(channelSub.dispose);
  }

  // -----------------------------------------------------------------------
  // Transport dispatch
  // -----------------------------------------------------------------------

  switch (session.transport) {
    case ChatCompletionTransport.httpStream:
      // Parse the SSE byte stream directly via the typed parser.
      bool receivedDone = false;
      final sub = parseOpenWebUIStream(session.byteStream!).listen(
        (update) {
          try {
            switch (update) {
              case OpenWebUIContentDelta(:final content):
                appendVisibleAssistantChunk(content);

              case OpenWebUIReasoningDelta(:final content):
                applyStreamingReasoningDelta(content);

              case OpenWebUIOutputUpdate(:final output):
                // Store structured output items from backend middleware.
                updateLastMessageWith(
                  (m) => m.copyWith(
                    output: output.whereType<Map<String, dynamic>>().toList(
                      growable: false,
                    ),
                  ),
                );

              case OpenWebUIUsageUpdate(:final usage):
                updateLastMessageWith((m) => m.copyWith(usage: usage));

              case OpenWebUISourcesUpdate(:final sources):
                final parsed = parseOpenWebUISourceList(sources);
                for (final source in parsed) {
                  appendSourceReference(assistantMessageId, source);
                }

              case OpenWebUISelectedModelUpdate(:final selectedModelId):
                updateLastMessageWith(
                  (m) => m.copyWith(
                    metadata: {
                      ...?m.metadata,
                      'selectedModelId': selectedModelId,
                      'arena': true,
                    },
                  ),
                );

              case OpenWebUIErrorUpdate(:final error):
                updateLastMessageWith(
                  (m) => m.copyWith(
                    error: ChatMessageError(
                      content: error['message']?.toString(),
                    ),
                  ),
                );

              case OpenWebUIStreamDone():
                finalizeStreamingReasoning();
                receivedDone = true;
                wrappedFinishStreaming();
            }
          } catch (e) {
            DebugLogger.error(
              'httpStream update handler error',
              scope: 'streaming/helper',
              error: e,
            );
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          DebugLogger.error(
            'httpStream parse error',
            scope: 'streaming/helper',
            error: error,
          );
          wrappedFinishStreaming();
        },
        onDone: () {
          // Stream ended. If we already received [DONE], nothing to do.
          if (receivedDone || hasFinished) return;

          DebugLogger.log(
            'httpStream ended without [DONE] - attempting recovery',
            scope: 'streaming/helper',
          );

          // Try to recover from server state.
          unawaited(
            (() async {
              try {
                final result = await pollServerForMessage();
                if (hasFinished) return;

                if (result != null) {
                  final applied = applyServerContent(
                    result.content,
                    result.followUps,
                    finishIfDone: true,
                    isDone: result.isDone,
                    source: 'httpStream premature-end recovery',
                    errorContent: result.errorContent,
                  );
                  if (applied) {
                    syncImages();
                    if (hasFinished) {
                      return;
                    }
                  }
                }
              } catch (e) {
                DebugLogger.log(
                  'httpStream recovery poll failed: $e',
                  scope: 'streaming/helper',
                );
              }
              // If recovery didn't finish streaming, finish now.
              wrappedFinishStreaming();
            })(),
          );
        },
      );
      socketSubscriptions.add(() {
        sub.cancel();
      });

    case ChatCompletionTransport.taskSocket:
      // For task/socket streaming the HTTP response body is typically empty
      // or very short (just the task_id JSON). We set up a
      // StreamController + StreamingResponseController so the existing
      // onComplete / onChunk / onError wiring is preserved.
      final pc = StreamController<String>.broadcast();

      // If there's a byteStream from the HTTP response, forward it.
      if (session.byteStream != null) {
        httpSubscription = session.byteStream!
            .transform(utf8.decoder)
            .listen(
              (data) => pc.add(data),
              onDone: () {
                DebugLogger.stream(
                  'taskSocket HTTP stream completed '
                  '- WebSocket handles content delivery',
                );
                if (!pc.isClosed) {
                  pc.close();
                }
              },
              onError: pc.addError,
            );
      } else {
        // No byte stream to forward — close the controller immediately so
        // the StreamingResponseController treats the HTTP side as complete.
        Future.microtask(() {
          if (!pc.isClosed) pc.close();
        });
      }

      streamController = StreamingResponseController(
        stream: pc.stream,
        onChunk: (chunk) {
          var effectiveChunk = chunk;
          if (webSearchEnabled && !isSearching) {
            if (chunk.contains('[SEARCHING]') ||
                chunk.contains('Searching the web') ||
                chunk.contains('web search')) {
              isSearching = true;
              updateLastMessageWith(
                (message) => message.copyWith(
                  content: '🔍 Searching the web...',
                  metadata: {'webSearchActive': true},
                ),
              );
              return;
            }
          }

          if (isSearching &&
              (chunk.contains('[/SEARCHING]') ||
                  chunk.contains('Search complete'))) {
            isSearching = false;
            updateLastMessageWith(
              (message) =>
                  message.copyWith(metadata: {'webSearchActive': false}),
            );
            effectiveChunk = effectiveChunk
                .replaceAll('[SEARCHING]', '')
                .replaceAll('[/SEARCHING]', '');
          }

          if (effectiveChunk.trim().isNotEmpty) {
            appendVisibleAssistantChunk(effectiveChunk);
          }
        },
        onComplete: () {
          DebugLogger.log(
            'taskSocket HTTP stream complete '
            '(socketSubs=${socketSubscriptions.length}, '
            'socketConnected=${socketService?.isConnected})',
            scope: 'streaming/helper',
          );

          if (socketSubscriptions.isEmpty) {
            DebugLogger.log(
              'No socket subscriptions - finishing streaming on HTTP complete',
              scope: 'streaming/helper',
            );
            wrappedFinishStreaming();
            Future.microtask(refreshConversationSnapshot);
          } else {
            DebugLogger.log(
              'Socket subscriptions active '
              '- waiting for socket done signal',
              scope: 'streaming/helper',
            );
          }
        },
        onError: (error, stackTrace) async {
          DebugLogger.error(
            'taskSocket stream error',
            scope: 'streaming/helper',
            error: error,
            data: {
              'conversationId': activeConversationId,
              'messageId': assistantMessageId,
              'modelId': modelId,
            },
          );

          final errorText = error.toString();
          final isRecoverable =
              error is! FormatException &&
              (errorText.contains('SocketException') ||
                  errorText.contains('TimeoutException') ||
                  errorText.contains('HandshakeException'));

          if (isRecoverable && socketService != null) {
            try {
              final connected = await socketService.ensureConnected(
                timeout: const Duration(seconds: 5),
              );
              if (connected) {
                DebugLogger.log(
                  'Socket recovery successful',
                  scope: 'streaming/helper',
                );
                return;
              }
            } catch (e) {
              DebugLogger.log(
                'Socket recovery failed: $e',
                scope: 'streaming/helper',
              );
            }
          }

          disposeSocketSubscriptions();
          wrappedFinishStreaming();
          Future.microtask(refreshConversationSnapshot);
        },
      );

    case ChatCompletionTransport.jsonCompletion:
      // Non-streamed: apply the JSON payload immediately.
      Future.microtask(() {
        try {
          final payload = session.jsonPayload ?? const <String, dynamic>{};

          // Apply error if present
          if (payload['error'] != null) {
            final error = payload['error'];
            final errorMap = error is Map<String, dynamic>
                ? error
                : <String, dynamic>{'message': error.toString()};
            updateLastMessageWith(
              (m) => m.copyWith(
                error: ChatMessageError(
                  content: errorMap['message']?.toString(),
                ),
              ),
            );
            wrappedFinishStreaming();
            return;
          }

          // Extract content from choices
          final choices = payload['choices'];
          if (choices is List && choices.isNotEmpty) {
            final firstChoice = choices.first;
            if (firstChoice is Map<String, dynamic>) {
              final message = firstChoice['message'];
              if (message is Map<String, dynamic>) {
                final content = message['content']?.toString() ?? '';
                if (content.isNotEmpty) {
                  replaceVisibleAssistantContent(content);
                }
              }
            }
          }

          // Apply usage
          final usage = payload['usage'];
          if (usage is Map<String, dynamic> && usage.isNotEmpty) {
            updateLastMessageWith((m) => m.copyWith(usage: usage));
          }

          // Apply sources
          final rawSources = payload['sources'];
          if (rawSources != null) {
            final normalizedSources = _normalizeSourcesPayload(rawSources);
            if (normalizedSources != null && normalizedSources.isNotEmpty) {
              final parsedSources = parseOpenWebUISourceList(normalizedSources);
              for (final source in parsedSources) {
                appendSourceReference(assistantMessageId, source);
              }
            }
          }

          wrappedFinishStreaming();
        } catch (e) {
          DebugLogger.error(
            'jsonCompletion processing error',
            scope: 'streaming/helper',
            error: e,
          );
          wrappedFinishStreaming();
        }
      });
  }

  return ActiveChatStream(
    controller: streamController,
    socketSubscriptions: socketSubscriptions,
    disposeWatchdog: () {},
  );
}

/// Normalizes incoming file payloads and merges them with existing files
/// on the assistant message, deduplicating by URL.
///
/// Returns the merged list if new files were added, or `null` if no
/// update is needed (all files were duplicates or empty).
List<Map<String, dynamic>>? _mergeNormalizedFiles({
  required List<Map<String, dynamic>> incoming,
  required List<Map<String, dynamic>> existing,
}) {
  if (incoming.isEmpty) return null;

  final seen = <String>{
    for (final f in existing)
      if (f['url'] is String) f['url'] as String,
  };

  final merged = <Map<String, dynamic>>[...existing];
  for (final f in incoming) {
    final url = f['url'] as String?;
    if (url != null && url.isNotEmpty && seen.add(url)) {
      merged.add({'type': 'image', 'url': url});
    }
  }

  return merged.length != existing.length ? merged : null;
}

List<Map<String, dynamic>> _extractFilesFromResult(dynamic resp) {
  final results = <Map<String, dynamic>>[];
  if (resp == null) return results;
  dynamic r = resp;
  if (r is String) {
    try {
      r = jsonDecode(r);
    } catch (_) {}
  }
  if (r is List) {
    for (final item in r) {
      if (item is String && item.isNotEmpty) {
        results.add({'type': 'image', 'url': item});
      } else if (item is Map) {
        final url = item['url'];
        final b64 = item['b64_json'] ?? item['b64'];
        if (url is String && url.isNotEmpty) {
          results.add({'type': 'image', 'url': url});
        } else if (b64 is String && b64.isNotEmpty) {
          results.add({'type': 'image', 'url': 'data:image/png;base64,$b64'});
        }
      }
    }
    return results;
  }
  if (r is! Map) return results;
  final data = r['data'];
  if (data is List) {
    for (final item in data) {
      if (item is Map) {
        final url = item['url'];
        final b64 = item['b64_json'] ?? item['b64'];
        if (url is String && url.isNotEmpty) {
          results.add({'type': 'image', 'url': url});
        } else if (b64 is String && b64.isNotEmpty) {
          results.add({'type': 'image', 'url': 'data:image/png;base64,$b64'});
        }
      } else if (item is String && item.isNotEmpty) {
        results.add({'type': 'image', 'url': item});
      }
    }
  }
  final images = r['images'];
  if (images is List) {
    for (final item in images) {
      if (item is String && item.isNotEmpty) {
        results.add({'type': 'image', 'url': item});
      } else if (item is Map) {
        final url = item['url'];
        final b64 = item['b64_json'] ?? item['b64'];
        if (url is String && url.isNotEmpty) {
          results.add({'type': 'image', 'url': url});
        } else if (b64 is String && b64.isNotEmpty) {
          results.add({'type': 'image', 'url': 'data:image/png;base64,$b64'});
        }
      }
    }
  }
  final files = r['files'];
  if (files is List) {
    results.addAll(_extractFilesFromResult(files));
  }
  final singleUrl = r['url'];
  if (singleUrl is String && singleUrl.isNotEmpty) {
    results.add({'type': 'image', 'url': singleUrl});
  }
  final singleB64 = r['b64_json'] ?? r['b64'];
  if (singleB64 is String && singleB64.isNotEmpty) {
    results.add({'type': 'image', 'url': 'data:image/png;base64,$singleB64'});
  }
  return results;
}

Map<String, dynamic>? _asStringMap(dynamic value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return value.map((key, val) => MapEntry(key.toString(), val));
  }
  return null;
}

List<dynamic>? _normalizeSourcesPayload(dynamic raw) {
  if (raw == null) {
    return null;
  }
  if (raw is List) {
    return raw;
  }
  if (raw is Iterable) {
    return raw.toList(growable: false);
  }
  if (raw is Map) {
    return [raw];
  }
  if (raw is String && raw.isNotEmpty) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded;
      }
      if (decoded is Map) {
        return [decoded];
      }
    } catch (_) {}
  }
  return null;
}

List<String> _parseFollowUpsField(dynamic raw) {
  if (raw is List) {
    return raw
        .whereType<dynamic>()
        .map((value) => value?.toString().trim() ?? '')
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
  }
  if (raw is String && raw.trim().isNotEmpty) {
    return [raw.trim()];
  }
  return const <String>[];
}

void _showSocketNotification(String type, String content) {
  if (content.isEmpty) return;
  final ctx = NavigationService.context;
  if (ctx == null) return;

  final AdaptiveSnackBarType snackBarType;
  switch (type) {
    case 'success':
      snackBarType = AdaptiveSnackBarType.success;
    case 'error':
      snackBarType = AdaptiveSnackBarType.error;
    case 'warning':
    case 'warn':
      snackBarType = AdaptiveSnackBarType.warning;
    default:
      snackBarType = AdaptiveSnackBarType.info;
  }

  AdaptiveSnackBar.show(
    ctx,
    message: content,
    type: snackBarType,
    duration: const Duration(seconds: 4),
  );
}

Future<bool> _showConfirmationDialog(Map<String, dynamic> data) async {
  final ctx = NavigationService.context;
  if (ctx == null) return false;
  final title = data['title']?.toString() ?? 'Confirm';
  final message = data['message']?.toString() ?? '';
  final confirmText = data['confirm_text']?.toString() ?? 'Confirm';
  final cancelText = data['cancel_text']?.toString() ?? 'Cancel';

  return ThemedDialogs.confirm(
    ctx,
    title: title,
    message: message,
    confirmText: confirmText,
    cancelText: cancelText,
    barrierDismissible: false,
  );
}

Future<String?> _showInputDialog(Map<String, dynamic> data) async {
  final ctx = NavigationService.context;
  if (ctx == null) return null;
  final title = data['title']?.toString() ?? 'Input Required';
  final message = data['message']?.toString() ?? '';
  final placeholder = data['placeholder']?.toString() ?? '';
  final initialValue = data['value']?.toString() ?? '';
  final controller = TextEditingController(text: initialValue);

  final result = await showDialog<String>(
    context: ctx,
    barrierDismissible: false,
    builder: (dialogCtx) {
      return ThemedDialogs.buildBase(
        context: dialogCtx,
        title: title,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (message.isNotEmpty) ...[
              Text(
                message,
                style: AppTypography.bodyMediumStyle.copyWith(
                  color: dialogCtx.conduitTheme.textSecondary,
                ),
              ),
              const SizedBox(height: Spacing.md),
            ],
            AdaptiveTextField(
              controller: controller,
              autofocus: true,
              placeholder: placeholder.isNotEmpty
                  ? placeholder
                  : 'Enter a value',
              onSubmitted: (value) {
                Navigator.of(
                  dialogCtx,
                ).pop(value.trim().isEmpty ? null : value.trim());
              },
            ),
          ],
        ),
        actions: [
          AdaptiveButton(
            onPressed: () => Navigator.of(dialogCtx).pop(null),
            label: data['cancel_text']?.toString() ?? 'Cancel',
            textColor: dialogCtx.conduitTheme.textSecondary,
            style: AdaptiveButtonStyle.plain,
          ),
          AdaptiveButton(
            onPressed: () {
              final trimmed = controller.text.trim();
              if (trimmed.isEmpty) {
                Navigator.of(dialogCtx).pop(null);
              } else {
                Navigator.of(dialogCtx).pop(trimmed);
              }
            },
            label: data['confirm_text']?.toString() ?? 'Submit',
            textColor: dialogCtx.conduitTheme.buttonPrimary,
            style: AdaptiveButtonStyle.plain,
          ),
        ],
      );
    },
  );

  controller.dispose();
  if (result == null) return null;
  final trimmed = result.trim();
  return trimmed.isEmpty ? null : trimmed;
}
