import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/foundation.dart';
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

@visibleForTesting
Duration debugTaskSocketTerminalRecoveryDelay = const Duration(seconds: 2);

@visibleForTesting
int debugTaskSocketStableNonTerminalRecoveryLimit = 3;

@visibleForTesting
List<Map<String, dynamic>> debugCollectImageReferencesFromContent(
  String content,
) => _collectImageReferencesWorker(content);

const Set<String> _explicitImageFileTypes = {'image'};

bool _statusUpdatesEquivalent(
  ChatStatusUpdate previous,
  ChatStatusUpdate next,
) {
  return previous.action == next.action &&
      previous.description == next.description &&
      previous.done == next.done &&
      previous.hidden == next.hidden &&
      previous.count == next.count &&
      previous.query == next.query &&
      listEquals(previous.queries, next.queries) &&
      listEquals(previous.urls, next.urls) &&
      listEquals(previous.items, next.items);
}

bool _statusHistoriesEquivalent(
  List<ChatStatusUpdate> previous,
  List<ChatStatusUpdate> next,
) {
  if (identical(previous, next)) {
    return true;
  }
  if (previous.length != next.length) {
    return false;
  }
  for (var index = 0; index < previous.length; index += 1) {
    if (!_statusUpdatesEquivalent(previous[index], next[index])) {
      return false;
    }
  }
  return true;
}

bool _deepEquals(Object? previous, Object? next) {
  if (identical(previous, next)) {
    return true;
  }
  if (previous is Map && next is Map) {
    if (previous.length != next.length) {
      return false;
    }
    for (final entry in previous.entries) {
      if (!next.containsKey(entry.key) ||
          !_deepEquals(entry.value, next[entry.key])) {
        return false;
      }
    }
    return true;
  }
  if (previous is List && next is List) {
    if (previous.length != next.length) {
      return false;
    }
    for (var index = 0; index < previous.length; index += 1) {
      if (!_deepEquals(previous[index], next[index])) {
        return false;
      }
    }
    return true;
  }
  return previous == next;
}

List<Map<String, dynamic>> _copyJsonMapList(List<Map<String, dynamic>> items) {
  return List<Map<String, dynamic>>.unmodifiable(
    items
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false),
  );
}

List<Map<String, dynamic>> _normalizeJsonMapList(dynamic raw) {
  if (raw is! List) {
    return const <Map<String, dynamic>>[];
  }
  final normalized = <Map<String, dynamic>>[];
  for (final item in raw) {
    final map = _asStringMap(item);
    if (map != null) {
      normalized.add(map);
    }
  }
  return List<Map<String, dynamic>>.unmodifiable(normalized);
}

List<ChatSourceReference> _mergeSourceReferences({
  required List<ChatSourceReference> existing,
  required Iterable<ChatSourceReference> incoming,
}) {
  final merged = [...existing];
  for (final reference in incoming) {
    final refId = reference.id?.trim();
    final refUrl = reference.url?.trim();
    final alreadyPresent = merged.any((source) {
      if (refId != null && refId.isNotEmpty) {
        return source.id == refId;
      }
      if (refUrl != null && refUrl.isNotEmpty) {
        return source.url == refUrl;
      }
      return false;
    });
    if (!alreadyPresent) {
      merged.add(reference);
    }
  }
  return List<ChatSourceReference>.unmodifiable(merged);
}

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
          collected.addAll(_extractExplicitImageFiles(entry.files));
        }
        if (entry.result != null) {
          collected.addAll(_extractExplicitImageFiles(entry.result));
        }
      }
    }
  }

  return collected;
}

