import 'dart:async';

import 'package:conduit_core/models/chat_message.dart';

import 'package:conduit_core/providers/app_providers.dart'
    show
        activeChatIdsProvider,
        activeConversationProvider,
        conversationsProvider,
        isTemporaryChat,
        refreshConversationsCache;
import 'package:conduit_core/providers/host_ports.dart';
import 'package:conduit_core/services/api_service.dart';

import 'package:conduit_core/services/chat_completion_transport.dart';

import 'package:conduit_core/services/socket_service.dart';

import 'package:conduit_core/services/streaming_helper.dart';

import 'package:conduit_core/sync/sync_engine.dart';

import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/utils/debug_logger.dart';

import '../providers/chat_providers.dart';

import 'package:conduit_core/features/chat/providers/openwebui_chat_prompt_provider.dart';
import 'package:conduit_core/features/navigation/models/sidebar_navigation_model.dart';
import 'package:conduit_core/features/navigation/providers/sidebar_active_tab_provider.dart';
import 'package:conduit_core/features/terminal/models/terminal_models.dart';
import 'package:conduit_core/features/terminal/providers/terminal_providers.dart';

// ---------------------------------------------------------------------------
// Transport metadata helpers
// ---------------------------------------------------------------------------

/// Writes transport metadata to the assistant message so that downstream
/// consumers (e.g. the stop provider) can determine which cancellation path
/// to follow without re-inspecting the network layer.
void writeTransportMetadata({
  required dynamic ref,
  required ChatCompletionSession session,
  ChatMessagesNotifier? messageNotifier,

  /// The one answer of a multi-model turn this session belongs to. Null writes
  /// to the list tail, as a single-answer turn does.
  String? slotMessageId,
}) {
  ChatMessage update(ChatMessage m) {
    final meta = Map<String, dynamic>.from(m.metadata ?? const {});
    meta['transport'] = session.transport.name;
    if (session.taskId != null && session.taskId!.isNotEmpty) {
      meta['taskId'] = session.taskId;
    }
    if (session.abort != null) {
      meta['hasActiveAbortHandle'] = true;
    }
    return m.copyWith(metadata: meta);
  }

  try {
    final notifier = messageNotifier ?? ref.read(chatMessagesProvider.notifier);
    if (slotMessageId != null) {
      notifier.updateMessageById(slotMessageId, update);
    } else {
      notifier.updateLastMessageWithFunction(update);
    }
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
void setAwaitingSocketBinding({
  required dynamic ref,
  required bool value,
  String? slotMessageId,
}) {
  ChatMessage update(ChatMessage m) {
    final meta = Map<String, dynamic>.from(m.metadata ?? const {});
    meta['awaitingSocketBinding'] = value;
    return m.copyWith(metadata: meta);
  }

  try {
    final notifier = ref.read(chatMessagesProvider.notifier);
    if (slotMessageId != null) {
      notifier.updateMessageById(slotMessageId, update);
    } else {
      notifier.updateLastMessageWithFunction(update);
    }
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
  bool Function()? ownsActiveConversation,
  String? slotMessageId,
}) async {
  bool ownsConversation() => ownsActiveConversation?.call() ?? true;
  if (session.transport != ChatCompletionTransport.taskSocket) return;
  if (socketService == null) return;
  if (!ownsConversation()) return;

  // Resume reuses the live socket subscription; there is no "awaiting binding"
  // window to surface on the message (no fresh HTTP request was issued), so we
  // skip that metadata churn but still ensure the socket is connected.
  if (!isResume) {
    setAwaitingSocketBinding(
      ref: ref,
      value: true,
      slotMessageId: slotMessageId,
    );
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
    if (!isResume && ownsConversation()) {
      setAwaitingSocketBinding(
        ref: ref,
        value: false,
        slotMessageId: slotMessageId,
      );
    }
  }
}

/// Configures remote task monitoring by writing the session's task ID and
/// conversation ID into message metadata so reconnection / recovery logic
/// can find the right server resource.
void configureRemoteTaskMonitoring({
  required dynamic ref,
  required ChatCompletionSession session,
  ChatMessagesNotifier? messageNotifier,
  String? slotMessageId,
}) {
  if (session.taskId == null || session.taskId!.isEmpty) return;
  ChatMessage update(ChatMessage m) {
    final meta = Map<String, dynamic>.from(m.metadata ?? const {});
    meta['taskId'] = session.taskId;
    if (session.conversationId != null) {
      meta['taskConversationId'] = session.conversationId;
    }
    return m.copyWith(metadata: meta);
  }

  try {
    final notifier = messageNotifier ?? ref.read(chatMessagesProvider.notifier);
    if (slotMessageId != null) {
      notifier.updateMessageById(slotMessageId, update);
    } else {
      notifier.updateLastMessageWithFunction(update);
    }
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
///
/// Both are started before this returns. The result completes once the server
/// has answered the task stop, and says whether it accepted it; a message with
/// no task has nothing to refuse. Callers that only fire the stop may ignore it.
Future<bool> stopActiveTransport(ChatMessage message, ApiService? api) async {
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
  Future<void>? taskStop;
  if (taskConversationId != null && taskConversationId.isNotEmpty) {
    taskStop = api?.stopTasksByChat(taskConversationId);
  } else if (taskId != null && taskId.isNotEmpty) {
    taskStop = api?.stopTask(taskId);
  }
  if (taskStop == null) return true;
  try {
    await taskStop;
    return true;
  } catch (error) {
    DebugLogger.log(
      'task-stop-failed',
      scope: 'transport/stop',
      data: {'errorType': error.runtimeType.toString()},
    );
    return false;
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
Future<bool> dispatchChatTransport({
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
  bool Function()? ownsActiveConversation,
  // Resume dispatch can originate from ChatMessagesNotifier itself. Supplying
  // that instance avoids asking its Riverpod Ref to read its own provider,
  // which Riverpod correctly rejects as a self-dependency.
  ChatMessagesNotifier? messageNotifier,

  /// Optional attempt-level admission guard for a newly-created placeholder.
  /// It is checked before dispatch and after the socket-binding await, but not
  /// after transport attachment: normal completion itself makes a placeholder
  /// non-streaming, while the registered transport then owns cancellation.
  bool Function()? ownsPendingPlaceholder,

  /// Set when [session] carries ONE answer of a multi-model turn. Every update
  /// then goes to this exact assistant message, never to the list tail, and the
  /// stream refuses events for the turn's other answers. Null is an ordinary
  /// single-answer dispatch.
  String? slotMessageId,

  /// The assistant message ids of the turn's other answers. The stream sees the
  /// transcript as if only its own answer ended it.
  List<String> slotSiblingIds = const <String>[],
}) async {
  bool ownsConversation() => ownsActiveConversation?.call() ?? true;
  bool ownsPending() =>
      ownsConversation() && (ownsPendingPlaceholder?.call() ?? true);
  ChatMessagesNotifier messagesNotifier() =>
      messageNotifier ?? ref.read(chatMessagesProvider.notifier);
  final slot = slotMessageId;
  final siblings = slotSiblingIds.toSet();
  if (!ownsPending()) return false;

  // Freeze authorization before this dispatch first yields. The eventual
  // `/api/chat/completed` callback must keep the account that authorized the
  // stream instead of adopting a token selected while generation was active.
  final chatCompletedAuthSnapshot = api.captureAuthSnapshot();

  // 1. Write transport + flow metadata onto assistant message
  writeTransportMetadata(
    ref: ref,
    session: session,
    messageNotifier: messageNotifier,
    slotMessageId: slot,
  );

  try {
    ChatMessage markFlow(ChatMessage m) {
      final mergedMeta = {
        if (m.metadata != null) ...m.metadata!,
        'backgroundFlow': isBackgroundFlow,
        if (webSearchEnabled) 'webSearchFlow': true,
        if (imageGenerationEnabled) 'imageGenerationFlow': true,
      };
      return m.copyWith(metadata: mergedMeta);
    }

    if (slot != null) {
      messagesNotifier().updateMessageById(slot, markFlow);
    } else {
      messagesNotifier().updateLastMessageWithFunction(markFlow);
    }
  } catch (_) {}

  // 2. Bind socket for taskSocket sessions
  await bindTaskSocketIfNeeded(
    ref: ref,
    session: session,
    socketService: socketService,
    isResume: isResume,
    ownsActiveConversation: ownsPending,
    slotMessageId: slot,
  );
  if (!ownsPending()) return false;

  // 3. Configure remote task monitoring
  configureRemoteTaskMonitoring(
    ref: ref,
    session: session,
    messageNotifier: messageNotifier,
    slotMessageId: slot,
  );

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
    // The host's surface for server-initiated prompts and notices;
    // the core decides when to ask, the host renders it.
    uiRequests: ref.read(uiRequestPortProvider),
    session: session,
    webSearchEnabled: webSearchEnabled,
    assistantMessageId: assistantMessageId,
    modelId: modelId,
    modelItem: modelItem,
    sessionId: effectiveSessionId,
    activeConversationId: activeConversationId,
    api: api,
    chatCompletedAuthSnapshot: chatCompletedAuthSnapshot,
    socketService: socketService,
    workerManager: workerManager,
    filterIds: filterIds,
    allowForeignMessageBinding: slot == null,
    appendToLastMessage: (c) {
      if (!ownsConversation()) return;
      if (slot != null) {
        messagesNotifier().appendToSlotMessage(slot, c);
        return;
      }
      messagesNotifier().appendToLastMessage(c);
    },
    bufferLastMessageContent: (c) {
      if (!ownsConversation()) return;
      if (slot != null) {
        messagesNotifier().appendToSlotMessage(slot, c);
        return;
      }
      messagesNotifier().bufferLastMessageContent(c);
    },
    bufferProgressiveLastMessageContent: (c) {
      if (!ownsConversation()) return;
      if (slot != null) {
        messagesNotifier().appendToSlotMessage(slot, c);
        return;
      }
      messagesNotifier().bufferLastMessageContent(c, immediate: false);
    },
    bufferProgressiveLastMessageSnapshot: (snapshot) {
      if (!ownsConversation()) return;
      if (slot != null) {
        messagesNotifier().replaceSlotMessageContent(slot, snapshot());
        return;
      }
      messagesNotifier().bufferLastMessageContentSnapshot(snapshot);
    },
    replaceLastMessageContent: (c) {
      if (!ownsConversation()) return;
      if (slot != null) {
        messagesNotifier().replaceSlotMessageContent(slot, c);
        return;
      }
      messagesNotifier().replaceLastMessageContent(c);
    },
    updateLastMessageWith: (updater) {
      if (!ownsConversation()) return;
      if (slot != null) {
        messagesNotifier().updateMessageById(slot, updater);
        return;
      }
      messagesNotifier().updateLastMessageWithFunction(updater);
    },
    appendStatusUpdate: (messageId, update) {
      if (!ownsConversation()) return;
      messagesNotifier().appendStatusUpdate(messageId, update);
    },
    upsertCodeExecution: (messageId, execution) {
      if (!ownsConversation()) return;
      messagesNotifier().upsertCodeExecution(messageId, execution);
    },
    appendSourceReference: (messageId, reference) {
      if (!ownsConversation()) return;
      messagesNotifier().appendSourceReference(messageId, reference);
    },
    updateMessageById: (messageId, updater) {
      if (!ownsConversation()) return;
      messagesNotifier().updateMessageById(messageId, updater);
    },
    modelUsesReasoning: modelUsesReasoning,
    toolsEnabled: toolsEnabled,
    ownsStreamContext: ownsConversation,
    onChatTitleUpdated: (newTitle) {
      if (!ownsConversation()) return;
      final active = ref.read(activeConversationProvider);
      if (active == null || isTemporaryChat(active.id)) return;
      final normalizedTitle = newTitle.trim();
      if (normalizedTitle.isEmpty) return;
      ref
          .read(activeConversationProvider.notifier)
          .set(active.copyWith(title: normalizedTitle));
      ref
          .read(conversationsProvider.notifier)
          .applyServerGeneratedTitle(active.id, normalizedTitle);
    },
    onChatTagsUpdated: () {
      if (!ownsConversation()) return;
      final active = ref.read(activeConversationProvider);
      if (active == null || isTemporaryChat(active.id)) return;
      refreshConversationsCache(ref);
      Future.microtask(() async {
        if (!ownsConversation()) return;
        try {
          final refreshed = await api.getConversation(active.id);
          if (!ownsConversation()) return;
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
    },
    onTerminalEvent: (type, data) {
      if (!ownsConversation()) return;
      if (type == 'terminal:display_file' &&
          (data['path']?.toString().trim().isNotEmpty ?? false)) {
        ref.read(sidebarActiveTabProvider.notifier).set(SidebarTabId.terminal);
        ref
            .read(terminalSidebarPanelProvider.notifier)
            .setPanel(TerminalSidebarPanel.files);
      }
      ref.read(terminalDisplayFileProvider.notifier).handleEvent(type, data);
    },
    onInteractivePrompt: (type, data, acknowledge) {
      final conversationId = activeConversationId;
      if (!ownsConversation() ||
          conversationId == null ||
          conversationId.isEmpty) {
        acknowledge(
          type == 'confirmation'
              ? false
              : const <String, dynamic>{'status': 'cancelled', 'answers': {}},
        );
        return;
      }
      ref
          .read(openWebUiLivePromptProvider.notifier)
          .handleSocketRequest(
            conversationId: conversationId,
            type: type,
            data: data,
            acknowledge: acknowledge,
          );
    },
    onRemoteMessageBound: (remoteMessageId) {
      if (!ownsConversation() || slot != null) return;
      // Record the foreign server id bound to this assistant so the poll
      // fallback can still resolve server content if the socket later dies.
      messagesNotifier().recordResumeBoundRemoteMessageId(
        assistantMessageId,
        remoteMessageId,
      );
    },
    onChatActiveChanged: (chatId, active) {
      if (chatId == null || chatId.isEmpty) return;
      final notifier = ref.read(activeChatIdsProvider.notifier);
      if (active) {
        if (!ownsConversation()) return;
        notifier.setActive(chatId);
        return;
      }
      // The backend `chat:active(false)` only fires when the LAST task for the
      // chat finishes. This optimistic safety-net removal must be last-task
      // aware too, or an overlapping multi-model / branched generation would
      // drop the sidebar spinner while another stream is still running. Only
      // clear once the task registry reports no remaining tasks for the chat.
      // Capture the activation token now so a stream that starts for this chat
      // during the async lookup is not clobbered by this stale clear.
      final token = notifier.activationToken(chatId);
      unawaited(() async {
        try {
          final ids = await api.getTaskIdsByChat(chatId);
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
    completeStreamingUi: () {
      if (!ownsConversation()) return;
      if (slot != null) {
        // The answer is done; its transport goes when the stream releases it.
        messagesNotifier().finishSlotMessage(slot);
        return;
      }
      messagesNotifier().completeStreamingUi();
    },
    finishStreaming: () {
      if (!ownsConversation()) return;
      if (slot != null) {
        messagesNotifier().finishSlotMessage(slot);
        return;
      }
      messagesNotifier().finishStreaming();
    },
    getMessages: () {
      if (!ownsConversation()) return const <ChatMessage>[];
      final all =
          messageNotifier?.messagesSnapshot ?? ref.read(chatMessagesProvider);
      if (slot == null) return all;
      // This stream sees the transcript as if its own answer ended it, so the
      // helper's "which assistant is current" checks name this answer.
      return [
        for (final message in all)
          if (message.id == slot || !siblings.contains(message.id)) message,
      ];
    },
    getVisibleStreamingContent: () => slot != null || !ownsConversation()
        ? null
        : ref.read(streamingContentProvider),
    flushStreamingBuffer: () {
      if (!ownsConversation() || slot != null) return;
      messagesNotifier().syncStreamingBuffer();
    },
    onObsoleteStreamRetired: () {
      if (!ownsConversation()) return;
      if (slot != null) {
        messagesNotifier().releaseSlotTransport(slot);
        return;
      }
      messagesNotifier().retireObsoleteStreamingTransport(assistantMessageId);
    },
    pullChatSnapshot: (chatId) async {
      if (!ownsConversation()) return null;
      // CDT-RFC-001 Phase 1 (E2): the post-stream snapshot refresh persists
      // through the sync engine (upsertServerChat under the chat lock).
      try {
        final syncEngine = ref.read(syncEngineProvider.notifier);
        final pulled = await syncEngine.pullChatNow(chatId);
        return ownsConversation() ? pulled : null;
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

  if (!ownsConversation()) {
    activeStream.disposeWatchdog();
    return false;
  }

  // SocketService replays buffered events synchronously while the helper is
  // attaching its handlers. A terminal replay can therefore finish the
  // message and dispose every local streaming resource before attach returns.
  // Do not resurrect that completed transport in the notifier.
  if (activeStream.isDisposed()) {
    return true;
  }

  // 6. Register controller + socket subscriptions with the notifier.
  //    ActiveChatStream.controller may be null for httpStream / jsonCompletion
  //    (those transports complete via their own stream, not a
  //    StreamingResponseController).
  final notifier = messagesNotifier();
  if (slot != null) {
    // One answer among several: register beside its siblings' transports
    // rather than replacing the single transport the notifier tracks.
    notifier.registerSlotTransport(
      slot,
      activeStream.socketSubscriptions,
      onDispose: activeStream.disposeWatchdog,
    );
    return true;
  }
  if (activeStream.controller != null) {
    notifier.setMessageStream(assistantMessageId, activeStream.controller!);
  }
  notifier.setSocketSubscriptions(
    assistantMessageId,
    activeStream.socketSubscriptions,
    onDispose: activeStream.disposeWatchdog,
  );
  return true;
}
