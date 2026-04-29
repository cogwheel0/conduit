import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:uuid/uuid.dart';
import 'package:yaml/yaml.dart' as yaml;

import '../../../core/auth/auth_state_manager.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/conversation.dart';
import '../../../core/models/file_info.dart';
import '../../../core/providers/app_providers.dart';

import '../../../core/services/settings_service.dart';
import '../../../core/services/socket_service.dart';
import '../../../core/services/streaming_response_controller.dart';
import '../../../core/services/worker_manager.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../core/utils/tool_calls_parser.dart';
import '../models/chat_context_attachment.dart';
import '../providers/context_attachments_provider.dart';
import '../../../core/persistence/conversation_store.dart';
import '../../../core/persistence/persistence_providers.dart';
import '../../../shared/services/outbox/message_outbox.dart';
import '../../../shared/services/tasks/task_queue.dart';
import '../../tools/providers/tools_providers.dart';
import '../services/chat_transport_dispatch.dart';
import '../services/reviewer_mode_service.dart';

part 'chat_providers.g.dart';

// Chat messages for current conversation
final chatMessagesProvider =
    NotifierProvider<ChatMessagesNotifier, List<ChatMessage>>(
      ChatMessagesNotifier.new,
    );

/// Whether chat is currently streaming a response.
/// Used by router to avoid showing connection issues during active streaming.
/// Uses select() to only rebuild when the streaming state actually changes,
/// not on every content update to the message list.
final isChatStreamingProvider = Provider<bool>((ref) {
  return ref.watch(
    chatMessagesProvider.select((messages) {
      if (messages.isEmpty) return false;
      final last = messages.last;
      return last.role == 'assistant' && last.isStreaming;
    }),
  );
});

/// The content of the currently streaming assistant message.
/// Only the actively streaming message widget should watch this.
/// This avoids rebuilding all visible messages on every chunk.
@Riverpod(keepAlive: true)
class StreamingContent extends _$StreamingContent {
  @override
  String? build() => null;