List<Map<String, dynamic>> _extractExplicitImageFiles(dynamic raw) {
  final results = <Map<String, dynamic>>[];
  if (raw == null) {
    return results;
  }

  dynamic value = raw;
  if (value is String) {
    try {
      value = jsonDecode(value);
    } catch (_) {
      return results;
    }
  }

  if (value is List) {
    for (final item in value) {
      results.addAll(_extractExplicitImageFiles(item));
    }
    return results;
  }

  if (value is! Map) {
    return results;
  }

  final map = _asStringMap(value);
  if (map == null) {
    return results;
  }

  final nestedFiles = map['files'];
  if (nestedFiles is List || nestedFiles is String) {
    results.addAll(_extractExplicitImageFiles(nestedFiles));
  }

  final type = map['type']?.toString().toLowerCase().trim();
  final contentType =
      (map['content_type'] ??
              map['contentType'] ??
              map['mime_type'] ??
              map['mimeType'])
          ?.toString()
          .toLowerCase()
          .trim() ??
      '';
  final isImage =
      (type != null && _explicitImageFileTypes.contains(type)) ||
      contentType.startsWith('image/');
  if (!isImage) {
    return results;
  }

  final url = map['url']?.toString();
  final content = map['content']?.toString();
  final rawBase64 = (map['b64_json'] ?? map['b64'])?.toString();
  final base64MimeType = contentType.startsWith('image/')
      ? contentType
      : 'image/png';
  final imageUrl = url?.isNotEmpty == true
      ? url
      : content?.startsWith('data:image/') == true
      ? content
      : rawBase64?.isNotEmpty == true
      ? rawBase64!.startsWith('data:image/')
            ? rawBase64
            : 'data:$base64MimeType;base64,$rawBase64'
      : null;

  if (imageUrl != null && imageUrl.isNotEmpty) {
    results.add({'type': 'image', 'url': imageUrl});
  }

  return results;
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

class _AssistantServerPatch {
  const _AssistantServerPatch({
    this.content,
    this.followUps,
    this.statusHistory,
    this.sources,
    this.usage,
    this.output,
    this.files,
    this.embeds,
    this.metadata,
    this.mergeMetadata = false,
    this.isStreaming,
    this.error,
  });

  final String? content;
  final List<String>? followUps;
  final List<ChatStatusUpdate>? statusHistory;
  final List<ChatSourceReference>? sources;
  final Map<String, dynamic>? usage;
  final List<Map<String, dynamic>>? output;
  final List<Map<String, dynamic>>? files;
  final List<Map<String, dynamic>>? embeds;
  final Map<String, dynamic>? metadata;
  final bool mergeMetadata;
  final bool? isStreaming;
  final ChatMessageError? error;
}

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
  required void Function(String) bufferLastMessageContent,
  required void Function(String) replaceLastMessageContent,
  required void Function(ChatMessage Function(ChatMessage))
  updateLastMessageWith,
  required void Function(String messageId, ChatStatusUpdate update)
  appendStatusUpdate,
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
  required String? Function() getVisibleStreamingContent,
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
  bool completionDoneHandled = false;
  bool delayedDoneRecoveryScheduled = false;
  bool isObsoleteStream = false;
  bool backgroundExecutionStopped = false;
  Timer? terminalCompletionRecoveryTimer;
  int stableNonTerminalTerminalRecoveryCount = 0;
  String? stableNonTerminalTerminalRecoverySignature;
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

  int? targetAssistantReverseOrdinal() {
    final messages = getMessages();
    var assistantOrdinal = 0;
    for (final message in messages.reversed) {
      if (message.role != 'assistant') {
        continue;
      }
      if (message.id == assistantMessageId) {
        return assistantOrdinal;
      }
      assistantOrdinal++;
    }
    return null;
  }

  ({ChatMessage? previous, ChatMessage? next}) targetAssistantNeighbors() {
    final messages = getMessages();
    final targetIndex = messages.indexWhere(
      (message) =>
          message.id == assistantMessageId && message.role == 'assistant',
    );
    if (targetIndex == -1) {
      return (previous: null, next: null);
    }

    return (
      previous: targetIndex > 0 ? messages[targetIndex - 1] : null,
      next: targetIndex + 1 < messages.length
          ? messages[targetIndex + 1]
          : null,
    );
  }

  void bindRecoveredRemoteMessageId(
    String? candidateId, {
    required String source,
  }) {
    if (candidateId == null ||
        candidateId.isEmpty ||
        candidateId == assistantMessageId ||
        boundRemoteMessageId != null) {
      return;
    }
    boundRemoteMessageId = candidateId;
    DebugLogger.log(
      'Binding $source server message $candidateId '
      'to local assistant $assistantMessageId',
      scope: 'streaming/helper',
    );
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

  // Reference to image sync functions - initialized to no-op and reassigned
  // after the real implementation is defined. Must not be `late` to avoid
  // LateInitializationError if callbacks fire early.
  void Function() syncImages = () {};
  void Function() updateImagesFromCurrentContent = () {};

  var renderedStreamingContent = (() {
    final visibleContent = getVisibleStreamingContent();
    if (visibleContent != null) {
      return visibleContent;
    }
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
    final visibleContent = getVisibleStreamingContent();
    if (visibleContent != null &&
        visibleContent.isNotEmpty &&
        (renderedStreamingContent.isEmpty ||
            visibleContent.length >= renderedStreamingContent.length)) {
      renderedStreamingContent = visibleContent;
      return;
    }
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

  // Wrap finishStreaming to always clear the cancel token, stop background
  // execution, and finalize any pending reasoning block before completion.
  void wrappedFinishStreaming() {
    if (hasFinished) return;
    finalizeStreamingReasoning();
    hasFinished = true;
    hasCompletedStreamingUi = true;
    terminalCompletionRecoveryTimer?.cancel();
    terminalCompletionRecoveryTimer = null;
    stableNonTerminalTerminalRecoveryCount = 0;
    stableNonTerminalTerminalRecoverySignature = null;
    api.clearStreamCancelToken(assistantMessageId);

    // Stop background execution when streaming completes
    stopBackgroundExecution();

    finishStreaming();
  }

  // For taskSocket transport, we still need a StreamController so the
  // StreamingResponseController can manage the stream lifecycle.
  // For httpStream/jsonCompletion, these are unused.
  StreamSubscription<dynamic>? httpSubscription;

  // Socket subscriptions list - starts empty so non-socket flows can finish via onComplete.
  // HTTP subscription is tracked separately and cleaned up in disposeSocketSubscriptions.
  final socketSubscriptions = <VoidCallback>[];
  final hasSocketSignals = socketService != null;
  late final void Function({required String source})
  scheduleTerminalCompletionRecovery;

  void resetTerminalCompletionRecoveryStability() {
    stableNonTerminalTerminalRecoveryCount = 0;
    stableNonTerminalTerminalRecoverySignature = null;
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
    bufferLastMessageContent(renderedStreamingContent);
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

  void handleStreamingToolCallStatuses(dynamic rawToolCalls) {
    if (rawToolCalls is! List) {
      return;
    }

    for (final call in rawToolCalls) {
      if (call is! Map<String, dynamic>) {
        continue;
      }
      final fn = call['function'];
      final name = (fn is Map && fn['name'] is String)
          ? fn['name'] as String
          : null;
      if (name is String && name.isNotEmpty) {
        final exists = renderedStreamingContent.contains('name="$name"');
        if (!exists) {
          handleToolCallStatus(name);
        }
      }
    }
  }

  Map<dynamic, dynamic>? extractStreamingChoiceDelta(
    Map<String, dynamic> payload,
  ) {
    final choices = payload['choices'];
    if (choices is! List || choices.isEmpty) {
      return null;
    }

    final choice = choices.first;
    final delta = choice is Map ? choice['delta'] : null;
    return delta is Map ? delta : null;
  }

  late final bool Function({
    required String targetId,
    required _AssistantServerPatch Function(ChatMessage current) buildPatch,
  })
  applyAssistantServerPatch;

  void applyParsedOpenWebUIUpdate(
    OpenWebUIStreamUpdate update, {
    required VoidCallback onDone,
    VoidCallback? onStructuredDoneEvent,
    bool Function(String type, Object? data)? handleEvent,
  }) {
    switch (update) {
      case OpenWebUIContentDelta(:final content):
        appendVisibleAssistantChunk(content);

      case OpenWebUIReasoningDelta(:final content):
        applyStreamingReasoningDelta(content);

      case OpenWebUIOutputUpdate(:final output):
        final normalizedOutput = _normalizeJsonMapList(output);
        if (normalizedOutput.isNotEmpty) {
          applyAssistantServerPatch(
            targetId: assistantMessageId,
            buildPatch: (_) => _AssistantServerPatch(output: normalizedOutput),
          );
        }

      case OpenWebUIUsageUpdate(:final usage):
        if (usage.isNotEmpty) {
          applyAssistantServerPatch(
            targetId: assistantMessageId,
            buildPatch: (_) => _AssistantServerPatch(usage: usage),
          );
        }

      case OpenWebUISourcesUpdate(:final sources):
        final parsed = parseOpenWebUISourceList(sources);
        if (parsed.isNotEmpty) {
          applyAssistantServerPatch(
            targetId: assistantMessageId,
            buildPatch: (current) => _AssistantServerPatch(
              sources: _mergeSourceReferences(
                existing: current.sources,
                incoming: parsed,
              ),
            ),
          );
        }

      case OpenWebUIEventUpdate(:final type, :final data):
        final eventPayload = _asStringMap(data);
        if (type == 'chat:completion' && eventPayload?['done'] == true) {
          onStructuredDoneEvent?.call();
        }
        handleEvent?.call(type, data);

      case OpenWebUISelectedModelUpdate(:final selectedModelId):
        applyAssistantServerPatch(
          targetId: assistantMessageId,
          buildPatch: (_) => _AssistantServerPatch(
            metadata: {'selectedModelId': selectedModelId, 'arena': true},
            mergeMetadata: true,
          ),
        );

      case OpenWebUIErrorUpdate(:final error):
        applyAssistantServerPatch(
          targetId: assistantMessageId,
          buildPatch: (_) => _AssistantServerPatch(
            error: ChatMessageError(content: error['message']?.toString()),
          ),
        );

      case OpenWebUIStreamDone():
        onDone();
    }
  }

  void settleVisibleStreamingContent() {
    if (hasCompletedStreamingUi) return;
    finalizeStreamingReasoning();
    flushStreamingBuffer();
    applyAssistantServerPatch(
      targetId: assistantMessageId,
      buildPatch: (_) => const _AssistantServerPatch(
        metadata: {'responseDone': true},
        mergeMetadata: true,
      ),
    );
    hasCompletedStreamingUi = true;
    resetTerminalCompletionRecoveryStability();
    if (session.transport == ChatCompletionTransport.taskSocket &&
        (hasSocketSignals || socketSubscriptions.isNotEmpty)) {
      scheduleTerminalCompletionRecovery(
        source: 'taskSocket terminal finish_reason recovery',
      );
    }
  }

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

  String extractServerMessageContent(dynamic rawContent) {
    if (rawContent is String) {
      return rawContent;
    }
    if (rawContent is List) {
      final textItem = rawContent.firstWhere(
        (item) =>
            item is Map &&
            (item['type'] == 'text' || item['type'] == 'output_text'),
        orElse: () => null,
      );
      if (textItem is Map) {
        return textItem['text']?.toString() ?? '';
      }
    }
    return '';
  }

  bool localMessageProvidesFallbackContext(ChatMessage? message) {
    if (message == null) {
      return false;
    }
    if (message.content.trim().isNotEmpty) {
      return true;
    }
    final error = message.error?.content?.trim();
    return error != null && error.isNotEmpty;
  }

  ({ChatMessage message, String comparisonContent})
  readLocalMessageComparisonSnapshot(ChatMessage localMessage) {
    if (localMessage.role != 'assistant' ||
        localMessage.id != assistantMessageId) {
      return (message: localMessage, comparisonContent: localMessage.content);
    }

    flushStreamingBuffer();

    final refreshedMessage =
        getMessages()
            .where((message) => message.id == localMessage.id)
            .firstOrNull ??
        localMessage;
    var comparisonContent = refreshedMessage.content;
    final visibleContent = getVisibleStreamingContent();
    if (visibleContent != null &&
        visibleContent.isNotEmpty &&
        visibleContent.length >= comparisonContent.length) {
      comparisonContent = visibleContent;
    }

    return (message: refreshedMessage, comparisonContent: comparisonContent);
  }

  bool serverMessageMatchesLocalContext(
    Map<String, dynamic>? serverMessage,
    ChatMessage localMessage,
  ) {
    if (serverMessage == null ||
        serverMessage['role']?.toString() != localMessage.role) {
      return false;
    }

    final serverId = serverMessage['id']?.toString();
    if (serverId != null &&
        serverId.isNotEmpty &&
        serverId == localMessage.id) {
      return true;
    }

    final localComparison = readLocalMessageComparisonSnapshot(localMessage);
    final localContent = localComparison.comparisonContent.trim();
    final serverContent = extractServerMessageContent(
      serverMessage['content'],
    ).trim();
    if (localContent.isNotEmpty && serverContent.isNotEmpty) {
      return localContent == serverContent;
    }

    final localError = localComparison.message.error?.content?.trim();
    final serverError = extractServerErrorContent(
      serverMessage['error'],
    )?.trim();
    return localError != null &&
        localError.isNotEmpty &&
        serverError != null &&
        serverError.isNotEmpty &&
        localError == serverError;
  }

  bool conversationMessageMatchesLocalContext(
    ChatMessage? serverMessage,
    ChatMessage localMessage,
  ) {
    if (serverMessage == null || serverMessage.role != localMessage.role) {
      return false;
    }

    if (serverMessage.id == localMessage.id) {
      return true;
    }

    final localComparison = readLocalMessageComparisonSnapshot(localMessage);
    final localContent = localComparison.comparisonContent.trim();
    final serverContent = serverMessage.content.trim();
    if (localContent.isNotEmpty && serverContent.isNotEmpty) {
      return localContent == serverContent;
    }

    final localError = localComparison.message.error?.content?.trim();
    final serverError = serverMessage.error?.content?.trim();
    return localError != null &&
        localError.isNotEmpty &&
        serverError != null &&
        serverError.isNotEmpty &&
        localError == serverError;
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

  Map<String, dynamic>? findServerAssistantByReverseOrdinal(
    dynamic rawMessages,
  ) {
    if (rawMessages is! List) {
      return null;
    }
    final targetOrdinal = targetAssistantReverseOrdinal();
    if (targetOrdinal == null) {
      return null;
    }

    final neighbors = targetAssistantNeighbors();
    final usePreviousContext = localMessageProvidesFallbackContext(
      neighbors.previous,
    );
    final useNextContext = localMessageProvidesFallbackContext(neighbors.next);
    if (!usePreviousContext && !useNextContext) {
      return null;
    }

    var assistantOrdinal = 0;
    for (var index = rawMessages.length - 1; index >= 0; index--) {
      final message = _asStringMap(rawMessages[index]);
      if (message == null || message['role']?.toString() != 'assistant') {
        continue;
      }
      if (assistantOrdinal == targetOrdinal) {
        final previous = index > 0
            ? _asStringMap(rawMessages[index - 1])
            : null;
        final next = index + 1 < rawMessages.length
            ? _asStringMap(rawMessages[index + 1])
            : null;
        final previousMatches =
            !usePreviousContext ||
            serverMessageMatchesLocalContext(previous, neighbors.previous!);
        final nextMatches =
            !useNextContext ||
            serverMessageMatchesLocalContext(next, neighbors.next!);
        if (previousMatches && nextMatches) {
          return message;
        }
        return null;
      }
      assistantOrdinal++;
    }

    return null;
  }

  ChatMessage? findConversationAssistantByReverseOrdinal(
    List<ChatMessage> messages,
  ) {
    final targetOrdinal = targetAssistantReverseOrdinal();
    if (targetOrdinal == null) {
      return null;
    }

    final neighbors = targetAssistantNeighbors();
    final usePreviousContext = localMessageProvidesFallbackContext(
      neighbors.previous,
    );
    final useNextContext = localMessageProvidesFallbackContext(neighbors.next);
    if (!usePreviousContext && !useNextContext) {
      return null;
    }

    var assistantOrdinal = 0;
    for (var index = messages.length - 1; index >= 0; index--) {
      final message = messages[index];
      if (message.role != 'assistant') {
        continue;
      }
      if (assistantOrdinal == targetOrdinal) {
        final previous = index > 0 ? messages[index - 1] : null;
        final next = index + 1 < messages.length ? messages[index + 1] : null;
        final previousMatches =
            !usePreviousContext ||
            conversationMessageMatchesLocalContext(
              previous,
              neighbors.previous!,
            );
        final nextMatches =
            !useNextContext ||
            conversationMessageMatchesLocalContext(next, neighbors.next!);
        if (previousMatches && nextMatches) {
          return message;
        }
        return null;
      }
      assistantOrdinal++;
    }

    return null;
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
      serverMsg ??=
          findServerAssistantByReverseOrdinal(chatObj?['messages']) ??
          findServerAssistantByReverseOrdinal(data?['messages']);
      if (serverMsg == null) return null;
      bindRecoveredRemoteMessageId(
        serverMsg['id']?.toString(),
        source: 'poll recovery',
      );

      // Extract content
      final content = extractServerMessageContent(serverMsg['content']);

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

  applyAssistantServerPatch =
      ({
        required String targetId,
        required _AssistantServerPatch Function(ChatMessage current) buildPatch,
      }) {
        var applied = false;
        updateMessageById(targetId, (current) {
          final patch = buildPatch(current);
          final nextContent = patch.content ?? current.content;
          final nextFollowUps = patch.followUps == null
              ? current.followUps
              : List<String>.from(patch.followUps!);
          final nextStatusHistory = patch.statusHistory == null
              ? current.statusHistory
              : List<ChatStatusUpdate>.from(patch.statusHistory!);
          final nextSources = patch.sources == null
              ? current.sources
              : List<ChatSourceReference>.from(patch.sources!);
          final nextUsage = patch.usage == null
              ? current.usage
              : Map<String, dynamic>.from(patch.usage!);
          final nextOutput = patch.output == null
              ? current.output
              : _copyJsonMapList(patch.output!);
          final nextFiles = patch.files == null
              ? current.files
              : _copyJsonMapList(patch.files!);
          final nextEmbeds = patch.embeds == null
              ? current.embeds
              : _copyJsonMapList(patch.embeds!);
          final nextMetadata = patch.metadata == null
              ? current.metadata
              : patch.mergeMetadata
              ? <String, dynamic>{...?current.metadata, ...patch.metadata!}
              : Map<String, dynamic>.from(patch.metadata!);
          final nextIsStreaming = patch.isStreaming ?? current.isStreaming;
          final nextError = patch.error ?? current.error;
          if (current.content == nextContent &&
              listEquals(current.followUps, nextFollowUps) &&
              _statusHistoriesEquivalent(
                current.statusHistory,
                nextStatusHistory,
              ) &&
              listEquals(current.sources, nextSources) &&
              _deepEquals(current.usage, nextUsage) &&
              _deepEquals(current.output, nextOutput) &&
              _deepEquals(current.files, nextFiles) &&
              _deepEquals(current.embeds, nextEmbeds) &&
              _deepEquals(current.metadata, nextMetadata) &&
              current.isStreaming == nextIsStreaming &&
              current.error == nextError) {
            return current;
          }
          applied = true;
          return current.copyWith(
            content: nextContent,
            followUps: nextFollowUps,
            statusHistory: nextStatusHistory,
            sources: nextSources,
            usage: nextUsage,
            output: nextOutput,
            files: nextFiles,
            embeds: nextEmbeds,
            metadata: nextMetadata,
            isStreaming: nextIsStreaming,
            error: nextError,
          );
        });
        return applied;
      };

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
    final targetIndex = msgs.indexWhere(
      (message) =>
          message.id == assistantMessageId && message.role == 'assistant',
    );
    if (targetIndex == -1) return false;
    final target = msgs[targetIndex];
    final isVisibleTarget =
        targetIndex == msgs.length - 1 && msgs.last.role == 'assistant';
    final comparisonSnapshot = readLocalMessageComparisonSnapshot(target);
    final comparisonLength = comparisonSnapshot.comparisonContent.length;
    final visibleTargetIsStreaming = comparisonSnapshot.message.isStreaming;

    var applied = false;

    if (errorContent != null) {
      DebugLogger.log(
        '$source: adopting server error',
        scope: 'streaming/helper',
      );
    }

    final shouldAdoptContent =
        content.isNotEmpty && content.length >= comparisonLength;
    if (shouldAdoptContent) {
      DebugLogger.log(
        '$source: adopting server content (${content.length} chars)',
        scope: 'streaming/helper',
      );
      if (isVisibleTarget) {
        replaceVisibleAssistantContent(content);
        applied = true;
      }
    }

    if (content.isNotEmpty &&
        isVisibleTarget &&
        content.length < comparisonLength) {
      DebugLogger.log(
        '$source: keeping fresher visible content '
        '($comparisonLength > ${content.length})',
        scope: 'streaming/helper',
      );
    }

    applied =
        applyAssistantServerPatch(
          targetId: assistantMessageId,
          buildPatch: (_) => _AssistantServerPatch(
            content: shouldAdoptContent && !isVisibleTarget ? content : null,
            followUps: followUps.isNotEmpty ? followUps : null,
            error: errorContent == null
                ? null
                : errorContent.isNotEmpty
                ? ChatMessageError(content: errorContent)
                : const ChatMessageError(content: null),
          ),
        ) ||
        applied;

    if (shouldAdoptContent && isVisibleTarget) {
      if (finishIfDone && isDone && visibleTargetIsStreaming) {
        wrappedFinishStreaming();
      }
      return true;
    }

    if (finishIfDone && isDone && isVisibleTarget) {
      wrappedFinishStreaming();
      return true;
    }

    return applied;
  }

  bool refreshingSnapshot = false;
  bool queuedSnapshotRefresh = false;
  Future<void> refreshConversationSnapshot() async {
    if (isObsoleteStream) return;
    if (refreshingSnapshot) {
      queuedSnapshotRefresh = true;
      return;
    }
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

      final targetMessageIds = currentServerMessageIds().toSet();
      ChatMessage? foundAssistant;
      for (final message in conversation.messages.reversed) {
        if (message.role == 'assistant' &&
            targetMessageIds.contains(message.id)) {
          foundAssistant = message;
          break;
        }
      }

      // Local buffers can omit older history, so the fallback still aligns by
      // recent assistant slot, but only accepts the candidate when the
      // surrounding persisted prompt context matches the local neighbors.
      foundAssistant ??= findConversationAssistantByReverseOrdinal(
        conversation.messages,
      );

      if (foundAssistant != null) {
        bindRecoveredRemoteMessageId(
          foundAssistant.id,
          source: 'snapshot recovery',
        );
      }

      final assistant = foundAssistant;
      if (assistant == null) {
        return;
      }

      applyAssistantServerPatch(
        targetId: assistantMessageId,
        buildPatch: (current) {
          // Preserve existing usage if server doesn't have it yet (issue #274)
          // Usage is captured from streaming but may not be persisted on server
          final effectiveUsage = assistant.usage ?? current.usage;
          final nextFollowUps = List<String>.from(assistant.followUps);
          final nextStatusHistory = assistant.statusHistory.isNotEmpty
              ? assistant.statusHistory
              : current.isStreaming
              ? current.statusHistory
              : current.statusHistory
                    .where((status) => status.done != false)
                    .toList(growable: false);
          final nextSources =
              assistant.sources.isNotEmpty || !current.isStreaming
              ? assistant.sources
              : current.sources;
          return _AssistantServerPatch(
            followUps: nextFollowUps,
            statusHistory: nextStatusHistory,
            sources: nextSources,
            metadata: assistant.metadata,
            mergeMetadata: true,
            usage: effectiveUsage,
          );
        },
      );
    } catch (_) {
      // Best-effort refresh; ignore failures.
    } finally {
      refreshingSnapshot = false;
      if (queuedSnapshotRefresh && !isObsoleteStream) {
        queuedSnapshotRefresh = false;
        unawaited(refreshConversationSnapshot());
      }
    }
  }

  bool finishFromLocalState({required bool allowContentOnlyTerminal}) {
    if (isObsoleteStream) {
      return false;
    }
    final msgs = getMessages();
    if (msgs.isEmpty || msgs.last.role != 'assistant') {
      return false;
    }

    final comparisonSnapshot = readLocalMessageComparisonSnapshot(msgs.last);
    final last = comparisonSnapshot.message;
    if (!last.isStreaming) {
      return true;
    }

    final hasNonTextTerminalArtifacts =
        (last.files?.isNotEmpty ?? false) ||
        (last.output?.isNotEmpty ?? false) ||
        (last.embeds?.isNotEmpty ?? false) ||
        last.codeExecutions.isNotEmpty ||
        last.sources.isNotEmpty;
    final hasTerminalState =
        last.error != null ||
        (allowContentOnlyTerminal &&
            (comparisonSnapshot.comparisonContent.trim().isNotEmpty ||
                hasNonTextTerminalArtifacts));
    if (!hasTerminalState) {
      return false;
    }

    wrappedFinishStreaming();
    return true;
  }

  Future<void> recoverTaskSocketTerminalState({
    required String source,
    bool allowContentOnlyTerminal = false,
    bool allowLocalContentFallbackAfterPollFailedOrMissing = false,
    bool allowLocalContentFallbackAfterNonTerminalSnapshot = false,
    bool retryWhenSnapshotStillStreaming = false,
  }) async {
    if (isObsoleteStream) {
      return;
    }
    bool pollFailedOrMissing = true;
    bool snapshotIndicatedDone = false;
    bool allowStableNonTerminalLocalFallback = false;
    try {
      final result = await pollServerForMessage();
      if (hasFinished || isObsoleteStream) {
        return;
      }

      if (result != null) {
        pollFailedOrMissing = false;
        snapshotIndicatedDone = result.isDone;
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
        if (!result.isDone && retryWhenSnapshotStillStreaming) {
          final messages = getMessages();
          final stabilitySignature =
              messages.isEmpty || messages.last.role != 'assistant'
              ? [
                  result.content,
                  result.followUps.join('\u001f'),
                  result.errorContent ?? '',
                ].join('\u0001')
              : () {
                  final comparisonSnapshot = readLocalMessageComparisonSnapshot(
                    messages.last,
                  );
                  final last = comparisonSnapshot.message;
                  return [
                    result.content,
                    result.followUps.join('\u001f'),
                    result.errorContent ?? '',
                    comparisonSnapshot.comparisonContent.trim(),
                    last.error?.content?.trim() ?? '',
                    last.followUps.join('\u001f'),
                    '${last.files?.length ?? 0}/${last.output?.length ?? 0}/'
                        '${last.embeds?.length ?? 0}/${last.codeExecutions.length}/'
                        '${last.sources.length}',
                    last.usage?.toString() ?? '',
                  ].join('\u0001');
                }();
          if (stabilitySignature ==
              stableNonTerminalTerminalRecoverySignature) {
            stableNonTerminalTerminalRecoveryCount += 1;
          } else {
            stableNonTerminalTerminalRecoverySignature = stabilitySignature;
            stableNonTerminalTerminalRecoveryCount = 1;
          }
          allowStableNonTerminalLocalFallback =
              stableNonTerminalTerminalRecoveryCount >=
              debugTaskSocketStableNonTerminalRecoveryLimit;
        } else {
          resetTerminalCompletionRecoveryStability();
        }
      } else {
        resetTerminalCompletionRecoveryStability();
      }
    } catch (e) {
      DebugLogger.log('$source failed: $e', scope: 'streaming/helper');
    }

    if (pollFailedOrMissing && retryWhenSnapshotStillStreaming) {
      final messages = getMessages();
      final stabilitySignature =
          messages.isEmpty || messages.last.role != 'assistant'
          ? 'poll-missing'
          : () {
              final comparisonSnapshot = readLocalMessageComparisonSnapshot(
                messages.last,
              );
              final last = comparisonSnapshot.message;
              return [
                'poll-missing',
                comparisonSnapshot.comparisonContent.trim(),
                last.error?.content?.trim() ?? '',
                last.followUps.join('\u001f'),
                '${last.files?.length ?? 0}/${last.output?.length ?? 0}/'
                    '${last.embeds?.length ?? 0}/${last.codeExecutions.length}/'
                    '${last.sources.length}',
                last.usage?.toString() ?? '',
              ].join('\u0001');
            }();
      if (stabilitySignature == stableNonTerminalTerminalRecoverySignature) {
        stableNonTerminalTerminalRecoveryCount += 1;
      } else {
        stableNonTerminalTerminalRecoverySignature = stabilitySignature;
        stableNonTerminalTerminalRecoveryCount = 1;
      }
      allowStableNonTerminalLocalFallback =
          stableNonTerminalTerminalRecoveryCount >=
          debugTaskSocketStableNonTerminalRecoveryLimit;
    } else if (pollFailedOrMissing) {
      resetTerminalCompletionRecoveryStability();
    }

    final shouldAllowLocalContentFallback =
        allowContentOnlyTerminal &&
        (allowLocalContentFallbackAfterPollFailedOrMissing ||
            snapshotIndicatedDone ||
            allowLocalContentFallbackAfterNonTerminalSnapshot ||
            allowStableNonTerminalLocalFallback);
    if (finishFromLocalState(
      allowContentOnlyTerminal: shouldAllowLocalContentFallback,
    )) {
      Future.microtask(refreshConversationSnapshot);
      return;
    }

    if (!hasFinished &&
        !isObsoleteStream &&
        retryWhenSnapshotStillStreaming &&
        !snapshotIndicatedDone &&
        !shouldAllowLocalContentFallback) {
      scheduleTerminalCompletionRecovery(source: source);
    }
  }

  scheduleTerminalCompletionRecovery = ({required String source}) {
    if (hasFinished || isObsoleteStream) {
      return;
    }
    if (terminalCompletionRecoveryTimer != null) {
      return;
    }

    terminalCompletionRecoveryTimer = Timer(
      debugTaskSocketTerminalRecoveryDelay,
      () {
        terminalCompletionRecoveryTimer = null;
        if (hasFinished || isObsoleteStream) {
          return;
        }
        if (currentAssistantTargetId() != assistantMessageId) {
          return;
        }
        DebugLogger.log(
          '$source: recovering after missed done/inactive',
          scope: 'streaming/helper',
        );
        unawaited(
          recoverTaskSocketTerminalState(
            source: source,
            allowContentOnlyTerminal: true,
            retryWhenSnapshotStillStreaming: true,
          ),
        );
      },
    );
  };

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
    terminalCompletionRecoveryTimer?.cancel();
    terminalCompletionRecoveryTimer = null;
    resetTerminalCompletionRecoveryStability();

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

  List<ChatStatusUpdate> mergeStatusHistory(
    List<ChatStatusUpdate> existing,
    ChatStatusUpdate update,
  ) {
    final withTimestamp = update.occurredAt == null
        ? update.copyWith(occurredAt: DateTime.now())
        : update;
    if (existing.isNotEmpty) {
      final last = existing.last;
      if (_statusUpdatesEquivalent(last, withTimestamp)) {
        return existing;
      }
      final sameAction =
          last.action != null && last.action == withTimestamp.action;
      final sameDescription =
          (withTimestamp.description?.isNotEmpty ?? false) &&
          withTimestamp.description == last.description;
      if (sameAction && sameDescription) {
        final history = [...existing];
        history[history.length - 1] = withTimestamp;
        return history;
      }
    }
    return [...existing, withTimestamp];
  }

  void applyMergedStatusUpdate({
    required String targetId,
    required ChatStatusUpdate statusUpdate,
    dynamic metadataStatus,
    bool storeMetadataStatus = false,
  }) {
    applyAssistantServerPatch(
      targetId: targetId,
      buildPatch: (current) {
        final mergedStatusHistory = mergeStatusHistory(
          current.statusHistory,
          statusUpdate,
        );
        return _AssistantServerPatch(
          statusHistory: mergedStatusHistory,
          metadata: storeMetadataStatus ? {'status': metadataStatus} : null,
          mergeMetadata: storeMetadataStatus,
        );
      },
    );
  }

  bool handleHttpStreamEventFastPath({
    required String type,
    required Object? data,
  }) {
    final payload = _asStringMap(data);
    switch (type) {
      case 'chat:message:delta':
      case 'message':
      case 'event:message:delta':
        final content = payload?['content']?.toString() ?? '';
        if (content.isNotEmpty) {
          appendVisibleAssistantChunk(content);
        }
        return true;

      case 'chat:message':
      case 'replace':
        final content = payload?['content']?.toString() ?? '';
        if (content.isNotEmpty) {
          replaceVisibleAssistantContent(content);
        }
        return true;

      case 'status':
        if (payload == null) {
          return false;
        }
        final statusUpdate = ChatStatusUpdate.fromJson(payload);
        applyMergedStatusUpdate(
          targetId: assistantMessageId,
          statusUpdate: statusUpdate,
          metadataStatus: statusUpdate.toJson(),
          storeMetadataStatus: true,
        );
        return true;

      case 'event:status':
        if (payload == null) {
          return false;
        }
        final statusText = payload['status']?.toString() ?? '';
        final statusUpdate = ChatStatusUpdate.fromJson(payload);
        applyMergedStatusUpdate(
          targetId: assistantMessageId,
          statusUpdate: statusUpdate,
          metadataStatus: statusText,
          storeMetadataStatus: statusText.isNotEmpty,
        );
        return true;
    }
    return false;
  }

  bool scheduleDelayedDoneRecovery({required bool finishAfterRecovery}) {
    final chatId = activeConversationId;
    if (chatId == null || chatId.isEmpty || isTemporaryChat(chatId)) {
      return false;
    }
    if (delayedDoneRecoveryScheduled) {
      return true;
    }
    delayedDoneRecoveryScheduled = true;

    Future.delayed(const Duration(seconds: 2), () async {
      try {
        if (isObsoleteStream) {
          return;
        }
        final result = await pollServerForMessage();
        if (!isObsoleteStream) {
          if (result != null) {
            applyServerContent(
              result.content,
              result.followUps,
              finishIfDone: false,
              isDone: result.isDone,
              source: 'done recovery',
              errorContent: result.errorContent,
            );
          }
          await refreshConversationSnapshot();
        }
      } catch (e) {
        DebugLogger.log(
          'Server recovery failed: $e',
          scope: 'streaming/helper',
        );
      } finally {
        delayedDoneRecoveryScheduled = false;
        if (finishAfterRecovery &&
            !isObsoleteStream &&
            currentAssistantTargetId() == assistantMessageId) {
          wrappedFinishStreaming();
        }
      }
    });

    return true;
  }

  void handleCompletionDone({
    String? doneTitle,
    bool allowEmptyContentRecovery = false,
  }) {
    if (hasFinished || completionDoneHandled) {
      return;
    }
    completionDoneHandled = true;

    if (doneTitle != null && doneTitle.isNotEmpty) {
      onChatTitleUpdated?.call(doneTitle);
    }

    try {
      if (!isTemporaryChat(activeConversationId)) {
        sendChatCompletedAndSync();
        Future.delayed(
          const Duration(milliseconds: 500),
          refreshConversationSnapshot,
        );
      }
    } catch (_) {
      // Non-critical - continue if sync fails
    }

    finalizeStreamingReasoning();
    flushStreamingBuffer();

    final msgs = getMessages();
    if (msgs.isNotEmpty && msgs.last.role == 'assistant') {
      final comparisonSnapshot = readLocalMessageComparisonSnapshot(msgs.last);
      final last = comparisonSnapshot.message;
      final lastContent = comparisonSnapshot.comparisonContent.trim();
      final hasNonTextArtifacts =
          (last.files?.isNotEmpty ?? false) ||
          (last.output?.isNotEmpty ?? false) ||
          (last.embeds?.isNotEmpty ?? false) ||
          last.codeExecutions.isNotEmpty ||
          last.sources.isNotEmpty;
      DebugLogger.log(
        'Done signal received: content length=${lastContent.length}',
        scope: 'streaming/helper',
      );
      if (allowEmptyContentRecovery &&
          lastContent.isEmpty &&
          last.error == null) {
        // Non-text artifacts can arrive before the final persisted answer text.
        // Only keep the UI open when the reply is otherwise blank; when files,
        // citations, or structured output are already present, finish now and
        // backfill any late text/error in the background.
        final waitingForRecovery = !hasNonTextArtifacts;
        if (scheduleDelayedDoneRecovery(
          finishAfterRecovery: waitingForRecovery,
        )) {
          if (waitingForRecovery) {
            return;
          }
        }
      }
    }

    wrappedFinishStreaming();
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
              final parsed = decodeOpenWebUIDataPayload(dataStr);
              final delta = extractStreamingChoiceDelta(parsed);
              if (delta != null) {
                handleStreamingToolCallStatuses(delta['tool_calls']);
              }

              for (final update in parseOpenWebUIParsedPayload(parsed)) {
                applyParsedOpenWebUIUpdate(
                  update,
                  onDone: onChannelDone,
                  handleEvent: (type, data) =>
                      handleHttpStreamEventFastPath(type: type, data: data),
                );
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
          final selectedModelId = payload['selected_model_id']?.toString();
          final usageData = payload['usage'];
          final usagePatch = usageData is Map && usageData.isNotEmpty
              ? Map<String, dynamic>.from(usageData)
              : null;
          final normalizedOutputItems = _normalizeJsonMapList(
            payload['output'],
          );
          final rawSources = payload['sources'] ?? payload['citations'];
          final normalizedSources = _normalizeSourcesPayload(rawSources);
          final parsedSources =
              normalizedSources == null || normalizedSources.isEmpty
              ? const <ChatSourceReference>[]
              : parseOpenWebUISourceList(normalizedSources);
          final metadataPatch =
              selectedModelId != null && selectedModelId.isNotEmpty
              ? <String, dynamic>{
                  'selectedModelId': selectedModelId,
                  'arena': true,
                }
              : null;
          if (completionTargetId != null &&
              (normalizedOutputItems.isNotEmpty ||
                  metadataPatch != null ||
                  usagePatch != null ||
                  parsedSources.isNotEmpty)) {
            applyAssistantServerPatch(
              targetId: completionTargetId,
              buildPatch: (current) => _AssistantServerPatch(
                output: normalizedOutputItems.isNotEmpty
                    ? normalizedOutputItems
                    : null,
                metadata: metadataPatch,
                mergeMetadata: metadataPatch != null,
                usage: usagePatch,
                sources: parsedSources.isEmpty
                    ? null
                    : _mergeSourceReferences(
                        existing: current.sources,
                        incoming: parsedSources,
                      ),
              ),
            );
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
                  '- settling visible content until done',
                  scope: 'streaming/helper',
                );
                settleVisibleStreamingContent();
              }
            }
          }
          if (payload['done'] == true) {
            if (completionTargetId == null) {
              return;
            }
            handleCompletionDone(
              doneTitle: payload['title'] is String
                  ? payload['title'] as String
                  : null,
              allowEmptyContentRecovery: true,
            );
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
            applyMergedStatusUpdate(
              targetId: targetId,
              statusUpdate: statusUpdate,
              metadataStatus: statusUpdate.toJson(),
              storeMetadataStatus: true,
            );
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
        applyAssistantServerPatch(
          targetId: targetId,
          buildPatch: (_) => _AssistantServerPatch(
            metadata: {'tasksCancelled': true},
            mergeMetadata: true,
            isStreaming: false,
          ),
        );
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
            applyAssistantServerPatch(
              targetId: targetId,
              buildPatch: (_) {
                return _AssistantServerPatch(
                  followUps: suggestions,
                  metadata: {'followUps': suggestions},
                  mergeMetadata: true,
                );
              },
            );
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
                  applyAssistantServerPatch(
                    targetId: targetId,
                    buildPatch: (current) => _AssistantServerPatch(
                      sources: _mergeSourceReferences(
                        existing: current.sources,
                        incoming: sources,
                      ),
                    ),
                  );
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
              applyAssistantServerPatch(
                targetId: targetId,
                buildPatch: (_) => _AssistantServerPatch(files: merged),
              );
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
              applyAssistantServerPatch(
                targetId: targetId,
                buildPatch: (_) => _AssistantServerPatch(embeds: embeds),
              );
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
                  allowLocalContentFallbackAfterPollFailedOrMissing: true,
                  allowLocalContentFallbackAfterNonTerminalSnapshot: true,
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
            final statusUpdate = ChatStatusUpdate.fromJson(map);
            applyMergedStatusUpdate(
              targetId: targetId,
              statusUpdate: statusUpdate,
              metadataStatus: status,
              storeMetadataStatus: status.isNotEmpty,
            );
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
            applyParsedOpenWebUIUpdate(
              update,
              onDone: () {
                receivedDone = true;
                handleCompletionDone(allowEmptyContentRecovery: true);
              },
              onStructuredDoneEvent: () {
                receivedDone = true;
              },
              handleEvent: (type, data) {
                if (handleHttpStreamEventFastPath(type: type, data: data)) {
                  return true;
                }
                chatHandler({
                  'message_id': assistantMessageId,
                  'data': {'type': type, 'data': data},
                }, null);
                return true;
              },
            );
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
            if (hasCompletedStreamingUi) {
              scheduleTerminalCompletionRecovery(
                source: 'taskSocket HTTP completion recovery',
              );
            }
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
            applyAssistantServerPatch(
              targetId: assistantMessageId,
              buildPatch: (_) => _AssistantServerPatch(
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

          final usage = payload['usage'];
          final usagePatch = usage is Map && usage.isNotEmpty
              ? Map<String, dynamic>.from(usage)
              : null;
          final normalizedOutputItems = _normalizeJsonMapList(
            payload['output'],
          );
          final selectedModelId = payload['selected_model_id']?.toString();
          final metadataPatch =
              selectedModelId != null && selectedModelId.isNotEmpty
              ? <String, dynamic>{
                  'selectedModelId': selectedModelId,
                  'arena': true,
                }
              : null;
          final rawSources = payload['sources'] ?? payload['citations'];
          final normalizedSources = _normalizeSourcesPayload(rawSources);
          final parsedSources =
              normalizedSources == null || normalizedSources.isEmpty
              ? const <ChatSourceReference>[]
              : parseOpenWebUISourceList(normalizedSources);
          if (usagePatch != null ||
              normalizedOutputItems.isNotEmpty ||
              metadataPatch != null ||
              parsedSources.isNotEmpty) {
            applyAssistantServerPatch(
              targetId: assistantMessageId,
              buildPatch: (current) => _AssistantServerPatch(
                usage: usagePatch,
                output: normalizedOutputItems.isNotEmpty
                    ? normalizedOutputItems
                    : null,
                metadata: metadataPatch,
                mergeMetadata: metadataPatch != null,
                sources: parsedSources.isEmpty
                    ? null
                    : _mergeSourceReferences(
                        existing: current.sources,
                        incoming: parsedSources,
                      ),
              ),
            );
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

  final result = await ThemedDialogs.showCustom<String>(
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
