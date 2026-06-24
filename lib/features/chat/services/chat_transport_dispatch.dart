import 'dart:async';

import '../../../core/models/chat_message.dart';
import '../../../core/providers/app_providers.dart'
    show
        activeChatIdsProvider,
        activeConversationProvider,
        apiServiceProvider,
        conversationsProvider,
        isTemporaryChat,
        refreshConversationsCache;
import '../../../core/services/api_service.dart';
import '../../../core/services/chat_completion_transport.dart';

import '../../../core/services/socket_service.dart';
import '../../../core/services/streaming_helper.dart';
import '../../../core/sync/sync_engine.dart';
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
  bool isResume = false,
}) async {
  if (session.transport != ChatCompletionTransport.taskSocket) return;
  if (socketService == null) return;

  // Resume reuses the live socket subscription; there is no "awaiting binding"
  // window to surface on the message (no fresh HTTP request was issued), so we
  // skip that metadata churn but still ensure the socket is connected.
  if (!isResume) {
    setAwaitingSocketBinding(ref: ref, value: true);
  }

  try {
    if (!socketService.isConnected) {
      final connected = await socketService.ensureConnected(timeout: timeout);
      if (!connected) {
        DebugLogger.log(
          'Socket not available for taskSocket binding — will rely on poll recovery',
          scope: isResume ? 'transport/resume' : 'transport/dispatch',
        );
        return;
      }
    }
  } finally {
    if (!isResume) {
      setAwaitingSocketBinding(ref: ref, value: false);
    }
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
  final taskConversationId = meta?['taskConversationId']?.toString();
  if (taskConversationId != null && taskConversationId.isNotEmpty) {
    unawaited(api?.stopTasksByChat(taskConversationId));
  } else if (taskId != null && taskId.isNotEmpty) {
    unawaited(api?.stopTask(taskId));
  }
}

// ---------------------------------------------------------------------------
// Dispatch entry point
// ---------------------------------------------------------------------------

/// Whether the just-dispatched [session] should optimistically light the
/// sidebar `generating` indicator for [conversationId].
///
/// A taskSocket session with a non-empty task ID is produced precisely when the
/// completion POST returned a non-empty `task_ids`, which upstream OpenWebUI
/// treats as the synchronous generation-START signal (alongside the async
/// `chat:active{true}` push). Temporary chats are never tracked in the sidebar.
bool shouldOptimisticallyMarkChatActive({
  required ChatCompletionSession session,
  required String? conversationId,
}) {
  return session.transport == ChatCompletionTransport.taskSocket &&
      session.taskId != null &&
      session.taskId!.isNotEmpty &&
      conversationId != null &&
      conversationId.isNotEmpty &&
      !isTemporaryChat(conversationId);
}

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
  List<String>? filterIds,

  /// Whether this dispatch resumes an in-flight chat that is still generating
  /// on the server (Feature C), rather than a fresh local send.
  ///
  /// When true the resume reuses the live socket subscription instead of an
  /// HTTP request: the awaiting-binding metadata is skipped, no abort handle is
  /// written, and the socket session ID is forced to `null` so the streaming
  /// helper binds the server's (possibly foreign) `message_id` by `chat_id`.
  bool isResume = false,
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
    isResume: isResume,
  );

  // 3. Configure remote task monitoring
  configureRemoteTaskMonitoring(ref: ref, session: session);

  // 3b. Optimistic generation-START for the sidebar indicator.
  //
  // Upstream OpenWebUI learns active state from two signals: the synchronous
  // completion-POST response (`{status, task_ids, chat_id}`) AND the async
  // `chat:active{active:true}` socket push. A taskSocket session is produced
  // exactly when that POST returned a non-empty `task_ids`, so light the
  // spinner immediately here instead of waiting for the socket event to land.
  // The authoritative `chat:active{false}` (or the paired cancel/error/finalize
  // `setInactive`) clears it, so no spinner is stranded.
  if (shouldOptimisticallyMarkChatActive(
    session: session,
    conversationId: activeConversationId,
  )) {
    ref.read(activeChatIdsProvider.notifier).setActive(activeConversationId!);
  }

  // 4. Build the effective session ID for socket event matching.
  // Prefer the live socket session ID over the one stored in the session
  // (the latter may be null when the socket was disconnected at send time).
  //
  // Resume forces a null session ID: upstream `chat:completion` envelopes for
  // an in-flight chat carry no `session_id`, and the server's `message_id` may
  // differ from the local placeholder id. A null session keeps
  // `matchesCurrentStreamSession` permissive so the helper binds the foreign
  // `message_id` by `chat_id` (`allowBindingForeignMessage`). Leaking the live
  // socket session id here would reject those foreign-session events.
  final effectiveSessionId = isResume
      ? null
      : (socketService?.sessionId ?? session.sessionId);

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
    filterIds: filterIds,
    appendToLastMessage: (c) =>
        ref.read(chatMessagesProvider.notifier).appendToLastMessage(c),
    bufferLastMessageContent: (c) =>
        ref.read(chatMessagesProvider.notifier).bufferLastMessageContent(c),
    replaceLastMessageContent: (c) =>
        ref.read(chatMessagesProvider.notifier).replaceLastMessageContent(c),
    updateLastMessageWith: (updater) => ref
        .read(chatMessagesProvider.notifier)
        .updateLastMessageWithFunction(updater),
    appendStatusUpdate: (messageId, update) => ref
        .read(chatMessagesProvider.notifier)
        .appendStatusUpdate(messageId, update),
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
          .updateConversationFromRemote(
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
                .upsertConversation(
                  refreshed.copyWith(messages: const []),
                  trustFolderConversation:
                      refreshed.folderId != null &&
                      refreshed.folderId!.isNotEmpty,
                );
          } catch (_) {}
        });
      }
    },
    onRemoteMessageBound: (remoteMessageId) {
      // Record the foreign server id bound to this assistant so the poll
      // fallback can still resolve server content if the socket later dies.
      ref
          .read(chatMessagesProvider.notifier)
          .recordResumeBoundRemoteMessageId(
            assistantMessageId,
            remoteMessageId,
          );
    },
    onChatActiveChanged: (chatId, active) {
      if (chatId == null || chatId.isEmpty) return;
      final notifier = ref.read(activeChatIdsProvider.notifier);
      if (active) {
        notifier.setActive(chatId);
        return;
      }
      // The backend `chat:active(false)` only fires when the LAST task for the
      // chat finishes. This optimistic safety-net removal must be last-task
      // aware too, or an overlapping multi-model / branched generation would
      // drop the sidebar spinner while another stream is still running. Only
      // clear once the task registry reports no remaining tasks for the chat.
      final apiRef = ref.read(apiServiceProvider);
      if (apiRef == null) {
        notifier.setInactive(chatId);
        return;
      }
      // Capture the activation token now so a stream that starts for this chat
      // during the async lookup is not clobbered by this stale clear.
      final token = notifier.activationToken(chatId);
      unawaited(() async {
        try {
          final ids = await apiRef.getTaskIdsByChat(chatId);
          if (ids.isEmpty) {
            notifier.setInactiveIfUnchanged(chatId, token);
          }
        } catch (_) {
          // Unreachable registry: clear anyway so a spinner can't strand,
          // still guarded against a racing re-activation.
          notifier.setInactiveIfUnchanged(chatId, token);
        }
      }());
    },
    completeStreamingUi: () =>
        ref.read(chatMessagesProvider.notifier).completeStreamingUi(),
    finishStreaming: () =>
        ref.read(chatMessagesProvider.notifier).finishStreaming(),
    getMessages: () => ref.read(chatMessagesProvider),
    getVisibleStreamingContent: () => ref.read(streamingContentProvider),
    flushStreamingBuffer: () =>
        ref.read(chatMessagesProvider.notifier).syncStreamingBuffer(),
    onObsoleteStreamRetired: () {
      ref
          .read(chatMessagesProvider.notifier)
          .retireObsoleteStreamingTransport(assistantMessageId);
    },
    pullChatSnapshot: (chatId) async {
      // CDT-RFC-001 Phase 1 (E2): the post-stream snapshot refresh persists
      // through the sync engine (upsertServerChat under the chat lock).
      try {
        return await ref.read(syncEngineProvider.notifier).pullChatNow(chatId);
      } catch (error, stackTrace) {
        // Engine unavailable (no database / reviewer mode): the helper falls
        // back to the direct fetch.
        DebugLogger.error(
          'pull-snapshot-failed',
          scope: 'transport/dispatch',
          error: error,
          stackTrace: stackTrace,
          data: {'chatId': chatId},
        );
        return null;
      }
    },
  );

  // 6. Register controller + socket subscriptions with the notifier.
  //    ActiveChatStream.controller may be null for httpStream / jsonCompletion
  //    (those transports complete via their own stream, not a
  //    StreamingResponseController).
  final notifier = ref.read(chatMessagesProvider.notifier);
  if (activeStream.controller != null) {
    notifier.setMessageStream(assistantMessageId, activeStream.controller!);
  }
  notifier.setSocketSubscriptions(
    assistantMessageId,
    activeStream.socketSubscriptions,
    onDispose: activeStream.disposeWatchdog,
  );
}