  // ignore: use_setters_to_change_properties
  void set(String? value) => state = value;
}

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
  /// Interval for syncing the streaming buffer into the message list state.
  /// Per-chunk updates go through [streamingContentProvider] instead.
  static const _streamingSyncInterval = Duration(milliseconds: 500);
  static const _passiveRefreshDebounce = Duration(milliseconds: 350);

  StreamingResponseController? _messageStream;
  ProviderSubscription? _conversationListener;
  final List<StreamSubscription> _subscriptions = [];
  final List<VoidCallback> _socketSubscriptions = [];
  VoidCallback? _socketTeardown;
  SocketEventSubscription? _passiveConversationSocketSubscription;
  DateTime? _lastStreamingActivity;
  StringBuffer? _streamingBuffer;
  Timer? _streamingSyncTimer;
  // Phase 3b — count buffer-sync ticks so we can persist the streaming
  // assistant message to SQLite roughly every [_streamingPersistEveryNTicks]
  // ticks instead of on every chunk. Reset wherever the buffer/timer reset.
  int _streamingSyncTickCount = 0;
  static const int _streamingPersistEveryNTicks = 4; // 4 × 500ms ≈ 2s
  Timer? _taskStatusTimer;
  Timer? _passiveConversationRefreshTimer;
  bool _taskStatusCheckInFlight = false;
  bool _observedRemoteTask = false;
  bool _passiveConversationRefreshInFlight = false;
  bool _queuedPassiveConversationRefresh = false;
  // Phase 4a — guard for refreshActiveConversationFromServer so back-to-back
  // taps on the app bar refresh button don't fire concurrent fetches.
  bool _manualRefreshInFlight = false;
  String? _passiveConversationId;
  String? _activeStreamingTransportMessageId;

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

        _configurePassiveConversationSync(next);

        // Only react when the conversation actually changes
        if (previous?.id == next?.id) {
          final serverMessages = next?.messages ?? const [];
          if (_shouldAdoptServerMessages(serverMessages)) {
            _adoptServerMessages(
              serverMessages,
              source: 'active conversation update',
            );
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

        _teardownPassiveConversationSync();
        _cancelMessageStream(clearStreamingContent: false);
        _stopRemoteTaskMonitor();
        _streamingSyncTimer?.cancel();
        _streamingSyncTimer = null;
        _streamingSyncTickCount = 0;

        _conversationListener?.close();
        _conversationListener = null;
      });
    }

    final activeConversation = ref.read(activeConversationProvider);
    _configurePassiveConversationSync(activeConversation);
    return activeConversation?.messages ?? const [];
  }

  bool _shouldAdoptServerMessages(List<ChatMessage> serverMessages) {
    if (serverMessages.isEmpty && state.isNotEmpty) {
      return false;
    }
    return !listEquals(serverMessages, state);
  }

  void _adoptServerMessages(
    List<ChatMessage> serverMessages, {
    required String source,
  }) {
    if (!_shouldAdoptServerMessages(serverMessages)) {
      return;
    }

    if (_shouldProtectLocalStreamingState) {
      DebugLogger.log(
        'Skipping server state adoption during active streaming '
        '(source: $source, message: ${state.lastOrNull?.id ?? "unknown"})',
        scope: 'chat/providers',
      );
      return;
    }

    final needsCleanup = _shouldCleanupStreamingFromServer(serverMessages);

    _streamingBuffer = null;
    _streamingSyncTimer?.cancel();
    _streamingSyncTimer = null;
    _streamingSyncTickCount = 0;
    _clearStreamingContent();
    if (_hasTrackedStreamingTransport) {
      _dropStreamingTransportState(source: 'server adoption from $source');
    }

    // Snapshot the pre-adopt state before swapping in the server's view —
    // we need it to rescue any in-memory streaming assistant placeholders
    // for rows the server doesn't know about yet (queued sends in flight).
    final priorState = List<ChatMessage>.unmodifiable(state);
    state = serverMessages;
    unawaited(
      _mergePendingOutboxIntoState(
        serverMessages,
        priorState: priorState,
        source: source,
      ),
    );

    if (needsCleanup) {
      _cancelMessageStream();
    }

    DebugLogger.log(
      'Adopted server conversation snapshot from $source '
      '(${serverMessages.length} messages)',
      scope: 'chat/providers',
    );
  }

  /// Re-add any outbox rows for the active conv that weren't in the server
  /// snapshot, plus the in-memory streaming assistant placeholders that
  /// are children of those rows. Without this, a passive sync that lands
  /// while a send is in flight wipes both the user bubble and the typing
  /// indicator from the screen.
  Future<void> _mergePendingOutboxIntoState(
    List<ChatMessage> serverMessages, {
    required List<ChatMessage> priorState,
    required String source,
  }) async {
    final activeId = ref.read(activeConversationProvider)?.id;
    if (activeId == null) return;
    final ConversationStore store;
    try {
      store = ref.read(conversationStoreProvider);
    } catch (_) {
      return;
    }

    final List<PendingMessage> pending;
    try {
      pending = await store.pendingMessages();
    } catch (_) {
      return;
    }
    if (!ref.mounted) return;

    final serverIds = {for (final m in serverMessages) m.id};
    final missing = <PendingMessage>[];
    for (final p in pending) {
      if (p.conversationId != activeId) continue;
      if (serverIds.contains(p.messageId)) continue;
      missing.add(p);
    }
    if (missing.isEmpty) return;

    final missingIds = {for (final p in missing) p.messageId};
    // Rescue any in-memory streaming assistant placeholders whose parent
    // is one of the pending user messages. These have no SQLite row yet
    // (they're created live by the streaming dispatcher) so the prior
    // in-memory state is the only place they exist.
    final rescuedAssistants = <ChatMessage>[];
    for (final m in priorState) {
      if (serverIds.contains(m.id)) continue;
      if (m.role != 'assistant') continue;
      final parentId = m.metadata?['parentId']?.toString();
      if (parentId == null || !missingIds.contains(parentId)) continue;
      rescuedAssistants.add(m);
    }

    final merged = <ChatMessage>[
      ...serverMessages,
      for (final p in missing) p.message,
      ...rescuedAssistants,
    ];

    if (!listEquals(merged, state)) {
      state = merged;
      DebugLogger.log(
        'Re-merged ${missing.length} outbox row(s) + '
        '${rescuedAssistants.length} streaming placeholder(s) '
        'after server adoption (source: $source)',
        scope: 'chat/providers',
      );
    }
  }

  void _configurePassiveConversationSync(Conversation? conversation) {
    final conversationId = conversation?.id;
    final socket = ref.read(socketServiceProvider);

    if (conversationId == null ||
        conversationId.isEmpty ||
        isTemporaryChat(conversationId) ||
        socket == null) {
      _teardownPassiveConversationSync();
      return;
    }

    if (_passiveConversationId == conversationId &&
        _passiveConversationSocketSubscription != null) {
      return;
    }

    _teardownPassiveConversationSync();
    _passiveConversationId = conversationId;
    _passiveConversationSocketSubscription = socket.addChatEventHandler(
      conversationId: conversationId,
      requireFocus: true,
      handler: (event, _) {
        if (!_shouldRefreshFromPassiveSocketEvent(
          event,
          localSessionId: socket.sessionId,
        )) {
          return;
        }

        _scheduleConversationRefreshFromServer(
          conversationId,
          source: _extractSocketEventType(event),
        );
      },
    );
  }

  void _teardownPassiveConversationSync() {
    _passiveConversationSocketSubscription?.dispose();
    _passiveConversationSocketSubscription = null;
    _passiveConversationRefreshTimer?.cancel();
    _passiveConversationRefreshTimer = null;
    _passiveConversationRefreshInFlight = false;
    _queuedPassiveConversationRefresh = false;
    _passiveConversationId = null;
  }

  bool _shouldRefreshFromPassiveSocketEvent(
    Map<String, dynamic> event, {
    String? localSessionId,
  }) {
    if (_shouldProtectLocalStreamingState) {
      return false;
    }

    final type = _extractSocketEventType(event);
    if (type.isEmpty) {
      return false;
    }

    const refreshingTypes = {
      'message',
      'replace',
      'chat:message',
      'chat:message:delta',
      'chat:message:error',
      'chat:message:files',
      'chat:message:embeds',
      'chat:message:follow_ups',
      'chat:completed',
      'chat:title',
      'chat:tags',
    };

    if (!refreshingTypes.contains(type)) {
      return false;
    }

    final incomingSessionId = _extractSocketEventSessionId(event);
    if (localSessionId != null &&
        incomingSessionId != null &&
        localSessionId == incomingSessionId) {
      return false;
    }

    return true;
  }

  String _extractSocketEventType(Map<String, dynamic> event) {
    String? candidate = event['type']?.toString();

    final data = event['data'];
    if (candidate == null && data is Map) {
      candidate = data['type']?.toString();

      final inner = data['data'];
      if (candidate == null && inner is Map) {
        candidate = inner['type']?.toString();
      }
    }

    return candidate ?? 'socket';
  }

  String? _extractSocketEventSessionId(Map<String, dynamic> event) {
    String? candidate = event['session_id']?.toString();

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

  void _scheduleConversationRefreshFromServer(
    String conversationId, {
    required String source,
  }) {
    _passiveConversationRefreshTimer?.cancel();
    _passiveConversationRefreshTimer = Timer(_passiveRefreshDebounce, () {
      if (_passiveConversationRefreshInFlight) {
        _queuedPassiveConversationRefresh = true;
        return;
      }

      unawaited(_refreshConversationFromServer(conversationId, source: source));
    });
  }

  /// Phase 4a — explicit refresh of the active conversation from the
  /// server. Used by the chat app bar refresh button, pull-to-refresh,
  /// and the foreground-resume observer to recover messages whose
  /// streaming completed server-side after the client disconnected.
  ///
  /// Differs from [_refreshConversationFromServer] in that it:
  ///   - bypasses the passive in-flight guard (this is explicit, not
  ///     socket-driven — duplicate taps just early-return below)
  ///   - drops stale transport state so the server snapshot can adopt
  ///     even if a stuck `isStreaming: true` placeholder is present
  ///   - persists the refreshed conversation to SQLite (Phase 3a cache)
  ///
  /// Safe to call when there is a live socket/stream — the
  /// [_shouldProtectLocalStreamingState] check below skips the refresh
  /// in that case so we don't truncate an in-flight response.
  Future<void> refreshActiveConversationFromServer({
    required String source,
  }) async {
    final activeConversation = ref.read(activeConversationProvider);
    if (activeConversation == null) return;
    if (isTemporaryChat(activeConversation.id)) return;

    if (_shouldProtectLocalStreamingState) {
      DebugLogger.log(
        'Skipping manual refresh while live transport is active '
        '(source: $source)',
        scope: 'chat/providers',
      );
      return;
    }

    if (_manualRefreshInFlight) return;
    _manualRefreshInFlight = true;

    try {
      final api = ref.read(apiServiceProvider);
      if (api == null) return;

      final conversationId = activeConversation.id;
      final refreshed = await api.getConversation(conversationId);
      if (!ref.mounted) return;

      final currentActive = ref.read(activeConversationProvider);
      if (currentActive == null || currentActive.id != conversationId) return;

      // A stuck `isStreaming: true` placeholder is still tracked as the
      // active transport message even though the stream is dead. Clear
      // that bookkeeping so [_adoptServerMessages] (triggered by the
      // setState below) can swap in the server's completed message
      // instead of guarding against it.
      _dropStreamingTransportState(source: 'manual refresh: $source');

      ref.read(activeConversationProvider.notifier).set(refreshed);

      try {
        ref
            .read(conversationsProvider.notifier)
            .upsertConversation(refreshed.copyWith(messages: const []));
      } catch (_) {}

      try {
        final storage = ref.read(optimizedStorageServiceProvider);
        unawaited(storage.cacheConversation(refreshed));
      } catch (_) {}

      DebugLogger.log(
        'Manually refreshed active conversation (source: $source, '
        'messages: ${refreshed.messages.length})',
        scope: 'chat/providers',
      );
    } catch (e) {
      DebugLogger.log(
        'Manual refresh failed (source: $source): $e',
        scope: 'chat/providers',
      );
    } finally {
      _manualRefreshInFlight = false;
    }
  }

  /// Phase 4a — true when the active conversation has a streaming
  /// assistant message but no live transport. A refresh would surface
  /// the server's completed version. Used by the foreground-resume
  /// observer to decide whether to fire a refresh on app resume.
  bool get hasStuckStreamingMessage {
    return _hasStreamingAssistant && !_shouldProtectLocalStreamingState;
  }

  Future<void> _refreshConversationFromServer(
    String conversationId, {
    required String source,
  }) async {
    if (_passiveConversationRefreshInFlight ||
        _shouldProtectLocalStreamingState) {
      return;
    }

    final api = ref.read(apiServiceProvider);
    final activeConversation = ref.read(activeConversationProvider);
    if (api == null ||
        activeConversation == null ||
        activeConversation.id != conversationId) {
      return;
    }

    _passiveConversationRefreshInFlight = true;
    try {
      final refreshed = await api.getConversation(conversationId);
      if (!ref.mounted) {
        return;
      }

      final currentActive = ref.read(activeConversationProvider);
      if (currentActive == null || currentActive.id != conversationId) {
        return;
      }

      ref.read(activeConversationProvider.notifier).set(refreshed);

      if (!isTemporaryChat(conversationId)) {
        try {
          ref
              .read(conversationsProvider.notifier)
              .upsertConversation(refreshed.copyWith(messages: const []));
        } catch (_) {}
      }

      DebugLogger.log(
        'Refreshed active conversation from server after $source',
        scope: 'chat/providers',
      );
    } catch (e) {
      DebugLogger.log(
        'Passive conversation refresh failed after $source: $e',
        scope: 'chat/providers',
      );
    } finally {
      _passiveConversationRefreshInFlight = false;
      if (_queuedPassiveConversationRefresh) {
        _queuedPassiveConversationRefresh = false;
        _scheduleConversationRefreshFromServer(
          conversationId,
          source: 'queued',
        );
      }
    }
  }

  /// Safely clears the streaming content provider, tolerating disposal
  /// races during conversation transitions.
  void _clearStreamingContent() {
    try {
      ref.read(streamingContentProvider.notifier).set(null);
    } on Object catch (_) {
      // Provider may be disposing or unavailable during conversation
      // transitions / notifier teardown.
    }
  }

  void _cancelMessageStream({bool clearStreamingContent = true}) {
    final controller = _messageStream;
    _messageStream = null;
    _activeStreamingTransportMessageId = null;
    if (controller != null && controller.isActive) {
      unawaited(controller.cancel());
    }
    cancelSocketSubscriptions();
    _streamingBuffer = null;
    _streamingSyncTimer?.cancel();
    _streamingSyncTimer = null;
    _streamingSyncTickCount = 0;
    if (clearStreamingContent) {
      _clearStreamingContent();
    }
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

  bool get _hasTrackedStreamingTransport {
    return _activeStreamingTransportMessageId != null ||
        _messageStream != null ||
        _socketSubscriptions.isNotEmpty ||
        _socketTeardown != null ||
        _taskStatusTimer != null ||
        _taskStatusCheckInFlight;
  }

  bool get _shouldProtectLocalStreamingState {
    if (!_hasStreamingAssistant || state.isEmpty) {
      return false;
    }

    final lastMessageId = state.last.id;
    if (_activeStreamingTransportMessageId != lastMessageId) {
      return false;
    }

    return _messageStream?.isActive == true ||
        _socketSubscriptions.isNotEmpty ||
        _socketTeardown != null ||
        _taskStatusTimer != null ||
        _taskStatusCheckInFlight;
  }

  void _dropStreamingTransportState({
    required String source,
    String? messageId,
  }) {
    if (!_hasTrackedStreamingTransport) {
      return;
    }

    final trackedMessageId = _activeStreamingTransportMessageId;
    if (messageId != null && trackedMessageId != messageId) {
      return;
    }

    DebugLogger.log(
      'Dropping stale transport state during $source '
      '(trackedMessage=${trackedMessageId ?? "unknown"})',
      scope: 'chat/providers',
    );

    _messageStream = null;
    _activeStreamingTransportMessageId = null;
    cancelSocketSubscriptions();
    _streamingBuffer = null;
    _streamingSyncTimer?.cancel();
    _streamingSyncTimer = null;
    _streamingSyncTickCount = 0;
    _clearStreamingContent();
    _stopRemoteTaskMonitor();
  }

  void retireObsoleteStreamingTransport(String messageId) {
    _dropStreamingTransportState(
      source: 'obsolete stream retirement',
      messageId: messageId,
    );
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
                final serverHasContent = serverVersion.content
                    .trim()
                    .isNotEmpty;

                // Since tasksDone already guarantees tasks genuinely completed,
                // server content should be the final version. Adopt if the
                // server has any content (replaces broken isStreaming check).
                if (serverHasContent) {
                  DebugLogger.log(
                    'Server sync: adopting server state '
                    '(serverHasContent=$serverHasContent, '
                    'serverLen=${serverVersion.content.length}, '
                    'localLen=${localLast.content.length})',
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

  void setMessageStream(
    String messageId,
    StreamingResponseController? controller,
  ) {
    _cancelMessageStream();
    _activeStreamingTransportMessageId = messageId;
    _messageStream = controller;
  }

  void setSocketSubscriptions(
    String messageId,
    List<VoidCallback> subscriptions, {
    VoidCallback? onDispose,
  }) {
    cancelSocketSubscriptions();
    _activeStreamingTransportMessageId = messageId;
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
        'Ignoring late chunk for finished message: '
        '${lastMessage.id}',
        scope: 'chat/providers',
      );
      return;
    }

    // Initialize buffer with existing content on first chunk
    _streamingBuffer ??= StringBuffer(lastMessage.content);
    _streamingBuffer!.write(content);

    // Update streaming content provider per-chunk so only the streaming
    // widget re-parses. Note: .toString() materializes the full string each
    // time (O(n) per chunk), but the StringBuffer avoids creating intermediate
    // concatenation objects that pressure GC. The alternative of exposing the
    // StringBuffer directly would leak mutable state into the widget layer.
    final accumulated = _streamingBuffer!.toString();
    ref.read(streamingContentProvider.notifier).set(accumulated);

    // Throttle message list state updates to every 500ms.
    // This prevents rebuilding ALL visible messages on
    // every chunk.
    _streamingSyncTimer ??= Timer.periodic(
      _streamingSyncInterval,
      (_) => _syncStreamingBufferToState(),
    );

    _touchStreamingActivity();
  }

  /// Syncs the accumulated streaming buffer content into
  /// the message list state.
  void _syncStreamingBufferToState() {
    if (_streamingBuffer == null || state.isEmpty) {
      // Streaming ended but timer still fired — cancel it.
      _streamingSyncTimer?.cancel();
      _streamingSyncTimer = null;
      _streamingSyncTickCount = 0;
      return;
    }
    final lastMessage = state.last;
    if (lastMessage.role != 'assistant' || !lastMessage.isStreaming) {
      _streamingSyncTimer?.cancel();
      _streamingSyncTimer = null;
      _streamingSyncTickCount = 0;
      return;
    }

    final accumulated = _streamingBuffer!.toString();
    if (accumulated == lastMessage.content) return;

    final updated = lastMessage.copyWith(content: accumulated);
    state = [...state.sublist(0, state.length - 1), updated];

    // Phase 3b — throttled SQLite write of the streaming assistant
    // message. Final write happens in [_completeStreamingMessage]; here
    // we just keep the on-disk view within ~2s of the in-memory one.
    _streamingSyncTickCount++;
    if (_streamingSyncTickCount % _streamingPersistEveryNTicks == 0) {
      _persistStreamingMessage(updated);
    }
  }

  /// Phase 3b — fire-and-forget SQLite write for the in-progress (or
  /// completed) assistant message. Gated by [_shouldPersistGranular] so
  /// reviewer mode and temporary chats are no-ops. Wrapped in try/catch
  /// because the synchronous provider reads can throw in test/restricted
  /// environments where Hive/storage isn't initialized — persistence
  /// failure must never break the streaming state machine.
  void _persistStreamingMessage(ChatMessage assistantMessage) {
    try {
      final activeConv = ref.read(activeConversationProvider);
      if (activeConv == null) return;
      if (!_shouldPersistGranular(ref, conversationId: activeConv.id)) return;
      final storage = ref.read(optimizedStorageServiceProvider);
      unawaited(
        storage.persistMessageEnsuringConversation(
          scaffold: activeConv.copyWith(messages: const []),
          message: assistantMessage,
        ),
      );
    } catch (_) {
      // Best-effort. The async error path inside the storage layer
      // already logs; this catches sync provider-construction failures.
    }
  }

  /// Flushes any pending streaming buffer content into the
  /// message list state.
  ///
  /// Called by the streaming helper before completion checks
  /// to ensure buffered delta content is visible in the
  /// Riverpod state.
  void syncStreamingBuffer() => _syncStreamingBufferToState();

  void replaceLastMessageContent(String content) {
    _streamingBuffer = null;
    _streamingSyncTimer?.cancel();
    _streamingSyncTimer = null;
    _streamingSyncTickCount = 0;
    _clearStreamingContent();
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

  ChatMessage _buildCompletedAssistantMessage(ChatMessage lastMessage) {
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

    return updatedLast;
  }

  void _syncConversationStateAfterStreamingUpdate() {
    final activeConversation = ref.read(activeConversationProvider);
    if (activeConversation != null) {
      final updatedActive = activeConversation.copyWith(
        messages: List<ChatMessage>.unmodifiable(state),
        updatedAt: DateTime.now(),
      );
      ref.read(activeConversationProvider.notifier).set(updatedActive);

      // Skip conversations list update for temporary chats
      if (!isTemporaryChat(activeConversation.id)) {
        try {
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
        } catch (_) {}
      }
    }

    // Skip server cache refresh for temporary chats
    if (!isTemporaryChat(ref.read(activeConversationProvider)?.id)) {
      try {
        refreshConversationsCache(ref);
      } catch (_) {}
    }
  }

  void _completeStreamingMessage({required bool releaseTransport}) {
    // Sync final buffer content to state before clearing
    _syncStreamingBufferToState();
    _streamingBuffer = null;
    _streamingSyncTimer?.cancel();
    _streamingSyncTimer = null;
    _streamingSyncTickCount = 0;
    _clearStreamingContent();

    if (state.isEmpty) {
      if (releaseTransport) {
        _messageStream = null;
        _activeStreamingTransportMessageId = null;
        cancelSocketSubscriptions();
        _stopRemoteTaskMonitor();
      }
      return;
    }

    final lastMessage = state.last;
    if (lastMessage.role != 'assistant' || !lastMessage.isStreaming) {
      if (releaseTransport) {
        _messageStream = null;
        _activeStreamingTransportMessageId = null;
        cancelSocketSubscriptions();
        _stopRemoteTaskMonitor();
      }
      return;
    }

    state = [
      ...state.sublist(0, state.length - 1),
      _buildCompletedAssistantMessage(lastMessage),
    ];

    if (releaseTransport) {
      _messageStream = null;
      _activeStreamingTransportMessageId = null;
      cancelSocketSubscriptions();
      _stopRemoteTaskMonitor();
    }

    // Phase 3b — final SQLite write of the now-complete assistant
    // message. Independent of the throttled tick counter so the row is
    // guaranteed to reflect `isStreaming: false` even if the last
    // periodic tick didn't fall on a persist boundary.
    _persistStreamingMessage(state.last);

    _syncConversationStateAfterStreamingUpdate();
  }

  void completeStreamingUi() {
    _completeStreamingMessage(releaseTransport: false);
  }

  void finishStreaming() {
    _completeStreamingMessage(releaseTransport: true);
  }
}

// Pre-seed an assistant skeleton message (with a given id or a new one) and
// return the id. Persisted chats rely on `/api/chat/completions` to update the
// server-side history; pushing the local buffer back first can truncate chats
// when the client has only partially loaded history.
Future<String> _preseedAssistantAndPersist(
  dynamic ref, {
  String? existingAssistantId,
  required String modelId,
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
        (ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier)
            .updateLastMessageWithFunction(
              (ChatMessage m) => m.copyWith(isStreaming: true),
            );
      }
    } catch (_) {}
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

Map<String, dynamic> _buildOpenWebUiBackgroundTasks({
  required Map<String, dynamic>? userSettings,
  required bool shouldGenerateTitle,
  bool webSearchEnabled = false,
  bool imageGenerationEnabled = false,
}) {
  bool? readBool(Map<String, dynamic>? map, String key) {
    final value = map?[key];
    return value is bool ? value : null;
  }

  bool? readTitleAuto(Map<String, dynamic>? map) {
    final title = map?['title'];
    if (title is Map && title['auto'] is bool) {
      return title['auto'] as bool;
    }
    return null;
  }

  final uiMap = switch (userSettings?['ui']) {
    final Map<String, dynamic> map => map,
    final Map map => map.map((key, value) => MapEntry(key.toString(), value)),
    _ => null,
  };

  final autoTitle = readTitleAuto(userSettings) ?? readTitleAuto(uiMap) ?? true;
  final autoTags =
      readBool(userSettings, 'autoTags') ?? readBool(uiMap, 'autoTags') ?? true;
  final autoFollowUps =
      readBool(userSettings, 'autoFollowUps') ??
      readBool(uiMap, 'autoFollowUps') ??
      true;

  return <String, dynamic>{
    // Default to the same enabled behavior as the web client, but still honor
    // explicit backend-synced user settings when they disable generation.
    if (shouldGenerateTitle && autoTitle) 'title_generation': true,
    if (shouldGenerateTitle && autoTags) 'tags_generation': true,
    if (autoFollowUps) 'follow_up_generation': true,
    if (webSearchEnabled) 'web_search': true,
    if (imageGenerationEnabled) 'image_generation': true,
  };
}

/// Exposes [_buildOpenWebUiBackgroundTasks] for focused unit tests.
@visibleForTesting
Map<String, dynamic> buildOpenWebUiBackgroundTasksForTest({
  required Map<String, dynamic>? userSettings,
  required bool shouldGenerateTitle,
  bool webSearchEnabled = false,
  bool imageGenerationEnabled = false,
}) {
  return _buildOpenWebUiBackgroundTasks(
    userSettings: userSettings,
    shouldGenerateTitle: shouldGenerateTitle,
    webSearchEnabled: webSearchEnabled,
    imageGenerationEnabled: imageGenerationEnabled,
  );
}

String _formatOpenWebUiDate(DateTime value) {
  final year = value.year.toString().padLeft(4, '0');
  final month = value.month.toString().padLeft(2, '0');
  final day = value.day.toString().padLeft(2, '0');
  return '$year-$month-$day';
}

String _formatOpenWebUiTime(DateTime value) {
  final hour = value.hour.toString().padLeft(2, '0');
  final minute = value.minute.toString().padLeft(2, '0');
  final second = value.second.toString().padLeft(2, '0');
  return '$hour:$minute:$second';
}

String _openWebUiWeekday(DateTime value) {
  const weekdays = <String>[
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  return weekdays[value.weekday - 1];
}

Map<String, dynamic> _buildOpenWebUiPromptVariables({
  required DateTime now,
  required String userName,
  required String userEmail,
  required String userLanguage,
  String? userLocation,
}) {
  final normalizedUserName = userName.trim().isNotEmpty
      ? userName.trim()
      : 'User';
  final normalizedUserEmail = userEmail.trim().isNotEmpty
      ? userEmail.trim()
      : 'Unknown';
  final normalizedUserLanguage = userLanguage.trim().isNotEmpty
      ? userLanguage.trim()
      : 'en-US';
  final normalizedUserLocation =
      userLocation != null && userLocation.trim().isNotEmpty
      ? userLocation.trim()
      : 'Unknown';
  final date = _formatOpenWebUiDate(now);
  final time = _formatOpenWebUiTime(now);

  return <String, dynamic>{
    '{{USER_NAME}}': normalizedUserName,
    '{{USER_EMAIL}}': normalizedUserEmail,
    '{{USER_LOCATION}}': normalizedUserLocation,
    '{{CURRENT_DATETIME}}': '$date $time',
    '{{CURRENT_DATE}}': date,
    '{{CURRENT_TIME}}': time,
    '{{CURRENT_WEEKDAY}}': _openWebUiWeekday(now),
    '{{CURRENT_TIMEZONE}}': now.timeZoneName,
    '{{USER_LANGUAGE}}': normalizedUserLanguage,
  };
}

String? _resolveOpenWebUiParentIdForNewUserMessage(List<ChatMessage> messages) {
  for (var index = messages.length - 1; index >= 0; index--) {
    final messageId = messages[index].id.trim();
    if (messageId.isNotEmpty) {
      return messageId;
    }
  }
  return null;
}

Map<String, dynamic>? _buildOpenWebUiUserMessage({
  required List<ChatMessage> messages,
  required String? userMessageId,
  required String modelId,
  String? assistantChildMessageId,
}) {
  if (userMessageId == null || userMessageId.isEmpty) {
    return null;
  }

  ChatMessage? userMessage;
  ChatMessage? previousMessage;
  for (var index = 0; index < messages.length; index++) {
    final message = messages[index];
    if (message.id == userMessageId) {
      userMessage = message;
      if (index > 0) {
        previousMessage = messages[index - 1];
      }
      break;
    }
  }
  if (userMessage == null) {
    return null;
  }

  final metadata = userMessage.metadata;
  final parentId = (() {
    final rawParentId = metadata?['parentId']?.toString().trim();
    if (rawParentId != null && rawParentId.isNotEmpty) {
      return rawParentId;
    }
    return previousMessage?.id;
  })();
  final rawChildren = metadata?['childrenIds'];
  final childrenIds = rawChildren is List
      ? rawChildren
            .map((child) => child?.toString() ?? '')
            .where((child) => child.isNotEmpty)
            .toList(growable: true)
      : <String>[];
  if (assistantChildMessageId != null &&
      assistantChildMessageId.isNotEmpty &&
      !childrenIds.contains(assistantChildMessageId)) {
    childrenIds.add(assistantChildMessageId);
  }

  final rawModels = metadata?['models'];
  final models = rawModels is List
      ? rawModels
            .map((model) => model?.toString() ?? '')
            .where((model) => model.isNotEmpty)
            .toList(growable: false)
      : <String>[];

  return <String, dynamic>{
    'id': userMessage.id,
    'parentId': parentId,
    'childrenIds': childrenIds,
    'role': userMessage.role,
    'content': userMessage.content,
    if (userMessage.role == 'user')
      'models': models.isNotEmpty ? models : <String>[modelId],
    'timestamp': userMessage.timestamp.millisecondsSinceEpoch ~/ 1000,
    if (userMessage.files != null && userMessage.files!.isNotEmpty)
      'files': userMessage.files,
    if (userMessage.attachmentIds != null &&
        userMessage.attachmentIds!.isNotEmpty)
      'attachment_ids': List<String>.from(userMessage.attachmentIds!),
  };
}

List<Map<String, dynamic>>? _extractTopLevelRequestFiles(
  Map<String, dynamic>? userMessage,
) {
  final rawFiles = userMessage?['files'];
  if (rawFiles is! List) {
    return null;
  }

  final files = rawFiles
      .whereType<Map>()
      .map((file) => file.map((key, value) => MapEntry(key.toString(), value)))
      .toList(growable: false);
  return files.isEmpty ? null : files;
}

bool _isDirectServerToolSelection(String id) {
  return id.startsWith('direct_server:');
}

List<String> _extractToolIdsForApi(Iterable<String> selectedToolIds) {
  return selectedToolIds
      .where((id) => !_isDirectServerToolSelection(id))
      .toList(growable: false);
}

List _extractConfiguredServerList(Map<String, dynamic>? settings, String key) {
  if (settings == null) {
    return const [];
  }

  final rootValue = settings[key];
  if (rootValue is List) {
    return rootValue;
  }

  final uiValue = settings['ui'];
  if (uiValue is Map && uiValue[key] is List) {
    return uiValue[key] as List;
  }

  return const [];
}

List _extractConfiguredToolServers(Map<String, dynamic>? settings) {
  return _extractConfiguredServerList(settings, 'toolServers');
}

List _extractConfiguredTerminalServers(Map<String, dynamic>? settings) {
  return _extractConfiguredServerList(settings, 'terminalServers');
}

bool _isConfiguredServerEnabled(dynamic server) {
  if (server is! Map) {
    return false;
  }

  final config = server['config'];
  if (config is Map && config.containsKey('enable')) {
    return config['enable'] == true;
  }

  final enabled = server['enabled'];
  if (enabled is bool) {
    return enabled;
  }

  return true;
}

List _filterSelectedConfiguredToolServers(
  List rawServers,
  Iterable<String> selectedToolIds,
) {
  final selectedServerIds = selectedToolIds
      .where(_isDirectServerToolSelection)
      .map((id) => id.substring('direct_server:'.length).trim())
      .where((id) => id.isNotEmpty)
      .toSet();
  if (selectedServerIds.isEmpty) {
    return const [];
  }

  final filtered = <dynamic>[];
  for (var index = 0; index < rawServers.length; index++) {
    final server = rawServers[index];
    if (server is! Map || !_isConfiguredServerEnabled(server)) {
      continue;
    }

    final serverId = server['id']?.toString().trim();
    final matchesSelection =
        selectedServerIds.contains(index.toString()) ||
        (serverId != null &&
            serverId.isNotEmpty &&
            selectedServerIds.contains(serverId));
    if (matchesSelection) {
      filtered.add(server);
    }
  }

  return filtered;
}

List _filterEnabledDirectTerminalServers(List rawServers) {
  final filtered = <dynamic>[];
  for (final server in rawServers) {
    if (server is! Map || !_isConfiguredServerEnabled(server)) {
      continue;
    }

    final serverId = server['id']?.toString().trim();
    final url = server['url']?.toString().trim() ?? '';
    if ((serverId == null || serverId.isEmpty) && url.isNotEmpty) {
      filtered.add(server);
    }
  }

  return filtered;
}

Future<List<Map<String, dynamic>>?> _resolveToolServersForRequest({
  required dynamic api,
  required Map<String, dynamic>? userSettings,
  required List<String> selectedToolIds,
}) async {
  final selectedRawToolServers = _filterSelectedConfiguredToolServers(
    _extractConfiguredToolServers(userSettings),
    selectedToolIds,
  );
  final directTerminalServers = _filterEnabledDirectTerminalServers(
    _extractConfiguredTerminalServers(userSettings),
  );

  if (selectedRawToolServers.isEmpty && directTerminalServers.isEmpty) {
    return null;
  }

  final resolved = <Map<String, dynamic>>[];
  if (selectedRawToolServers.isNotEmpty) {
    resolved.addAll(await _resolveToolServers(selectedRawToolServers, api));
  }
  if (directTerminalServers.isNotEmpty) {
    resolved.addAll(await _resolveToolServers(directTerminalServers, api));
  }

  return resolved.isEmpty ? null : resolved;
}

List<Map<String, dynamic>> _buildChatCompletionMessages({
  required List<Map<String, dynamic>> conversationMessages,
  required bool isTemporary,
}) {
  final requestMessages = isTemporary
      ? conversationMessages
      : conversationMessages.where((message) {
          return (message['role']?.toString().toLowerCase() ?? '') == 'system';
        });

  return requestMessages
      .map((message) => Map<String, dynamic>.from(message))
      .toList(growable: false);
}

bool _coerceBool(dynamic value, {required bool fallback}) {
  if (value is bool) {
    return value;
  }
  if (value is String) {
    final normalized = value.trim().toLowerCase();
    if (normalized == 'true' || normalized == '1') {
      return true;
    }
    if (normalized == 'false' || normalized == '0') {
      return false;
    }
  }
  if (value is num) {
    return value != 0;
  }
  return fallback;
}

bool modelSupportsTerminal(dynamic selectedModel) {
  final metadata = selectedModel?.metadata as Map<String, dynamic>?;
  final info = metadata?['info'] as Map<String, dynamic>?;
  final infoMeta = info?['meta'] as Map<String, dynamic>?;
  final capabilities = infoMeta?['capabilities'];
  if (capabilities is Map) {
    return _coerceBool(capabilities['terminal'], fallback: true);
  }
  return true;
}

String? _resolveTerminalIdForRequest({required String? selectedTerminalId}) {
  String? normalize(dynamic value) {
    final text = value?.toString().trim();
    if (text == null || text.isEmpty) {
      return null;
    }
    return text;
  }

  final explicitSelection = normalize(selectedTerminalId);
  if (explicitSelection != null) {
    return explicitSelection;
  }

  return null;
}

@visibleForTesting
List<String> extractToolIdsForApiForTest(List<String> selectedToolIds) {
  return _extractToolIdsForApi(selectedToolIds);
}

@visibleForTesting
List filterSelectedConfiguredToolServersForTest({
  required List rawServers,
  required List<String> selectedToolIds,
}) {
  return _filterSelectedConfiguredToolServers(rawServers, selectedToolIds);
}

@visibleForTesting
List<Map<String, dynamic>> buildChatCompletionMessagesForTest({
  required List<Map<String, dynamic>> conversationMessages,
  required bool isTemporary,
}) {
  return _buildChatCompletionMessages(
    conversationMessages: conversationMessages,
    isTemporary: isTemporary,
  );
}

@visibleForTesting
String? resolveTerminalIdForRequestForTest(String? selectedTerminalId) {
  return _resolveTerminalIdForRequest(selectedTerminalId: selectedTerminalId);
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
          'size': ?fileSize,
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
      case ChatContextAttachmentType.note:
        return <String, dynamic>{
          'type': 'note',
          'id': attachment.id,
          'name': attachment.displayName,
          'title': attachment.displayName,
        };
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
    final toolIdsForApi = _extractToolIdsForApi(selectedToolIds);
    final selectedTerminalId = ref.read(selectedTerminalIdProvider);
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
          if (msg.files != null && msg.files!.isNotEmpty) {
            final rawFiles = messageMap['files'];
            final existingFiles = rawFiles is List
                ? rawFiles.whereType<Map<String, dynamic>>().toList()
                : <Map<String, dynamic>>[];
            messageMap['files'] = <Map<String, dynamic>>[
              ...existingFiles,
              ...msg.files!,
            ];
          }
          if (msg.output != null && msg.output!.isNotEmpty) {
            messageMap['output'] = msg.output;
          }
          conversationMessages.add(messageMap);
        } else {
          conversationMessages.add({
            'role': msg.role,
            'content': cleaned,
            'files': ?msg.files,
            'output': ?msg.output,
          });
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
    final isTemporary =
        isTemporaryChat(activeConversation.id) ||
        ref.read(temporaryChatEnabledProvider);
    final requestMessages = _buildChatCompletionMessages(
      conversationMessages: conversationMessages,
      isTemporary: isTemporary,
    );

    // Pre-seed assistant skeleton and persist chain; always use a new id so
    // server history can branch like OpenWebUI.
    final String assistantMessageId = await _preseedAssistantAndPersist(
      ref,
      existingAssistantId: null,
      modelId: selectedModel.id,
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
          (ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier)
              .updateLastMessageWithFunction(
                (ChatMessage m) =>
                    m.copyWith(versions: [...m.versions, snapshot]),
              );
        }
      }
    } catch (_) {}

    // Feature toggles
    final webSearchEnabled =
        ref.read(webSearchEnabledProvider) &&
        ref.read(webSearchAvailableProvider);
    final imageGenerationEnabled = ref.read(imageGenerationEnabledProvider);

    final modelItem = _buildLocalModelItem(selectedModel);

    // Socket is optional — only needed for taskSocket transport.
    final socketService = ref.read(socketServiceProvider);
    final socketSessionId = socketService?.sessionId;

    List<Map<String, dynamic>>? toolServers;
    try {
      toolServers = await _resolveToolServersForRequest(
        api: api,
        userSettings: userSettingsData,
        selectedToolIds: selectedToolIds,
      );
    } catch (_) {}
    final terminalIdForApi = modelSupportsTerminal(selectedModel)
        ? _resolveTerminalIdForRequest(selectedTerminalId: selectedTerminalId)
        : null;

    // Background tasks should follow backend-synced user settings instead of
    // forcing local defaults.
    bool shouldGenerateTitle = false;
    if (!isTemporary) {
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
    }

    final bgTasks = _buildOpenWebUiBackgroundTasks(
      userSettings: userSettingsData,
      shouldGenerateTitle: shouldGenerateTitle,
      webSearchEnabled: webSearchEnabled,
      imageGenerationEnabled: imageGenerationEnabled,
    );

    final bool isBackgroundToolsFlowPre =
        toolIdsForApi.isNotEmpty ||
        terminalIdForApi != null ||
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

    // Build template variables (same as _sendMessageInternal)
    Map<String, dynamic>? promptVars2;
    Map<String, dynamic>? parentMsgMap;
    try {
      final now2 = DateTime.now();
      String userName = 'User';
      String userEmail = 'Unknown';
      String userLanguage = 'en-US';
      String? userLocation;

      try {
        final userData = ref.read(currentUserProvider);
        if (userData is AsyncData) {
          final user = userData.value;
          if (user != null) {
            userName = user.name?.trim().isNotEmpty == true
                ? user.name!.trim()
                : user.email;
            userEmail = user.email;
          }
        }
      } catch (_) {}

      try {
        final dynamic locale = ref.read(appLocaleProvider);
        if (locale != null) {
          userLanguage = locale.toLanguageTag()?.toString() ?? 'en-US';
        }
      } catch (_) {}

      try {
        final uiSettings = userSettingsData?['ui'];
        if (uiSettings is Map) {
          final rawLocation = uiSettings['userLocation'];
          if (rawLocation is String && rawLocation.trim().isNotEmpty) {
            userLocation = rawLocation.trim();
          }
        }
      } catch (_) {}

      promptVars2 = _buildOpenWebUiPromptVariables(
        now: now2,
        userName: userName,
        userEmail: userEmail,
        userLanguage: userLanguage,
        userLocation: userLocation,
      );
    } catch (_) {}

    try {
      parentMsgMap = _buildOpenWebUiUserMessage(
        messages: messages,
        userMessageId: lastUserMessageId,
        modelId: selectedModel.id,
        assistantChildMessageId: assistantMessageId,
      );
    } catch (_) {}

    // Start buffering socket events before sending to avoid timing races.
    // Include session/message aliases because some early taskSocket events are
    // emitted before the handler attaches and may not carry chat_id yet.
    final regenSocketService = ref.read(socketServiceProvider);
    regenSocketService?.startBuffering(
      activeConversation.id,
      sessionId: socketSessionId,
      messageId: assistantMessageId,
    );

    try {
      // Use transport-aware session dispatch
      final session = await api!.sendMessageSession(
        messages: requestMessages,
        model: selectedModel.id,
        conversationId: activeConversation.id,
        terminalId: terminalIdForApi,
        toolIds: toolIdsForApi.isNotEmpty ? toolIdsForApi : null,
        filterIds: selectedFilterIds.isNotEmpty ? selectedFilterIds : null,
        enableWebSearch: webSearchEnabled,
        enableImageGeneration: imageGenerationEnabled,
        modelItem: modelItem,
        sessionIdOverride: socketSessionId,
        toolServers: toolServers,
        backgroundTasks: bgTasks,
        responseMessageId: assistantMessageId,
        userSettings: userSettingsData,
        parentId: parentMsgMap?['parentId']?.toString(),
        userMessage: parentMsgMap,
        variables: promptVars2,
        files: _extractTopLevelRequestFiles(parentMsgMap),
      );

      // Check if model uses reasoning based on common naming patterns
      final modelLower = selectedModel.id.toLowerCase();
      final modelUsesReasoning =
          modelLower.contains('o1') ||
          modelLower.contains('o3') ||
          modelLower.contains('deepseek-r1') ||
          modelLower.contains('reasoning') ||
          modelLower.contains('think');

      final bool isBackgroundFlow =
          isBackgroundToolsFlowPre ||
          isBackgroundWebSearchPre ||
          imageGenerationEnabled ||
          bgTasks.isNotEmpty;

      await dispatchChatTransport(
        ref: ref,
        session: session,
        assistantMessageId: assistantMessageId,
        modelId: selectedModel.id,
        modelItem: modelItem,
        activeConversationId: activeConversation.id,
        api: api!,
        socketService: socketService,
        workerManager: ref.read(workerManagerProvider),
        webSearchEnabled: webSearchEnabled,
        imageGenerationEnabled: imageGenerationEnabled,
        isBackgroundFlow: isBackgroundFlow,
        modelUsesReasoning: modelUsesReasoning,
        toolsEnabled:
            toolIdsForApi.isNotEmpty ||
            terminalIdForApi != null ||
            (toolServers != null && toolServers.isNotEmpty) ||
            imageGenerationEnabled,
        isTemporary: isTemporary,
        filterIds: selectedFilterIds.isNotEmpty ? selectedFilterIds : null,
      );
    } finally {
      regenSocketService?.stopBuffering(
        activeConversation.id,
        sessionId: socketSessionId,
        messageId: assistantMessageId,
      );
    }
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
  bool isVoiceMode = false,
]) async {
  await _sendMessageInternal(ref, message, attachments, toolIds, isVoiceMode);
}

// Service-friendly wrapper (accepts generic Ref). [pendingMessageId] is the
// SQLite outbox row id when this send is driven by [MessageOutbox]; on retry
// the same id is passed back so the existing in-memory bubble is reused.
Future<void> sendMessageFromService(
  Ref ref,
  String message,
  List<String>? attachments, {
  List<String>? toolIds,
  bool isVoiceMode = false,
  String? pendingMessageId,
}) async {
  await _sendMessageInternal(
    ref,
    message,
    attachments,
    toolIds,
    isVoiceMode,
    pendingMessageId,
  );
}

Future<void> sendMessageWithContainer(
  ProviderContainer container,
  String message,
  List<String>? attachments, [
  List<String>? toolIds,
  bool isVoiceMode = false,
]) async {
  await _sendMessageInternal(
    container,
    message,
    attachments,
    toolIds,
    isVoiceMode,
  );
}

// Build the request-shape file map from a locally cached [FileInfo].
//
// Mirrors the shape produced by the network branch in [_sendMessageInternal]
// so cache hits and misses are interchangeable from the server's perspective.
Map<String, dynamic> _fileMapFromCachedInfo(FileInfo info) {
  final mimeType = info.mimeType;
  final isImage = mimeType.startsWith('image/');
  final collectionName = info.metadata?['collection_name'];
  return <String, dynamic>{
    'type': isImage ? 'image' : 'file',
    'id': info.id,
    'name': info.filename.isNotEmpty ? info.filename : 'file',
    'url': info.id,
    if (info.size > 0) 'size': info.size,
    'collection_name': ?collectionName,
    if (mimeType.isNotEmpty) 'content_type': mimeType,
  };
}

// Internal send message implementation
//
// [pendingMessageId] is the SQLite messages.id of the user message that is
// already in the outbox (status='sending') when this send is driven by the
// chat input or by [MessageOutbox] on retry. When non-null, the in-memory
// user/assistant bubbles are reused (instead of creating fresh ids) so a
// retry doesn't duplicate the bubble. On success/failure the corresponding
// SQLite row's outbox state is advanced (markSent / scheduleRetry /
// markPermanentFailed).
Future<void> _sendMessageInternal(
  dynamic ref,
  String message,
  List<String>? attachments, [
  List<String>? toolIds,
  bool isVoiceMode = false,
  String? pendingMessageId,
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

  final existingMessages = ref.read(chatMessagesProvider);
  final openWebUiParentId = _resolveOpenWebUiParentIdForNewUserMessage(
    existingMessages,
  );

  // Retry / reuse: when [pendingMessageId] is non-null, the chat input (or
  // outbox) has already created the SQLite outbox row for this send. If a
  // user message with that id is also still in the in-memory chat state
  // (e.g. user is on the same conversation), reuse the existing ids so the
  // bubble isn't duplicated. The matching assistant placeholder is reset
  // to a fresh streaming state.
  String? existingUserMessageId;
  String? existingAssistantMessageId;
  if (pendingMessageId != null) {
    for (final m in existingMessages) {
      if (m.role == 'user' && m.id == pendingMessageId) {
        existingUserMessageId = m.id;
        final children = m.metadata?['childrenIds'];
        if (children is List && children.isNotEmpty) {
          final raw = children.first;
          if (raw is String && raw.isNotEmpty) {
            existingAssistantMessageId = raw;
          }
        }
        break;
      }
    }
  }

  final userMessageId =
      existingUserMessageId ?? pendingMessageId ?? const Uuid().v4();
  final String assistantMessageId =
      existingAssistantMessageId ?? const Uuid().v4();
  var userMessage = ChatMessage(
    id: userMessageId,
    role: 'user',
    content: message,
    timestamp: DateTime.now(),
    model: selectedModel.id,
    attachmentIds: attachments,
    files: initialUserFiles,
    metadata: {
      'parentId': openWebUiParentId,
      'childrenIds': <String>[assistantMessageId],
      'models': <String>[selectedModel.id],
      if (toolIds != null && toolIds.isNotEmpty)
        'toolIds': List<String>.from(toolIds),
    },
  );

  // Add (or replace) user message in the UI for instant feedback.
  if (existingUserMessageId != null) {
    ref
        .read(chatMessagesProvider.notifier)
        .updateMessageById(userMessageId, (_) => userMessage);
  } else {
    ref.read(chatMessagesProvider.notifier).addMessage(userMessage);
  }

  // Persist the user message to SQLite as an outbox row immediately, before
  // any await. SQLite is now the single source of truth for outbound state
  // — a force-quit between here and the first network call leaves the row
  // visible (status='sending'); the outbox resumes on next launch.
  //
  // For brand-new conversations the local row doesn't exist yet (no conv
  // id), so we skip the outbox write and rely on the in-memory bubble
  // until createConversation resolves below.
  try {
    final activeForEarlyPersist = ref.read(activeConversationProvider);
    if (activeForEarlyPersist != null &&
        _shouldPersistGranular(
          ref,
          conversationId: activeForEarlyPersist.id,
        )) {
      final store = ref.read(conversationStoreProvider);
      unawaited(
        store.insertMessageAsSending(
          conversationId: activeForEarlyPersist.id,
          message: userMessage,
        ),
      );
    }
  } catch (_) {}

  // Add (or reset) assistant placeholder so the typing indicator shows
  // right away. On retry, the previous placeholder might be in error or
  // partially-streamed state — overwrite it cleanly.
  final assistantPlaceholder = ChatMessage(
    id: assistantMessageId,
    role: 'assistant',
    content: '',
    timestamp: DateTime.now(),
    model: selectedModel.id,
    isStreaming: true,
    metadata: {'parentId': userMessageId, 'childrenIds': const <String>[]},
  );
  if (existingAssistantMessageId != null) {
    ref
        .read(chatMessagesProvider.notifier)
        .updateMessageById(assistantMessageId, (_) => assistantPlaceholder);
  } else {
    ref.read(chatMessagesProvider.notifier).addMessage(assistantPlaceholder);
  }

  // Now do async work in parallel: user settings + server file info
  String? userSystemPrompt;
  Map<String, dynamic>? userSettingsData;
  final serverFiles = <Map<String, dynamic>>[];

  // Phase 2.2: hoisted createConversation future. Kicked in parallel with
  // file-info resolution once we know the system prompt, then awaited at the
  // bottom of the new-chat branch. Lets the network call for the new server
  // conversation overlap with attachment metadata fetches instead of running
  // strictly afterwards.
  Future<Conversation>? pendingCreateConversation;
  Conversation? createConversationLocal;
  String? createConversationFolderId;
  if (!reviewerMode && api != null) {
    // Local-first: prefer the cached system prompt synchronously so we
    // don't gate the send on a settings round-trip. Refresh in the
    // background; the next send will pick up any change. The very first
    // send after a fresh install still pays the round-trip — the cache is
    // warmed on success below.
    final storage = ref.read(optimizedStorageServiceProvider);
    userSystemPrompt = storage.getCachedUserSystemPrompt();
    final settingsFuture = userSystemPrompt == null
        // Cold cache: we have to await so the system prompt is included.
        ? api.getUserSettings().catchError((_) => null)
        // Warm cache: kick a background refresh and don't block on it.
        : (api.getUserSettings()
                  .then((data) {
                    final fresh = _extractSystemPromptFromSettings(data);
                    unawaited(storage.setCachedUserSystemPrompt(fresh));
                    return data;
                  })
                  .catchError((_) => null)
              as Future<Map<String, dynamic>?>);
    final fileInfoFutures = serverFileIds.map((fileId) async {
      // Cache hit: build the request shape entirely from local data.
      try {
        final cached = await storage.getCachedFileInfo(fileId);
        if (cached != null) {
          return _fileMapFromCachedInfo(cached);
        }
      } catch (_) {}
      // Cache miss: fall back to the existing network fetch.
      try {
        final fileInfo = await api.getFileInfo(fileId);
        final fileName = fileInfo['filename'] ?? fileInfo['name'] ?? 'file';
        final fileSize = fileInfo['size'] ?? fileInfo['meta']?['size'];
        final contentType =
            fileInfo['meta']?['content_type'] ?? fileInfo['content_type'] ?? '';
        final collectionName =
            fileInfo['meta']?['collection_name'] ?? fileInfo['collection_name'];

        // Warm the cache for next time. Best-effort — wrapped in try/catch
        // inside FileInfo.fromJson so a malformed response just skips caching.
        try {
          final parsed = FileInfo.fromJson(Map<String, dynamic>.from(fileInfo));
          unawaited(storage.cacheFileInfo(parsed));
        } catch (_) {}

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
          'size': ?fileSize,
          'collection_name': ?collectionName,
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

    // Phase 2.2: resolve settings first so we know userSystemPrompt early,
    // then kick the createConversation network call concurrently with the
    // remaining file-info futures. This overlaps two previously-serial
    // network round-trips for new-chat sends with attachments.
    //
    // When the warm-cache path is taken above, settingsFuture is fire-
    // and-forget — we already have the system prompt synchronously.
    if (userSystemPrompt == null) {
      userSettingsData = await settingsFuture;
      if (userSettingsData != null) {
        userSystemPrompt = _extractSystemPromptFromSettings(userSettingsData);
        // Warm the cache for future sends.
        unawaited(storage.setCachedUserSystemPrompt(userSystemPrompt));
      }
    }

    final activeForCreate = ref.read(activeConversationProvider);
    if (activeForCreate == null) {
      final pendingFolderId = ref.read(pendingFolderIdProvider);
      final isTemporary = ref.read(temporaryChatEnabledProvider);
      if (!isTemporary) {
        // Build the local placeholder now and set it as active so the chat
        // UI keeps rendering the user message while the server call is in
        // flight. Streaming send is gated below until createConversation
        // resolves to obtain the server-assigned conversation id.
        createConversationFolderId = pendingFolderId;
        createConversationLocal = Conversation(
          id: const Uuid().v4(),
          title: 'New Chat',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          systemPrompt: userSystemPrompt,
          messages: [userMessage, assistantPlaceholder],
          folderId: pendingFolderId,
        );
        ref
            .read(activeConversationProvider.notifier)
            .set(createConversationLocal);
        final lightweightForCreate = userMessage.copyWith(
          attachmentIds: null,
          files: null,
        );
        pendingCreateConversation = api.createConversation(
          title: 'New Chat',
          messages: [lightweightForCreate],
          model: selectedModel.id,
          systemPrompt: userSystemPrompt,
          folderId: pendingFolderId,
        );
      }
    }

    final fileInfoResults = await Future.wait(fileInfoFutures);
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

  // Phase 2.2: if we kicked createConversation in parallel with the file
  // info resolution above, await it now and apply the server-assigned id +
  // folder. The local placeholder is already set as active, so the chat UI
  // has been rendering the user message throughout this delay.
  if (pendingCreateConversation != null && createConversationLocal != null) {
    final localPlaceholder = createConversationLocal;
    final pendingFolderId = createConversationFolderId;
    try {
      final serverConversation = await pendingCreateConversation;

      ref.read(pendingFolderIdProvider.notifier).clear();

      final currentMessages = ref.read(chatMessagesProvider);
      final updatedConversation = localPlaceholder.copyWith(
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

      // Phase 3b — now that the server has returned a real conversation
      // id, persist the full conversation (header + user message +
      // assistant placeholder) to SQLite in a single upsert. This is the
      // canonical "first write" for a new chat. Subsequent streaming
      // chunks piggyback on _persistStreamingMessage under the same id.
      try {
        if (_shouldPersistGranular(
          ref,
          conversationId: updatedConversation.id,
        )) {
          final storage = ref.read(optimizedStorageServiceProvider);
          unawaited(storage.cacheConversation(updatedConversation));
        }
      } catch (_) {}

      Future.delayed(const Duration(milliseconds: 100), () {
        try {
          final isMounted = ref is Ref ? ref.mounted : true;
          if (isMounted) {
            refreshConversationsCache(
              ref,
              includeFolders: pendingFolderId != null,
            );
          }
        } catch (_) {}
      });
    } catch (e) {
      ref.read(pendingFolderIdProvider.notifier).clear();
    }
  } else if (activeConversation == null) {
    // No createConversation was kicked: either temporary chat or reviewer
    // mode. Build the appropriate local placeholder.
    final pendingFolderId = ref.read(pendingFolderIdProvider);
    final isTemporary = ref.read(temporaryChatEnabledProvider);

    if (isTemporary) {
      final socketId = ref.read(socketServiceProvider)?.sessionId ?? 'unknown';
      final localConversation = Conversation(
        id: 'local:${socketId}_${const Uuid().v4()}',
        title: 'New Chat',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        systemPrompt: userSystemPrompt,
        messages: [userMessage, assistantPlaceholder],
      );

      ref.read(activeConversationProvider.notifier).set(localConversation);
      activeConversation = localConversation;
      ref.read(pendingFolderIdProvider.notifier).clear();
    } else {
      // Reviewer mode new chat: build local placeholder, no server call.
      final localConversation = Conversation(
        id: const Uuid().v4(),
        title: 'New Chat',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        systemPrompt: userSystemPrompt,
        messages: [userMessage, assistantPlaceholder],
        folderId: pendingFolderId,
      );

      ref.read(activeConversationProvider.notifier).set(localConversation);
      activeConversation = localConversation;
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

  // Phase 3b — persist the user message to SQLite as soon as we have a
  // real (non-temp, non-pending) conversation id. unawaited so the
  // disk write never blocks the network send below; failures log and
  // are swallowed by the storage layer. The new-chat full upsert above
  // already covers that branch — this catches existing chats where the
  // user message addMessage at line ~2620 was a no-op.
  try {
    if (activeConversation != null &&
        _shouldPersistGranular(ref, conversationId: activeConversation.id)) {
      final storage = ref.read(optimizedStorageServiceProvider);
      unawaited(
        storage.persistMessageEnsuringConversation(
          scaffold: activeConversation.copyWith(messages: const []),
          message: userMessage,
        ),
      );
    }
  } catch (_) {}

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
        if (msg.output != null && msg.output!.isNotEmpty) {
          messageMap['output'] = msg.output;
        }
        conversationMessages.add(messageMap);
      } else {
        // Regular text-only message
        final Map<String, dynamic> messageMap = {
          'role': msg.role,
          'content': cleaned,
          'output': ?msg.output,
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
  final selectedToolIds = toolIds ?? const <String>[];
  final toolIdsForApi = _extractToolIdsForApi(selectedToolIds);
  final selectedTerminalId = ref.read(selectedTerminalIdProvider);
  final isTemporary =
      (activeConversation != null && isTemporaryChat(activeConversation.id)) ||
      ref.read(temporaryChatEnabledProvider);
  final requestMessages = _buildChatCompletionMessages(
    conversationMessages: conversationMessages,
    isTemporary: isTemporary,
  );

  // Check feature toggles for API (gated by server availability)
  final webSearchEnabled =
      ref.read(webSearchEnabledProvider) &&
      ref.read(webSearchAvailableProvider);
  final imageGenerationEnabled = ref.read(imageGenerationEnabledProvider);

  // Get selected toggle filter IDs
  final selectedFilterIds = ref.read(selectedFilterIdsProvider);
  final List<String>? filterIdsForApi = selectedFilterIds.isNotEmpty
      ? selectedFilterIds
      : null;

  String? chatIdForBuffer;
  String? sessionIdForBuffer;
  String? messageIdForBuffer;
  try {
    final modelItem = _buildLocalModelItem(selectedModel);

    // Socket is optional — only needed for taskSocket transport.
    final socketService = ref.read(socketServiceProvider);
    final socketSessionId = socketService?.sessionId;

    List<Map<String, dynamic>>? toolServers;
    try {
      toolServers = await _resolveToolServersForRequest(
        api: api,
        userSettings: userSettingsData,
        selectedToolIds: selectedToolIds,
      );
    } catch (_) {}
    final terminalIdForApi = modelSupportsTerminal(selectedModel)
        ? _resolveTerminalIdForRequest(selectedTerminalId: selectedTerminalId)
        : null;

    // Background tasks should follow backend-synced user settings instead of
    // forcing local defaults. Enable title/tags generation only on the first
    // user turn of a new chat.
    bool shouldGenerateTitle = false;
    if (!isTemporary) {
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
    }

    final bgTasks = _buildOpenWebUiBackgroundTasks(
      userSettings: userSettingsData,
      shouldGenerateTitle: shouldGenerateTitle,
    );

    // Determine if we need background task flow (tools/tool servers or web search)
    final bool isBackgroundToolsFlowPre =
        toolIdsForApi.isNotEmpty ||
        terminalIdForApi != null ||
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

    // Use transport-aware session dispatch
    // Build template variables for prompt substitution (matches OpenWebUI's
    // getPromptVariables). The backend replaces {{USER_NAME}} etc. in system
    // prompts and tool descriptions.
    Map<String, dynamic>? promptVariables;
    Map<String, dynamic>? userMessageMap;
    try {
      final now = DateTime.now();
      String userName = 'User';
      String userEmail = 'Unknown';
      String userLanguage = 'en-US';
      String? userLocation;
      try {
        final userData = ref.read(currentUserProvider);
        if (userData is AsyncData) {
          final user = userData.value;
          if (user != null) {
            userName = user.name?.trim().isNotEmpty == true
                ? user.name!.trim()
                : user.email;
            userEmail = user.email;
          }
        }
      } catch (_) {}
      try {
        final dynamic locale = ref.read(appLocaleProvider);
        if (locale != null) {
          userLanguage = locale.toLanguageTag()?.toString() ?? 'en-US';
        }
      } catch (_) {}
      try {
        final uiSettings = userSettingsData?['ui'];
        if (uiSettings is Map) {
          final rawLocation = uiSettings['userLocation'];
          if (rawLocation is String && rawLocation.trim().isNotEmpty) {
            userLocation = rawLocation.trim();
          }
        }
      } catch (_) {}

      promptVariables = _buildOpenWebUiPromptVariables(
        now: now,
        userName: userName,
        userEmail: userEmail,
        userLanguage: userLanguage,
        userLocation: userLocation,
      );
    } catch (e) {
      DebugLogger.error(
        'Failed to build prompt variables: $e',
        scope: 'chat/providers',
        error: e,
      );
    }

    try {
      userMessageMap = _buildOpenWebUiUserMessage(
        messages: messages,
        userMessageId: lastUserMessageId,
        modelId: selectedModel.id,
        assistantChildMessageId: assistantMessageId,
      );
    } catch (_) {}

    // Start buffering socket events for this chat BEFORE sending the HTTP
    // request. The backend may emit events (especially for fast pipe models)
    // before dispatchChatTransport registers the streaming handler.
    chatIdForBuffer = activeConversation?.id;
    sessionIdForBuffer = socketSessionId;
    messageIdForBuffer = assistantMessageId;
    if (chatIdForBuffer != null) {
      socketService?.startBuffering(
        chatIdForBuffer,
        sessionId: sessionIdForBuffer,
        messageId: messageIdForBuffer,
      );
    }

    try {
      final session = await api.sendMessageSession(
        messages: requestMessages,
        model: selectedModel.id,
        conversationId: activeConversation?.id,
        terminalId: terminalIdForApi,
        toolIds: toolIdsForApi.isNotEmpty ? toolIdsForApi : null,
        filterIds: filterIdsForApi,
        enableWebSearch: webSearchEnabled,
        enableImageGeneration: imageGenerationEnabled,
        isVoiceMode: isVoiceMode,
        modelItem: modelItem,
        sessionIdOverride: socketSessionId,
        toolServers: toolServers,
        backgroundTasks: bgTasks,
        responseMessageId: assistantMessageId,
        userSettings: userSettingsData,
        parentId: userMessageMap?['parentId']?.toString(),
        userMessage: userMessageMap,
        variables: promptVariables,
        files: _extractTopLevelRequestFiles(userMessageMap),
      );

      // Check if model uses reasoning based on common naming patterns
      final modelLower2 = selectedModel.id.toLowerCase();
      final modelUsesReasoning2 =
          modelLower2.contains('o1') ||
          modelLower2.contains('o3') ||
          modelLower2.contains('deepseek-r1') ||
          modelLower2.contains('reasoning') ||
          modelLower2.contains('think');

      final bool isBackgroundFlow =
          isBackgroundToolsFlowPre ||
          isBackgroundWebSearchPre ||
          imageGenerationEnabled ||
          bgTasks.isNotEmpty;

      await dispatchChatTransport(
        ref: ref,
        session: session,
        assistantMessageId: assistantMessageId,
        modelId: selectedModel.id,
        modelItem: modelItem,
        activeConversationId: activeConversation?.id,
        api: api,
        socketService: socketService,
        workerManager: ref.read(workerManagerProvider),
        webSearchEnabled: webSearchEnabled,
        imageGenerationEnabled: imageGenerationEnabled,
        isBackgroundFlow: isBackgroundFlow,
        modelUsesReasoning: modelUsesReasoning2,
        toolsEnabled:
            toolIdsForApi.isNotEmpty ||
            terminalIdForApi != null ||
            (toolServers != null && toolServers.isNotEmpty) ||
            imageGenerationEnabled,
        isTemporary: isTemporary,
        filterIds: filterIdsForApi,
      );
    } finally {
      if (chatIdForBuffer != null) {
        socketService?.stopBuffering(
          chatIdForBuffer,
          sessionId: sessionIdForBuffer,
          messageId: messageIdForBuffer,
        );
      }
    }

    // Clear context attachments after successfully initiating the message send.
    // This prevents stale attachments from being included in subsequent messages.
    try {
      ref.read(contextAttachmentsProvider.notifier).clear();
    } catch (_) {}

    // Dispatch returned without throwing → the server has accepted the
    // message. Flip the SQLite outbox row to 'sent' so the next sync is
    // free to overwrite it with the server's authoritative version, and
    // so the per-message badge clears. We don't touch the row on any
    // error branch — that's owned by scheduleRetry / markPermanentFailed.
    try {
      final store = ref.read(conversationStoreProvider);
      unawaited(store.markSent(userMessageId));
    } catch (_) {}

    return;
  } catch (e, st) {
    DebugLogger.error(
      '_sendMessageInternal failed: $e',
      scope: 'chat/providers',
      error: e,
      stackTrace: st,
    );

    final ChatMessagesNotifier notifier =
        ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier;
    final classification = _classifySendException(e);
    final store = ref.read(conversationStoreProvider);

    if (classification.kind == _SendExceptionKind.auth) {
      // 401/403 — token rejected. Drop the placeholder cleanly and let the
      // auth manager handle re-auth UI. No error text is written into the
      // chat; the auth flow takes over. Mark the outbox row as permanent
      // so it stops retrying — the user will see "Tap to retry" once auth
      // is restored and they explicitly retry.
      notifier.updateLastMessageWithFunction(
        (ChatMessage m) =>
            m.copyWith(content: '', isStreaming: false, error: null),
      );
      notifier.finishStreaming();
      ref.invalidate(authStateManagerProvider);
      unawaited(
        store.markPermanentFailed(
          messageId: userMessageId,
          error: 'auth: ${e.toString()}',
        ),
      );
      return;
    }

    if (classification.kind == _SendExceptionKind.permanent) {
      // 4xx client error — retrying won't help. Surface the specific message
      // on the assistant placeholder so the user understands what failed,
      // and stop the outbox.
      final chatError = ChatMessageError(content: classification.message!);
      notifier.updateLastMessageWithFunction(
        (ChatMessage m) => m.copyWith(error: chatError),
      );
      notifier.finishStreaming();
      unawaited(
        store.markPermanentFailed(
          messageId: userMessageId,
          error: e.toString(),
        ),
      );
      return;
    }

    // Transient: server hiccup, network blip, timeout. Stop the typing
    // indicator but do NOT splash an error string across the assistant
    // placeholder — the bubble badge will show "Queued / Tap to retry"
    // sourced from the row's send_status. Schedule the retry on the row
    // and let the outbox pick it up.
    notifier.updateLastMessageWithFunction(
      (ChatMessage m) =>
          m.copyWith(content: '', isStreaming: false, error: null),
    );
    notifier.finishStreaming();

    final attempt = await _readAttempt(store, userMessageId);
    final nextAttempt = attempt + 1;
    if (nextAttempt >= _maxAttempts) {
      unawaited(
        store.scheduleRetry(
          messageId: userMessageId,
          attempt: nextAttempt,
          // Retry budget exhausted: keep status='failed' but push the next
          // attempt far out. The reconnect path clears this so the user
          // gets one more shot when the network comes back.
          nextAt: DateTime.now().add(const Duration(hours: 24)),
          error: e.toString(),
        ),
      );
    } else {
      final delay = ref.read(messageOutboxProvider.notifier).backoffFor(
        nextAttempt,
      );
      unawaited(
        store.scheduleRetry(
          messageId: userMessageId,
          attempt: nextAttempt,
          nextAt: DateTime.now().add(delay),
          error: e.toString(),
        ),
      );
    }
  }
}

const int _maxAttempts = 8;

Future<int> _readAttempt(ConversationStore store, String messageId) async {
  // Lightweight: avoids decoding a payload just to read the attempt count.
  final pending = await store.pendingMessages();
  for (final p in pending) {
    if (p.messageId == messageId) return p.attempt;
  }
  return 0;
}

enum _SendExceptionKind { auth, permanent, transient }

class _SendExceptionClassification {
  const _SendExceptionClassification(this.kind, [this.message]);
  final _SendExceptionKind kind;
  final String? message;
}

/// Buckets a send-path exception into auth / permanent / transient. Only
/// permanent failures get a user-visible error string written into the
/// assistant bubble — transient ones (network, timeout, 5xx) are handled
/// silently by the TaskQueue retry path.
_SendExceptionClassification _classifySendException(Object e) {
  final msg = e.toString();
  if (msg.contains('401') || msg.contains('403')) {
    return const _SendExceptionClassification(_SendExceptionKind.auth);
  }
  if (msg.contains('400')) {
    return const _SendExceptionClassification(
      _SendExceptionKind.permanent,
      'There was an issue with the message format. This might be '
          'because an attachment couldn\'t be processed, the request format '
          'is incompatible with the selected model, or the message contains '
          'unsupported content. Try again, or try without attachments.',
    );
  }
  if (msg.contains('404')) {
    DebugLogger.log(
      'Model or endpoint not found (404)',
      scope: 'chat/providers',
    );
    return const _SendExceptionClassification(
      _SendExceptionKind.permanent,
      'The selected AI model doesn\'t seem to be available. '
          'Try a different model or check with your administrator.',
    );
  }
  // Everything else (5xx, network, timeout, socket, parse errors) is
  // treated as transient so the queue retries with backoff.
  return const _SendExceptionClassification(_SendExceptionKind.transient);
}

// Save current conversation to OpenWebUI server
// Removed server persistence; only local caching is used in mobile app.

/// Phase 3b — gates granular SQLite writes from the chat send/streaming
/// path. Returns false in cases where there is no real persistent
/// conversation to write to:
///   - reviewer mode (handled by [_saveConversationLocally] / Hive blob)
///   - temporary chats (`local:` prefix — never persisted by design)
///   - no active conversation, or empty/null id (new-chat window before
///     `createConversation` resolves with a server id)
bool _shouldPersistGranular(dynamic ref, {String? conversationId}) {
  if (ref.read(reviewerModeProvider) as bool) return false;
  final id = conversationId ?? ref.read(activeConversationProvider)?.id;
  if (id == null || id.isEmpty) return false;
  if (isTemporaryChat(id)) return false;
  return true;
}

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

/// Phase 4c — delete a set of messages from the active conversation.
///
/// Local-first: removes from the in-memory chat state and SQLite cache
/// immediately so the UI feels instant, then best-effort syncs the new
/// authoritative message list to the server. Server failure is logged
/// but does NOT roll back the local deletion — the next refresh from
/// server will reconcile if the deletion never landed.
///
/// Skips no-op deletions (empty set or no active conversation).
/// Temporary chats persist nothing to SQLite or server — the local
/// state update is the entire delete.
///
/// Returns the number of messages actually removed from local state.
Future<int> deleteMessages(WidgetRef ref, Set<String> messageIds) async {
  if (messageIds.isEmpty) return 0;
  final activeConversation = ref.read(activeConversationProvider);
  if (activeConversation == null) return 0;

  final currentMessages = ref.read(chatMessagesProvider);
  final remaining = currentMessages
      .where((m) => !messageIds.contains(m.id))
      .toList(growable: false);
  if (remaining.length == currentMessages.length) {
    // None of the requested ids were present — nothing to do.
    return 0;
  }

  // Optimistic local removal: chat list, active conversation, drawer
  // summary all update before any network call.
  final notifier = ref.read(chatMessagesProvider.notifier);
  notifier.setMessages(remaining);

  final updatedConversation = activeConversation.copyWith(
    messages: remaining,
    updatedAt: DateTime.now(),
  );
  ref.read(activeConversationProvider.notifier).set(updatedConversation);

  if (!isTemporaryChat(activeConversation.id)) {
    try {
      ref
          .read(conversationsProvider.notifier)
          .upsertConversation(updatedConversation.copyWith(messages: const []));
    } catch (_) {}

    // SQLite: drop the message rows. Triggers from Phase 4b also remove
    // them from the FTS index so search results don't include zombies.
    try {
      final storage = ref.read(optimizedStorageServiceProvider);
      for (final id in messageIds) {
        unawaited(storage.persistMessageDeletion(activeConversation.id, id));
      }
    } catch (_) {}

    // Best-effort server sync. We hold the authoritative post-delete
    // snapshot, so syncConversationMessages is safe here (its docstring
    // warns against partial buffers — this is the explicit-snapshot
    // case it allows).
    try {
      final api = ref.read(apiServiceProvider);
      if (api != null) {
        unawaited(
          api
              .syncConversationMessages(
                activeConversation.id,
                remaining,
                title: updatedConversation.title,
                model: updatedConversation.model,
                systemPrompt: updatedConversation.systemPrompt,
              )
              .catchError((Object e) {
                DebugLogger.log(
                  'deleteMessages server sync failed: $e',
                  scope: 'chat/providers',
                );
              }),
        );
      }
    } catch (e) {
      DebugLogger.log(
        'deleteMessages server sync threw: $e',
        scope: 'chat/providers',
      );
    }
  }

  return currentMessages.length - remaining.length;
}

/// Whether [message] is an assistant message whose normalized [files]
/// contain at least one image entry (`type == 'image'`).
///
/// Used by the regeneration path to decide whether to force
/// `imageGenerationEnabled` during replay.
bool assistantHasNormalizedImageFiles(ChatMessage message) {
  if (message.role != 'assistant') return false;
  final files = message.files;
  if (files == null || files.isEmpty) return false;
  return files.any((f) => f['type'] == 'image');
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
        assistantHasNormalizedImageFiles(lastAssistantMessage);
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
        final api = ref.read(apiServiceProvider);

        // Use transport-aware stop which inspects message metadata to
        // choose the right cancellation path (abort handle, task stop, or
        // both).
        stopActiveTransport(messages.last, api);

        // Cancel local stream subscription to stop propagating further chunks
        ref.read(chatMessagesProvider.notifier).cancelActiveMessageStream();
      }
    } catch (_) {}

    // Best-effort: stop any background tasks associated with this chat
    // (parity with web) — covers tasks not tracked via message metadata.
    try {
      final api = ref.read(apiServiceProvider);
      final activeConv = ref.read(activeConversationProvider);
      if (api != null && activeConv != null) {
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

/// Builds the `model_item` map from real server model data.
///
/// Includes routing-critical fields (`pipe`, `actions`, `owned_by`, etc.)
/// preserved during model parsing. The backend uses these for pipe routing,
/// filter resolution, and action dispatch.
Map<String, dynamic> _buildLocalModelItem(dynamic selectedModel) {
  final meta = selectedModel.metadata as Map<String, dynamic>?;
  return {
    'id': selectedModel.id,
    'name': selectedModel.name,
    'supported_parameters':
        selectedModel.supportedParameters ??
        [
          'max_tokens',
          'tool_choice',
          'tools',
          'response_format',
          'structured_outputs',
        ],
    'capabilities': selectedModel.capabilities,
    'info': meta?['info'],
    // Routing-critical fields for pipe models
    if (meta?['pipe'] != null) 'pipe': meta!['pipe'],
    if (meta?['actions'] != null) 'actions': meta!['actions'],
    if (meta?['owned_by'] != null) 'owned_by': meta!['owned_by'],
    if (meta?['object'] != null) 'object': meta!['object'],
    if (meta?['created'] != null) 'created': meta!['created'],
    if (meta?['has_user_valves'] != null)
      'has_user_valves': meta!['has_user_valves'],
    if (meta?['tags'] != null) 'tags': meta!['tags'],
    // Include filters for outlet filter routing
    if (selectedModel.filters != null)
      'filters': (selectedModel.filters as List)
          .map((f) => f.toJson())
          .toList(),
  };
}

/// Phase 4a — when the app returns to the foreground, refresh the
/// active conversation if it has a stuck `isStreaming: true` message.
/// The OpenWebUI server keeps generating after the client disconnects;
/// the completed response gets persisted server-side. This observer
/// surfaces it without the user having to manually pull-to-refresh.
///
/// Mounted from [appStartupOrchestrationProvider] alongside the other
/// lifecycle observers.
final chatLifecycleProvider = Provider<void>((ref) {
  final observer = _ChatLifecycleObserver(ref);
  WidgetsBinding.instance.addObserver(observer);
  ref.onDispose(() => WidgetsBinding.instance.removeObserver(observer));
});

class _ChatLifecycleObserver extends WidgetsBindingObserver {
  _ChatLifecycleObserver(this._ref);

  final Ref _ref;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    Future.microtask(() {
      try {
        final notifier = _ref.read(chatMessagesProvider.notifier);
        if (!notifier.hasStuckStreamingMessage) return;
        unawaited(
          notifier.refreshActiveConversationFromServer(
            source: 'app foreground',
          ),
        );
      } catch (_) {}
    });
  }
}
