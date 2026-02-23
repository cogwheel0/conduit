import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:uuid/uuid.dart';
import 'package:yaml/yaml.dart' as yaml;

import '../../../core/auth/auth_state_manager.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/conversation.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/conversation_delta_listener.dart';
import '../../../core/services/settings_service.dart';
import '../../../core/services/streaming_helper.dart';
import '../../../core/services/streaming_response_controller.dart';
import '../../../core/services/worker_manager.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../core/utils/tool_calls_parser.dart';
import '../models/chat_context_attachment.dart';
import '../providers/context_attachments_provider.dart';
import '../../../shared/services/tasks/task_queue.dart';
import '../../tools/providers/tools_providers.dart';
import '../services/reviewer_mode_service.dart';

part 'chat_providers.g.dart';

const bool kSocketVerboseLogging = false;

/// Returns true if the conversation ID indicates a temporary chat
bool isTemporaryConversation(String? conversationId) {
  return conversationId?.startsWith('local:') ?? false;
}

// Chat messages for current conversation
final chatMessagesProvider =
    NotifierProvider<ChatMessagesNotifier, List<ChatMessage>>(
      ChatMessagesNotifier.new,
    );

/// Whether chat is currently streaming a response.
/// Used by router to avoid showing connection issues during active streaming.
final isChatStreamingProvider = Provider<bool>((ref) {
  final messages = ref.watch(chatMessagesProvider);
  if (messages.isEmpty) return false;
  final last = messages.last;
  return last.role == 'assistant' && last.isStreaming;
});

// Loading state for conversation (used to show chat skeletons during fetch)
@Riverpod(keepAlive: true)
class IsLoadingConversation extends _$IsLoadingConversation {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

// Prefilled input text (e.g., when sharing text from other apps)
@Riverpod(keepAlive: true)
class PrefilledInputText extends _$PrefilledInputText {
  @override
  String? build() => null;

  void set(String? value) => state = value;

  void clear() => state = null;
}

// Trigger to request focus on the chat input (increment to signal)
@Riverpod(keepAlive: true)
class InputFocusTrigger extends _$InputFocusTrigger {
  @override
  int build() => 0;

  void set(int value) => state = value;

  int increment() {
    final next = state + 1;
    state = next;
    return next;
  }
}

// Whether the chat composer currently has focus
@Riverpod(keepAlive: true)
class ComposerHasFocus extends _$ComposerHasFocus {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

// Whether the chat composer is allowed to auto-focus.
// When false, the composer will remain unfocused until the user taps it.
@Riverpod(keepAlive: true)
class ComposerAutofocusEnabled extends _$ComposerAutofocusEnabled {
  @override
  bool build() => true;

  void set(bool value) => state = value;
}

// Chat messages notifier class
class ChatMessagesNotifier extends Notifier<List<ChatMessage>> {
  StreamingResponseController? _messageStream;
  ProviderSubscription? _conversationListener;
  final List<StreamSubscription> _subscriptions = [];
  final List<VoidCallback> _socketSubscriptions = [];
  VoidCallback? _socketTeardown;
  DateTime? _lastStreamingActivity;
  Timer? _taskStatusTimer;
  bool _taskStatusCheckInFlight = false;
  bool _observedRemoteTask = false;

  bool _initialized = false;

  @override
  List<ChatMessage> build() {
    if (!_initialized) {
      _initialized = true;
      _conversationListener = ref.listen(activeConversationProvider, (
        previous,
        next,
      ) {
        DebugLogger.log(
          'Conversation changed: ${previous?.id} -> ${next?.id}',
          scope: 'chat/providers',
        );

        // Only react when the conversation actually changes
        if (previous?.id == next?.id) {
          // If same conversation but server updated it (e.g., title/content), avoid overwriting
          // locally streamed assistant content with an outdated server copy.
          if (previous?.updatedAt != next?.updatedAt) {
            final serverMessages = next?.messages ?? const [];
            // Primary rule: adopt server messages when there are strictly more of them.
            if (serverMessages.length > state.length) {
              // Check streaming state BEFORE updating state
              final needsCleanup = _shouldCleanupStreamingFromServer(
                serverMessages,
              );
              state = serverMessages;
              if (needsCleanup) _cancelMessageStream();
              return;
            }

            // Secondary rule: if counts are equal but the last assistant message grew,
            // adopt the server copy to recover from missed socket events.
            if (serverMessages.isNotEmpty && state.isNotEmpty) {
              final serverLast = serverMessages.last;
              final localLast = state.last;
              final serverText = serverLast.content.trim();
              final localText = localLast.content.trim();
              final sameLastId = serverLast.id == localLast.id;
              final isAssistant = serverLast.role == 'assistant';
              final serverHasMore =
                  serverText.isNotEmpty && serverText.length > localText.length;
              final localEmptyButServerHas =
                  localText.isEmpty && serverText.isNotEmpty;
              // Also recover if server says streaming is done but local still streaming
              final serverDoneButLocalStreaming =
                  !serverLast.isStreaming && localLast.isStreaming;
              if (sameLastId &&
                  isAssistant &&
                  (serverHasMore ||
                      localEmptyButServerHas ||
                      serverDoneButLocalStreaming)) {
                // Check streaming state BEFORE updating state
                final needsCleanup = _shouldCleanupStreamingFromServer(
                  serverMessages,
                );
                state = serverMessages;
                if (needsCleanup) _cancelMessageStream();
                return;
              }
            }
          }
          return;
        }

        // Cancel any existing message stream when switching conversations
        _cancelMessageStream();
        _stopRemoteTaskMonitor();

        if (next != null) {
          state = next.messages;

          // Update selected model if conversation has a different model
          _updateModelForConversation(next);

          if (_hasStreamingAssistant) {
            _ensureRemoteTaskMonitor();
          }
        } else {
          state = [];
          _stopRemoteTaskMonitor();
        }
      });

      ref.onDispose(() {
        for (final subscription in _subscriptions) {
          subscription.cancel();
        }
        _subscriptions.clear();

        _cancelMessageStream();
        _stopRemoteTaskMonitor();

        _conversationListener?.close();
        _conversationListener = null;
      });
    }

    final activeConversation = ref.read(activeConversationProvider);
    return activeConversation?.messages ?? const [];
  }

  void _cancelMessageStream() {
    final controller = _messageStream;
    _messageStream = null;
    if (controller != null && controller.isActive) {
      unawaited(controller.cancel());
    }
    cancelSocketSubscriptions();
    _stopRemoteTaskMonitor();
  }

  /// Checks if streaming cleanup is needed when adopting server messages.
  /// Must be called BEFORE updating state, as it compares current local state
  /// with incoming server state.
  bool _shouldCleanupStreamingFromServer(List<ChatMessage> serverMessages) {
    if (serverMessages.isEmpty) return false;
    if (!_hasStreamingAssistant) return false;

    // Find the local streaming assistant message
    final localStreamingMsg = state.lastWhere(
      (m) => m.role == 'assistant' && m.isStreaming,
      orElse: () => state.last,
    );

    // Find the same message in server messages by ID
    final serverMsg = serverMessages.where((m) => m.id == localStreamingMsg.id);
    if (serverMsg.isNotEmpty && !serverMsg.first.isStreaming) {
      DebugLogger.log(
        'Server indicates streaming complete for message ${localStreamingMsg.id}',
        scope: 'chat/providers',
      );
      return true;
    }

    // Also check if server has MORE messages than local - if so, streaming must be done
    // (e.g., server has [assistant(done), user] but local only has [assistant(streaming)])
    if (serverMessages.length > state.length) {
      // Server has additional messages, so any local streaming must have completed
      DebugLogger.log(
        'Server has more messages (${serverMessages.length} vs ${state.length}) - '
        'streaming must be complete',
        scope: 'chat/providers',
      );
      return true;
    }

    return false;
  }

  bool get _hasStreamingAssistant {
    if (state.isEmpty) return false;
    final last = state.last;
    return last.role == 'assistant' && last.isStreaming;
  }

