import 'dart:async';

import '../../../core/models/chat_message.dart';
import '../../../core/providers/app_providers.dart'
    show
        activeConversationProvider,
        apiServiceProvider,
        conversationsProvider,
        isTemporaryChat,
        refreshConversationsCache;
import '../../../core/services/api_service.dart';
import '../../../core/services/chat_completion_transport.dart';
import '../../../core/services/conversation_delta_listener.dart';
import '../../../core/services/socket_service.dart';
import '../../../core/services/streaming_helper.dart';
import '../../../core/services/worker_manager.dart';
import '../../../core/utils/debug_logger.dart';
import '../providers/chat_providers.dart';

// ---------------------------------------------------------------------------
// Transport metadata helpers
// ---------------------------------------------------------------------------

/// Writes transport metadata to the assistant message so that downstream
/// consumers (e.g. the stop provider) can determine which cancellation path
/// to follow without re-inspecting the network layer.
void writeTransportMetadata({
  required dynamic ref,
  required ChatCompletionSession session,
}) {
  try {
    ref.read(chatMessagesProvider.notifier).updateLastMessageWithFunction((
      ChatMessage m,
    ) {
      final meta = Map<String, dynamic>.from(m.metadata ?? const {});
      meta['transport'] = session.transport.name;
      if (session.taskId != null && session.taskId!.isNotEmpty) {
        meta['taskId'] = session.taskId;
      }
      if (session.abort != null) {
        meta['hasActiveAbortHandle'] = true;
      }
      return m.copyWith(metadata: meta);
    });
  } catch (_) {
    // Non-critical — metadata is advisory.
  }
}

/// Writes the abort handle flag to the assistant message metadata.
///
/// Called after transport dispatch when an abort handle is available.
void writeAbortHandleMetadata({required dynamic ref}) {
  try {
    ref.read(chatMessagesProvider.notifier).updateLastMessageWithFunction((
      ChatMessage m,
    ) {
      final meta = Map<String, dynamic>.from(m.metadata ?? const {});
      meta['hasActiveAbortHandle'] = true;
      return m.copyWith(metadata: meta);
    });
  } catch (_) {}
}

// ---------------------------------------------------------------------------
// Socket binding helpers
// ---------------------------------------------------------------------------

/// Sets the `awaitingSocketBinding` flag on the assistant message metadata.
///
/// Used by the taskSocket transport while waiting for the WebSocket to
/// deliver its first event for this task.
void setAwaitingSocketBinding({required dynamic ref, required bool value}) {
  try {
    ref.read(chatMessagesProvider.notifier).updateLastMessageWithFunction((
      ChatMessage m,
    ) {
      final meta = Map<String, dynamic>.from(m.metadata ?? const {});
      meta['awaitingSocketBinding'] = value;
      return m.copyWith(metadata: meta);
    });
  } catch (_) {}
}

/// For taskSocket sessions, optionally waits for the socket connection and
/// binds the session's task ID.
///
/// If the socket is unavailable or not connected, this is a no-op — the
/// streaming helper's watchdog + poll recovery will still deliver content.
Future<void> bindTaskSocketIfNeeded({
  required dynamic ref,
  required ChatCompletionSession session,
  required SocketService? socketService,
  Duration timeout = const Duration(seconds: 10),
}) async {
  if (session.transport != ChatCompletionTransport.taskSocket) return;
  if (socketService == null) return;

  setAwaitingSocketBinding(ref: ref, value: true);

  try {
    if (!socketService.isConnected) {
      final connected = await socketService.ensureConnected(timeout: timeout);
      if (!connected) {
        DebugLogger.log(
          'Socket not available for taskSocket binding — will rely on poll recovery',
          scope: 'transport/dispatch',
        );
        return;
      }
    }
  } finally {
    setAwaitingSocketBinding(ref: ref, value: false);
  }
}

/// Configures remote task monitoring by writing the session's task ID and
/// conversation ID into message metadata so reconnection / recovery logic
/// can find the right server resource.
void configureRemoteTaskMonitoring({
  required dynamic ref,
  required ChatCompletionSession session,
}) {
  if (session.taskId == null || session.taskId!.isEmpty) return;
  try {
    ref.read(chatMessagesProvider.notifier).updateLastMessageWithFunction((
      ChatMessage m,
    ) {
      final meta = Map<String, dynamic>.from(m.metadata ?? const {});
      meta['taskId'] = session.taskId;
      if (session.conversationId != null) {
        meta['taskConversationId'] = session.conversationId;
      }
      return m.copyWith(metadata: meta);
    });
  } catch (_) {}
}

// ---------------------------------------------------------------------------
// Transport-aware stop
// ---------------------------------------------------------------------------

/// Cancels the active transport for a streaming assistant [message].
///
/// Inspects the message's transport metadata to choose the right
/// cancellation path:
/// - **httpStream / abort handle** → `cancelStreamingMessage()`
/// - **taskSocket / task ID** → `stopTask()`
/// - Mixed (abort + task) → both paths are invoked.
void stopActiveTransport(ChatMessage message, ApiService? api) {
  final meta = message.metadata;
  final transport = meta?['transport']?.toString();
  final hasAbortHandle = meta?['hasActiveAbortHandle'] == true;

  // Abort HTTP stream / cancel token
  if (transport == 'httpStream' || hasAbortHandle) {
    api?.cancelStreamingMessage(message.id);
  }

  // Stop background task
  final taskId = meta?['taskId']?.toString();
  if (taskId != null && taskId.isNotEmpty) {
    unawaited(api?.stopTask(taskId));
  }
}

// ---------------------------------------------------------------------------
// Dispatch entry point
// ---------------------------------------------------------------------------