  void _ensureRemoteTaskMonitor() {
    if (_taskStatusTimer != null) {
      return;
    }
    // Poll every second for fast recovery from missed socket events.
    // This is a lightweight API call and provides the best UX for stuck streaming.
    _taskStatusTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_taskStatusCheckInFlight) {
        unawaited(_syncRemoteTaskStatus());
      }
    });
    if (!_taskStatusCheckInFlight) {
      unawaited(_syncRemoteTaskStatus());
    }
  }

  void _stopRemoteTaskMonitor() {
    _taskStatusTimer?.cancel();
    _taskStatusTimer = null;
    _taskStatusCheckInFlight = false;
    _observedRemoteTask = false;
  }

  Future<void> _syncRemoteTaskStatus() async {
    if (_taskStatusCheckInFlight) {
      return;
    }
    if (!_hasStreamingAssistant) {
      _stopRemoteTaskMonitor();
      return;
    }

    final api = ref.read(apiServiceProvider);
    final activeConversation = ref.read(activeConversationProvider);
    if (api == null || activeConversation == null) {
      _stopRemoteTaskMonitor();
      return;
    }

    // Skip server sync for temporary chats
    if (isTemporaryConversation(activeConversation.id)) {
      _stopRemoteTaskMonitor();
      return;
    }

    _taskStatusCheckInFlight = true;
    try {
      // Check both task status and server message state
      final taskIds = await api.getTaskIdsByChat(activeConversation.id);
      final hasActiveTasks = taskIds.isNotEmpty;

      if (hasActiveTasks) {
        _observedRemoteTask = true;
      }

      // When no active tasks and we previously observed tasks, streaming should be done.
      final tasksDone = _observedRemoteTask && !hasActiveTasks;

      // Secondary check: fetch conversation from server and compare message state.
      // This catches cases where the done signal was missed AND syncs any missed
      // content. Only runs when tasks have genuinely completed (were observed and
      // are now gone). We intentionally avoid any timed fallback checks here
      // because they conflict with legitimate slow task registration scenarios
      // like web search, which can take a long time to start on the server.
      // Note: If a socket connection silently fails before tasks complete, the
      // user can cancel via the stop button or navigate away to recover.
      if (_hasStreamingAssistant && tasksDone) {
        try {
          final serverConversation = await api.getConversation(
            activeConversation.id,
          );
          final serverMessages = serverConversation.messages;

          if (serverMessages.isNotEmpty && state.isNotEmpty) {
            final localLast = state.last;

            // Case 1: Server has more messages than local - streaming must be done
            if (serverMessages.length > state.length) {
              DebugLogger.log(
                'Server sync: server has more messages '
                '(${serverMessages.length} vs ${state.length})',
                scope: 'chat/providers',
              );
              state = serverMessages;
              _cancelMessageStream();
              return;
            }

            // Case 2: Find the local streaming message in server messages by ID
            // This handles cases where last messages differ
            if (localLast.role == 'assistant' && localLast.isStreaming) {
              final serverVersion = serverMessages
                  .where((m) => m.id == localLast.id)
                  .firstOrNull;

              if (serverVersion != null) {
                final serverDone = !serverVersion.isStreaming;
                final serverHasMoreContent =
                    serverVersion.content.length > localLast.content.length;

                if (serverDone || serverHasMoreContent) {
                  DebugLogger.log(
                    'Server sync: adopting server state '
                    '(serverDone=$serverDone, serverHasMore=$serverHasMoreContent)',
                    scope: 'chat/providers',
                  );
                  state = serverMessages;
                  _cancelMessageStream();
                }
              }
            }
          }
        } catch (e) {
          DebugLogger.log(
            'Server conversation fetch failed: $e',
            scope: 'chat/providers',
          );
        }
      }
    } catch (err, stack) {
      DebugLogger.log('Task status poll failed: $err', scope: 'chat/provider');
      debugPrintStack(stackTrace: stack);
    } finally {
      _taskStatusCheckInFlight = false;
    }
  }

  String _stripStreamingPlaceholders(String content) {
    var result = content;
    const ti = '[TYPING_INDICATOR]';
    const searchBanner = '🔍 Searching the web...';
    if (result.startsWith(ti)) {
      result = result.substring(ti.length);
    }
    if (result.startsWith(searchBanner)) {
      result = result.substring(searchBanner.length);
    }
    return result;
  }

  void _touchStreamingActivity() {
    _lastStreamingActivity = DateTime.now();
    if (_hasStreamingAssistant) {
      // Reset observed flag each time a new streaming session starts.
      if (_taskStatusTimer == null) {
        _observedRemoteTask = false;
      }
      _ensureRemoteTaskMonitor();
    } else {
      _stopRemoteTaskMonitor();
    }
  }

  // Enhanced streaming recovery method similar to OpenWebUI's approach
  void recoverStreamingIfNeeded() {
    if (state.isEmpty) return;

    final lastMessage = state.last;
    if (lastMessage.role != 'assistant' || !lastMessage.isStreaming) return;

    // Check if streaming has been inactive for too long
    final now = DateTime.now();
    if (_lastStreamingActivity != null) {
      final inactiveTime = now.difference(_lastStreamingActivity!);
      // If inactive for more than 3 minutes, consider recovery
      if (inactiveTime > const Duration(minutes: 3)) {
        DebugLogger.log(
          'Streaming inactive for ${inactiveTime.inSeconds}s, attempting recovery',
          scope: 'chat/provider',
        );

        // Try to gracefully finish the streaming state
        finishStreaming();
      }
    }
  }

  // Public wrapper to cancel the currently active stream (used by Stop)
  void cancelActiveMessageStream() {
    _cancelMessageStream();
  }

  Future<void> _updateModelForConversation(Conversation conversation) async {
    // Check if conversation has a model specified
    if (conversation.model == null || conversation.model!.isEmpty) {
      return;
    }

    final currentSelectedModel = ref.read(selectedModelProvider);

    // If the conversation's model is different from the currently selected one
    if (currentSelectedModel?.id != conversation.model) {
      // Get available models to find the matching one
      try {
        final models = await ref.read(modelsProvider.future);

        if (models.isEmpty) {
          return;
        }

        // Look for exact match first
        final conversationModel = models
            .where((model) => model.id == conversation.model)
            .firstOrNull;

        if (conversationModel != null) {
          // Update the selected model
          ref.read(selectedModelProvider.notifier).set(conversationModel);
        } else {
          // Model not found in available models - silently continue
        }
      } catch (e) {
        // Model update failed - silently continue
      }
    }
  }

  void setMessageStream(StreamingResponseController controller) {
    _cancelMessageStream();
    _messageStream = controller;
  }

  void setSocketSubscriptions(
    List<VoidCallback> subscriptions, {
    VoidCallback? onDispose,
  }) {
    cancelSocketSubscriptions();
    _socketSubscriptions.addAll(subscriptions);
    _socketTeardown = onDispose;
  }

  void cancelSocketSubscriptions() {
    if (_socketSubscriptions.isEmpty) {
      _socketTeardown?.call();
      _socketTeardown = null;
      return;
    }
    for (final dispose in _socketSubscriptions) {
      try {
        dispose();
      } catch (_) {}
    }
    _socketSubscriptions.clear();
    _socketTeardown?.call();
    _socketTeardown = null;
  }

  void addMessage(ChatMessage message) {
    state = [...state, message];
    if (message.role == 'assistant' && message.isStreaming) {
      _touchStreamingActivity();
    }
  }

  void removeLastMessage() {
    if (state.isNotEmpty) {
      state = state.sublist(0, state.length - 1);
    }
  }

  void clearMessages() {
    state = [];
  }

  void setMessages(List<ChatMessage> messages) {
    state = messages;
  }

  void updateLastMessage(String content) {
    if (state.isEmpty) return;

    final lastMessage = state.last;
    if (lastMessage.role != 'assistant') return;

    state = [
      ...state.sublist(0, state.length - 1),
      lastMessage.copyWith(content: _stripStreamingPlaceholders(content)),
    ];
    _touchStreamingActivity();
  }

  void updateLastMessageWithFunction(
    ChatMessage Function(ChatMessage) updater,
  ) {
    if (state.isEmpty) return;

    final lastMessage = state.last;
    if (lastMessage.role != 'assistant') return;
    final updated = updater(lastMessage);
    state = [...state.sublist(0, state.length - 1), updated];
    if (updated.isStreaming) {
      _touchStreamingActivity();
    }
  }

  void updateMessageById(
    String messageId,
    ChatMessage Function(ChatMessage current) updater,
  ) {
    final index = state.indexWhere((m) => m.id == messageId);
    if (index == -1) return;
    final original = state[index];
    final updated = updater(original);
    if (identical(updated, original)) {
      return;
    }
    final next = [...state];
    next[index] = updated;
    state = next;
  }

  // Archive the last assistant message's current content as a previous version
  // and clear it to prepare for regeneration, keeping the same message id.
  void archiveLastAssistantAsVersion() {
    if (state.isEmpty) return;
    final last = state.last;
    if (last.role != 'assistant') return;
    // Do not archive if it's already streaming (nothing final to archive)
    if (last.isStreaming) return;

    final snapshot = ChatMessageVersion(
      id: last.id,
      content: last.content,
      timestamp: last.timestamp,
      model: last.model,
      files: last.files == null
          ? null
          : List<Map<String, dynamic>>.from(last.files!),
      sources: List<ChatSourceReference>.from(last.sources),
      followUps: List<String>.from(last.followUps),
      codeExecutions: List<ChatCodeExecution>.from(last.codeExecutions),
      usage: last.usage == null ? null : Map<String, dynamic>.from(last.usage!),
      error: last.error, // Preserve error in version snapshot
    );

    final updated = last.copyWith(
      // Start a fresh stream for the new generation
      isStreaming: true,
      content: '',
      files: null,
      followUps: const [],
      codeExecutions: const [],
      sources: const [],
      usage: null,
      error: null, // Clear error for new generation
      versions: [...last.versions, snapshot],
    );

    state = [...state.sublist(0, state.length - 1), updated];
    _touchStreamingActivity();
  }

  void appendStatusUpdate(String messageId, ChatStatusUpdate update) {
    final withTimestamp = update.occurredAt == null
        ? update.copyWith(occurredAt: DateTime.now())
        : update;

    updateMessageById(messageId, (current) {
      final history = [...current.statusHistory];
      if (history.isNotEmpty) {
        final last = history.last;
        final sameAction =
            last.action != null && last.action == withTimestamp.action;
        final sameDescription =
            (withTimestamp.description?.isNotEmpty ?? false) &&
            withTimestamp.description == last.description;
        if (sameAction && sameDescription) {
          history[history.length - 1] = withTimestamp;
          return current.copyWith(statusHistory: history);
        }
      }

      history.add(withTimestamp);
      return current.copyWith(statusHistory: history);
    });
  }

  void setFollowUps(String messageId, List<String> followUps) {
    updateMessageById(messageId, (current) {
      return current.copyWith(followUps: List<String>.from(followUps));
    });
  }

  void upsertCodeExecution(String messageId, ChatCodeExecution execution) {
    updateMessageById(messageId, (current) {
      final existing = current.codeExecutions;
      final idx = existing.indexWhere((e) => e.id == execution.id);
      if (idx == -1) {
        return current.copyWith(codeExecutions: [...existing, execution]);
      }
      final next = [...existing];
      next[idx] = execution;
      return current.copyWith(codeExecutions: next);
    });
  }

  void appendSourceReference(String messageId, ChatSourceReference reference) {
    updateMessageById(messageId, (current) {
      final existing = current.sources;
      final alreadyPresent = existing.any((source) {
        if (reference.id != null && reference.id!.isNotEmpty) {
          return source.id == reference.id;
        }
        if (reference.url != null && reference.url!.isNotEmpty) {
          return source.url == reference.url;
        }
        return false;
      });
      if (alreadyPresent) {
        return current;
      }
      return current.copyWith(sources: [...existing, reference]);
    });
  }

  void appendToLastMessage(String content) {
    if (state.isEmpty) return;

    final lastMessage = state.last;
    if (lastMessage.role != 'assistant') return;
    if (!lastMessage.isStreaming) {
      DebugLogger.log(
        'Ignoring late chunk for finished message: ${lastMessage.id}',
        scope: 'chat/providers',
      );
      return;
    }

    // Append content directly - the widget's normalize() handles incomplete markdown
    state = [
      ...state.sublist(0, state.length - 1),
      lastMessage.copyWith(content: lastMessage.content + content),
    ];
    _touchStreamingActivity();
  }

  void replaceLastMessageContent(String content) {
    if (state.isEmpty) return;

    final lastMessage = state.last;
    if (lastMessage.role != 'assistant') return;

    final sanitized = _stripStreamingPlaceholders(content);
    state = [
      ...state.sublist(0, state.length - 1),
      lastMessage.copyWith(content: sanitized),
    ];
    _touchStreamingActivity();
  }

  void finishStreaming() {
    if (state.isEmpty) return;

    final lastMessage = state.last;
    if (lastMessage.role != 'assistant' || !lastMessage.isStreaming) return;

    final cleaned = _stripStreamingPlaceholders(lastMessage.content);

    var updatedLast = lastMessage.copyWith(
      isStreaming: false,
      content: cleaned,
    );

    // Fallback: if there is an immediately previous assistant message
    // marked as an archived variant and we have no versions yet, attach it
    // as a version so the UI shows a switcher.
    if (state.length >= 2 && updatedLast.versions.isEmpty) {
      final prev = state[state.length - 2];
      final isArchivedAssistant =
          prev.role == 'assistant' &&
          (prev.metadata?['archivedVariant'] == true);
      if (isArchivedAssistant) {
        final snapshot = ChatMessageVersion(
          id: prev.id,
          content: prev.content,
          timestamp: prev.timestamp,
          model: prev.model,
          files: prev.files,
          sources: prev.sources,
          followUps: prev.followUps,
          codeExecutions: prev.codeExecutions,
          usage: prev.usage,
        );
        updatedLast = updatedLast.copyWith(
          versions: [...updatedLast.versions, snapshot],
        );
      }
    }

    state = [...state.sublist(0, state.length - 1), updatedLast];
    _messageStream = null;
    _stopRemoteTaskMonitor();

    final activeConversation = ref.read(activeConversationProvider);
    if (activeConversation != null) {
      final updatedActive = activeConversation.copyWith(
        messages: List<ChatMessage>.unmodifiable(state),
        updatedAt: DateTime.now(),
      );
      ref.read(activeConversationProvider.notifier).set(updatedActive);

      final conversationsAsync = ref.read(conversationsProvider);
      Conversation? summary;
      conversationsAsync.maybeWhen(
        data: (conversations) {
          for (final conversation in conversations) {
            if (conversation.id == updatedActive.id) {
              summary = conversation;
              break;
            }
          }
        },
        orElse: () {},
      );
      final updatedSummary =
          (summary ?? updatedActive.copyWith(messages: const [])).copyWith(
            updatedAt: updatedActive.updatedAt,
          );

      ref
          .read(conversationsProvider.notifier)
          .upsertConversation(updatedSummary.copyWith(messages: const []));
    }

    // Trigger a refresh of the conversations list so UI like the Chats Drawer
    // can reconcile with the server once streaming completes. Best-effort:
    // ignore if ref lifecycle/context prevents invalidation.
    try {
      refreshConversationsCache(ref);
    } catch (_) {}
  }
}

// Pre-seed an assistant skeleton message (with a given id or a new one),
// persist it to the server to establish the message structure, and return the id.
Future<String> _preseedAssistantAndPersist(
  dynamic ref, {
  String? existingAssistantId,
  required String modelId,
  String? systemPrompt,
}) async {
  // Choose id: reuse existing if provided, else create new
  final String assistantMessageId =
      (existingAssistantId != null && existingAssistantId.isNotEmpty)
      ? existingAssistantId
      : const Uuid().v4();

  // If the message with this id doesn't exist locally, add a placeholder
  final msgs = ref.read(chatMessagesProvider);
  final exists = msgs.any((m) => m.id == assistantMessageId);
  if (!exists) {
    final placeholder = ChatMessage(
      id: assistantMessageId,
      role: 'assistant',
      content: '',
      timestamp: DateTime.now(),
      model: modelId,
      isStreaming: true,
    );
    ref.read(chatMessagesProvider.notifier).addMessage(placeholder);
  } else {
    // If it exists and is the last assistant, ensure we mark it streaming
    try {
      final last = msgs.isNotEmpty ? msgs.last : null;
      if (last != null &&
          last.id == assistantMessageId &&
          last.role == 'assistant' &&
          !last.isStreaming) {
        ref
            .read(chatMessagesProvider.notifier)
            .updateLastMessageWithFunction(
              (m) => m.copyWith(isStreaming: true),
            );
      }
    } catch (_) {}
  }

  // Sync conversation state to establish the full message structure on the server.
  // The server's upsert only sets parentId and model - we need to set role,
  // timestamp, childrenIds, etc. for proper message rendering.
  // Note: syncConversationMessages always sets done:true to prevent broken UI
  // if streaming is interrupted (see api_service.dart).
  try {
    final api = ref.read(apiServiceProvider);
    final activeConv = ref.read(activeConversationProvider);
    if (api != null && activeConv != null && !isTemporaryConversation(activeConv.id)) {
      final resolvedSystemPrompt =
          (systemPrompt != null && systemPrompt.trim().isNotEmpty)
          ? systemPrompt.trim()
          : activeConv.systemPrompt;
      final current = ref.read(chatMessagesProvider);
      await api.syncConversationMessages(
        activeConv.id,
        current,
        model: modelId,
        systemPrompt: resolvedSystemPrompt,
      );
    }
  } catch (_) {
    // Non-critical - continue if sync fails
  }

  return assistantMessageId;
}

String? _extractSystemPromptFromSettings(Map<String, dynamic>? settings) {
  if (settings == null) return null;

  final rootValue = settings['system'];
  if (rootValue is String) {
    final trimmed = rootValue.trim();
    if (trimmed.isNotEmpty) return trimmed;
  }

  final ui = settings['ui'];
  if (ui is Map<String, dynamic>) {
    final uiValue = ui['system'];
    if (uiValue is String) {
      final trimmed = uiValue.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
  }

  return null;
}

// Start a new chat (unified function for both "New Chat" button and home screen)
void startNewChat(dynamic ref) {
  // Clear active conversation
  ref.read(activeConversationProvider.notifier).clear();

  // Clear messages
  ref.read(chatMessagesProvider.notifier).clearMessages();

  // Clear context attachments (web pages, YouTube, knowledge base docs)
  ref.read(contextAttachmentsProvider.notifier).clear();

  // Clear any pending folder selection
  ref.read(pendingFolderIdProvider.notifier).clear();

  // Reset to default model for new conversations (fixes #296)
  restoreDefaultModel(ref);
}

/// Restores the selected model to the user's configured default model.
/// Call this when starting a new conversation or when settings change.
Future<void> restoreDefaultModel(dynamic ref) async {
  // Mark that this is not a manual selection
  ref.read(isManualModelSelectionProvider.notifier).set(false);

  // If auto-select (no explicit default), clear the cached default model
  // so defaultModelProvider will fetch from server
  final settingsDefault = ref.read(appSettingsProvider).defaultModel;
  if (settingsDefault == null || settingsDefault.isEmpty) {
    final storage = ref.read(optimizedStorageServiceProvider);
    await storage.saveLocalDefaultModel(null);
    DebugLogger.log('cleared-cached-default', scope: 'chat/model');
  }

  // Invalidate and re-read to force defaultModelProvider to use settings priority
  ref.invalidate(defaultModelProvider);

  try {
    await ref.read(defaultModelProvider.future);
  } catch (e) {
    DebugLogger.error('restore-default-failed', scope: 'chat/model', error: e);
  }
}

// Available tools provider
final availableToolsProvider =
    NotifierProvider<AvailableToolsNotifier, List<String>>(
      AvailableToolsNotifier.new,
    );

// Web search enabled state for API-based web search
final webSearchEnabledProvider =
    NotifierProvider<WebSearchEnabledNotifier, bool>(
      WebSearchEnabledNotifier.new,
    );

// Image generation enabled state - behaves like web search
final imageGenerationEnabledProvider =
    NotifierProvider<ImageGenerationEnabledNotifier, bool>(
      ImageGenerationEnabledNotifier.new,
    );

// Vision capable models provider
final visionCapableModelsProvider =
    NotifierProvider<VisionCapableModelsNotifier, List<String>>(
      VisionCapableModelsNotifier.new,
    );

// File upload capable models provider
final fileUploadCapableModelsProvider =
    NotifierProvider<FileUploadCapableModelsNotifier, List<String>>(
      FileUploadCapableModelsNotifier.new,
    );

class AvailableToolsNotifier extends Notifier<List<String>> {
  @override
  List<String> build() => [];

  void set(List<String> tools) => state = List<String>.from(tools);
}

class WebSearchEnabledNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

class ImageGenerationEnabledNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

class VisionCapableModelsNotifier extends Notifier<List<String>> {
  @override
  List<String> build() {
    final selectedModel = ref.watch(selectedModelProvider);
    if (selectedModel == null) {
      return [];
    }

    if (selectedModel.isMultimodal == true) {
      return [selectedModel.id];
    }

    // For now, assume all models support vision unless explicitly marked
    return [selectedModel.id];
  }
}

class FileUploadCapableModelsNotifier extends Notifier<List<String>> {
  @override
  List<String> build() {
    final selectedModel = ref.watch(selectedModelProvider);
    if (selectedModel == null) {
      return [];
    }

    // For now, assume all models support file upload
    return [selectedModel.id];
  }
}

// Helper function to validate file size
bool validateFileSize(int fileSize, int? maxSizeMB) {
  if (maxSizeMB == null) return true;
  final maxSizeBytes = maxSizeMB * 1024 * 1024;
  return fileSize <= maxSizeBytes;
}

// Helper function to validate file count
bool validateFileCount(int currentCount, int newFilesCount, int? maxCount) {
  if (maxCount == null) return true;
  return (currentCount + newFilesCount) <= maxCount;
}

// Small internal helper to convert a message with attachments into the
// OpenWebUI content payload format (text + image_url + files).
// - Adds text first (if non-empty)
// - Images (base64 or server-stored) go into content array as image_url
// - Non-image files go into files array for RAG/server-side resolution
Future<Map<String, dynamic>> _buildMessagePayloadWithAttachments({
  required dynamic api,
  required String role,
  required String cleanedText,
  required List<String> attachmentIds,
}) async {
  final List<Map<String, dynamic>> contentArray = [];

  if (cleanedText.isNotEmpty) {
    contentArray.add({'type': 'text', 'text': cleanedText});
  }

  // Collect non-image files for the files array
  final allFiles = <Map<String, dynamic>>[];

  for (final attachmentId in attachmentIds) {
    try {
      // Check if this is a base64 data URL (legacy or inline)
      if (attachmentId.startsWith('data:image/')) {
        // Inline image data URL - add directly to content array for LLM vision
        contentArray.add({
          'type': 'image_url',
          'image_url': {'url': attachmentId},
        });
        continue;
      }

      // For server-stored files, fetch info to determine type
      final fileInfo = await api.getFileInfo(attachmentId);
      final fileName = fileInfo['filename'] ?? fileInfo['name'] ?? 'Unknown';
      final fileSize = fileInfo['size'] ?? fileInfo['meta']?['size'];
      final contentType =
          fileInfo['meta']?['content_type'] ?? fileInfo['content_type'] ?? '';

      // Check if this is an image file
      final isImage = contentType.toString().startsWith('image/');

      if (isImage) {
        // Images must be in content array as image_url for LLM vision
        // Fetch the image content from server and convert to base64 data URL
        try {
          final fileContent = await api.getFileContent(attachmentId);
          String dataUrl;
          if (fileContent.startsWith('data:')) {
            dataUrl = fileContent;
          } else {
            // Determine MIME type from content type or file extension
            String mimeType = contentType.isNotEmpty
                ? contentType.toString()
                : _getMimeTypeFromFileName(fileName);
            dataUrl = 'data:$mimeType;base64,$fileContent';
          }
          contentArray.add({
            'type': 'image_url',
            'image_url': {'url': dataUrl},
          });
        } catch (_) {
          // If we can't fetch the image, skip it
        }
      } else {
        // Non-image files go to files array for RAG/server-side processing
        allFiles.add({
          'type': 'file',
          'id': attachmentId,
          // OpenWebUI now stores just the file ID, not the full URL path
          'url': attachmentId,
          'name': fileName,
          if (fileSize != null) 'size': fileSize,
        });
      }
    } catch (_) {
      // Swallow and continue to keep regeneration robust
    }
  }

  final messageMap = <String, dynamic>{
    'role': role,
    'content': contentArray.isNotEmpty ? contentArray : cleanedText,
  };
  if (allFiles.isNotEmpty) {
    messageMap['files'] = allFiles;
  }
  return messageMap;
}

String _getMimeTypeFromFileName(String fileName) {
  final ext = fileName.toLowerCase().split('.').last;
  return switch (ext) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'svg' => 'image/svg+xml',
    'bmp' => 'image/bmp',
    _ => 'image/png',
  };
}

List<Map<String, dynamic>> _contextAttachmentsToFiles(
  List<ChatContextAttachment> attachments,
) {
  return attachments.map((attachment) {
    switch (attachment.type) {
      case ChatContextAttachmentType.web:
        // Web pages use type 'text' with file data nested under 'file' key
        return {
          'type': 'text',
          'name': attachment.url ?? attachment.displayName,
          if (attachment.url != null) 'url': attachment.url,
          if (attachment.collectionName != null)
            'collection_name': attachment.collectionName,
          'file': {
            'data': {'content': attachment.content ?? ''},
            'meta': {
              'name': attachment.displayName,
              if (attachment.url != null) 'source': attachment.url,
            },
          },
        };
      case ChatContextAttachmentType.youtube:
        // YouTube uses type 'text' with context 'full' for full transcript
        return {
          'type': 'text',
          'name': attachment.url ?? attachment.displayName,
          if (attachment.url != null) 'url': attachment.url,
          'context': 'full',
          if (attachment.collectionName != null)
            'collection_name': attachment.collectionName,
          'file': {
            'data': {'content': attachment.content ?? ''},
            'meta': {
              'name': attachment.displayName,
              if (attachment.url != null) 'source': attachment.url,
            },
          },
        };
      case ChatContextAttachmentType.knowledge:
        // Knowledge base files use type 'file' with id for lookup
        final map = <String, dynamic>{
          'type': 'file',
          'id': attachment.fileId ?? attachment.id,
          'name': attachment.displayName,
          'knowledge': true,
          if (attachment.collectionName != null)
            'collection_name': attachment.collectionName,
          if (attachment.url != null) 'source': attachment.url,
        };
        return map;
    }
  }).toList();
}