/// Shared transport dispatch glue used by both `regenerateMessage()` and
/// `_sendMessageInternal()`.
///
/// Given a [ChatCompletionSession] returned by `api.sendMessageSession()`,
/// this function:
/// 1. Writes transport metadata onto the assistant message.
/// 2. Binds the socket if the session is taskSocket.
/// 3. Calls [attachUnifiedChunkedStreaming] with the correct session.
/// 4. Registers the resulting controller & subscriptions with the notifier.
Future<void> dispatchChatTransport({
  required dynamic ref,
  required ChatCompletionSession session,
  required String assistantMessageId,
  required String modelId,
  required Map<String, dynamic> modelItem,
  required String? activeConversationId,
  required ApiService api,
  required SocketService? socketService,
  required WorkerManager workerManager,
  required bool webSearchEnabled,
  required bool imageGenerationEnabled,
  required bool isBackgroundFlow,
  required bool modelUsesReasoning,
  required bool toolsEnabled,
  required bool isTemporary,
  RegisterConversationDeltaListener? registerDeltaListener,
}) async {
  // 1. Write transport + flow metadata onto assistant message
  writeTransportMetadata(ref: ref, session: session);

  try {
    ref.read(chatMessagesProvider.notifier).updateLastMessageWithFunction((
      ChatMessage m,
    ) {
      final mergedMeta = {
        if (m.metadata != null) ...m.metadata!,
        'backgroundFlow': isBackgroundFlow,
        if (webSearchEnabled) 'webSearchFlow': true,
        if (imageGenerationEnabled) 'imageGenerationFlow': true,
      };
      return m.copyWith(metadata: mergedMeta);
    });
  } catch (_) {}

  // 2. Bind socket for taskSocket sessions
  await bindTaskSocketIfNeeded(
    ref: ref,
    session: session,
    socketService: socketService,
  );

  // 3. Configure remote task monitoring
  configureRemoteTaskMonitoring(ref: ref, session: session);

  // 4. Build the effective session ID for socket event matching
  final effectiveSessionId = socketService?.sessionId ?? session.sessionId;

  // 5. Attach streaming
  final activeStream = attachUnifiedChunkedStreaming(
    session: session,
    webSearchEnabled: webSearchEnabled,
    assistantMessageId: assistantMessageId,
    modelId: modelId,
    modelItem: modelItem,
    sessionId: effectiveSessionId,
    activeConversationId: activeConversationId,
    api: api,
    socketService: socketService,
    workerManager: workerManager,
    registerDeltaListener: registerDeltaListener,
    appendToLastMessage: (c) =>
        ref.read(chatMessagesProvider.notifier).appendToLastMessage(c),
    replaceLastMessageContent: (c) =>
        ref.read(chatMessagesProvider.notifier).replaceLastMessageContent(c),
    updateLastMessageWith: (updater) => ref
        .read(chatMessagesProvider.notifier)
        .updateLastMessageWithFunction(updater),
    appendStatusUpdate: (messageId, update) => ref
        .read(chatMessagesProvider.notifier)
        .appendStatusUpdate(messageId, update),
    setFollowUps: (messageId, followUps) => ref
        .read(chatMessagesProvider.notifier)
        .setFollowUps(messageId, followUps),
    upsertCodeExecution: (messageId, execution) => ref
        .read(chatMessagesProvider.notifier)
        .upsertCodeExecution(messageId, execution),
    appendSourceReference: (messageId, reference) => ref
        .read(chatMessagesProvider.notifier)
        .appendSourceReference(messageId, reference),
    updateMessageById: (messageId, updater) => ref
        .read(chatMessagesProvider.notifier)
        .updateMessageById(messageId, updater),
    modelUsesReasoning: modelUsesReasoning,
    toolsEnabled: toolsEnabled,
    onChatTitleUpdated: (newTitle) {
      final active = ref.read(activeConversationProvider);
      if (active == null || isTemporaryChat(active.id)) return;
      ref
          .read(activeConversationProvider.notifier)
          .set(active.copyWith(title: newTitle));
      ref
          .read(conversationsProvider.notifier)
          .updateConversation(
            active.id,
            (conversation) => conversation.copyWith(
              title: newTitle,
              updatedAt: DateTime.now(),
            ),
          );
      refreshConversationsCache(ref);
    },
    onChatTagsUpdated: () {
      final active = ref.read(activeConversationProvider);
      if (active == null || isTemporaryChat(active.id)) return;
      refreshConversationsCache(ref);
      final apiRef = ref.read(apiServiceProvider);
      if (apiRef != null) {
        Future.microtask(() async {
          try {
            final refreshed = await apiRef.getConversation(active.id);
            ref.read(activeConversationProvider.notifier).set(refreshed);
            ref
                .read(conversationsProvider.notifier)
                .upsertConversation(refreshed.copyWith(messages: const []));
          } catch (_) {}
        });
      }
    },
    finishStreaming: () =>
        ref.read(chatMessagesProvider.notifier).finishStreaming(),
    getMessages: () => ref.read(chatMessagesProvider),
    flushStreamingBuffer: () =>
        ref.read(chatMessagesProvider.notifier).syncStreamingBuffer(),
  );

  // 6. Register controller + socket subscriptions with the notifier.
  //    ActiveChatStream.controller may be null for httpStream / jsonCompletion
  //    (those transports complete via their own stream, not a
  //    StreamingResponseController).
  final notifier = ref.read(chatMessagesProvider.notifier);
  if (activeStream.controller != null) {
    notifier.setMessageStream(activeStream.controller!);
  }
  notifier.setSocketSubscriptions(
    activeStream.socketSubscriptions,
    onDispose: activeStream.disposeWatchdog,
  );
}