// Regenerate message function that doesn't duplicate user message
Future<void> regenerateMessage(
  dynamic ref,
  String userMessageContent,
  List<String>? attachments, [
  String? existingAssistantId,
]) async {
  final reviewerMode = ref.read(reviewerModeProvider);
  final api = ref.read(apiServiceProvider);
  final selectedModel = ref.read(selectedModelProvider);

  if ((!reviewerMode && api == null) || selectedModel == null) {
    throw Exception('No API service or model selected');
  }

  var activeConversation = ref.read(activeConversationProvider);
  if (activeConversation == null) {
    throw Exception('No active conversation');
  }

  // In reviewer mode, simulate response
  if (reviewerMode) {
    final assistantMessage = ChatMessage(
      id: const Uuid().v4(),
      role: 'assistant',
      content: '',
      timestamp: DateTime.now(),
      model: selectedModel.id,
      isStreaming: true,
    );
    ref.read(chatMessagesProvider.notifier).addMessage(assistantMessage);

    // Helpers defined above

    // Reviewer mode: no immediate tool preview (no tool context)

    // Reviewer mode: no immediate tool preview (no tool context)

    // Use canned response for regeneration
    final responseText = ReviewerModeService.generateResponse(
      userMessage: userMessageContent,
    );

    // Simulate streaming response
    final words = responseText.split(' ');
    for (final word in words) {
      await Future.delayed(const Duration(milliseconds: 40));
      ref.read(chatMessagesProvider.notifier).appendToLastMessage('$word ');
    }

    ref.read(chatMessagesProvider.notifier).finishStreaming();
    await _saveConversationLocally(ref);
    return;
  }

  // For real API, proceed with regeneration using existing conversation messages
  try {
    Map<String, dynamic>? userSettingsData;
    String? userSystemPrompt;
    try {
      userSettingsData = await api!.getUserSettings();
      userSystemPrompt = _extractSystemPromptFromSettings(userSettingsData);
    } catch (_) {}

    if ((activeConversation.systemPrompt == null ||
            activeConversation.systemPrompt!.trim().isEmpty) &&
        (userSystemPrompt?.isNotEmpty ?? false)) {
      final updated = activeConversation.copyWith(
        systemPrompt: userSystemPrompt,
      );
      ref.read(activeConversationProvider.notifier).set(updated);
      activeConversation = updated;
    }

    // Include selected tool ids so provider-native tool calling is triggered
    final selectedToolIds = ref.read(selectedToolIdsProvider);
    // Include selected filter ids (toggle filters enabled by user)
    final selectedFilterIds = ref.read(selectedFilterIdsProvider);
    // Get conversation history for context (excluding the removed assistant message)
    final List<ChatMessage> messages = ref.read(chatMessagesProvider);
    final List<Map<String, dynamic>> conversationMessages =
        <Map<String, dynamic>>[];

    for (int i = 0; i < messages.length; i++) {
      final msg = messages[i];
      if (msg.role.isNotEmpty && msg.content.isNotEmpty && !msg.isStreaming) {
        final cleaned = ToolCallsParser.sanitizeForApi(msg.content);

        // Prefer provided attachments for the last user message; otherwise use message attachments
        final bool isLastUser =
            (i == messages.length - 1) && msg.role == 'user';
        final List<String> messageAttachments =
            (isLastUser && (attachments != null && attachments.isNotEmpty))
            ? List<String>.from(attachments)
            : (msg.attachmentIds ?? const <String>[]);

        if (messageAttachments.isNotEmpty) {
          final messageMap = await _buildMessagePayloadWithAttachments(
            api: api,
            role: msg.role,
            cleanedText: cleaned,
            attachmentIds: messageAttachments,
          );
          conversationMessages.add(messageMap);
        } else {
          conversationMessages.add({'role': msg.role, 'content': cleaned});
        }
      }
    }

    final conversationSystemPrompt = activeConversation.systemPrompt?.trim();
    final effectiveSystemPrompt =
        (conversationSystemPrompt != null &&
            conversationSystemPrompt.isNotEmpty)
        ? conversationSystemPrompt
        : userSystemPrompt;
    if (effectiveSystemPrompt != null && effectiveSystemPrompt.isNotEmpty) {
      final hasSystemMessage = conversationMessages.any(
        (m) => (m['role']?.toString().toLowerCase() ?? '') == 'system',
      );
      if (!hasSystemMessage) {
        conversationMessages.insert(0, {
          'role': 'system',
          'content': effectiveSystemPrompt,
        });
      }
    }

    // Pre-seed assistant skeleton and persist chain; always use a new id so
    // server history can branch like OpenWebUI.
    final String assistantMessageId = await _preseedAssistantAndPersist(
      ref,
      existingAssistantId: null,
      modelId: selectedModel.id,
      systemPrompt: effectiveSystemPrompt,
    );

    // Attach previous assistant as a version snapshot to the new assistant
    try {
      final msgs = ref.read(chatMessagesProvider);
      if (msgs.length >= 2) {
        final prev = msgs[msgs.length - 2];
        final last = msgs.last;
        if (prev.role == 'assistant' && last.id == assistantMessageId) {
          final snapshot = ChatMessageVersion(
            id: prev.id,
            content: prev.content,
            timestamp: prev.timestamp,
            model: prev.model,
            files: prev.files,
            sources: prev.sources,
            followUps: prev.followUps,
            codeExecutions: prev.codeExecutions,
            usage: prev.usage,
            error: prev.error, // Preserve error in version snapshot
          );
          ref
              .read(chatMessagesProvider.notifier)
              .updateLastMessageWithFunction(
                (m) => m.copyWith(versions: [...m.versions, snapshot]),
              );
        }
      }
    } catch (_) {}

    // Feature toggles
    final webSearchEnabled =
        ref.read(webSearchEnabledProvider) &&
        ref.read(webSearchAvailableProvider);
    final imageGenerationEnabled = ref.read(imageGenerationEnabledProvider);

    // Model metadata for completion notifications
    final supportedParams =
        selectedModel.supportedParameters ??
        [
          'max_tokens',
          'tool_choice',
          'tools',
          'response_format',
          'structured_outputs',
        ];
    final modelItem = {
      'id': selectedModel.id,
      'canonical_slug': selectedModel.id,
      'hugging_face_id': '',
      'name': selectedModel.name,
      'created': 1754089419,
      'description':
          selectedModel.description ??
          'This is a cloaked model provided to the community to gather feedback. This is an improved version of [Horizon Alpha](/openrouter/horizon-alpha)\n\nNote: It\'s free to use during this testing period, and prompts and completions are logged by the model creator for feedback and training.',
      'context_length': 256000,
      'architecture': {
        'modality': 'text+image->text',
        'input_modalities': ['image', 'text'],
        'output_modalities': ['text'],
        'tokenizer': 'Other',
        'instruct_type': null,
      },
      'pricing': {
        'prompt': '0',
        'completion': '0',
        'request': '0',
        'image': '0',
        'audio': '0',
        'web_search': '0',
        'internal_reasoning': '0',
      },
      'top_provider': {
        'context_length': 256000,
        'max_completion_tokens': 128000,
        'is_moderated': false,
      },
      'per_request_limits': null,
      'supported_parameters': supportedParams,
      'connection_type': 'external',
      'owned_by': 'openai',
      'openai': {
        'id': selectedModel.id,
        'canonical_slug': selectedModel.id,
        'hugging_face_id': '',
        'name': selectedModel.name,
        'created': 1754089419,
        'description':
            selectedModel.description ??
            'This is a cloaked model provided to the community to gather feedback. This is an improved version of [Horizon Alpha](/openrout'
                'er/horizon-alpha)\n\nNote: It\'s free to use during this testing period, and prompts and completions are logged by the model creator for feedback and training.',
        'context_length': 256000,
        'architecture': {
          'modality': 'text+image->text',
          'input_modalities': ['image', 'text'],
          'output_modalities': ['text'],
          'tokenizer': 'Other',
          'instruct_type': null,
        },
        'pricing': {
          'prompt': '0',
          'completion': '0',
          'request': '0',
          'image': '0',
          'audio': '0',
          'web_search': '0',
          'internal_reasoning': '0',
        },
        'top_provider': {
          'context_length': 256000,
          'max_completion_tokens': 128000,
          'is_moderated': false,
        },
        'per_request_limits': null,
        'supported_parameters': [
          'max_tokens',
          'tool_choice',
          'tools',
          'response_format',
          'structured_outputs',
        ],
        'connection_type': 'external',
      },
      'urlIdx': 0,
      'actions': <dynamic>[],
      'filters': <dynamic>[],
      'tags': <dynamic>[],
      // Include capabilities from the actual model for usage stats support
      'capabilities': selectedModel.capabilities,
      // Include info/metadata for usage capability detection
      'info': selectedModel.metadata?['info'],
    };

    // WebSocket-only streaming requires socket connection
    final socketService = ref.read(socketServiceProvider);
    if (socketService == null) {
      // No socket service available
      ref.read(chatMessagesProvider.notifier).updateLastMessageWithFunction((
        m,
      ) {
        return m.copyWith(
          content: 'Connection not available. Please try again later.',
          isStreaming: false,
        );
      });
      return;
    }

    // Ensure socket is connected (with 10s timeout)
    if (!socketService.isConnected) {
      final connected = await socketService.ensureConnected(
        timeout: const Duration(seconds: 10),
      );
      if (!connected) {
        ref.read(chatMessagesProvider.notifier).updateLastMessageWithFunction((
          m,
        ) {
          return m.copyWith(
            content:
                'Unable to connect to server. Please check your connection and try again.',
            isStreaming: false,
          );
        });
        return;
      }
    }

    final socketSessionId = socketService.sessionId;
    final bool wantSessionBinding =
        socketService.isConnected &&
        (socketSessionId != null && socketSessionId.isNotEmpty);

    // Resolve tool servers from user settings (if any)
    List<Map<String, dynamic>>? toolServers;
    final uiSettings = userSettingsData?['ui'] as Map<String, dynamic>?;
    final rawServers = uiSettings != null
        ? (uiSettings['toolServers'] as List?)
        : null;
    if (rawServers != null && rawServers.isNotEmpty) {
      try {
        toolServers = await _resolveToolServers(rawServers, api);
      } catch (_) {}
    }

    // Background tasks parity with Web client (safe defaults)
    bool shouldGenerateTitle = false;
    try {
      final conv = ref.read(activeConversationProvider);
      final nonSystemCount = conversationMessages
          .where((m) => (m['role']?.toString() ?? '') != 'system')
          .length;
      shouldGenerateTitle =
          (conv == null) ||
          ((conv.title == 'New Chat' || (conv.title.isEmpty)) &&
              nonSystemCount == 1);
    } catch (_) {}

    final bgTasks = <String, dynamic>{
      if (shouldGenerateTitle) 'title_generation': true,
      if (shouldGenerateTitle) 'tags_generation': true,
      'follow_up_generation': true,
      if (webSearchEnabled) 'web_search': true,
      if (imageGenerationEnabled) 'image_generation': true,
    };

    final bool isBackgroundToolsFlowPre =
        (selectedToolIds.isNotEmpty) ||
        (toolServers != null && toolServers.isNotEmpty);
    final bool isBackgroundWebSearchPre = webSearchEnabled;

    // Find the last user message ID for proper parent linking
    String? lastUserMessageId;
    for (int i = messages.length - 1; i >= 0; i--) {
      if (messages[i].role == 'user') {
        lastUserMessageId = messages[i].id;
        break;
      }
    }

    // Dispatch using unified send pipeline (background tools flow)
    final bool isBackgroundFlowPre =
        isBackgroundToolsFlowPre ||
        isBackgroundWebSearchPre ||
        imageGenerationEnabled;
    final bool passSocketSession =
        wantSessionBinding && (isBackgroundFlowPre || bgTasks.isNotEmpty);
    final response = api!.sendMessage(
      messages: conversationMessages,
      model: selectedModel.id,
      conversationId: activeConversation.id,
      toolIds: selectedToolIds.isNotEmpty ? selectedToolIds : null,
      filterIds: selectedFilterIds.isNotEmpty ? selectedFilterIds : null,
      enableWebSearch: webSearchEnabled,
      enableImageGeneration: imageGenerationEnabled,
      modelItem: modelItem,
      sessionIdOverride: passSocketSession ? socketSessionId : null,
      socketSessionId: socketSessionId,
      toolServers: toolServers,
      backgroundTasks: bgTasks,
      responseMessageId: assistantMessageId,
      userSettings: userSettingsData,
      parentMessageId: lastUserMessageId,
    );

    final stream = response.stream;
    final sessionId = response.sessionId;
    final effectiveSessionId =
        response.socketSessionId ?? socketSessionId ?? sessionId;

    final bool isBackgroundFlow = response.isBackgroundFlow;
    try {
      ref.read(chatMessagesProvider.notifier).updateLastMessageWithFunction((
        m,
      ) {
        final mergedMeta = {
          if (m.metadata != null) ...m.metadata!,
          'backgroundFlow': isBackgroundFlow,
          if (isBackgroundWebSearchPre) 'webSearchFlow': true,
          if (imageGenerationEnabled) 'imageGenerationFlow': true,
        };
        return m.copyWith(metadata: mergedMeta);
      });
    } catch (_) {}

    final registerDeltaListener = createConversationDeltaRegistrar(ref);

    // Check if model uses reasoning based on common naming patterns
    final modelLower = selectedModel.id.toLowerCase();
    final modelUsesReasoning =
        modelLower.contains('o1') ||
        modelLower.contains('o3') ||
        modelLower.contains('deepseek-r1') ||
        modelLower.contains('reasoning') ||
        modelLower.contains('think');

    final activeStream = attachUnifiedChunkedStreaming(
      stream: stream,
      webSearchEnabled: webSearchEnabled,
      assistantMessageId: assistantMessageId,
      modelId: selectedModel.id,
      modelItem: modelItem,
      sessionId: effectiveSessionId,
      activeConversationId: activeConversation.id,
      api: api!,
      socketService: socketService,
      workerManager: ref.read(workerManagerProvider),
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
      toolsEnabled:
          selectedToolIds.isNotEmpty ||
          (toolServers != null && toolServers.isNotEmpty) ||
          imageGenerationEnabled,
      onChatTitleUpdated: (newTitle) {
        final active = ref.read(activeConversationProvider);
        if (active != null) {
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
        }
        refreshConversationsCache(ref);
      },
      onChatTagsUpdated: () {
        refreshConversationsCache(ref);
        final active = ref.read(activeConversationProvider);
        final api = ref.read(apiServiceProvider);
        if (active != null && api != null && !isTemporaryConversation(active.id)) {
          Future.microtask(() async {
            try {
              final refreshed = await api.getConversation(active.id);
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
    );
    ref.read(chatMessagesProvider.notifier)
      ..setMessageStream(activeStream.controller)
      ..setSocketSubscriptions(
        activeStream.socketSubscriptions,
        onDispose: activeStream.disposeWatchdog,
      );
    return;
  } catch (e) {
    rethrow;
  }
}

// Send message function for widgets
Future<void> sendMessage(
  WidgetRef ref,
  String message,
  List<String>? attachments, [
  List<String>? toolIds,
]) async {
  await _sendMessageInternal(ref, message, attachments, toolIds);
}

// Service-friendly wrapper (accepts generic Ref)
Future<void> sendMessageFromService(
  Ref ref,
  String message,
  List<String>? attachments, [
  List<String>? toolIds,
]) async {
  await _sendMessageInternal(ref, message, attachments, toolIds);
}

Future<void> sendMessageWithContainer(
  ProviderContainer container,
  String message,
  List<String>? attachments, [
  List<String>? toolIds,
]) async {
  await _sendMessageInternal(container, message, attachments, toolIds);
}

// Internal send message implementation
Future<void> _sendMessageInternal(
  dynamic ref,
  String message,
  List<String>? attachments, [
  List<String>? toolIds,
]) async {
  final reviewerMode = ref.read(reviewerModeProvider);
  final api = ref.read(apiServiceProvider);
  final selectedModel = ref.read(selectedModelProvider);

  if ((!reviewerMode && api == null) || selectedModel == null) {
    throw Exception('No API service or model selected');
  }

  // Get context attachments synchronously (no API calls)
  final contextAttachments = ref.read(contextAttachmentsProvider);
  final contextFiles = _contextAttachmentsToFiles(contextAttachments);

  // All attachments are now server file IDs (images uploaded like OpenWebUI)
  // Legacy base64 support kept for backwards compatibility
  final legacyBase64Images = <Map<String, dynamic>>[];
  final serverFileIds = <String>[];

  if (attachments != null) {
    for (final attachment in attachments) {
      if (attachment.startsWith('data:image/')) {
        // Legacy base64 format - keep for backwards compatibility
        legacyBase64Images.add({'type': 'image', 'url': attachment});
      } else {
        // Server file ID (both images and documents)
        serverFileIds.add(attachment);
      }
    }
  }

  // Build initial user files with legacy base64 and context (server files added later)
  final List<Map<String, dynamic>>? initialUserFiles =
      (legacyBase64Images.isNotEmpty || contextFiles.isNotEmpty)
      ? [...legacyBase64Images, ...contextFiles]
      : null;

  // Create user message - files will be updated after fetching server info
  final userMessageId = const Uuid().v4();
  var userMessage = ChatMessage(
    id: userMessageId,
    role: 'user',
    content: message,
    timestamp: DateTime.now(),
    model: selectedModel.id,
    attachmentIds: attachments,
    files: initialUserFiles,
  );

  // Add user message to UI immediately for instant feedback
  ref.read(chatMessagesProvider.notifier).addMessage(userMessage);

  // Add assistant placeholder immediately to show typing indicator right away
  final String assistantMessageId = const Uuid().v4();
  final assistantPlaceholder = ChatMessage(
    id: assistantMessageId,
    role: 'assistant',
    content: '',
    timestamp: DateTime.now(),
    model: selectedModel.id,
    isStreaming: true,
  );
  ref.read(chatMessagesProvider.notifier).addMessage(assistantPlaceholder);

  // Now do async work in parallel: user settings + server file info
  String? userSystemPrompt;
  Map<String, dynamic>? userSettingsData;
  final serverFiles = <Map<String, dynamic>>[];

  if (!reviewerMode && api != null) {
    // Fetch user settings and server file info in parallel
    final settingsFuture = api.getUserSettings().catchError((_) => null);
    final fileInfoFutures = serverFileIds.map((fileId) async {
      try {
        final fileInfo = await api.getFileInfo(fileId);
        final fileName = fileInfo['filename'] ?? fileInfo['name'] ?? 'file';
        final fileSize = fileInfo['size'] ?? fileInfo['meta']?['size'];
        final contentType =
            fileInfo['meta']?['content_type'] ?? fileInfo['content_type'] ?? '';
        final collectionName =
            fileInfo['meta']?['collection_name'] ?? fileInfo['collection_name'];

        // Determine type: 'image' for image content types, 'file' for others
        // .toString() for safety against malformed API responses returning non-String
        final isImage = contentType.toString().startsWith('image/');
        return <String, dynamic>{
          'type': isImage ? 'image' : 'file',
          'id': fileId,
          'name': fileName,
          // OpenWebUI now stores just the file ID, not the full URL path
          // The frontend resolves it when displaying
          'url': fileId,
          if (fileSize != null) 'size': fileSize,
          if (collectionName != null) 'collection_name': collectionName,
          if (contentType.isNotEmpty) 'content_type': contentType,
        };
      } catch (_) {
        return <String, dynamic>{
          'type': 'file',
          'id': fileId,
          'name': 'file',
          'url': fileId,
        };
      }
    });

    // Wait for all async work to complete in parallel
    final fileInfoResults = await Future.wait(fileInfoFutures);
    userSettingsData = await settingsFuture;

    if (userSettingsData != null) {
      userSystemPrompt = _extractSystemPromptFromSettings(userSettingsData);
    }
    serverFiles.addAll(fileInfoResults);

    // Update user message with server file info if needed
    if (serverFiles.isNotEmpty || legacyBase64Images.isNotEmpty) {
      final allFiles = [...legacyBase64Images, ...serverFiles, ...contextFiles];
      userMessage = userMessage.copyWith(files: allFiles);
      ref
          .read(chatMessagesProvider.notifier)
          .updateMessageById(
            userMessageId,
            (ChatMessage m) => m.copyWith(files: allFiles),
          );
    }
  }

  // Check if we need to create a new conversation first
  var activeConversation = ref.read(activeConversationProvider);

  if (activeConversation == null) {
    // Check if there's a pending folder ID for this new conversation
    final pendingFolderId = ref.read(pendingFolderIdProvider);

    // Check if temporary chat mode is enabled
    final isTemporary = ref.read(temporaryChatEnabledProvider);
    final conversationId = isTemporary
        ? 'local:${const Uuid().v4()}'
        : const Uuid().v4();

    // Create new conversation with user message AND assistant placeholder
    // so the listener doesn't remove the placeholder when setting active
    final localConversation = Conversation(
      id: conversationId,
      title: 'New Chat',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      systemPrompt: userSystemPrompt,
      messages: [userMessage, assistantPlaceholder],
      folderId: pendingFolderId,
    );

    // Set as active conversation locally
    ref.read(activeConversationProvider.notifier).set(localConversation);
    activeConversation = localConversation;

    if (!reviewerMode && !isTemporary) {
      // Try to create on server - skip for temporary chats
      // Use lightweight message without large
      // base64 image data to avoid timeout (images sent in chat request)
      try {
        final lightweightMessage = userMessage.copyWith(
          attachmentIds: null,
          files: null,
        );
        final serverConversation = await api.createConversation(
          title: 'New Chat',
          messages: [lightweightMessage],
          model: selectedModel.id,
          systemPrompt: userSystemPrompt,
          folderId: pendingFolderId,
        );

        // Clear the pending folder ID after successful creation
        ref.read(pendingFolderIdProvider.notifier).clear();

        // Keep local messages (user + assistant placeholder) instead of server
        // messages, since we're in the middle of sending and streaming
        final currentMessages = ref.read(chatMessagesProvider);
        final updatedConversation = localConversation.copyWith(
          id: serverConversation.id,
          systemPrompt: serverConversation.systemPrompt ?? userSystemPrompt,
          messages: currentMessages,
          folderId: serverConversation.folderId ?? pendingFolderId,
        );
        ref.read(activeConversationProvider.notifier).set(updatedConversation);
        activeConversation = updatedConversation;

        ref
            .read(conversationsProvider.notifier)
            .upsertConversation(
              updatedConversation.copyWith(updatedAt: DateTime.now()),
            );

        // Invalidate conversations provider to refresh the list
        // Adding a small delay to prevent rapid invalidations that could cause duplicates
        Future.delayed(const Duration(milliseconds: 100), () {
          try {
            // Guard against using ref after provider disposal
            // Only Ref has .mounted; WidgetRef/ProviderContainer don't support
            // this check, so we proceed and let the underlying read operations
            // handle any disposal gracefully.
            final isMounted = ref is Ref ? ref.mounted : true;
            if (isMounted) {
              refreshConversationsCache(
                ref,
                includeFolders: pendingFolderId != null,
              );
            }
          } catch (_) {
            // If ref is disposed or invalid, skip
          }
        });
      } catch (e) {
        // Clear the pending folder ID on failure to prevent stale state
        ref.read(pendingFolderIdProvider.notifier).clear();
      }
    } else {
      // Clear the pending folder ID even in reviewer mode
      ref.read(pendingFolderIdProvider.notifier).clear();
    }
  }

  if (activeConversation != null &&
      (activeConversation.systemPrompt == null ||
          activeConversation.systemPrompt!.trim().isEmpty) &&
      (userSystemPrompt?.isNotEmpty ?? false)) {
    final updated = activeConversation.copyWith(systemPrompt: userSystemPrompt);
    ref.read(activeConversationProvider.notifier).set(updated);
    activeConversation = updated;
  }

  // Reviewer mode: simulate a response locally and return
  if (reviewerMode) {
    // Check if there are attachments
    String? filename;
    if (attachments != null && attachments.isNotEmpty) {
      // Get the first attachment filename for the response
      // In reviewer mode, we just simulate having a file
      filename = "demo_file.txt";
    }

    // Check if this is voice input
    // In reviewer mode, we don't have actual voice input state
    final isVoiceInput = false;

    // Generate appropriate canned response
    final responseText = ReviewerModeService.generateResponse(
      userMessage: message,
      filename: filename,
      isVoiceInput: isVoiceInput,
    );

    // Simulate token-by-token streaming
    final words = responseText.split(' ');
    for (final word in words) {
      await Future.delayed(const Duration(milliseconds: 40));
      ref.read(chatMessagesProvider.notifier).appendToLastMessage('$word ');
    }
    ref.read(chatMessagesProvider.notifier).finishStreaming();

    // Save locally
    await _saveConversationLocally(ref);
    return;
  }

  // Get conversation history for context
  final List<ChatMessage> messages = ref.read(chatMessagesProvider);
  final List<Map<String, dynamic>> conversationMessages =
      <Map<String, dynamic>>[];

  for (final msg in messages) {
    // Skip only empty assistant message placeholders that are currently streaming
    // Include completed messages (both user and assistant) for conversation history
    if (msg.role.isNotEmpty && msg.content.isNotEmpty && !msg.isStreaming) {
      // Prepare cleaned text content (strip tool details etc.)
      final cleaned = ToolCallsParser.sanitizeForApi(msg.content);

      final List<String> ids = msg.attachmentIds ?? const <String>[];
      if (ids.isNotEmpty) {
        final messageMap = await _buildMessagePayloadWithAttachments(
          api: api!,
          role: msg.role,
          cleanedText: cleaned,
          attachmentIds: ids,
        );
        if (msg.files != null && msg.files!.isNotEmpty) {
          // Safe cast - messageMap['files'] may be List<dynamic> after storage
          final rawFiles = messageMap['files'];
          final existingFiles = rawFiles is List
              ? rawFiles.whereType<Map<String, dynamic>>().toList()
              : <Map<String, dynamic>>[];
          messageMap['files'] = <Map<String, dynamic>>[
            ...existingFiles,
            ...msg.files!,
          ];
        }
        conversationMessages.add(messageMap);
      } else {
        // Regular text-only message
        final Map<String, dynamic> messageMap = {
          'role': msg.role,
          'content': cleaned,
        };
        if (msg.files != null && msg.files!.isNotEmpty) {
          messageMap['files'] = msg.files;
        }
        conversationMessages.add(messageMap);
      }
    }
  }

  final conversationSystemPrompt = activeConversation?.systemPrompt?.trim();
  final effectiveSystemPrompt =
      (conversationSystemPrompt != null && conversationSystemPrompt.isNotEmpty)
      ? conversationSystemPrompt
      : userSystemPrompt;
  if (effectiveSystemPrompt != null && effectiveSystemPrompt.isNotEmpty) {
    final hasSystemMessage = conversationMessages.any(
      (m) => (m['role']?.toString().toLowerCase() ?? '') == 'system',
    );
    if (!hasSystemMessage) {
      conversationMessages.insert(0, {
        'role': 'system',
        'content': effectiveSystemPrompt,
      });
    }
  }

  // Check feature toggles for API (gated by server availability)
  final webSearchEnabled =
      ref.read(webSearchEnabledProvider) &&
      ref.read(webSearchAvailableProvider);
  final imageGenerationEnabled = ref.read(imageGenerationEnabledProvider);

  // Prepare tools list - pass tool IDs directly
  final List<String>? toolIdsForApi = (toolIds != null && toolIds.isNotEmpty)
      ? toolIds
      : null;

  // Get selected toggle filter IDs
  final selectedFilterIds = ref.read(selectedFilterIdsProvider);
  final List<String>? filterIdsForApi = selectedFilterIds.isNotEmpty
      ? selectedFilterIds
      : null;

  try {
    // Assistant placeholder was already added above (after user message)
    // to show typing indicator immediately. Sync conversation state to server.
    // Sync conversation state to ensure WebUI can load conversation history
    try {
      final activeConvForSeed = ref.read(activeConversationProvider);
      if (activeConvForSeed != null && !isTemporaryConversation(activeConvForSeed.id)) {
        final msgsForSeed = ref.read(chatMessagesProvider);
        await api.syncConversationMessages(
          activeConvForSeed.id,
          msgsForSeed,
          model: selectedModel.id,
          systemPrompt: effectiveSystemPrompt,
        );
      }
    } catch (_) {
      // Non-critical - continue if sync fails
    }
    // Use the model's actual supported parameters if available
    final supportedParams =
        selectedModel.supportedParameters ??
        [
          'max_tokens',
          'tool_choice',
          'tools',
          'response_format',
          'structured_outputs',
        ];

    // Create comprehensive model item matching OpenWebUI format exactly
    final modelItem = {
      'id': selectedModel.id,
      'canonical_slug': selectedModel.id,
      'hugging_face_id': '',
      'name': selectedModel.name,
      'created': 1754089419, // Use example timestamp for consistency
      'description':
          selectedModel.description ??
          'This is a cloaked model provided to the community to gather feedback. This is an improved version of [Horizon Alpha](/openrouter/horizon-alpha)\n\nNote: It\'s free to use during this testing period, and prompts and completions are logged by the model creator for feedback and training.',
      'context_length': 256000,
      'architecture': {
        'modality': 'text+image->text',
        'input_modalities': ['image', 'text'],
        'output_modalities': ['text'],
        'tokenizer': 'Other',
        'instruct_type': null,
      },
      'pricing': {
        'prompt': '0',
        'completion': '0',
        'request': '0',
        'image': '0',
        'audio': '0',
        'web_search': '0',
        'internal_reasoning': '0',
      },
      'top_provider': {
        'context_length': 256000,
        'max_completion_tokens': 128000,
        'is_moderated': false,
      },
      'per_request_limits': null,
      'supported_parameters': supportedParams,
      'connection_type': 'external',
      'owned_by': 'openai',
      'openai': {
        'id': selectedModel.id,
        'canonical_slug': selectedModel.id,
        'hugging_face_id': '',
        'name': selectedModel.name,
        'created': 1754089419,
        'description':
            selectedModel.description ??
            'This is a cloaked model provided to the community to gather feedback. This is an improved version of [Horizon Alpha](/openrout'
                'er/horizon-alpha)\n\nNote: It\'s free to use during this testing period, and prompts and completions are logged by the model creator for feedback and training.',
        'context_length': 256000,
        'architecture': {
          'modality': 'text+image->text',
          'input_modalities': ['image', 'text'],
          'output_modalities': ['text'],
          'tokenizer': 'Other',
          'instruct_type': null,
        },
        'pricing': {
          'prompt': '0',
          'completion': '0',
          'request': '0',
          'image': '0',
          'audio': '0',
          'web_search': '0',
          'internal_reasoning': '0',
        },
        'top_provider': {
          'context_length': 256000,
          'max_completion_tokens': 128000,
          'is_moderated': false,
        },
        'per_request_limits': null,
        'supported_parameters': [
          'max_tokens',
          'tool_choice',
          'tools',
          'response_format',
          'structured_outputs',
        ],
        'connection_type': 'external',
      },
      'urlIdx': 0,
      'actions': <dynamic>[],
      'filters': <dynamic>[],
      'tags': <dynamic>[],
      // Include capabilities from the actual model for usage stats support
      'capabilities': selectedModel.capabilities,
      // Include info/metadata for usage capability detection
      'info': selectedModel.metadata?['info'],
    };

    // WebSocket-only streaming requires socket connection.
    // Wait for connection with timeout before proceeding.
    final socketService = ref.read(socketServiceProvider);
    if (socketService == null) {
      // No socket service available at all
      ref.read(chatMessagesProvider.notifier).updateLastMessageWithFunction((
        m,
      ) {
        return m.copyWith(
          content: 'Connection not available. Please try again later.',
          isStreaming: false,
        );
      });
      return;
    }

    // Ensure socket is connected (with 10s timeout for initial connection)
    if (!socketService.isConnected) {
      final connected = await socketService.ensureConnected(
        timeout: const Duration(seconds: 10),
      );
      if (!connected) {
        // Socket connection failed - cannot stream without it
        ref.read(chatMessagesProvider.notifier).updateLastMessageWithFunction((
          m,
        ) {
          return m.copyWith(
            content:
                'Unable to connect to server. Please check your connection and try again.',
            isStreaming: false,
          );
        });
        return;
      }
    }

    // Socket is now connected - resolve session for background tasks parity
    final socketSessionId = socketService.sessionId;
    final bool wantSessionBinding =
        socketService.isConnected &&
        (socketSessionId != null && socketSessionId.isNotEmpty);

    // Resolve tool servers from user settings (if any)
    List<Map<String, dynamic>>? toolServers;
    final uiSettings = userSettingsData?['ui'] as Map<String, dynamic>?;
    final rawServers = uiSettings != null
        ? (uiSettings['toolServers'] as List?)
        : null;
    if (rawServers != null && rawServers.isNotEmpty) {
      try {
        toolServers = await _resolveToolServers(rawServers, api);
      } catch (_) {}
    }

    // Background tasks parity with Web client (safe defaults)
    // Enable title/tags generation on the very first user turn of a new chat.
    bool shouldGenerateTitle = false;
    try {
      final conv = ref.read(activeConversationProvider);
      // Use the outbound conversationMessages we just built (excludes streaming placeholders)
      final nonSystemCount = conversationMessages
          .where((m) => (m['role']?.toString() ?? '') != 'system')
          .length;
      shouldGenerateTitle =
          (conv == null) ||
          ((conv.title == 'New Chat' || (conv.title.isEmpty)) &&
              nonSystemCount == 1);
    } catch (_) {}

    // Match web client: request background follow-ups always; title/tags on first turn
    final bgTasks = <String, dynamic>{
      if (shouldGenerateTitle) 'title_generation': true,
      if (shouldGenerateTitle) 'tags_generation': true,
      'follow_up_generation': true,
      if (webSearchEnabled) 'web_search': true, // enable bg web search
      if (imageGenerationEnabled)
        'image_generation': true, // enable bg image flow
    };

    // Determine if we need background task flow (tools/tool servers or web search)
    final bool isBackgroundToolsFlowPre =
        (toolIdsForApi != null && toolIdsForApi.isNotEmpty) ||
        (toolServers != null && toolServers.isNotEmpty);
    final bool isBackgroundWebSearchPre = webSearchEnabled;

    // Find the last user message ID for proper parent linking
    String? lastUserMessageId;
    for (int i = messages.length - 1; i >= 0; i--) {
      if (messages[i].role == 'user') {
        lastUserMessageId = messages[i].id;
        break;
      }
    }

    final bool shouldBindSession =
        wantSessionBinding &&
        (isBackgroundToolsFlowPre ||
            isBackgroundWebSearchPre ||
            imageGenerationEnabled ||
            bgTasks.isNotEmpty);

    final response = await api.sendMessage(
      messages: conversationMessages,
      model: selectedModel.id,
      conversationId: activeConversation?.id,
      toolIds: toolIdsForApi,
      filterIds: filterIdsForApi,
      enableWebSearch: webSearchEnabled,
      // Enable image generation on the server when requested
      enableImageGeneration: imageGenerationEnabled,
      modelItem: modelItem,
      // Bind to Socket session whenever available so the server can push
      // streaming updates to this client (improves first-turn streaming).
      sessionIdOverride: shouldBindSession ? socketSessionId : null,
      socketSessionId: socketSessionId,
      toolServers: toolServers,
      backgroundTasks: bgTasks,
      responseMessageId: assistantMessageId,
      userSettings: userSettingsData,
      parentMessageId: lastUserMessageId,
    );

    final stream = response.stream;
    final sessionId = response.sessionId;
    final effectiveSessionId =
        response.socketSessionId ?? socketSessionId ?? sessionId;

    // Use unified streaming helper for WebSocket handling
    final bool isBackgroundFlow = response.isBackgroundFlow;

    try {
      ref.read(chatMessagesProvider.notifier).updateLastMessageWithFunction((
        m,
      ) {
        final mergedMeta = {
          if (m.metadata != null) ...m.metadata!,
          'backgroundFlow': isBackgroundFlow,
          if (isBackgroundWebSearchPre) 'webSearchFlow': true,
          if (imageGenerationEnabled) 'imageGenerationFlow': true,
        };
        return m.copyWith(metadata: mergedMeta);
      });
    } catch (_) {}

    final registerDeltaListener = createConversationDeltaRegistrar(ref);

    // Check if model uses reasoning based on common naming patterns
    final modelLower2 = selectedModel.id.toLowerCase();
    final modelUsesReasoning2 =
        modelLower2.contains('o1') ||
        modelLower2.contains('o3') ||
        modelLower2.contains('deepseek-r1') ||
        modelLower2.contains('reasoning') ||
        modelLower2.contains('think');

    final activeStream = attachUnifiedChunkedStreaming(
      stream: stream,
      webSearchEnabled: webSearchEnabled,
      assistantMessageId: assistantMessageId,
      modelId: selectedModel.id,
      modelItem: modelItem,
      sessionId: effectiveSessionId,
      activeConversationId: activeConversation?.id,
      api: api!,
      socketService: socketService,
      workerManager: ref.read(workerManagerProvider),
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
      modelUsesReasoning: modelUsesReasoning2,
      toolsEnabled:
          (toolIdsForApi != null && toolIdsForApi.isNotEmpty) ||
          (toolServers != null && toolServers.isNotEmpty) ||
          imageGenerationEnabled,
      onChatTitleUpdated: (newTitle) {
        final active = ref.read(activeConversationProvider);
        if (active != null) {
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
        }
        refreshConversationsCache(ref);
      },
      onChatTagsUpdated: () {
        refreshConversationsCache(ref);
        final active = ref.read(activeConversationProvider);
        final api = ref.read(apiServiceProvider);
        if (active != null && api != null && !isTemporaryConversation(active.id)) {
          Future.microtask(() async {
            try {
              final refreshed = await api.getConversation(active.id);
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
    );

    ref.read(chatMessagesProvider.notifier)
      ..setMessageStream(activeStream.controller)
      ..setSocketSubscriptions(
        activeStream.socketSubscriptions,
        onDispose: activeStream.disposeWatchdog,
      );

    // Clear context attachments after successfully initiating the message send.
    // This prevents stale attachments from being included in subsequent messages.
    try {
      ref.read(contextAttachmentsProvider.notifier).clear();
    } catch (_) {}

    return;
  } catch (e) {
    // Handle error - remove the assistant message placeholder
    ref.read(chatMessagesProvider.notifier).removeLastMessage();

    // Add user-friendly error message instead of rethrowing
    if (e.toString().contains('400')) {
      final errorMessage = ChatMessage(
        id: const Uuid().v4(),
        role: 'assistant',
        content: '',
        timestamp: DateTime.now(),
        isStreaming: false,
        error: const ChatMessageError(
          content:
              'There was an issue with the message format. This might be '
              'because the image attachment couldn\'t be processed, the request '
              'format is incompatible with the selected model, or the message '
              'contains unsupported content. Please try sending the message '
              'again, or try without attachments.',
        ),
      );
      ref.read(chatMessagesProvider.notifier).addMessage(errorMessage);
    } else if (e.toString().contains('401') || e.toString().contains('403')) {
      // Authentication errors - clear auth state and redirect to login
      ref.invalidate(authStateManagerProvider);
    } else if (e.toString().contains('500')) {
      final errorMessage = ChatMessage(
        id: const Uuid().v4(),
        role: 'assistant',
        content: '',
        timestamp: DateTime.now(),
        isStreaming: false,
        error: const ChatMessageError(
          content:
              'Unable to connect to the AI model. The server returned an '
              'error (500). This is typically a server-side issue. Please try '
              'again or contact your administrator.',
        ),
      );
      ref.read(chatMessagesProvider.notifier).addMessage(errorMessage);
    } else if (e.toString().contains('404')) {
      DebugLogger.log(
        'Model or endpoint not found (404)',
        scope: 'chat/providers',
      );
      final errorMessage = ChatMessage(
        id: const Uuid().v4(),
        role: 'assistant',
        content: '',
        timestamp: DateTime.now(),
        isStreaming: false,
        error: const ChatMessageError(
          content:
              'The selected AI model doesn\'t seem to be available. '
              'Please try selecting a different model or check with your '
              'administrator.',
        ),
      );
      ref.read(chatMessagesProvider.notifier).addMessage(errorMessage);
    } else {
      // For other errors, provide a generic message and rethrow
      final errorMessage = ChatMessage(
        id: const Uuid().v4(),
        role: 'assistant',
        content: '',
        timestamp: DateTime.now(),
        isStreaming: false,
        error: const ChatMessageError(
          content:
              'An unexpected error occurred while processing your request. '
              'Please try again or check your connection.',
        ),
      );
      ref.read(chatMessagesProvider.notifier).addMessage(errorMessage);
    }
  }
}

// Save current conversation to OpenWebUI server
// Removed server persistence; only local caching is used in mobile app.

// Fallback: Save current conversation to local storage
Future<void> _saveConversationLocally(dynamic ref) async {
  try {
    final storage = ref.read(optimizedStorageServiceProvider);
    final messages = ref.read(chatMessagesProvider);
    final activeConversation = ref.read(activeConversationProvider);

    if (messages.isEmpty) return;

    // Create or update conversation locally
    final conversation =
        activeConversation ??
        Conversation(
          id: const Uuid().v4(),
          title: _generateConversationTitle(messages),
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          messages: messages,
        );

    final updatedConversation = conversation.copyWith(
      messages: messages,
      updatedAt: DateTime.now(),
    );

    // Store conversation locally using the storage service's actual methods
    final conversationsJson = await storage.getString('conversations') ?? '[]';
    final List<dynamic> conversations = jsonDecode(conversationsJson);

    // Find and update or add the conversation
    final existingIndex = conversations.indexWhere(
      (c) => c['id'] == updatedConversation.id,
    );
    if (existingIndex >= 0) {
      conversations[existingIndex] = updatedConversation.toJson();
    } else {
      conversations.add(updatedConversation.toJson());
    }

    await storage.setString('conversations', jsonEncode(conversations));
    ref.read(activeConversationProvider.notifier).set(updatedConversation);
    refreshConversationsCache(ref);
  } catch (e) {
    // Handle local storage errors silently
  }
}

String _generateConversationTitle(List<ChatMessage> messages) {
  final firstUserMessage = messages.firstWhere(
    (msg) => msg.role == 'user',
    orElse: () => ChatMessage(
      id: '',
      role: 'user',
      content: 'New Chat',
      timestamp: DateTime.now(),
    ),
  );

  // Use first 50 characters of the first user message as title
  final title = firstUserMessage.content.length > 50
      ? '${firstUserMessage.content.substring(0, 50)}...'
      : firstUserMessage.content;

  return title.isEmpty ? 'New Chat' : title;
}

// Pin/Unpin conversation
Future<void> pinConversation(
  WidgetRef ref,
  String conversationId,
  bool pinned,
) async {
  try {
    final api = ref.read(apiServiceProvider);
    if (api == null) throw Exception('No API service available');

    await api.pinConversation(conversationId, pinned);

    ref
        .read(conversationsProvider.notifier)
        .updateConversation(
          conversationId,
          (conversation) =>
              conversation.copyWith(pinned: pinned, updatedAt: DateTime.now()),
        );

    // Refresh conversations list to reflect the change
    refreshConversationsCache(ref);

    // Update active conversation if it's the one being pinned
    final activeConversation = ref.read(activeConversationProvider);
    if (activeConversation?.id == conversationId) {
      ref
          .read(activeConversationProvider.notifier)
          .set(activeConversation!.copyWith(pinned: pinned));
    }
  } catch (e) {
    DebugLogger.log(
      'Error ${pinned ? 'pinning' : 'unpinning'} conversation: $e',
      scope: 'chat/providers',
    );
    rethrow;
  }
}

// Archive/Unarchive conversation
Future<void> archiveConversation(
  WidgetRef ref,
  String conversationId,
  bool archived,
) async {
  final api = ref.read(apiServiceProvider);
  final activeConversation = ref.read(activeConversationProvider);

  // Update local state first
  if (activeConversation?.id == conversationId && archived) {
    ref.read(activeConversationProvider.notifier).clear();
    ref.read(chatMessagesProvider.notifier).clearMessages();
  }

  try {
    if (api == null) throw Exception('No API service available');

    await api.archiveConversation(conversationId, archived);

    ref
        .read(conversationsProvider.notifier)
        .updateConversation(
          conversationId,
          (conversation) => conversation.copyWith(
            archived: archived,
            updatedAt: DateTime.now(),
          ),
        );

    // Refresh conversations list to reflect the change
    refreshConversationsCache(ref);
  } catch (e) {
    DebugLogger.log(
      'Error ${archived ? 'archiving' : 'unarchiving'} conversation: $e',
      scope: 'chat/providers',
    );

    // If server operation failed and we archived locally, restore the conversation
    if (activeConversation?.id == conversationId && archived) {
      ref.read(activeConversationProvider.notifier).set(activeConversation);
      // Messages will be restored through the listener
    }

    rethrow;
  }
}

// Share conversation
Future<String?> shareConversation(WidgetRef ref, String conversationId) async {
  try {
    final api = ref.read(apiServiceProvider);
    if (api == null) throw Exception('No API service available');

    final shareId = await api.shareConversation(conversationId);

    ref
        .read(conversationsProvider.notifier)
        .updateConversation(
          conversationId,
          (conversation) => conversation.copyWith(
            shareId: shareId,
            updatedAt: DateTime.now(),
          ),
        );

    // Refresh conversations list to reflect the change
    refreshConversationsCache(ref);

    return shareId;
  } catch (e) {
    DebugLogger.log('Error sharing conversation: $e', scope: 'chat/providers');
    rethrow;
  }
}

// Clone conversation
Future<void> cloneConversation(WidgetRef ref, String conversationId) async {
  try {
    final api = ref.read(apiServiceProvider);
    if (api == null) throw Exception('No API service available');

    final clonedConversation = await api.cloneConversation(conversationId);

    // Set the cloned conversation as active
    ref.read(activeConversationProvider.notifier).set(clonedConversation);
    // Load messages through the listener mechanism
    // The ChatMessagesNotifier will automatically load messages when activeConversation changes

    // Refresh conversations list to show the new conversation
    ref
        .read(conversationsProvider.notifier)
        .upsertConversation(
          clonedConversation.copyWith(updatedAt: DateTime.now()),
        );
    refreshConversationsCache(ref);
  } catch (e) {
    DebugLogger.log('Error cloning conversation: $e', scope: 'chat/providers');
    rethrow;
  }
}

// Regenerate last message
final regenerateLastMessageProvider = Provider<Future<void> Function()>((ref) {
  return () async {
    final messages = ref.read(chatMessagesProvider);
    if (messages.length < 2) return;

    // Find last user message with proper bounds checking
    ChatMessage? lastUserMessage;
    // Detect if last assistant message had generated images
    final ChatMessage? lastAssistantMessage = messages.isNotEmpty
        ? messages.last
        : null;
    final bool lastAssistantHadImages =
        lastAssistantMessage != null &&
        lastAssistantMessage.role == 'assistant' &&
        (lastAssistantMessage.files?.any((f) => f['type'] == 'image') == true);
    for (int i = messages.length - 2; i >= 0 && i < messages.length; i--) {
      if (i >= 0 && messages[i].role == 'user') {
        lastUserMessage = messages[i];
        break;
      }
    }

    if (lastUserMessage == null) return;

    // Mark previous assistant as an archived variant so UI can hide it
    final notifier = ref.read(chatMessagesProvider.notifier);
    if (lastAssistantMessage != null) {
      notifier.updateLastMessageWithFunction((m) {
        final meta = Map<String, dynamic>.from(m.metadata ?? const {});
        meta['archivedVariant'] = true;
        // Keep content/files intact for server persistence
        return m.copyWith(metadata: meta, isStreaming: false);
      });
    }

    // If previous assistant was image-only or had images, regenerate images instead of text
    if (lastAssistantHadImages) {
      final prev = ref.read(imageGenerationEnabledProvider);
      try {
        // Force image generation enabled during regeneration
        ref.read(imageGenerationEnabledProvider.notifier).set(true);
        await regenerateMessage(
          ref,
          lastUserMessage.content,
          lastUserMessage.attachmentIds,
        );
      } finally {
        // restore previous state
        ref.read(imageGenerationEnabledProvider.notifier).set(prev);
      }
      return;
    }

    // Text regeneration without duplicating user message
    await regenerateMessage(
      ref,
      lastUserMessage.content,
      lastUserMessage.attachmentIds,
    );
  };
});

// Stop generation provider
final stopGenerationProvider = Provider<void Function()>((ref) {
  return () {
    try {
      final messages = ref.read(chatMessagesProvider);
      if (messages.isNotEmpty &&
          messages.last.role == 'assistant' &&
          messages.last.isStreaming) {
        final lastId = messages.last.id;

        // Cancel the network stream if active
        final api = ref.read(apiServiceProvider);
        api?.cancelStreamingMessage(lastId);

        // Cancel local stream subscription to stop propagating further chunks
        ref.read(chatMessagesProvider.notifier).cancelActiveMessageStream();
      }
    } catch (_) {}

    // Best-effort: stop any background tasks associated with this chat (parity with web)
    try {
      final api = ref.read(apiServiceProvider);
      final activeConv = ref.read(activeConversationProvider);
      if (api != null && activeConv != null && !isTemporaryConversation(activeConv.id)) {
        unawaited(() async {
          try {
            final ids = await api.getTaskIdsByChat(activeConv.id);
            for (final t in ids) {
              try {
                await api.stopTask(t);
              } catch (_) {}
            }
          } catch (_) {}
        }());

        // Also cancel local queue tasks for this conversation
        try {
          // Fire-and-forget local queue cancellation
          // ignore: unawaited_futures
          ref
              .read(taskQueueProvider.notifier)
              .cancelByConversation(activeConv.id);
        } catch (_) {}
      }
    } catch (_) {}

    // Ensure UI transitions out of streaming state
    ref.read(chatMessagesProvider.notifier).finishStreaming();
  };
});

// ========== Shared Streaming Utilities ==========

// ========== Tool Servers (OpenAPI) Helpers ==========

Future<List<Map<String, dynamic>>> _resolveToolServers(
  List rawServers,
  dynamic api,
) async {
  final List<Map<String, dynamic>> resolved = [];
  for (final s in rawServers) {
    try {
      if (s is! Map) continue;
      final cfg = s['config'];
      if (cfg is Map && cfg['enable'] != true) continue;

      final url = (s['url'] ?? '').toString();
      final path = (s['path'] ?? '').toString();
      if (url.isEmpty || path.isEmpty) continue;
      final fullUrl = path.contains('://')
          ? path
          : '$url${path.startsWith('/') ? '' : '/'}$path';

      // Fetch OpenAPI spec (supports YAML/JSON)
      Map<String, dynamic>? openapi;
      try {
        final resp = await api.dio.get(fullUrl);
        final ct = resp.headers.map['content-type']?.join(',') ?? '';
        if (fullUrl.toLowerCase().endsWith('.yaml') ||
            fullUrl.toLowerCase().endsWith('.yml') ||
            ct.contains('yaml')) {
          final doc = yaml.loadYaml(resp.data);
          openapi = json.decode(json.encode(doc)) as Map<String, dynamic>;
        } else {
          final data = resp.data;
          if (data is Map<String, dynamic>) {
            openapi = data;
          } else if (data is String) {
            openapi = json.decode(data) as Map<String, dynamic>;
          }
        }
      } catch (_) {
        continue;
      }
      if (openapi == null) continue;

      // Convert OpenAPI to tool specs
      final specs = _convertOpenApiToToolPayload(openapi);
      resolved.add({
        'url': url,
        'openapi': openapi,
        'info': openapi['info'],
        'specs': specs,
      });
    } catch (_) {
      continue;
    }
  }
  return resolved;
}

Map<String, dynamic>? _resolveRef(
  String ref,
  Map<String, dynamic>? components,
) {
  // e.g., #/components/schemas/MySchema
  if (!ref.startsWith('#/')) return null;
  final parts = ref.split('/');
  if (parts.length < 4) return null;
  final type = parts[2]; // schemas
  final name = parts[3];
  final section = components?[type];
  if (section is Map<String, dynamic>) {
    final schema = section[name];
    if (schema is Map<String, dynamic>) {
      return Map<String, dynamic>.from(schema);
    }
  }
  return null;
}

Map<String, dynamic> _resolveSchemaSimple(
  dynamic schema,
  Map<String, dynamic>? components,
) {
  if (schema is Map<String, dynamic>) {
    if (schema.containsKey(r'$ref')) {
      final ref = schema[r'$ref'] as String;
      final resolved = _resolveRef(ref, components);
      if (resolved != null) return _resolveSchemaSimple(resolved, components);
    }
    final type = schema['type'];
    final out = <String, dynamic>{};
    if (type is String) {
      out['type'] = type;
      if (schema['description'] != null) {
        out['description'] = schema['description'];
      }
      if (type == 'object') {
        out['properties'] = <String, dynamic>{};
        if (schema['required'] is List) {
          out['required'] = List.from(schema['required']);
        }
        final props = schema['properties'];
        if (props is Map<String, dynamic>) {
          props.forEach((k, v) {
            out['properties'][k] = _resolveSchemaSimple(v, components);
          });
        }
      } else if (type == 'array') {
        out['items'] = _resolveSchemaSimple(schema['items'], components);
      }
    }
    return out;
  }
  return <String, dynamic>{};
}

List<Map<String, dynamic>> _convertOpenApiToToolPayload(
  Map<String, dynamic> openApi,
) {
  final tools = <Map<String, dynamic>>[];
  final paths = openApi['paths'];
  if (paths is! Map) return tools;
  paths.forEach((path, methods) {
    if (methods is! Map) return;
    methods.forEach((method, operation) {
      if (operation is Map && operation['operationId'] != null) {
        final tool = <String, dynamic>{
          'name': operation['operationId'],
          'description':
              operation['description'] ??
              operation['summary'] ??
              'No description available.',
          'parameters': {
            'type': 'object',
            'properties': <String, dynamic>{},
            'required': <dynamic>[],
          },
        };
        // Parameters
        final params = operation['parameters'];
        if (params is List) {
          for (final p in params) {
            if (p is Map) {
              final name = p['name'];
              final schema = p['schema'] as Map?;
              if (name != null && schema != null) {
                String desc = (schema['description'] ?? p['description'] ?? '')
                    .toString();
                if (schema['enum'] is List) {
                  desc =
                      '$desc. Possible values: ${(schema['enum'] as List).join(', ')}';
                }
                tool['parameters']['properties'][name] = {
                  'type': schema['type'],
                  'description': desc,
                };
                if (p['required'] == true) {
                  (tool['parameters']['required'] as List).add(name);
                }
              }
            }
          }
        }
        // requestBody
        final reqBody = operation['requestBody'];
        if (reqBody is Map) {
          final content = reqBody['content'];
          if (content is Map && content['application/json'] is Map) {
            final schema = content['application/json']['schema'];
            final resolved = _resolveSchemaSimple(
              schema,
              openApi['components'] as Map<String, dynamic>?,
            );
            if (resolved['properties'] is Map) {
              tool['parameters']['properties'] = {
                ...tool['parameters']['properties'],
                ...resolved['properties'] as Map<String, dynamic>,
              };
              if (resolved['required'] is List) {
                final req = Set.from(tool['parameters']['required'] as List)
                  ..addAll(resolved['required'] as List);
                tool['parameters']['required'] = req.toList();
              }
            } else if (resolved['type'] == 'array') {
              tool['parameters'] = resolved;
            }
          }
        }
        tools.add(tool);
      }
    });
  });
  return tools;
}

/// Saves a temporary chat to the server, converting it to permanent.
/// Returns the new permanent conversation, or null on failure.
Future<Conversation?> saveTemporaryChat(
  dynamic ref,
  Conversation temporaryConversation,
) async {
  if (!temporaryConversation.id.startsWith('local:')) {
    return temporaryConversation; // Already permanent
  }

  final api = ref.read(apiServiceProvider);
  if (api == null) return null;

  try {
    final serverConversation = await api.createConversation(
      title: temporaryConversation.title,
      messages: temporaryConversation.messages,
      model: temporaryConversation.model,
      systemPrompt: temporaryConversation.systemPrompt,
    );

    final permanentConversation = temporaryConversation.copyWith(
      id: serverConversation.id,
    );

    ref.read(activeConversationProvider.notifier).set(permanentConversation);
    ref.read(conversationsProvider.notifier).upsertConversation(permanentConversation);

    // Disable temporary mode after saving
    ref.read(temporaryChatEnabledProvider.notifier).setEnabled(false);

    return permanentConversation;
  } catch (e) {
    DebugLogger.error('Failed to save temporary chat', scope: 'chat/providers', error: e);
    return null;
  }
}
