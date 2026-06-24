import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:uuid/uuid.dart';
import 'package:yaml/yaml.dart' as yaml;

import '../../../core/auth/auth_state_manager.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/model.dart';
import '../../../core/models/conversation.dart';
import '../../../core/models/file_info.dart';
import '../../../core/database/app_database.dart';
import '../../../core/database/daos/outbox_dao.dart';
import '../../../core/database/database_provider.dart';
import '../../../core/database/local_conversation_loader.dart';
import '../../../core/database/mappers/chat_blob_mapper.dart';
import '../../../core/database/mappers/conversation_assembler.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/sync/chat_locks.dart';
import '../../../core/sync/clock.dart';
import '../../../core/sync/id_remapper.dart';
import '../../../core/sync/outbox_drainer.dart' show OutboxDeferralException;
import '../../../core/sync/sync_engine.dart';

import '../../../core/services/chat_completion_transport.dart';
import '../../../core/services/location_service.dart';
import '../../../core/services/settings_service.dart';
import '../../../core/services/socket_service.dart';
import '../../../core/services/streaming_response_controller.dart';
import '../../../core/services/performance_profiler.dart';
import '../../../core/services/worker_manager.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../core/utils/json_normalization.dart';
import '../../../core/utils/message_tree_utils.dart' as message_tree;
import '../../../core/utils/tool_calls_parser.dart';
import '../models/chat_context_attachment.dart';
import '../providers/context_attachments_provider.dart';
import '../../tools/providers/tools_providers.dart';
import '../services/chat_transport_dispatch.dart';
import '../services/file_attachment_service.dart';
import '../services/reviewer_mode_service.dart';

part 'chat_capability_providers.dart';
part 'chat_composer_providers.dart';
part 'chat_providers.g.dart';

// Chat messages for current conversation
final chatMessagesProvider =
    NotifierProvider<ChatMessagesNotifier, List<ChatMessage>>(
      ChatMessagesNotifier.new,
    );

@immutable
class _ChatMessageListStructure {
  const _ChatMessageListStructure({required this.ids, required this.signature});

  factory _ChatMessageListStructure.fromMessages(List<ChatMessage> messages) {
    final ids = List<String>.unmodifiable(
      messages.map((message) => message.id).toList(growable: false),
    );
    final buffer = StringBuffer();
    for (final message in messages) {
      buffer
        ..write(message.id)
        ..write('\u0000')
        ..write(message.role)
        ..write('\u0000')
        ..write(message.model ?? '')
        ..write('\u0000')
        ..write(message.attachmentIds?.length ?? 0)
        ..write('\u0000')
        ..write(message.files?.length ?? 0)
        ..write('\u0000')
        ..write(message.embeds?.length ?? 0)
        ..write('\u0000')
        ..write(message.output?.length ?? 0)
        ..write('\u0000')
        ..write(message.statusHistory.length)
        ..write('\u0000')
        ..write(message.followUps.length)
        ..write('\u0000')
        ..write(message.sources.length)
        ..write('\u0000')
        ..write(message.codeExecutions.length)
        ..write('\u0000')
        ..write(message.error == null ? 0 : 1)
        ..write('\u0000')
        ..write(message.metadata?['archivedVariant'] == true ? 1 : 0)
        ..write('\u0000')
        // Include the displayed model-name fallback so the structure signature
        // changes whenever the label changes, keeping the list-shell rebuild
        // trigger in agreement with chat_page's layout signature. Use the
        // normalized extractor so trim/empty handling matches the displayed name.
        ..write(_messageModelName(message) ?? '')
        ..write('\u0000')
        ..write(message.versions.length);
      for (final version in message.versions) {
        buffer
          ..write('\u0000')
          ..write(version.model ?? '');
      }
      buffer.writeln();
    }
    return _ChatMessageListStructure(ids: ids, signature: buffer.toString());
  }

  final List<String> ids;
  final String signature;

  bool get hasMessages => ids.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _ChatMessageListStructure && other.signature == signature;

  @override
  int get hashCode => signature.hashCode;
}

final _chatMessageListStructureProvider = Provider<_ChatMessageListStructure>((
  ref,
) {
  return ref.watch(
    chatMessagesProvider.select(_ChatMessageListStructure.fromMessages),
  );
});

final _chatMessageMapProvider = Provider<Map<String, ChatMessage>>((ref) {
  return ref.watch(
    chatMessagesProvider.select((messages) {
      final byId = <String, ChatMessage>{};
      for (final message in messages) {
        byId[message.id] = message;
      }
      return Map<String, ChatMessage>.unmodifiable(byId);
    }),
  );
});

final chatMessageStructureSignatureProvider = Provider<String>((ref) {
  return ref.watch(
    _chatMessageListStructureProvider.select(
      (structure) => structure.signature,
    ),
  );
});

final chatMessageIdsProvider = Provider<List<String>>((ref) {
  return ref.watch(
    _chatMessageListStructureProvider.select((structure) => structure.ids),
  );
});

final hasChatMessagesProvider = Provider<bool>((ref) {
  return ref.watch(
    _chatMessageListStructureProvider.select(
      (structure) => structure.hasMessages,
    ),
  );
});

final chatMessageByIdProvider = Provider.autoDispose
    .family<ChatMessage?, String>((ref, messageId) {
      return ref.watch(
        _chatMessageMapProvider.select(
          (messagesById) => messagesById[messageId],
        ),
      );
    });

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

final shouldProtectLocalStreamingStateProvider = Provider<bool>((ref) {
  final isStreaming = ref.watch(isChatStreamingProvider);
  if (isStreaming) {
    return true;
  }

  return ref.watch(
    streamingContentProvider.select(
      (content) => content != null && content.isNotEmpty,
    ),
  );
});

String? _connectedSocketSessionId(SocketService? socketService) {
  if (socketService?.isConnected != true) {
    return null;
  }

  final sessionId = socketService!.sessionId;
  if (sessionId == null || sessionId.isEmpty) {
    return null;
  }

  return sessionId;
}

const Duration _headlessStreamDrainTimeout = Duration(minutes: 5);

Future<String?> _ensureConnectedSocketSessionId(
  SocketService? socketService, {
  Duration timeout = const Duration(milliseconds: 1200),
}) async {
  if (socketService == null) {
    return null;
  }

  if (!socketService.isConnected) {
    try {
      await socketService.ensureConnected(timeout: timeout);
    } catch (e) {
      DebugLogger.log(
        'Socket reconnect before chat send failed: $e',
        scope: 'chat/providers',
      );
    }
  }

  return _connectedSocketSessionId(socketService);
}

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

@visibleForTesting
Duration debugStreamingContentUpdateIntervalForBuffer(
  int length, {
  bool isWeb = false,
  TargetPlatform platform = TargetPlatform.android,
}) {
  return _streamingContentUpdateIntervalForTarget(
    length,
    isMobileTarget:
        !isWeb &&
        (platform == TargetPlatform.android || platform == TargetPlatform.iOS),
  );
}

Duration _streamingContentUpdateIntervalForTarget(
  int length, {
  required bool isMobileTarget,
}) {
  if (length >= 16000) {
    return isMobileTarget
        ? const Duration(milliseconds: 750)
        : const Duration(milliseconds: 420);
  }
  if (length >= 8000) {
    return isMobileTarget
        ? const Duration(milliseconds: 500)
        : const Duration(milliseconds: 280);
  }
  if (length >= 4000) {
    return isMobileTarget
        ? const Duration(milliseconds: 300)
        : const Duration(milliseconds: 180);
  }
  if (length >= 2000) {
    return isMobileTarget
        ? const Duration(milliseconds: 220)
        : const Duration(milliseconds: 140);
  }
  if (length >= 1000) {
    return isMobileTarget
        ? const Duration(milliseconds: 160)
        : const Duration(milliseconds: 120);
  }
  return isMobileTarget
      ? const Duration(milliseconds: 100)
      : const Duration(milliseconds: 80);
}

// Loading state for conversation (used to show chat skeletons during fetch)
@Riverpod(keepAlive: true)
class IsLoadingConversation extends _$IsLoadingConversation {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

// Chat messages notifier class
class ChatMessagesNotifier extends Notifier<List<ChatMessage>> {
  static const _passiveRefreshDebounce = Duration(milliseconds: 350);

  StreamingResponseController? _messageStream;
  ProviderSubscription? _conversationListener;
  final List<StreamSubscription> _subscriptions = [];
  final List<VoidCallback> _socketSubscriptions = [];
  VoidCallback? _socketTeardown;
  SocketEventSubscription? _passiveConversationSocketSubscription;
  StreamSubscription<List<MessageRow>>? _dbMessagesSubscription;
  String? _dbWatchedChatId;
  int _dbMessagesGeneration = 0;
  DateTime? _lastStreamingActivity;
  StringBuffer? _streamingBuffer;
  Timer? _streamingSyncTimer;
  Timer? _streamingContentTimer;
  bool _streamingContentFrameScheduled = false;
  DateTime? _lastStreamingContentFlushAt;
  int _streamingBufferVersion = 0;
  int _lastFlushedStreamingBufferVersion = -1;
  Timer? _taskStatusTimer;
  Timer? _passiveConversationRefreshTimer;
  bool _taskStatusCheckInFlight = false;
  bool _observedRemoteTask = false;
  // Feature C: number of consecutive polls that saw `tasksDone` while a socket
  // resume stream still held protection. The poll's force-adoption is deferred
  // for a short grace window so the socket's own `done` finalize wins and we
  // never double-finalize. Reset whenever tasks are active again.
  int _tasksDoneGracePolls = 0;
  // Polls to wait after `tasksDone` before the poll force-adopts server state
  // over a still-protected socket resume stream (~2s at the 1s cadence).
  static const int _tasksDoneSocketGracePolls = 2;
  bool _passiveConversationRefreshInFlight = false;
  bool _queuedPassiveConversationRefresh = false;
  String? _passiveConversationId;
  String? _activeStreamingTransportMessageId;
  // Foreign server-assigned message id bound to the streaming tail (socket
  // resume). Lets the poll fallback resolve server messages by this id if the
  // socket dies after binding but before delivering `done`.
  String? _boundRemoteMessageId;
  String? _streamingProfileTaskKey;
  String? _streamingProfileMessageId;
  DateTime? _streamingProfileStartedAt;
  int _streamingProfileChunkCount = 0;
  int _streamingProfileBytes = 0;

  bool _initialized = false;
  bool _disposed = false;

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
        _configureDbMessagesWatch(next?.id);

        // Only react when the conversation actually changes
        if (previous?.id == next?.id ||
            isActiveConversationInPlaceRemap(ref, previous?.id, next?.id)) {
          final serverMessages = next?.messages ?? const [];
          // While resuming a reopened, server-active chat the progressive poll
          // owns content; don't let a same-id server snapshot (isStreaming:false)
          // clobber the streaming state and end it prematurely.
          if (!_isResumeStreamingActive &&
              _shouldAdoptServerMessages(serverMessages)) {
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
          final nextMessages = next.messages;
          final currentMessagesAlreadyVisible =
              state.isNotEmpty &&
              !_messagesDifferByStreamingSignatures(nextMessages, state);
          if (!currentMessagesAlreadyVisible) {
            state = nextMessages;
          }
          _syncStreamingProfileWithState();

          // Update selected model if conversation has a different model
          _updateModelForConversation(next);

          if (_hasStreamingAssistant) {
            _ensureRemoteTaskMonitor();
          } else {
            // The opened chat may still be generating on the server; the server
            // never sends `isStreaming`, so detect it from the task registry and
            // re-engage the indicator + monitor.
            unawaited(_detectActiveOnOpen(next));
          }
        } else {
          state = [];
          _finishStreamingProfile(reason: 'conversation_cleared');
          _stopRemoteTaskMonitor();
        }
      });

      ref.onDispose(() {
        _disposed = true;
        for (final subscription in _subscriptions) {
          subscription.cancel();
        }
        _subscriptions.clear();

        _teardownPassiveConversationSync();
        _cancelDbMessagesWatch();
        _cancelMessageStream(clearStreamingContent: false);
        _stopRemoteTaskMonitor();
        _streamingSyncTimer?.cancel();
        _streamingSyncTimer = null;
        _streamingContentTimer?.cancel();
        _streamingContentTimer = null;

        _conversationListener?.close();
        _conversationListener = null;
      });
    }

    final activeConversation = ref.read(activeConversationProvider);
    _configurePassiveConversationSync(activeConversation);
    _configureDbMessagesWatch(activeConversation?.id);
    return activeConversation?.messages ?? const [];
  }

  /// One narrow Drift watch over the active chat's message rows
  /// (CDT-RFC-001 §10.2: always `WHERE chatId = ?`). Resubscribed on
  /// conversation change, cancelled on null/dispose.
  void _configureDbMessagesWatch(String? conversationId) {
    if (conversationId == null ||
        conversationId.isEmpty ||
        isTemporaryChat(conversationId)) {
      _cancelDbMessagesWatch();
      return;
    }
    if (_dbWatchedChatId == conversationId && _dbMessagesSubscription != null) {
      return;
    }
    _cancelDbMessagesWatch();
    final db = _maybeDatabase();
    if (db == null) {
      return;
    }
    _dbWatchedChatId = conversationId;
    _dbMessagesSubscription = db.messagesDao
        .watchForChat(conversationId)
        .listen(
          (rows) {
            final generation = ++_dbMessagesGeneration;
            unawaited(_onDbMessagesChanged(conversationId, rows, generation));
          },
          onError: (Object error, StackTrace stackTrace) {
            DebugLogger.error(
              'db-watch-failed',
              scope: 'chat/providers',
              error: error,
              stackTrace: stackTrace,
              data: {'conversationId': conversationId},
            );
          },
        );
  }

  void _cancelDbMessagesWatch() {
    _dbMessagesSubscription?.cancel();
    _dbMessagesSubscription = null;
    _dbWatchedChatId = null;
    _dbMessagesGeneration++;
  }

  /// Database emissions adopt through the exact same protected path as
  /// server snapshots: streaming state is never touched while
  /// [_shouldProtectLocalStreamingState] holds, and all dedupe/protection
  /// lives in [_adoptServerMessages].
  Future<void> _onDbMessagesChanged(
    String conversationId,
    List<MessageRow> rows,
    int generation,
  ) async {
    if (_disposed ||
        generation != _dbMessagesGeneration ||
        _shouldProtectLocalStreamingState) {
      return;
    }
    if (ref.read(activeConversationProvider)?.id != conversationId) {
      return;
    }
    final db = _maybeDatabase();
    if (db == null) {
      return;
    }
    try {
      final chat = await db.chatsDao.getChat(conversationId);
      if (generation != _dbMessagesGeneration) {
        return;
      }
      if (chat == null || !chat.bodySynced) {
        return;
      }
      final conversation = assembleConversation(chat, rows);
      if (_disposed ||
          !ref.mounted ||
          generation != _dbMessagesGeneration ||
          _shouldProtectLocalStreamingState) {
        return;
      }
      if (ref.read(activeConversationProvider)?.id != conversationId) {
        return;
      }
      _adoptServerMessages(conversation.messages, source: 'database watch');
    } catch (error, stackTrace) {
      DebugLogger.error(
        'db-adopt-failed',
        scope: 'chat/providers',
        error: error,
        stackTrace: stackTrace,
        data: {'conversationId': conversationId},
      );
    }
  }

  AppDatabase? _maybeDatabase() {
    // Database dependencies unavailable (e.g. teardown or test harness
    // without an active server) resolve to null.
    return _readAppDatabaseOrNull(ref);
  }

  bool _shouldAdoptServerMessages(List<ChatMessage> serverMessages) {
    if (serverMessages.isEmpty && state.isNotEmpty) {
      return false;
    }
    if (_messagesDifferByCoreFields(serverMessages, state)) {
      return true;
    }
    if (_hasStreamingAssistant ||
        (serverMessages.lastOrNull?.role == 'assistant' &&
            serverMessages.lastOrNull?.isStreaming == true)) {
      return _messagesDifferByStreamingSignatures(serverMessages, state);
    }
    return !listEquals(serverMessages, state);
  }

  bool _messagesDifferByCoreFields(
    List<ChatMessage> left,
    List<ChatMessage> right,
  ) {
    if (left.length != right.length) {
      return true;
    }
    for (var index = 0; index < left.length; index += 1) {
      final leftMessage = left[index];
      final rightMessage = right[index];
      if (leftMessage.id != rightMessage.id ||
          leftMessage.role != rightMessage.role ||
          leftMessage.isStreaming != rightMessage.isStreaming ||
          leftMessage.content != rightMessage.content) {
        return true;
      }
    }
    return false;
  }

  bool _messagesDifferByStreamingSignatures(
    List<ChatMessage> left,
    List<ChatMessage> right,
  ) {
    if (left.length != right.length) {
      return true;
    }
    for (var index = 0; index < left.length; index += 1) {
      if (_streamingMessageSignature(left[index]) !=
          _streamingMessageSignature(right[index])) {
        return true;
      }
    }
    return false;
  }

  int _streamingMessageSignature(ChatMessage message) {
    return Object.hash(
      message.id,
      message.role,
      message.model,
      message.isStreaming,
      message.content,
      message.error?.content,
      _statusHistoryStreamingSignature(message.statusHistory),
      _stringListStreamingSignature(message.followUps),
      _stringListStreamingSignature(message.attachmentIds ?? const <String>[]),
      _dynamicMapListStreamingSignature(message.files),
      _dynamicMapListStreamingSignature(message.output),
      _dynamicMapListStreamingSignature(message.embeds),
      _sourceStreamingSignature(message.sources),
      _codeExecutionStreamingSignature(message.codeExecutions),
      _versionStreamingSignature(message.versions),
      _mapStreamingSignature(message.metadata),
      _mapStreamingSignature(message.usage),
    );
  }

  int _statusHistoryStreamingSignature(List<ChatStatusUpdate> statuses) {
    return Object.hashAll(
      statuses.map(
        (status) => Object.hash(
          status.action,
          status.description,
          status.done,
          status.hidden,
          status.count,
          status.query,
          Object.hashAll(status.queries),
          Object.hashAll(status.urls),
          _statusItemsStreamingSignature(status.items),
          status.occurredAt?.millisecondsSinceEpoch,
        ),
      ),
    );
  }

  int _stringListStreamingSignature(List<String> values) =>
      Object.hashAll(values);

  int _sourceStreamingSignature(List<ChatSourceReference> sources) {
    return Object.hashAll(
      sources.map(
        (source) => Object.hash(
          source.id,
          source.title,
          source.url,
          source.snippet,
          source.type,
          _mapStreamingSignature(source.metadata),
        ),
      ),
    );
  }

  int _codeExecutionStreamingSignature(List<ChatCodeExecution> executions) {
    return Object.hashAll(
      executions.map(
        (execution) => Object.hash(
          execution.id,
          execution.name,
          execution.language,
          execution.code,
          execution.result?.output,
          execution.result?.error,
          _executionFilesStreamingSignature(
            execution.result?.files ?? const <ChatExecutionFile>[],
          ),
          _mapStreamingSignature(execution.result?.metadata),
          _mapStreamingSignature(execution.metadata),
        ),
      ),
    );
  }

  int _versionStreamingSignature(List<ChatMessageVersion> versions) {
    return Object.hashAll(
      versions.map(
        (version) => Object.hash(
          version.id,
          version.model,
          version.content,
          version.error?.content,
          _dynamicMapListStreamingSignature(version.files),
          _dynamicMapListStreamingSignature(version.output),
          _dynamicMapListStreamingSignature(version.embeds),
          _sourceStreamingSignature(version.sources),
          _stringListStreamingSignature(version.followUps),
          _codeExecutionStreamingSignature(version.codeExecutions),
          _mapStreamingSignature(version.usage),
        ),
      ),
    );
  }

  int _statusItemsStreamingSignature(List<ChatStatusItem> items) {
    return Object.hashAll(
      items.map(
        (item) => Object.hash(
          item.title,
          item.link,
          item.snippet,
          _mapStreamingSignature(item.metadata),
        ),
      ),
    );
  }

  int _executionFilesStreamingSignature(List<ChatExecutionFile> files) {
    return Object.hashAll(
      files.map(
        (file) => Object.hash(
          file.name,
          file.url,
          _mapStreamingSignature(file.metadata),
        ),
      ),
    );
  }

  int _dynamicMapListStreamingSignature(List<Map<String, dynamic>>? values) {
    if (values == null || values.isEmpty) {
      return 0;
    }
    return Object.hash(
      values.length,
      Object.hashAll(values.map(_mapStreamingSignature)),
    );
  }

  int _mapStreamingSignature(Map<String, dynamic>? value) {
    if (value == null || value.isEmpty) {
      return 0;
    }
    final entries = value.entries.toList(growable: false)
      ..sort((left, right) => left.key.compareTo(right.key));
    return Object.hashAll(
      entries.map((entry) {
        return Object.hash(
          entry.key,
          _dynamicValueStreamingSignature(entry.value),
        );
      }),
    );
  }

  int _dynamicValueStreamingSignature(Object? value) {
    if (value == null) {
      return 0;
    }
    if (value is String || value is num || value is bool) {
      return Object.hash(value.runtimeType, value);
    }
    if (value is DateTime) {
      return Object.hash(DateTime, value.microsecondsSinceEpoch);
    }
    if (value is Map) {
      final normalized = <String, dynamic>{
        for (final entry in value.entries)
          entry.key?.toString() ?? '': entry.value,
      };
      return _mapStreamingSignature(normalized);
    }
    if (value is Iterable) {
      final entries = value.toList(growable: false);
      return Object.hash(
        entries.length,
        Object.hashAll(entries.map(_dynamicValueStreamingSignature)),
      );
    }
    return Object.hash(value.runtimeType, value.toString());
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

    _clearStreamingBuffer();
    _streamingSyncTimer?.cancel();
    _streamingSyncTimer = null;
    _streamingContentTimer?.cancel();
    _streamingContentTimer = null;
    _clearStreamingContent();
    if (_hasTrackedStreamingTransport) {
      _dropStreamingTransportState(source: 'server adoption from $source');
    }
    state = _preserveFreshLocalAssistantState(serverMessages);
    _syncStreamingProfileWithState();

    if (needsCleanup) {
      _cancelMessageStream();
    }

    DebugLogger.log(
      'Adopted server conversation snapshot from $source '
      '(${serverMessages.length} messages)',
      scope: 'chat/providers',
    );
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

  List<ChatMessage> _preserveFreshLocalAssistantState(
    List<ChatMessage> serverMessages,
  ) {
    if (state.isEmpty || serverMessages.isEmpty) {
      return serverMessages;
    }

    final localById = <String, ChatMessage>{
      for (final message in state)
        // Also index empty placeholders that still carry a local-only
        // `modelName`, so a stale pre-first-token snapshot can't drop the model
        // label before the metadata merge runs.
        if (message.role == 'assistant' &&
            (message.content.trim().isNotEmpty ||
                message.followUps.isNotEmpty ||
                _messageModelName(message) != null))
          message.id: message,
    };
    if (localById.isEmpty) {
      return serverMessages;
    }

    // Content preservation only protects the streaming tail — the one message
    // that may be mid-finalization when a lagging snapshot arrives. Older,
    // already-completed assistant messages must defer to the server so an
    // authoritative refresh can correct or truncate them.
    final localTailId = state.last.role == 'assistant' ? state.last.id : null;

    var changed = false;
    final merged = <ChatMessage>[];
    for (final serverMessage in serverMessages) {
      // A socket resume binds a foreign server message_id to the local tail; a
      // lagging snapshot may carry that remote id instead of the local
      // placeholder id, so resolve it back to the tail.
      final boundToTail =
          _boundRemoteMessageId != null &&
          serverMessage.id == _boundRemoteMessageId &&
          localTailId != null;
      final localMessage =
          localById[serverMessage.id] ??
          (boundToTail ? localById[localTailId] : null);
      final isStreamingTail =
          localMessage != null &&
          (serverMessage.id == localTailId || boundToTail);
      final preserveContent =
          localMessage != null &&
          isStreamingTail &&
          _shouldPreserveLocalAssistantContent(localMessage, serverMessage);
      final sameResponseContent =
          localMessage != null &&
          _sameAssistantResponseText(
            localMessage.content,
            serverMessage.content,
          );
      final shouldPreserveFollowUps =
          localMessage != null &&
          localMessage.followUps.isNotEmpty &&
          serverMessage.role == 'assistant' &&
          serverMessage.followUps.isEmpty &&
          (sameResponseContent || preserveContent);
      // Preserve a local-only modelName the server snapshot hasn't caught up to
      // (notably an empty placeholder whose first token hasn't landed).
      final shouldPreserveModelName =
          localMessage != null &&
          serverMessage.role == 'assistant' &&
          _messageModelName(localMessage) != null &&
          _messageModelName(serverMessage) == null;
      if (!preserveContent &&
          !shouldPreserveFollowUps &&
          !shouldPreserveModelName) {
        merged.add(serverMessage);
        continue;
      }

      changed = true;
      // Merge local + server metadata so local-only fields (e.g. `modelName`)
      // survive a server snapshot captured before the durable payload was
      // finalized. Server values take precedence; local fills only the gaps.
      final metadata = <String, dynamic>{
        ...?localMessage.metadata,
        ...?serverMessage.metadata,
      };
      if (shouldPreserveFollowUps) {
        // Overwrite (not putIfAbsent): the merged map may carry a stale
        // `followUps` from the server snapshot (e.g. an explicit empty list),
        // which must mirror the preserved typed `.followUps` field below.
        metadata['followUps'] = List<String>.from(localMessage.followUps);
      }
      if (shouldPreserveModelName) {
        // The raw server map may carry an empty/whitespace `modelName` that the
        // union spread on top of the local one; restore the normalized local
        // value so an empty server field can't blank the displayed model name.
        metadata['modelName'] = _messageModelName(localMessage);
      }
      merged.add(
        serverMessage.copyWith(
          content: preserveContent
              ? localMessage.content
              : serverMessage.content,
          followUps: shouldPreserveFollowUps
              ? List<String>.from(localMessage.followUps)
              : serverMessage.followUps,
          metadata: metadata.isEmpty ? null : metadata,
        ),
      );
    }

    return changed ? List<ChatMessage>.unmodifiable(merged) : serverMessages;
  }

  bool _shouldPreserveLocalAssistantContent(
    ChatMessage localMessage,
    ChatMessage serverMessage,
  ) {
    if (serverMessage.role != 'assistant') {
      return false;
    }
    if (!_hasLocalStreamingProvenance(localMessage)) {
      return false;
    }
    final localContent = localMessage.content;
    final serverContent = serverMessage.content;
    if (localContent.trim().isEmpty) {
      return false;
    }
    if (serverContent.trim().isEmpty) {
      return true;
    }
    if (localContent.length <= serverContent.length) {
      return false;
    }
    return _sameAssistantResponsePrefix(localContent, serverContent);
  }

  bool _hasLocalStreamingProvenance(ChatMessage message) {
    final metadata = message.metadata;
    return message.isStreaming ||
        metadata?['responseDone'] == true ||
        metadata?['transport'] != null ||
        metadata?['taskId'] != null ||
        metadata?['hasActiveAbortHandle'] == true;
  }

  bool _sameAssistantResponseText(String left, String right) {
    return left == right || left.trim() == right.trim();
  }

  bool _sameAssistantResponsePrefix(String longer, String shorter) {
    return longer.startsWith(shorter) ||
        longer.trimLeft().startsWith(shorter.trimLeft());
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

  Future<void> _refreshConversationFromServer(
    String conversationId, {
    required String source,
  }) async {
    if (_passiveConversationRefreshInFlight ||
        _shouldProtectLocalStreamingState ||
        _isResumeStreamingActive) {
      return;
    }

    final activeConversation = ref.read(activeConversationProvider);
    if (activeConversation == null || activeConversation.id != conversationId) {
      return;
    }

    _passiveConversationRefreshInFlight = true;
    try {
      // Pull through the sync engine: the raw fetch persists via
      // upsertServerChat under the chat lock, then returns the assembled
      // conversation (CDT-RFC-001 Phase 1). Falls back to a direct fetch when
      // the engine is inert/unavailable (no database, reviewer mode).
      final refreshed = await pullChatOrFetch(ref, conversationId);
      if (refreshed == null) {
        return;
      }
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
              .upsertConversation(
                refreshed.copyWith(messages: const []),
                trustFolderConversation:
                    refreshed.folderId != null &&
                    refreshed.folderId!.isNotEmpty,
              );
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
    _streamingContentTimer?.cancel();
    _streamingContentTimer = null;
    _streamingContentFrameScheduled = false;
    _lastStreamingContentFlushAt = null;
    _lastFlushedStreamingBufferVersion = -1;
    try {
      ref.read(streamingContentProvider.notifier).set(null);
    } on Object catch (_) {
      // Provider may be disposing or unavailable during conversation
      // transitions / notifier teardown.
    }
  }

  void _beginStreamingProfile(ChatMessage message) {
    if (message.role != 'assistant' || !message.isStreaming) {
      return;
    }
    if (_streamingProfileMessageId == message.id &&
        _streamingProfileTaskKey != null) {
      return;
    }

    _finishStreamingProfile(reason: 'replaced');
    _streamingProfileMessageId = message.id;
    _streamingProfileStartedAt = DateTime.now();
    _streamingProfileChunkCount = 0;
    _streamingProfileBytes = message.content.length;
    _streamingProfileTaskKey = PerformanceProfiler.instance.startTask(
      'chat_stream',
      scope: 'chat',
      key: 'chat-stream:${message.id}',
      data: {
        'messageId': message.id,
        'conversationId': ref.read(activeConversationProvider)?.id ?? 'none',
        'initialLength': message.content.length,
      },
    );
  }

  void _recordStreamingChunk(String content) {
    if (content.isEmpty || state.isEmpty) {
      return;
    }
    final lastMessage = state.last;
    if (lastMessage.role != 'assistant' || !lastMessage.isStreaming) {
      return;
    }

    _beginStreamingProfile(lastMessage);
    _streamingProfileChunkCount += 1;
    _streamingProfileBytes += content.length;
    if (_streamingProfileChunkCount == 1 ||
        _streamingProfileChunkCount % 25 == 0) {
      PerformanceProfiler.instance.instant(
        'chat_stream_chunk',
        scope: 'chat',
        data: {
          'messageId': lastMessage.id,
          'chunkCount': _streamingProfileChunkCount,
          'chunkBytes': content.length,
          'bufferBytes': _streamingProfileBytes,
        },
      );
    }
  }

  void _syncStreamingProfileWithState() {
    final lastMessage = state.lastOrNull;
    if (lastMessage == null ||
        lastMessage.role != 'assistant' ||
        !lastMessage.isStreaming) {
      _finishStreamingProfile(reason: 'state_sync');
      return;
    }

    _beginStreamingProfile(lastMessage);
    _streamingProfileBytes = lastMessage.content.length;
  }

  void _syncStreamingProfileWithBufferedContent() {
    final lastMessage = state.lastOrNull;
    if (lastMessage == null ||
        lastMessage.role != 'assistant' ||
        !lastMessage.isStreaming) {
      _finishStreamingProfile(reason: 'buffer_sync');
      return;
    }

    _beginStreamingProfile(lastMessage);
    _streamingProfileBytes =
        _streamingBuffer?.length ?? lastMessage.content.length;
  }

  void _finishStreamingProfile({required String reason, ChatMessage? message}) {
    final taskKey = _streamingProfileTaskKey;
    final messageId = _streamingProfileMessageId;
    if (taskKey == null || messageId == null) {
      _streamingProfileTaskKey = null;
      _streamingProfileMessageId = null;
      _streamingProfileStartedAt = null;
      _streamingProfileChunkCount = 0;
      _streamingProfileBytes = 0;
      return;
    }

    final elapsed = _streamingProfileStartedAt == null
        ? null
        : DateTime.now().difference(_streamingProfileStartedAt!);
    final finalMessage = message ?? state.lastOrNull;
    PerformanceProfiler.instance.finishTask(
      taskKey,
      data: {
        'messageId': messageId,
        'reason': reason,
        'chunkCount': _streamingProfileChunkCount,
        'bufferBytes': _streamingProfileBytes,
        'elapsedMs': elapsed?.inMilliseconds ?? 0,
        'finalLength': finalMessage?.content.length ?? 0,
      },
    );
    _streamingProfileTaskKey = null;
    _streamingProfileMessageId = null;
    _streamingProfileStartedAt = null;
    _streamingProfileChunkCount = 0;
    _streamingProfileBytes = 0;
  }

  void _markStreamingBufferChanged() {
    _streamingBufferVersion += 1;
  }

  void _clearStreamingBuffer() {
    _streamingBuffer = null;
    _streamingBufferVersion = 0;
    _lastFlushedStreamingBufferVersion = -1;
  }

  /// Records the foreign server message id the streaming helper bound to the
  /// local assistant tail (socket resume), so [_syncRemoteTaskStatus] can match
  /// the server's growing/final message even when its id differs from the local
  /// placeholder id. Scoped to the current streaming tail.
  void recordResumeBoundRemoteMessageId(
    String localMessageId,
    String remoteMessageId,
  ) {
    if (remoteMessageId.isEmpty || state.isEmpty) {
      return;
    }
    if (state.last.id != localMessageId) {
      return;
    }
    _boundRemoteMessageId = remoteMessageId;
  }

  void _cancelMessageStream({bool clearStreamingContent = true}) {
    final controller = _messageStream;
    _messageStream = null;
    _activeStreamingTransportMessageId = null;
    _boundRemoteMessageId = null;
    if (controller != null && controller.isActive) {
      unawaited(controller.cancel());
    }
    cancelSocketSubscriptions();
    _clearStreamingBuffer();
    _streamingSyncTimer?.cancel();
    _streamingSyncTimer = null;
    _streamingContentTimer?.cancel();
    _streamingContentTimer = null;
    if (clearStreamingContent) {
      _clearStreamingContent();
    }
    _stopRemoteTaskMonitor();
    _finishStreamingProfile(reason: 'cancelled');
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

  /// Test-only view of [_shouldProtectLocalStreamingState] so resume regression
  /// tests can assert protection holds ONLY for the matching streaming message
  /// id (Feature C de-risking) without coupling to private members.
  @visibleForTesting
  bool get debugShouldProtectLocalStreamingState =>
      _shouldProtectLocalStreamingState;

  /// Test-only view of the socket-resume grace-poll counter so the
  /// double-finalize race guard (Feature C: "socket done wins / poll defers")
  /// can be asserted across poll iterations without coupling to private state.
  @visibleForTesting
  int get debugTasksDoneGracePolls => _tasksDoneGracePolls;

  /// Test-only entry point that drives a single remote-task poll iteration,
  /// mirroring exactly one tick of the 1s monitor. Lets grace-window regression
  /// tests exercise [_syncRemoteTaskStatus] deterministically.
  @visibleForTesting
  Future<void> debugSyncRemoteTaskStatus() => _syncRemoteTaskStatus();

  /// Test-only hook that cancels just the periodic 1s poll timer without
  /// clearing observed-task / grace state, so a test can drive poll iterations
  /// manually via [debugSyncRemoteTaskStatus] without the timer racing them.
  @visibleForTesting
  void debugCancelRemoteTaskMonitorTimer() {
    _taskStatusTimer?.cancel();
    _taskStatusTimer = null;
  }

  /// Test-only view of the poll re-entry guard so a test can confirm no
  /// background poll is mid-flight before driving deterministic manual polls.
  @visibleForTesting
  bool get debugTaskStatusCheckInFlight => _taskStatusCheckInFlight;

  /// True while streaming was re-engaged for a reopened, server-active chat
  /// (typing indicator + 1s poll) with no genuine local transport. The
  /// progressive poll owns content updates during this window; passive server
  /// refreshes must not clobber the streaming state and end it prematurely.
  bool get _isResumeStreamingActive =>
      _taskStatusTimer != null &&
      _hasStreamingAssistant &&
      !_shouldProtectLocalStreamingState;

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
    _boundRemoteMessageId = null;
    cancelSocketSubscriptions();
    _clearStreamingBuffer();
    _streamingSyncTimer?.cancel();
    _streamingSyncTimer = null;
    _streamingContentTimer?.cancel();
    _streamingContentTimer = null;
    _clearStreamingContent();
    _stopRemoteTaskMonitor();
  }

  void retireObsoleteStreamingTransport(String messageId) {
    _dropStreamingTransportState(
      source: 'obsolete stream retirement',
      messageId: messageId,
    );
  }

  /// When a chat is opened that is still generating on the server, mark its
  /// last assistant message as streaming so the typing indicator + remote-task
  /// monitor engage. The server never sends `isStreaming`, so a reopened
  /// in-flight chat would otherwise render as an empty/partial response.
  Future<void> _detectActiveOnOpen(Conversation conversation) async {
    final chatId = conversation.id;
    if (_disposed || isTemporaryChat(chatId)) {
      return;
    }
    // A genuine local stream, or an already-streaming message, owns this chat.
    if (_shouldProtectLocalStreamingState || _hasStreamingAssistant) {
      return;
    }
    if (state.isEmpty || state.last.role != 'assistant') {
      return;
    }

    // Fast path: the active-chats set (populated by ActiveChatsSync) may already
    // know. Otherwise ask the server's task registry directly. Either way we
    // try to capture an active task id so the resumed message carries stoppable
    // task metadata (stop/delete can then cancel the server task, not just the
    // local subscription).
    final api = ref.read(apiServiceProvider);
    String? resumeTaskId;
    var isActive = ref.read(activeChatIdsProvider).contains(chatId);
    if (!isActive) {
      if (api == null) {
        return;
      }
      try {
        final taskIds = await api.getTaskIdsByChat(chatId);
        isActive = taskIds.isNotEmpty;
        resumeTaskId = taskIds.isNotEmpty ? taskIds.first : null;
      } catch (_) {
        // Offline / unreachable: leave the response as-is (static).
        return;
      }
    } else if (api != null) {
      // Already known-active; best-effort task-id fetch for stoppable metadata.
      try {
        final taskIds = await api.getTaskIdsByChat(chatId);
        resumeTaskId = taskIds.isNotEmpty ? taskIds.first : null;
      } catch (_) {
        // Best-effort only; resume still proceeds without a task id.
      }
    }
    if (!isActive || _disposed) {
      return;
    }

    // The active chat may have changed, or a real stream may have started,
    // while we awaited the probe.
    if (ref.read(activeConversationProvider)?.id != chatId) {
      return;
    }
    if (_shouldProtectLocalStreamingState || _hasStreamingAssistant) {
      return;
    }
    if (state.isEmpty || state.last.role != 'assistant') {
      return;
    }

    final last = state.last;
    state = [
      ...state.sublist(0, state.length - 1),
      last.copyWith(isStreaming: true),
    ];
    // Pre-seed so the monitor's tasksDone finalization resolves once the server
    // task disappears (otherwise tasksDone could never become true).
    _observedRemoteTask = true;
    // Attach a socket resume stream so deltas render token-by-token (mirroring
    // Open WebUI) instead of waiting on the 1s poll. The poll stays armed as a
    // safety-net fallback below. When no connected socket is available the
    // attach is a no-op and behaviour is identical to today's poll-only resume.
    _attachResumeSocketStream(conversation, state.last, taskId: resumeTaskId);
    _ensureRemoteTaskMonitor();
  }

  /// Feature C: subscribe the reopened, server-active chat to the shared
  /// Socket.IO `events` stream so token deltas render in real time, reusing the
  /// full `dispatchChatTransport` callback wiring via `isResume: true`.
  ///
  /// This is best-effort: it only attaches when a connected socket is present.
  /// Offline / disconnected opens fall through to the 1s task poll unchanged.
  /// Registering the socket subscriptions makes [_shouldProtectLocalStreamingState]
  /// true for the resumed message, which demotes the poll's content-adoption to
  /// a pure fallback (the socket owns content).
  void _attachResumeSocketStream(
    Conversation conversation,
    ChatMessage last, {
    String? taskId,
  }) {
    if (_disposed || isTemporaryChat(conversation.id)) {
      return;
    }
    // A genuine local stream already owns this chat — never overwrite it.
    if (_shouldProtectLocalStreamingState) {
      return;
    }
    if (last.role != 'assistant') {
      return;
    }

    final socketService = ref.read(socketServiceProvider);
    if (socketService == null || !socketService.isConnected) {
      // No live socket — rely on the poll fallback (today's behaviour).
      return;
    }

    final api = ref.read(apiServiceProvider);
    if (api == null) {
      return;
    }

    // Resolve a model item for watchdog timing / logging only — resume content
    // arrives over the socket, so the exact model item is non-critical.
    final selectedModel = ref.read(selectedModelProvider);
    final resolvedModelId = (last.model != null && last.model!.isNotEmpty)
        ? last.model!
        : (conversation.model ?? selectedModel?.id ?? '');
    final modelItem =
        (selectedModel != null && selectedModel.id == resolvedModelId)
        ? _buildLocalModelItem(selectedModel)
        : <String, dynamic>{
            'id': resolvedModelId,
            'name': resolvedModelId,
          };

    DebugLogger.log(
      'Attaching socket resume stream for in-flight chat',
      scope: 'chat/resume',
      data: {'chatId': conversation.id, 'messageId': last.id},
    );

    final session = ChatCompletionSession.resumeSocket(
      messageId: last.id,
      conversationId: conversation.id,
      // Carry the discovered task id so dispatchChatTransport writes stoppable
      // task metadata onto the resumed message (stop/delete can cancel the
      // server task, not just the local socket subscription).
      taskId: taskId,
    );

    unawaited(
      dispatchChatTransport(
        ref: ref,
        session: session,
        assistantMessageId: last.id,
        modelId: resolvedModelId,
        modelItem: modelItem,
        activeConversationId: conversation.id,
        api: api,
        socketService: socketService,
        workerManager: ref.read(workerManagerProvider),
        webSearchEnabled: false,
        imageGenerationEnabled: false,
        isBackgroundFlow: false,
        modelUsesReasoning: _modelUsesReasoning(resolvedModelId),
        toolsEnabled: false,
        isTemporary: false,
        isResume: true,
      ),
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
    _tasksDoneGracePolls = 0;
    _boundRemoteMessageId = null;
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

      // Feature C race guard: when a socket resume stream still owns this chat
      // (protection holds), let its own `done` finalize win. Defer the poll's
      // force-adoption for a short grace window so we never double-finalize the
      // same message. The window starts the first poll that sees `tasksDone`
      // while protected; once it elapses (or protection drops) the poll resumes
      // as the authoritative recovery finalizer below.
      if (tasksDone && _shouldProtectLocalStreamingState) {
        _tasksDoneGracePolls++;
      } else {
        _tasksDoneGracePolls = 0;
      }
      final socketResumeGraceActive =
          _shouldProtectLocalStreamingState &&
          _tasksDoneGracePolls > 0 &&
          _tasksDoneGracePolls <= _tasksDoneSocketGracePolls;

      // Resume case: while the server task is still running and no genuine local
      // stream owns this chat (i.e. we re-engaged streaming on reopen), adopt the
      // growing server content so a reopened in-flight chat streams in instead of
      // showing an empty/partial response. A real local send delivers its own
      // socket/HTTP deltas, so it is excluded via _shouldProtectLocalStreamingState.
      if (_hasStreamingAssistant &&
          hasActiveTasks &&
          !_shouldProtectLocalStreamingState) {
        try {
          final refreshed = await pullChatOrFetch(ref, activeConversation.id);
          // Bail if we switched chats or a real stream started during the await.
          if (refreshed == null ||
              _disposed ||
              ref.read(activeConversationProvider)?.id !=
                  activeConversation.id ||
              !_hasStreamingAssistant ||
              _shouldProtectLocalStreamingState) {
            return;
          }
          if (state.isNotEmpty) {
            final localLast = state.last;
            if (localLast.role == 'assistant' && localLast.isStreaming) {
              final snapshot = _readStreamingMessageComparisonSnapshot(
                localLast.id,
              );
              final serverVersion = refreshed.messages
                  .where(
                    (m) =>
                        m.id == localLast.id || m.id == _boundRemoteMessageId,
                  )
                  .firstOrNull;
              final serverContent = serverVersion?.content ?? '';
              // Monotonic growth guard: only adopt when the server has strictly
              // more content than we already show (prevents flicker/duplicates).
              if (serverVersion != null &&
                  serverContent.length > snapshot.comparisonContent.length) {
                state = [
                  ...state.sublist(0, state.length - 1),
                  serverVersion.copyWith(isStreaming: true),
                ];
              }
            }
          }
        } catch (e) {
          DebugLogger.log(
            'Progressive resume fetch failed: $e',
            scope: 'chat/providers',
          );
        }
      }

      // Secondary check: fetch conversation from server and compare message state.
      // This catches cases where the done signal was missed AND syncs any missed
      // content. Only runs when tasks have genuinely completed (were observed and
      // are now gone). We intentionally avoid any timed fallback checks here
      // because they conflict with legitimate slow task registration scenarios
      // like web search, which can take a long time to start on the server.
      // Note: If a socket connection silently fails before tasks complete, the
      // user can cancel via the stop button or navigate away to recover.
      //
      // Feature C: while the socket resume grace window is active, skip the
      // force-adoption so the socket's own `done` finalize wins (avoids a
      // double-finalize / content flicker race). After the window elapses (or
      // if the socket silently died and dropped protection) the poll resumes as
      // the authoritative recovery finalizer.
      if (_hasStreamingAssistant && tasksDone && !socketResumeGraceActive) {
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
              final comparisonSnapshot =
                  _readStreamingMessageComparisonSnapshot(localLast.id);
              final serverVersion = serverMessages
                  .where(
                    (m) =>
                        m.id == localLast.id || m.id == _boundRemoteMessageId,
                  )
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
                    'localLen=${comparisonSnapshot.comparisonContent.length})',
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

  /// Cancels the active stream after folding any buffered content into state.
  ///
  /// This is used by explicit stop flows where the user expects the partial
  /// assistant response to remain visible after streaming ends.
  void cancelActiveMessageStreamPreservingContent() {
    _flushStreamingContentUpdate();
    _syncStreamingBufferToState();
    _cancelMessageStream(clearStreamingContent: false);
  }

  Future<void> _updateModelForConversation(Conversation conversation) async {
    // Check if conversation has a model specified
    if (conversation.model == null || conversation.model!.isEmpty) {
      return;
    }

    final currentSelectedModel = ref.read(selectedModelProvider);

    // If the conversation's model is different from the currently selected one
    if (currentSelectedModel?.id != conversation.model) {
      // Existing chats must keep using their saved model, even if an admin
      // later hides it from selectors.
      try {
        final api = ref.read(apiServiceProvider);
        final models = api != null
            ? await api.getModels(includeHidden: true)
            : await ref.read(modelsProvider.future);

        if (models.isEmpty) {
          return;
        }

        // Look for exact match first
        final conversationModel = models
            .where((model) => model.id == conversation.model)
            .firstOrNull;

        if (conversationModel != null) {
          // Update the selected model
          ref
              .read(selectedModelProvider.notifier)
              .set(conversationModel, allowHidden: true);
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
      _beginStreamingProfile(message);
      _touchStreamingActivity();
    }
  }

  void addMessages(List<ChatMessage> messages) {
    if (messages.isEmpty) return;
    state = [...state, ...messages];
    for (final message in messages.reversed) {
      if (message.role == 'assistant' && message.isStreaming) {
        _beginStreamingProfile(message);
        _touchStreamingActivity();
        break;
      }
    }
  }

  void removeLastMessage() {
    if (state.isNotEmpty) {
      state = state.sublist(0, state.length - 1);
      _syncStreamingProfileWithState();
    }
  }

  void clearMessages() {
    state = [];
    _finishStreamingProfile(reason: 'cleared');
  }

  void failLastStreamingAssistant(Object error, {String? assistantMessageId}) {
    if (state.isEmpty) {
      // No placeholder to mark failed, but still release any dangling
      // streaming/transport bookkeeping so a generic recovery catch cannot
      // leave streaming state hung.
      finishStreaming();
      return;
    }
    // Resolve the target by the captured assistant id so a list reshape between
    // placeholder insertion and this failure (e.g. a concurrent server
    // adoption appending messages) can't attach the error to — or finalize —
    // the wrong tail. Fall back to the last message when no id was captured.
    final target = assistantMessageId != null
        ? state.where((m) => m.id == assistantMessageId).firstOrNull
        : state.last;
    if (target == null || target.role != 'assistant' || !target.isStreaming) {
      // The captured assistant is gone or no longer streaming (e.g. completed,
      // or reshaped). There is no placeholder to attach the error to, but
      // finishStreaming() is idempotent and releases transport/profile state,
      // matching the prior unconditional cleanup this helper replaced.
      finishStreaming();
      return;
    }

    final chatError = ChatMessageError(
      content: chatErrorContentForException(error),
    );
    // Update by id so the error lands on the captured message even if it is no
    // longer the list tail, and clear its streaming flag directly: finishStreaming()
    // only completes state.last, so a non-tail failed message would otherwise stay
    // stuck in isStreaming: true.
    updateMessageById(
      target.id,
      (message) => message.copyWith(error: chatError, isStreaming: false),
    );
    finishStreaming();
  }

  void setMessages(List<ChatMessage> messages) {
    state = messages;
    _syncStreamingProfileWithState();
  }

  void updateLastMessage(String content) {
    if (state.isEmpty) return;

    final lastMessage = state.last;
    if (lastMessage.role != 'assistant') return;

    state = [
      ...state.sublist(0, state.length - 1),
      lastMessage.copyWith(content: _stripStreamingPlaceholders(content)),
    ];
    _syncStreamingProfileWithState();
    _touchStreamingActivity();
  }

  void updateLastMessageWithFunction(
    ChatMessage Function(ChatMessage) updater,
  ) {
    if (state.isEmpty) return;

    final lastMessage = state.last;
    if (lastMessage.role != 'assistant') return;
    final bufferedLastMessage = _messageWithBufferedStreamingContent(
      lastMessage,
    );
    final updated = updater(bufferedLastMessage);
    if (identical(updated, lastMessage)) {
      return;
    }
    state = [...state.sublist(0, state.length - 1), updated];
    if (updated.isStreaming) {
      _syncStreamingProfileWithState();
      _touchStreamingActivity();
    } else {
      _finishStreamingProfile(
        reason: 'updated_non_streaming',
        message: updated,
      );
    }
  }

  void updateMessageById(
    String messageId,
    ChatMessage Function(ChatMessage current) updater,
  ) {
    final index = state.indexWhere((m) => m.id == messageId);
    if (index == -1) return;
    final original = state[index];
    final bufferedOriginal = _messageWithBufferedStreamingContent(original);
    final updated = updater(bufferedOriginal);
    if (identical(updated, original)) {
      return;
    }
    final next = [...state];
    next[index] = updated;
    state = next;
  }

  Map<String, dynamic>? _metadataWithoutResponseDone(
    Map<String, dynamic>? metadata,
  ) {
    if (metadata == null || metadata.isEmpty) {
      return metadata;
    }
    final next = Map<String, dynamic>.from(metadata);
    next.remove('responseDone');
    return next.isEmpty ? null : next;
  }

  // Archive the last assistant message's current content as a previous version
  // and clear it to prepare for regeneration, keeping the same message id.
  void archiveLastAssistantAsVersion() {
    if (state.isEmpty) return;
    final last = state.last;
    if (last.role != 'assistant') return;
    // Do not archive if it's already streaming (nothing final to archive)
    if (last.isStreaming) return;

    final updated = last.copyWith(
      // Start a fresh stream for the new generation
      isStreaming: true,
      metadata: _metadataWithoutResponseDone(last.metadata),
      content: '',
      files: null,
      followUps: const [],
      codeExecutions: const [],
      sources: const [],
      usage: null,
      error: null, // Clear error for new generation
      versions: _buildReplayVersions(last),
    );

    state = [...state.sublist(0, state.length - 1), updated];
    _beginStreamingProfile(updated);
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
        if (_statusUpdatesEquivalent(last, withTimestamp)) {
          return current;
        }
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
      if (listEquals(current.followUps, followUps)) {
        return current;
      }
      return current.copyWith(followUps: List<String>.from(followUps));
    });
  }

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
    if (content.isEmpty) return;

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
    _markStreamingBufferChanged();
    _recordStreamingChunk(content);

    _scheduleStreamingContentUpdate();
    _syncStreamingProfileWithBufferedContent();
    _touchStreamingActivity();
  }

  void _scheduleStreamingContentUpdate() {
    if (_disposed || _streamingBuffer == null) {
      return;
    }
    final currentVisible = ref.read(streamingContentProvider);
    if (currentVisible == null || currentVisible.isEmpty) {
      _scheduleStreamingContentFrame();
      return;
    }
    if (_streamingContentFrameScheduled || _streamingContentTimer != null) {
      return;
    }
    final interval = _streamingContentUpdateIntervalForBuffer(
      _streamingBuffer!.length,
    );
    final lastFlushAt = _lastStreamingContentFlushAt;
    if (lastFlushAt == null) {
      _scheduleStreamingContentFrame();
      return;
    }
    final elapsed = DateTime.now().difference(lastFlushAt);
    final remaining = interval - elapsed;
    if (remaining <= Duration.zero) {
      _scheduleStreamingContentFrame();
      return;
    }
    _streamingContentTimer = Timer(remaining, _scheduleStreamingContentFrame);
  }

  Duration _streamingContentUpdateIntervalForBuffer(int length) {
    final isMobileTarget =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    return _streamingContentUpdateIntervalForTarget(
      length,
      isMobileTarget: isMobileTarget,
    );
  }

  void _scheduleStreamingContentFrame() {
    _streamingContentTimer?.cancel();
    _streamingContentTimer = null;
    if (_disposed || _streamingContentFrameScheduled) {
      return;
    }
    _streamingContentFrameScheduled = true;
    SchedulerBinding.instance.scheduleFrame();
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _streamingContentFrameScheduled = false;
      if (_disposed) {
        return;
      }
      _flushStreamingContentUpdate();
    });
  }

  void _flushStreamingContentUpdate() {
    if (_disposed) {
      return;
    }
    final buffer = _streamingBuffer;
    if (buffer == null) return;
    if (_streamingBufferVersion == _lastFlushedStreamingBufferVersion) {
      return;
    }
    final nextContent = buffer.toString();
    if (ref.read(streamingContentProvider) == nextContent) {
      _lastFlushedStreamingBufferVersion = _streamingBufferVersion;
      return;
    }
    _lastStreamingContentFlushAt = DateTime.now();
    _lastFlushedStreamingBufferVersion = _streamingBufferVersion;
    ref.read(streamingContentProvider.notifier).set(nextContent);
  }

  ChatMessage _messageWithBufferedStreamingContent(ChatMessage message) {
    final buffer = _streamingBuffer;
    if (buffer == null ||
        state.isEmpty ||
        message.role != 'assistant' ||
        !message.isStreaming) {
      return message;
    }

    final lastMessage = state.last;
    if (lastMessage.id != message.id ||
        lastMessage.role != 'assistant' ||
        !lastMessage.isStreaming) {
      return message;
    }

    final accumulated = buffer.toString();
    if (accumulated == message.content) {
      return message;
    }

    return message.copyWith(content: accumulated);
  }

  ({ChatMessage? message, String comparisonContent})
  _readStreamingMessageComparisonSnapshot(String messageId) {
    _streamingContentTimer?.cancel();
    _streamingContentTimer = null;
    _flushStreamingContentUpdate();
    _syncStreamingBufferToState();

    final refreshedMessage = state
        .where((message) => message.id == messageId)
        .firstOrNull;
    if (refreshedMessage == null) {
      return (message: null, comparisonContent: '');
    }

    var comparisonContent = refreshedMessage.content;
    final visibleContent = ref.read(streamingContentProvider);
    if (visibleContent != null &&
        visibleContent.isNotEmpty &&
        visibleContent.length >= comparisonContent.length) {
      comparisonContent = visibleContent;
    }

    return (message: refreshedMessage, comparisonContent: comparisonContent);
  }

  /// Syncs the accumulated streaming buffer content into
  /// the message list state.
  void _syncStreamingBufferToState() {
    if (_streamingBuffer == null || state.isEmpty) {
      return;
    }
    final lastMessage = state.last;
    if (lastMessage.role != 'assistant' || !lastMessage.isStreaming) {
      return;
    }
    final bufferedLastMessage = _messageWithBufferedStreamingContent(
      lastMessage,
    );
    if (identical(bufferedLastMessage, lastMessage)) return;

    state = [...state.sublist(0, state.length - 1), bufferedLastMessage];
    _syncStreamingProfileWithState();
  }

  /// Flushes any pending streaming buffer content into the
  /// message list state.
  ///
  /// Called by the streaming helper before completion checks
  /// to ensure buffered delta content is visible in the
  /// Riverpod state.
  void syncStreamingBuffer() => _syncStreamingBufferToState();

  /// Buffers a full replacement for the active streaming assistant message.
  ///
  /// This is used for generated content that must replace the visible
  /// streaming text, such as an in-progress reasoning block. The live widget
  /// still receives frequent updates through [streamingContentProvider]. The
  /// canonical message list is updated only when the stream is explicitly
  /// flushed or completed.
  void bufferLastMessageContent(String content) {
    if (state.isEmpty) return;

    final lastMessage = state.last;
    if (lastMessage.role != 'assistant' || !lastMessage.isStreaming) return;

    final sanitized = _stripStreamingPlaceholders(content);
    if (_streamingBuffer?.toString() == sanitized) {
      return;
    }
    _streamingBuffer = StringBuffer(sanitized);
    _markStreamingBufferChanged();
    _scheduleStreamingContentUpdate();
    _touchStreamingActivity();
    _syncStreamingProfileWithBufferedContent();
  }

  void replaceLastMessageContent(String content) {
    if (state.isEmpty) return;

    final lastMessage = state.last;
    if (lastMessage.role != 'assistant') return;

    final sanitized = _stripStreamingPlaceholders(content);
    if (!lastMessage.isStreaming) {
      state = [
        ...state.sublist(0, state.length - 1),
        lastMessage.copyWith(content: sanitized),
      ];
      _syncStreamingProfileWithState();
      _touchStreamingActivity();
      return;
    }
    if (_streamingBuffer?.toString() == sanitized) {
      return;
    }
    _streamingBuffer = StringBuffer(sanitized);
    _markStreamingBufferChanged();
    _scheduleStreamingContentUpdate();
    _touchStreamingActivity();
    _syncStreamingProfileWithBufferedContent();
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
        updatedLast = updatedLast.copyWith(
          versions: _buildReplayVersions(prev),
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

    // Skip server cache refresh for temporary or no-active-conversation chats.
    if (activeConversation != null && !isTemporaryChat(activeConversation.id)) {
      try {
        refreshConversationsCache(ref);
      } catch (_) {}
    }
  }

  void _completeStreamingMessage({required bool releaseTransport}) {
    _streamingContentTimer?.cancel();
    _streamingContentTimer = null;
    _flushStreamingContentUpdate();
    _streamingSyncTimer?.cancel();
    _streamingSyncTimer = null;
    final bufferedLastMessage = state.isEmpty
        ? null
        : _messageWithBufferedStreamingContent(state.last);
    _clearStreamingBuffer();
    _clearStreamingContent();

    if (state.isEmpty) {
      _finishStreamingProfile(reason: 'empty_state');
      if (releaseTransport) {
        _messageStream = null;
        _activeStreamingTransportMessageId = null;
        cancelSocketSubscriptions();
        _stopRemoteTaskMonitor();
      }
      return;
    }

    final lastMessage = bufferedLastMessage ?? state.last;
    if (lastMessage.role != 'assistant' || !lastMessage.isStreaming) {
      _finishStreamingProfile(reason: 'not_streaming', message: lastMessage);
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
    _finishStreamingProfile(
      reason: releaseTransport ? 'completed' : 'ui_completed',
      message: state.lastOrNull,
    );

    if (releaseTransport) {
      _messageStream = null;
      _activeStreamingTransportMessageId = null;
      cancelSocketSubscriptions();
      _stopRemoteTaskMonitor();
    }

    _syncConversationStateAfterStreamingUpdate();
    _persistCompletedTurn();
  }

  void completeStreamingUi() {
    _completeStreamingMessage(releaseTransport: false);
  }

  void finishStreaming() {
    _completeStreamingMessage(releaseTransport: true);
  }

  /// D-07 local echo: after a stream lands, write the trailing user message
  /// and the completed assistant message to the local database under the
  /// chat lock. The rows are plain local echoes the next pull fast-forwards
  /// over (no dirty flag in Phase 1; outbox semantics arrive in Phase 2).
  /// Silently no-ops for temporary chats and when the chats row is absent
  /// (`upsertLocalEcho` returns false).
  void _persistCompletedTurn() {
    final activeId = ref.read(activeConversationProvider)?.id;
    if (activeId == null || activeId.isEmpty || isTemporaryChat(activeId)) {
      return;
    }
    final db = _maybeDatabase();
    if (db == null) {
      return;
    }
    final messages = state;
    if (messages.isEmpty) {
      return;
    }
    final assistant = messages.last;
    if (assistant.role != 'assistant' || assistant.isStreaming) {
      return;
    }
    final trailingUser = _trailingUserMessage(messages);
    final ChatLocks locks;
    try {
      locks = ref.read(chatLocksProvider);
    } catch (_) {
      return;
    }
    unawaited(
      _writeTurnEcho(
        db: db,
        locks: locks,
        chatId: activeId,
        trailingUser: trailingUser,
        assistant: assistant,
      ),
    );
  }

  /// D-07 pause checkpoint: when the app backgrounds mid-stream, flush the
  /// streaming buffer into state and echo the in-flight turn so a process
  /// kill cannot lose it. No-op unless a stream is active; silently no-ops
  /// when the chats row is absent.
  Future<void> persistPauseCheckpoint() async {
    if (!_hasStreamingAssistant) {
      return;
    }
    final activeId = ref.read(activeConversationProvider)?.id;
    if (activeId == null || activeId.isEmpty || isTemporaryChat(activeId)) {
      return;
    }
    final db = _maybeDatabase();
    if (db == null) {
      return;
    }
    syncStreamingBuffer();
    final messages = state;
    if (messages.isEmpty) {
      return;
    }
    final assistant = messages.last;
    if (assistant.role != 'assistant') {
      return;
    }
    final trailingUser = _trailingUserMessage(messages);
    final ChatLocks locks;
    try {
      locks = ref.read(chatLocksProvider);
    } catch (_) {
      return;
    }
    await _writeTurnEcho(
      db: db,
      locks: locks,
      chatId: activeId,
      trailingUser: trailingUser,
      assistant: assistant,
    );
  }

  Future<void> _writeTurnEcho({
    required AppDatabase db,
    required ChatLocks locks,
    required String chatId,
    required ChatMessage? trailingUser,
    required ChatMessage assistant,
  }) async {
    try {
      await locks.runExclusive(chatId, () async {
        await db.messagesDao.upsertLocalEchoTurn(
          chatId: chatId,
          user: trailingUser == null
              ? null
              : _localEchoRow(chatId, trailingUser),
          assistant: _localEchoRow(chatId, assistant),
        );
      });
    } catch (error, stackTrace) {
      DebugLogger.error(
        'turn-echo-failed',
        scope: 'chat/providers',
        error: error,
        stackTrace: stackTrace,
        data: {'chatId': chatId},
      );
    }
  }

  ChatMessage? _trailingUserMessage(List<ChatMessage> messages) {
    for (var index = messages.length - 1; index >= 0; index -= 1) {
      if (messages[index].role == 'user') {
        return messages[index];
      }
    }
    return null;
  }

  /// Minimal history-message shape (`{id, parentId, childrenIds, role,
  /// content, timestamp, model?}`) — explicitly a local echo.
  ///
  /// The `parentId` written here is only a placeholder for the payload map:
  /// `MessagesDao.upsertLocalEchoTurn` re-parents these rows via `_withParent`,
  /// rewriting both the row and `payload['parentId']` to the branch tip.
  MessageRowData _localEchoRow(String chatId, ChatMessage message) {
    final timestamp = message.timestamp.millisecondsSinceEpoch ~/ 1000;
    final resolvedParentId = message_tree.chatMessageParentId(message);
    final childrenIds = message_tree
        .chatMessageChildrenIds(message)
        .toList(growable: false);
    return MessageRowData(
      id: message.id,
      chatId: chatId,
      parentId: resolvedParentId,
      role: message.role,
      content: message.content,
      model: message.model,
      createdAt: timestamp,
      // Recomputed by upsertLocalEcho for new rows.
      orderIndex: 0,
      payload: <String, dynamic>{
        'id': message.id,
        'parentId': resolvedParentId,
        'childrenIds': childrenIds,
        'role': message.role,
        'content': message.content,
        'timestamp': timestamp,
        'isStreaming': message.isStreaming,
        if (message.role == 'assistant' && !message.isStreaming) 'done': true,
        if (message.model != null) 'model': message.model,
        if (message.metadata != null && message.metadata!.isNotEmpty)
          'metadata': message.metadata,
      },
    );
  }
}

bool _shouldIncludeConversationHistoryMessage(ChatMessage message) {
  if (message.role.isEmpty || message.content.isEmpty) {
    return false;
  }
  if (message.role != 'assistant') {
    return true;
  }
  return assistantMessageResponseCompleted(message);
}

bool _isArchivedAssistantVariant(ChatMessage message) {
  return message.role == 'assistant' &&
      message.metadata?['archivedVariant'] == true;
}

ChatMessageVersion _buildAssistantVersionSnapshot(ChatMessage message) {
  return ChatMessageVersion(
    id: message.id,
    content: message.content,
    timestamp: message.timestamp,
    model: message.model,
    modelName: _messageModelName(message),
    files: message.files == null
        ? null
        : List<Map<String, dynamic>>.from(message.files!),
    output: message.output == null
        ? null
        : List<Map<String, dynamic>>.from(message.output!),
    embeds: message.embeds == null
        ? null
        : List<Map<String, dynamic>>.from(message.embeds!),
    sources: List<ChatSourceReference>.from(message.sources),
    followUps: List<String>.from(message.followUps),
    codeExecutions: List<ChatCodeExecution>.from(message.codeExecutions),
    usage: message.usage == null
        ? null
        : Map<String, dynamic>.from(message.usage!),
    error: message.error,
  );
}

String? _messageModelName(ChatMessage message) {
  final raw = message.metadata?['modelName'] ?? message.metadata?['model_name'];
  final value = raw?.toString().trim();
  return value == null || value.isEmpty ? null : value;
}

List<ChatMessageVersion> _buildReplayVersions(ChatMessage message) {
  return [...message.versions, _buildAssistantVersionSnapshot(message)];
}

// Pre-seed an assistant skeleton message (with a given id or a new one) and
// return the id. Persisted chats rely on `/api/chat/completions` to update the
// server-side history; pushing the local buffer back first can truncate chats
// when the client has only partially loaded history.
Future<String> _preseedAssistantAndPersist(
  dynamic ref, {
  String? existingAssistantId,
  required String modelId,
  String? modelName,
}) async {
  // Choose id: reuse existing if provided, else create new
  final String assistantMessageId =
      (existingAssistantId != null && existingAssistantId.isNotEmpty)
      ? existingAssistantId
      : const Uuid().v4();

  final trimmedModelName = modelName?.trim();
  final modelNameMetadata = <String, dynamic>{
    if (trimmedModelName != null && trimmedModelName.isNotEmpty)
      'modelName': trimmedModelName,
  };

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
      metadata: modelNameMetadata,
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
        final notifier =
            ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier;
        notifier.updateLastMessageWithFunction(
          (ChatMessage m) => m.copyWith(
            isStreaming: true,
            metadata: {
              ...?notifier._metadataWithoutResponseDone(m.metadata),
              ...modelNameMetadata,
            },
          ),
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

Future<Map<String, dynamic>> _buildOpenWebUiPromptVariablesForRequest(
  dynamic ref, {
  required DateTime now,
  required Map<String, dynamic>? userSettings,
}) async {
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
    final locationService = ref.read(locationServiceProvider);
    final api = ref.read(apiServiceProvider);
    userLocation = await locationService.resolveLocationForUserSettings(
      userSettings,
      api: api,
    );
  } catch (error, stackTrace) {
    DebugLogger.error(
      'Failed to resolve user location',
      scope: 'chat/providers',
      error: error,
      stackTrace: stackTrace,
    );
  }

  return _buildOpenWebUiPromptVariables(
    now: now,
    userName: userName,
    userEmail: userEmail,
    userLanguage: userLanguage,
    userLocation: userLocation,
  );
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
  final parentId =
      message_tree.chatMessageParentId(userMessage) ?? previousMessage?.id;
  final childrenIds = message_tree
      .chatMessageChildrenIds(userMessage)
      .toList(growable: true);
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

/// Builds the chat-completion request `messages` for both the foreground
/// ([runQueuedCompletion]) and headless ([runHeadlessCompletion]) paths:
/// rebuild the live conversation history (skip archived/non-history rows,
/// sanitize content, merge attachment/file/output payloads), prepend the
/// effective system message (conversation prompt, falling back to the user
/// prompt) when one is absent, then apply [_buildChatCompletionMessages].
Future<List<Map<String, dynamic>>> _buildCompletionRequestMessages({
  required dynamic api,
  required List<ChatMessage> messages,
  required String? conversationSystemPrompt,
  required String? userSystemPrompt,
  required bool isTemporary,
}) async {
  final conversationMessages = <Map<String, dynamic>>[];
  for (final msg in messages) {
    if (_isArchivedAssistantVariant(msg)) continue;
    if (!_shouldIncludeConversationHistoryMessage(msg)) continue;
    final cleaned = ToolCallsParser.sanitizeForApi(msg.content);
    final attachments = msg.attachmentIds ?? const <String>[];
    if (attachments.isNotEmpty) {
      final messageMap = await _buildMessagePayloadWithAttachments(
        api: api,
        role: msg.role,
        cleanedText: cleaned,
        attachmentIds: attachments,
      );
      if (msg.files != null && msg.files!.isNotEmpty) {
        final raw = messageMap['files'];
        final existing = raw is List
            ? raw.whereType<Map<String, dynamic>>().toList()
            : <Map<String, dynamic>>[];
        messageMap['files'] = [...existing, ...msg.files!];
      }
      if (msg.output != null && msg.output!.isNotEmpty) {
        messageMap['output'] = msg.output;
      }
      conversationMessages.add(messageMap);
    } else {
      conversationMessages.add({
        'role': msg.role,
        'content': cleaned,
        if (msg.files != null) 'files': msg.files,
        if (msg.output != null) 'output': msg.output,
      });
    }
  }

  final convSystemPrompt = conversationSystemPrompt?.trim();
  final effectiveSystemPrompt =
      (convSystemPrompt != null && convSystemPrompt.isNotEmpty)
      ? convSystemPrompt
      : userSystemPrompt;
  if (effectiveSystemPrompt != null && effectiveSystemPrompt.isNotEmpty) {
    final hasSystem = conversationMessages.any(
      (m) => (m['role']?.toString().toLowerCase() ?? '') == 'system',
    );
    if (!hasSystem) {
      conversationMessages.insert(0, {
        'role': 'system',
        'content': effectiveSystemPrompt,
      });
    }
  }

  return _buildChatCompletionMessages(
    conversationMessages: conversationMessages,
    isTemporary: isTemporary,
  );
}

/// Last `user`-role message id in [messages], scanning newest-first; `null`
/// when none exists.
String? _lastUserMessageId(List<ChatMessage> messages) {
  for (int i = messages.length - 1; i >= 0; i--) {
    if (messages[i].role == 'user') {
      return messages[i].id;
    }
  }
  return null;
}

/// Whether [modelId] looks like a reasoning model, based on common naming
/// patterns (o1/o3/deepseek-r1/reasoning/think).
bool _modelUsesReasoning(String modelId) {
  final m = modelId.toLowerCase();
  return m.contains('o1') ||
      m.contains('o3') ||
      m.contains('deepseek-r1') ||
      m.contains('reasoning') ||
      m.contains('think');
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

  final settings = ref.read(appSettingsProvider);
  ref
      .read(temporaryChatEnabledProvider.notifier)
      .set(settings.temporaryChatByDefault);
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
    if (ref is Ref && !ref.mounted) return;
    await storage.saveLocalDefaultModel(null);
    if (ref is Ref && !ref.mounted) return;
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

typedef _ChatFeatureDefaults = ({
  bool webSearchEnabled,
  bool imageGenerationEnabled,
  bool codeInterpreterEnabled,
});

Map<String, dynamic>? _asStringDynamicMap(dynamic value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return value.map((key, value) => MapEntry(key.toString(), value));
  }
  return null;
}

Iterable<String> _stringList(dynamic value) {
  if (value is! List) {
    return const <String>[];
  }
  return value.map((item) => item.toString());
}

bool _isAlwaysOnChatFeatureSetting(
  Map<String, dynamic>? userSettings, {
  required String uiKey,
  required String legacyKey,
}) {
  final uiMap = _asStringDynamicMap(userSettings?['ui']);
  final raw = uiMap?[uiKey] ?? userSettings?[legacyKey];

  if (raw is bool) {
    return raw;
  }
  if (raw is num) {
    return raw != 0;
  }
  if (raw is String) {
    switch (raw.toLowerCase()) {
      case 'always':
      case 'enabled':
      case 'on':
      case 'true':
      case '1':
        return true;
      default:
        return false;
    }
  }
  return false;
}

Set<String> _extractModelDefaultFeatureIds(Model? model) {
  final metadata = model?.metadata;
  final rootMeta = _asStringDynamicMap(metadata?['meta']);
  final infoMeta = _asStringDynamicMap(
    _asStringDynamicMap(metadata?['info'])?['meta'],
  );
  final defaultFeatureIds = <String>{};

  for (final candidate in <dynamic>[
    metadata?['defaultFeatureIds'],
    metadata?['default_feature_ids'],
    rootMeta?['defaultFeatureIds'],
    rootMeta?['default_feature_ids'],
    infoMeta?['defaultFeatureIds'],
    infoMeta?['default_feature_ids'],
  ]) {
    defaultFeatureIds.addAll(_stringList(candidate));
  }

  return defaultFeatureIds;
}

_ChatFeatureDefaults _resolveChatFeatureDefaults({
  required AppSettings appSettings,
  required Map<String, dynamic>? userSettings,
  required Model? model,
}) {
  final defaultFeatureIds = _extractModelDefaultFeatureIds(model);
  final webSearchDefault =
      _isAlwaysOnChatFeatureSetting(
        userSettings,
        uiKey: 'webSearch',
        legacyKey: 'webSearchEnabled',
      ) ||
      defaultFeatureIds.contains('web_search');
  final imageGenerationDefault =
      _isAlwaysOnChatFeatureSetting(
        userSettings,
        uiKey: 'imageGeneration',
        legacyKey: 'imageGenerationEnabled',
      ) ||
      defaultFeatureIds.contains('image_generation');
  final codeInterpreterDefault =
      _isAlwaysOnChatFeatureSetting(
        userSettings,
        uiKey: 'codeInterpreter',
        legacyKey: 'codeInterpreterEnabled',
      ) ||
      defaultFeatureIds.contains('code_interpreter');

  return (
    webSearchEnabled: appSettings.chatWebSearchEnabled ?? webSearchDefault,
    imageGenerationEnabled:
        appSettings.chatImageGenerationEnabled ?? imageGenerationDefault,
    codeInterpreterEnabled:
        appSettings.chatCodeInterpreterEnabled ?? codeInterpreterDefault,
  );
}

@visibleForTesting
({
  bool webSearchEnabled,
  bool imageGenerationEnabled,
  bool codeInterpreterEnabled,
})
resolveChatFeatureDefaultsForTest({
  required AppSettings appSettings,
  Map<String, dynamic>? userSettings,
  Model? model,
}) {
  return _resolveChatFeatureDefaults(
    appSettings: appSettings,
    userSettings: userSettings,
    model: model,
  );
}

final _chatFeatureDefaultsProvider = Provider<_ChatFeatureDefaults>((ref) {
  final appSettings = ref.watch(appSettingsProvider);
  final userSettings = ref.watch(rawUserSettingsProvider).asData?.value;
  final selectedModel = ref.watch(selectedModelProvider);
  return _resolveChatFeatureDefaults(
    appSettings: appSettings,
    userSettings: userSettings,
    model: selectedModel,
  );
});

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
            final mimeType = contentType.isNotEmpty
                ? contentType.toString()
                : _getMimeTypeFromFileName(fileName) ?? 'image/png';
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
        final filePayload = <String, dynamic>{
          'type': 'file',
          'id': attachmentId,
          // OpenWebUI now stores just the file ID, not the full URL path
          'url': attachmentId,
          'name': fileName,
        };
        if (fileSize != null) {
          filePayload['size'] = fileSize;
        }
        allFiles.add(filePayload);
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

String? _getMimeTypeFromFileName(String fileName) {
  final ext = fileName.toLowerCase().split('.').last;
  return switch (ext) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'svg' => 'image/svg+xml',
    'bmp' => 'image/bmp',
    _ => null,
  };
}

@visibleForTesting
String? mimeTypeFromFileNameForTest(String fileName) {
  return _getMimeTypeFromFileName(fileName);
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
      metadata: {'modelName': selectedModel.name},
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

    // Include selected tool ids so provider-native tool calling is triggered
    final selectedToolIds = ref.read(selectedToolIdsProvider);
    final toolIdsForApi = _extractToolIdsForApi(selectedToolIds);
    final selectedTerminalId = ref.read(selectedTerminalIdProvider);
    // Include selected filter ids (toggle filters enabled by user)
    final selectedFilterIds = ref.read(selectedFilterIdsProvider);
    // Get conversation history for context, skipping archived variants that are
    // kept locally only for the version switcher.
    final List<ChatMessage> messages = ref.read(chatMessagesProvider);
    final List<Map<String, dynamic>> conversationMessages =
        <Map<String, dynamic>>[];
    var lastUserIndex = -1;
    for (var index = messages.length - 1; index >= 0; index--) {
      if (messages[index].role == 'user') {
        lastUserIndex = index;
        break;
      }
    }

    for (int i = 0; i < messages.length; i++) {
      final msg = messages[i];
      if (_isArchivedAssistantVariant(msg)) {
        continue;
      }
      if (_shouldIncludeConversationHistoryMessage(msg)) {
        final cleaned = ToolCallsParser.sanitizeForApi(msg.content);

        // Prefer provided attachments for the last user message; otherwise use message attachments
        final bool isLastUser = i == lastUserIndex && msg.role == 'user';
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
            if (msg.files != null) 'files': msg.files,
            if (msg.output != null) 'output': msg.output,
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
      modelName: selectedModel.name,
    );

    // Attach previous assistant as a version snapshot to the new assistant
    try {
      final msgs = ref.read(chatMessagesProvider);
      if (msgs.length >= 2) {
        final prev = msgs[msgs.length - 2];
        final last = msgs.last;
        if (prev.role == 'assistant' && last.id == assistantMessageId) {
          (ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier)
              .updateLastMessageWithFunction(
                (ChatMessage m) =>
                    m.copyWith(versions: _buildReplayVersions(prev)),
              );
        }
      }
    } catch (_) {}

    // Feature toggles
    final webSearchEnabled =
        ref.read(webSearchEnabledProvider) &&
        ref.read(webSearchAvailableProvider);
    final imageGenerationEnabled =
        ref.read(imageGenerationEnabledProvider) &&
        ref.read(imageGenerationAvailableProvider);
    final codeInterpreterEnabled =
        ref.read(codeInterpreterEnabledProvider) &&
        ref.read(codeInterpreterAvailableProvider);

    final modelItem = _buildLocalModelItem(selectedModel);

    // Reconnect before choosing session_id so eligible sends stay on the
    // task/socket transport instead of falling back to fragile HTTP streaming.
    final socketService = ref.read(socketServiceProvider);
    final socketSessionId = await _ensureConnectedSocketSessionId(
      socketService,
    );

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
      promptVars2 = await _buildOpenWebUiPromptVariablesForRequest(
        ref,
        now: DateTime.now(),
        userSettings: userSettingsData,
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
        enableCodeInterpreter: codeInterpreterEnabled,
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

      final modelUsesReasoning = _modelUsesReasoning(selectedModel.id);

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

/// Drives the EXISTING streaming pipeline for a turn whose rows already exist
/// (the user message + assistant placeholder are in the DB and loaded into
/// `chatMessagesProvider`). The SHARED streaming tail used by both the queued
/// completion runner (Wiring D) and — over time — the interactive send paths,
/// so there is exactly ONE `sendMessageSession`/`dispatchChatTransport`
/// dispatch path.
///
/// It rebuilds `requestMessages` LIVE from `chatMessagesProvider` rows (never
/// snapshots), passes [assistantMessageId] as `responseMessageId` (load-bearing
/// for the R8 one-row-per-turn guarantee), and does NOT mint a new assistant id
/// nor re-add the user message. Caller has already ensured the placeholder is
/// the last message and marked streaming (via [_preseedAssistantAndPersist]).
Future<void> runQueuedCompletion(
  dynamic ref, {
  required String chatId,
  required String assistantMessageId,
  required String model,
  List<String> toolIds = const <String>[],
  List<String> filterIds = const <String>[],
  String? terminalId,
  bool enableWebSearch = false,
  bool enableImageGeneration = false,
  bool enableCodeInterpreter = false,
  String? sessionIdOverride,
}) async {
  final api = ref.read(apiServiceProvider);
  if (api == null) {
    throw StateError('runQueuedCompletion requires an API service');
  }
  final selectedModel = ref.read(selectedModelProvider);
  // Empty model => fall back to the selected default model (mirrors the
  // migrator's empty-model contract). A still-empty model is a hard error.
  final effectiveModelId = model.isNotEmpty ? model : (selectedModel?.id ?? '');
  final effectiveModelName = selectedModel?.id == effectiveModelId
      ? selectedModel?.name
      : null;
  if (effectiveModelId.isEmpty) {
    throw StateError('runQueuedCompletion has no model to send');
  }

  final activeConversation = ref.read(activeConversationProvider);
  if (activeConversation == null || activeConversation.id != chatId) {
    // The caller (runner) activates the chat before driving; a mismatch means
    // the active chat changed under us — let the op retry on a later drain.
    throw _QueuedCompletionDeferred(
      'runQueuedCompletion: chat $chatId is not active',
    );
  }

  Map<String, dynamic>? userSettingsData;
  String? userSystemPrompt;
  try {
    userSettingsData = await api.getUserSettings();
    userSystemPrompt = _extractSystemPromptFromSettings(userSettingsData);
  } catch (_) {}

  final toolIdsForApi = _extractToolIdsForApi(toolIds);
  final selectedFilterIds = filterIds;

  // Rebuild the conversation history LIVE from the loaded rows (§3.iii).
  final List<ChatMessage> messages = ref.read(chatMessagesProvider);
  final isTemporary =
      isTemporaryChat(activeConversation.id) ||
      ref.read(temporaryChatEnabledProvider);
  final requestMessages = await _buildCompletionRequestMessages(
    api: api,
    messages: messages,
    conversationSystemPrompt: activeConversation.systemPrompt,
    userSystemPrompt: userSystemPrompt,
    isTemporary: isTemporary,
  );

  // Ensure the (already-existing) assistant placeholder is loaded + streaming.
  await _preseedAssistantAndPersist(
    ref,
    existingAssistantId: assistantMessageId,
    modelId: effectiveModelId,
    modelName: effectiveModelName,
  );

  final Map<String, dynamic> modelItem =
      (selectedModel != null && selectedModel.id == effectiveModelId)
      ? _buildLocalModelItem(selectedModel)
      : <String, dynamic>{'id': effectiveModelId, 'name': effectiveModelId};

  final socketService = ref.read(socketServiceProvider);
  final socketSessionId =
      sessionIdOverride ?? await _ensureConnectedSocketSessionId(socketService);

  List<Map<String, dynamic>>? toolServers;
  try {
    toolServers = await _resolveToolServersForRequest(
      api: api,
      userSettings: userSettingsData,
      selectedToolIds: toolIds,
    );
  } catch (_) {}

  final bgTasks = _buildOpenWebUiBackgroundTasks(
    userSettings: userSettingsData,
    shouldGenerateTitle: false,
    webSearchEnabled: enableWebSearch,
    imageGenerationEnabled: enableImageGeneration,
  );

  final bool isBackgroundToolsFlowPre =
      toolIdsForApi.isNotEmpty ||
      terminalId != null ||
      (toolServers != null && toolServers.isNotEmpty);

  final lastUserMessageId = _lastUserMessageId(messages);

  Map<String, dynamic>? promptVars2;
  Map<String, dynamic>? parentMsgMap;
  try {
    promptVars2 = await _buildOpenWebUiPromptVariablesForRequest(
      ref,
      now: DateTime.now(),
      userSettings: userSettingsData,
    );
  } catch (_) {}
  try {
    parentMsgMap = _buildOpenWebUiUserMessage(
      messages: messages,
      userMessageId: lastUserMessageId,
      modelId: effectiveModelId,
      assistantChildMessageId: assistantMessageId,
    );
  } catch (_) {}

  socketService?.startBuffering(
    chatId,
    sessionId: socketSessionId,
    messageId: assistantMessageId,
  );

  try {
    final session = await api.sendMessageSession(
      messages: requestMessages,
      model: effectiveModelId,
      conversationId: chatId,
      terminalId: terminalId,
      toolIds: toolIdsForApi.isNotEmpty ? toolIdsForApi : null,
      filterIds: selectedFilterIds.isNotEmpty ? selectedFilterIds : null,
      enableWebSearch: enableWebSearch,
      enableImageGeneration: enableImageGeneration,
      enableCodeInterpreter: enableCodeInterpreter,
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

    final modelUsesReasoning = _modelUsesReasoning(effectiveModelId);

    final bool isBackgroundFlow =
        isBackgroundToolsFlowPre ||
        enableWebSearch ||
        enableImageGeneration ||
        bgTasks.isNotEmpty;

    await dispatchChatTransport(
      ref: ref,
      session: session,
      assistantMessageId: assistantMessageId,
      modelId: effectiveModelId,
      modelItem: modelItem,
      activeConversationId: chatId,
      api: api,
      socketService: socketService,
      workerManager: ref.read(workerManagerProvider),
      webSearchEnabled: enableWebSearch,
      imageGenerationEnabled: enableImageGeneration,
      isBackgroundFlow: isBackgroundFlow,
      modelUsesReasoning: modelUsesReasoning,
      toolsEnabled:
          toolIdsForApi.isNotEmpty ||
          terminalId != null ||
          (toolServers != null && toolServers.isNotEmpty) ||
          enableImageGeneration,
      isTemporary: isTemporary,
      filterIds: selectedFilterIds.isNotEmpty ? selectedFilterIds : null,
    );
  } finally {
    socketService?.stopBuffering(
      chatId,
      sessionId: socketSessionId,
      messageId: assistantMessageId,
    );
  }
}

/// HEADLESS completion (CDT-RFC-001 Option B). Drives a queued
/// `requestCompletion` for a chat the user is NOT looking at WITHOUT touching
/// the global UI providers (no active-conversation switch, no
/// chatMessagesProvider mutation).
///
/// This is feasible because Open WebUI persists the assistant message
/// SERVER-SIDE during the completion (`upsert_message_to_chat_by_id...` in the
/// server's `utils/middleware.py`; the outlet handler "replaces the POST
/// /api/chat/completed round-trip"). Verified live: firing the completion and
/// DISCARDING every stream chunk still leaves the full reply persisted on the
/// chat. So the client only has to: build the request from the DB rows, fire
/// it, drain the stream to EOF so the server runs to completion, then PULL the
/// chat to merge the server-persisted reply into the local DB (Phase 3 merge).
///
/// No second streaming implementation; the rich-field accumulation lives on the
/// server. [messages] is the target chat's history (DB-derived), NOT
/// `chatMessagesProvider` (which holds whatever chat the user is viewing).
Future<void> runHeadlessCompletion(
  dynamic ref, {
  required String chatId,
  required String assistantMessageId,
  required List<ChatMessage> messages,
  required Conversation conversation,
  required String model,
  List<String> toolIds = const <String>[],
  List<String> filterIds = const <String>[],
  String? terminalId,
  bool enableWebSearch = false,
  bool enableImageGeneration = false,
  bool enableCodeInterpreter = false,
  String? sessionIdOverride,
}) async {
  final api = ref.read(apiServiceProvider);
  if (api == null) {
    throw StateError('runHeadlessCompletion requires an API service');
  }
  final selectedModel = ref.read(selectedModelProvider);
  final effectiveModelId = model.isNotEmpty ? model : (selectedModel?.id ?? '');
  if (effectiveModelId.isEmpty) {
    throw StateError('runHeadlessCompletion has no model to send');
  }
  if (isTemporaryChat(chatId)) {
    // Temp chats are not persisted server-side, so headless persistence does
    // not apply; the caller never queues completions for them.
    return;
  }

  Map<String, dynamic>? userSettingsData;
  String? userSystemPrompt;
  try {
    userSettingsData = await api.getUserSettings();
    userSystemPrompt = _extractSystemPromptFromSettings(userSettingsData);
  } catch (_) {}

  final toolIdsForApi = _extractToolIdsForApi(toolIds);

  // Build the request history from the PASSED messages (the target chat's DB
  // rows), never the globally-active chat's provider state.
  final requestMessages = await _buildCompletionRequestMessages(
    api: api,
    messages: messages,
    conversationSystemPrompt: conversation.systemPrompt,
    userSystemPrompt: userSystemPrompt,
    isTemporary: false,
  );

  final modelItem =
      (selectedModel != null && selectedModel.id == effectiveModelId)
      ? _buildLocalModelItem(selectedModel)
      : <String, dynamic>{'id': effectiveModelId, 'name': effectiveModelId};

  final socketService = ref.read(socketServiceProvider);
  final socketSessionId =
      sessionIdOverride ?? await _ensureConnectedSocketSessionId(socketService);

  List<Map<String, dynamic>>? toolServers;
  try {
    toolServers = await _resolveToolServersForRequest(
      api: api,
      userSettings: userSettingsData,
      selectedToolIds: toolIds,
    );
  } catch (_) {}

  final bgTasks = _buildOpenWebUiBackgroundTasks(
    userSettings: userSettingsData,
    shouldGenerateTitle: false,
    webSearchEnabled: enableWebSearch,
    imageGenerationEnabled: enableImageGeneration,
  );

  final lastUserMessageId = _lastUserMessageId(messages);
  Map<String, dynamic>? promptVars;
  Map<String, dynamic>? parentMsgMap;
  try {
    promptVars = await _buildOpenWebUiPromptVariablesForRequest(
      ref,
      now: DateTime.now(),
      userSettings: userSettingsData,
    );
  } catch (_) {}
  try {
    parentMsgMap = _buildOpenWebUiUserMessage(
      messages: messages,
      userMessageId: lastUserMessageId,
      modelId: effectiveModelId,
      assistantChildMessageId: assistantMessageId,
    );
  } catch (_) {}

  final session = await api.sendMessageSession(
    messages: requestMessages,
    model: effectiveModelId,
    conversationId: chatId,
    terminalId: terminalId,
    toolIds: toolIdsForApi.isNotEmpty ? toolIdsForApi : null,
    filterIds: filterIds.isNotEmpty ? filterIds : null,
    enableWebSearch: enableWebSearch,
    enableImageGeneration: enableImageGeneration,
    enableCodeInterpreter: enableCodeInterpreter,
    modelItem: modelItem,
    sessionIdOverride: socketSessionId,
    toolServers: toolServers,
    backgroundTasks: bgTasks,
    responseMessageId: assistantMessageId,
    userSettings: userSettingsData,
    parentId: parentMsgMap?['parentId']?.toString(),
    userMessage: parentMsgMap,
    variables: promptVars,
    files: _extractTopLevelRequestFiles(parentMsgMap),
  );

  // Drain the HTTP byte stream to EOF (discarding chunks) so the server runs to
  // completion + persists. The socket/task flow has no byteStream — the server
  // generates it as a background task; the subsequent pull(s) collect it.
  final byteStream = session.byteStream;
  if (byteStream != null) {
    try {
      await byteStream.drain<void>().timeout(_headlessStreamDrainTimeout);
    } on TimeoutException catch (error) {
      DebugLogger.error(
        'headless-stream-drain-timeout',
        scope: 'chat/completion',
        error: error,
        data: {'chatId': chatId},
      );
      await _abortQuietly(session);
      throw _QueuedCompletionDeferred(
        'headless stream drain timed out for chat $chatId',
      );
    } catch (error) {
      DebugLogger.error(
        'headless-stream-drain-failed',
        scope: 'chat/completion',
        error: error,
        data: {'chatId': chatId},
      );
      await _abortQuietly(session);
      throw _QueuedCompletionDeferred(
        'headless stream drain failed for chat $chatId: $error',
      );
    }
  }

  await _markHeadlessCompletionSubmitted(
    ref,
    chatId: chatId,
    assistantMessageId: assistantMessageId,
  );

  // Pull the chat (bounded) until the server-persisted assistant reply lands
  // locally. The Phase 3 merge applies it under the chat lock. Both transport
  // flows persist the assistant message ASYNCHRONOUSLY (the server defaults
  // ENABLE_REALTIME_CHAT_SAVE=False, so even after the HTTP byte stream drains
  // to EOF the final upsert can trail the stream close), so BOTH paths poll
  // with a short backoff rather than trusting a single immediate pull. If it
  // still hasn't landed within the window the content is safe on the server and
  // the next sync cycle collects it — this only tightens the latency.
  final engine = ref.read(syncEngineProvider.notifier);
  for (var attempt = 0; attempt < 6; attempt++) {
    if (attempt > 0) await Future<void>.delayed(const Duration(seconds: 2));
    final convo = await engine.pullChatNow(chatId);
    final asst = convo?.messages
        .where((m) => m.id == assistantMessageId)
        .firstOrNull;
    if (asst != null && _headlessAssistantLanded(asst)) {
      DebugLogger.log(
        'headless-completion-landed',
        scope: 'chat/completion',
        data: {'chatId': chatId, 'attempt': attempt},
      );
      return;
    }
  }
  DebugLogger.log(
    'headless-completion-not-yet-landed',
    scope: 'chat/completion',
    data: {'chatId': chatId},
  );
}

bool _headlessAssistantLanded(ChatMessage message) {
  if (message.content.trim().isNotEmpty) return true;
  if (message.output?.isNotEmpty == true) return true;
  if (message.files?.isNotEmpty == true) return true;
  if (message.embeds?.isNotEmpty == true) return true;
  if (message.sources.isNotEmpty) return true;
  if (message.codeExecutions.isNotEmpty) return true;
  if (message.followUps.isNotEmpty) return true;
  if (message.error != null) return true;

  return false;
}

@visibleForTesting
bool headlessAssistantLandedForTest(ChatMessage message) =>
    _headlessAssistantLanded(message);

class _QueuedCompletionDeferred implements OutboxDeferralException {
  const _QueuedCompletionDeferred(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Cancels the active completion's underlying request (e.g. the Dio
/// CancelToken for the httpStream transport), tearing down the byte-stream
/// subscription and closing the socket. Swallows abort errors so callers can
/// continue propagating their original failure/deferral.
Future<void> _abortQuietly(ChatCompletionSession session) async {
  final abort = session.abort;
  if (abort == null) return;
  try {
    await abort();
  } catch (error, stackTrace) {
    DebugLogger.error(
      'headless-stream-abort-failed',
      scope: 'chat/completion',
      error: error,
      stackTrace: stackTrace,
    );
  }
}

Future<void> _markHeadlessCompletionSubmitted(
  dynamic ref, {
  required String chatId,
  required String assistantMessageId,
}) async {
  final db = _readAppDatabaseOrNull(ref);
  if (db == null) return;
  try {
    await db.messagesDao.markAssistantResponseDone(
      chatId: chatId,
      messageId: assistantMessageId,
    );
  } catch (error, stackTrace) {
    DebugLogger.error(
      'headless-completion-marker-failed',
      scope: 'chat/completion',
      error: error,
      stackTrace: stackTrace,
      data: {'chatId': chatId, 'assistantMessageId': assistantMessageId},
    );
  }
}

AppDatabase? _readAppDatabaseOrNull(dynamic ref) {
  try {
    return ref.read(appDatabaseProvider);
  } catch (_) {
    return null;
  }
}

/// Durable send (CDT-RFC-001 §7.2 write path; Group 1 of the task_queue
/// retirement). Replaces the legacy `taskQueueProvider.enqueueSendText` path.
///
/// Writes the user message + assistant placeholder rows AND the outbox op(s)
/// (createChat or updateChat, plus requestCompletion) in ONE transaction via the
/// `*WithOutbox` DAO methods, under `ChatLocks.runExclusive(chatId)`, so a send
/// composed offline survives a force-quit (NON-NEGOTIABLE 4). The optimistic UI
/// add is separate + instant. The SAME [assistantMessageId] is threaded into the
/// in-memory placeholder, the DB row, and `RequestCompletionPayload`
/// (NON-NEGOTIABLE 1, R8). Streaming is then driven by the requestCompletion op
/// via the drainer's runner — `drainNow()` fires immediately so an online send
/// streams with no perceptible delay.
///
/// Falls back to the legacy inline send ([_sendMessageInternal]) when there is
/// no active database (reviewer mode / no active server), preserving behavior.
Future<void> durableSend(
  dynamic ref,
  String message,
  List<String>? attachments, {
  List<String>? toolIds,
  String? pendingFolderIdOverride,
  bool isVoiceMode = false,
}) async {
  final activeAtSendStart = ref.read(activeConversationProvider);
  if (isTemporaryChat(activeAtSendStart?.id)) {
    await _sendMessageInternal(
      ref,
      message,
      attachments,
      toolIds,
      isVoiceMode,
      pendingFolderIdOverride,
    );
    return;
  }

  final db = _readAppDatabaseOrNull(ref);
  final reviewerMode = ref.read(reviewerModeProvider);
  final selectedModel = ref.read(selectedModelProvider);
  final temporary = ref.read(temporaryChatEnabledProvider);

  // No durable backend (reviewer mode, no active server) OR a temporary chat
  // (never persisted): fall back to the legacy inline send path unchanged.
  if (db == null || reviewerMode || selectedModel == null || temporary) {
    await _sendMessageInternal(
      ref,
      message,
      attachments,
      toolIds,
      isVoiceMode,
      pendingFolderIdOverride,
    );
    return;
  }

  final filterIds = ref.read(selectedFilterIdsProvider);
  final now = ref.read(syncClockProvider).nowEpochSeconds();
  final selectedTerminalId = ref.read(selectedTerminalIdProvider);
  final terminalIdForCompletion = modelSupportsTerminal(selectedModel)
      ? _resolveTerminalIdForRequest(selectedTerminalId: selectedTerminalId)
      : null;
  final webSearchEnabled =
      ref.read(webSearchEnabledProvider) &&
      ref.read(webSearchAvailableProvider);
  final imageGenerationEnabled =
      ref.read(imageGenerationEnabledProvider) &&
      ref.read(imageGenerationAvailableProvider);
  final codeInterpreterEnabled =
      ref.read(codeInterpreterEnabledProvider) &&
      ref.read(codeInterpreterAvailableProvider);

  final existingMessages = ref.read(chatMessagesProvider);
  final parentId = _resolveOpenWebUiParentIdForNewUserMessage(existingMessages);

  // Mint both ids ONCE (R8): the placeholder, the DB row, and the completion
  // payload all share `assistantMessageId`.
  final userMessageId = const Uuid().v4();
  final assistantMessageId = const Uuid().v4();

  // ---- optimistic UI (instant; NON-NEGOTIABLE 4) ----
  final contextAttachments = ref.read(contextAttachmentsProvider);
  final contextFiles = _contextAttachmentsToFiles(contextAttachments);
  final attachmentIds = attachments;
  final userMessage = ChatMessage(
    id: userMessageId,
    role: 'user',
    content: message,
    timestamp: DateTime.now(),
    model: selectedModel.id,
    attachmentIds: attachmentIds,
    files: contextFiles.isEmpty ? null : contextFiles,
    metadata: {
      'parentId': parentId,
      'childrenIds': <String>[assistantMessageId],
      'models': <String>[selectedModel.id],
    },
  );
  final assistantPlaceholder = ChatMessage(
    id: assistantMessageId,
    role: 'assistant',
    content: '',
    timestamp: DateTime.now(),
    model: selectedModel.id,
    isStreaming: true,
    metadata: {
      'parentId': userMessageId,
      'childrenIds': const <String>[],
      if (selectedModel.name.trim().isNotEmpty)
        'modelName': selectedModel.name.trim(),
    },
  );
  ref.read(chatMessagesProvider.notifier).addMessages([
    userMessage,
    assistantPlaceholder,
  ]);

  final chatLocks = ref.read(chatLocksProvider);
  final attachmentList = attachments ?? const <String>[];
  final toolIdList = toolIds ?? const <String>[];
  final durableAttachmentFiles = await _resolveDurableFilesFor(
    ref,
    attachmentList,
  );
  final durableFiles = <Map<String, dynamic>>[
    ...durableAttachmentFiles,
    ...contextFiles,
  ];

  final completion = RequestCompletionPayload(
    assistantMessageId: assistantMessageId,
    model: selectedModel.id,
    toolIds: toolIdList,
    filterIds: filterIds,
    terminalId: terminalIdForCompletion,
    enableWebSearch: webSearchEnabled,
    enableImageGeneration: imageGenerationEnabled,
    enableCodeInterpreter: codeInterpreterEnabled,
  );

  var activeConversation = activeAtSendStart;

  if (activeConversation == null) {
    // ---- NEW local chat ----
    final pendingFolderId =
        pendingFolderIdOverride ?? ref.read(pendingFolderIdProvider);
    final localId = 'local:${const Uuid().v4()}';
    final title = _titleFromText(message);

    final blob = _buildDurableNewChatBlob(
      userMsgId: userMessageId,
      asstId: assistantMessageId,
      parentId: parentId,
      text: message,
      files: durableFiles,
      modelId: selectedModel.id,
      modelName: selectedModel.name,
      now: now,
    );
    final rows = ChatBlobMapper.blobToRows(
      chatId: localId,
      blob: blob,
      title: title,
      folderId: pendingFolderId,
      createdAt: now,
      updatedAt: now,
    );
    final contentHash = createChatContentHash(rows);

    // Set the active conversation to the local id BEFORE persisting so the
    // runner / remap consumer see a stable id.
    final localConversation = Conversation(
      id: localId,
      title: title,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      messages: ref.read(chatMessagesProvider),
      folderId: pendingFolderId,
    );
    ref.read(activeConversationProvider.notifier).set(localConversation);
    activeConversation = localConversation;
    ref.read(pendingFolderIdProvider.notifier).clear();

    await chatLocks.runExclusive(localId, () async {
      await db.chatsDao.insertLocalChatWithCreateOp(
        chat: rows.chat,
        messages: rows.messages,
        blobRows: rows,
        contentHash: contentHash,
        completion: completion,
      );
    });
  } else {
    // ---- EXISTING chat ----
    final chatId = activeConversation.id;
    final userRow = MessageRowData(
      id: userMessageId,
      chatId: chatId,
      parentId: parentId,
      role: 'user',
      content: message,
      createdAt: now,
      orderIndex: 0,
      payload: <String, dynamic>{
        'id': userMessageId,
        'parentId': parentId,
        'childrenIds': <String>[assistantMessageId],
        'role': 'user',
        'content': message,
        'files': durableFiles,
        'models': <String>[selectedModel.id],
        'timestamp': now,
      },
    );
    final asstRow = MessageRowData(
      id: assistantMessageId,
      chatId: chatId,
      parentId: userMessageId,
      role: 'assistant',
      content: '',
      model: selectedModel.id,
      createdAt: now,
      orderIndex: 1,
      payload: _durableAssistantPayload(
        id: assistantMessageId,
        parentId: userMessageId,
        modelId: selectedModel.id,
        modelName: selectedModel.name,
        timestamp: now,
      ),
    );

    await chatLocks.runExclusive(chatId, () async {
      await db.chatsDao.appendMessagesWithUpdateOp(
        chatId: chatId,
        messages: [userRow, asstRow],
        currentMessageId: assistantMessageId,
        updatedAt: now,
        enqueueCompletion: true,
        completion: completion,
      );
    });
  }

  // Context attachments (web page / YouTube transcript / KB doc) have now been
  // folded into the persisted user message + durable rows, so clear them —
  // otherwise they stay attached and are silently re-sent on the next message
  // (mirrors `_sendMessageInternal`).
  ref.read(contextAttachmentsProvider.notifier).clear();

  // Drive streaming immediately (online) via the requestCompletion op.
  await ref.read(syncEngineProvider.notifier).drainNow();
}

Map<String, dynamic> _buildDurableNewChatBlob({
  required String userMsgId,
  required String asstId,
  required String? parentId,
  required String text,
  required List<Map<String, dynamic>> files,
  required String modelId,
  required String modelName,
  required int now,
}) {
  return <String, dynamic>{
    'title': _titleFromText(text),
    'models': <String>[modelId],
    'history': <String, dynamic>{
      'currentId': asstId,
      'messages': <String, dynamic>{
        userMsgId: <String, dynamic>{
          'id': userMsgId,
          'parentId': parentId,
          'childrenIds': <String>[asstId],
          'role': 'user',
          'content': text,
          'files': files,
          'models': <String>[modelId],
          'timestamp': now,
        },
        asstId: _durableAssistantPayload(
          id: asstId,
          parentId: userMsgId,
          modelId: modelId,
          modelName: modelName,
          timestamp: now,
        ),
      },
    },
  };
}

Map<String, dynamic> _durableAssistantPayload({
  required String id,
  required String parentId,
  required String modelId,
  required String modelName,
  required int timestamp,
}) {
  final trimmedModelName = modelName.trim();
  return <String, dynamic>{
    'id': id,
    'parentId': parentId,
    'childrenIds': <String>[],
    'role': 'assistant',
    'content': '',
    'model': modelId,
    if (trimmedModelName.isNotEmpty) 'modelName': trimmedModelName,
    'timestamp': timestamp,
  };
}

@visibleForTesting
Map<String, dynamic> debugBuildDurableAssistantPayloadForTesting({
  required String id,
  required String parentId,
  required String modelId,
  required String modelName,
  required int timestamp,
}) {
  return _durableAssistantPayload(
    id: id,
    parentId: parentId,
    modelId: modelId,
    modelName: modelName,
    timestamp: timestamp,
  );
}

typedef _AttachmentTypeMap = Map<String, String>;

Future<List<Map<String, dynamic>>> _resolveDurableFilesFor(
  dynamic ref,
  List<String> attachments,
) async {
  if (attachments.isEmpty) return const [];

  final contentTypes = _durableAttachmentContentTypesFromState(
    ref,
    attachments,
  );
  final missingIds = attachments
      .where((id) => !id.startsWith('data:image/'))
      .where((id) => (contentTypes[id] ?? '').isEmpty)
      .toSet();

  final api = ref.read(apiServiceProvider);
  if (api != null && missingIds.isNotEmpty) {
    final fetchedTypes = await Future.wait(
      missingIds.map((id) async {
        try {
          final raw = await api.getFileInfo(id);
          if (raw is! Map) return null;
          final contentType = _contentTypeFromFileInfo(raw);
          if (contentType.isEmpty) return null;
          return MapEntry(id, contentType);
        } catch (_) {
          return null;
        }
      }),
    );
    for (final entry in fetchedTypes) {
      if (entry != null) contentTypes[entry.key] = entry.value;
    }
  }

  return _durableFilesFor(attachments, contentTypes: contentTypes);
}

_AttachmentTypeMap _durableAttachmentContentTypesFromState(
  dynamic ref,
  List<String> attachments,
) {
  final ids = attachments.where((id) => !id.startsWith('data:image/')).toSet();
  if (ids.isEmpty) return <String, String>{};

  final contentTypes = <String, String>{};

  try {
    for (final file in ref.read(attachedFilesProvider)) {
      final fileId = file.fileId;
      if (fileId == null || !ids.contains(fileId) || file.isImage != true) {
        continue;
      }
      final contentType = _getMimeTypeFromFileName(file.fileName);
      if (contentType != null && contentType.isNotEmpty) {
        contentTypes[fileId] = contentType;
      }
    }
  } catch (_) {}

  try {
    final cachedFiles = ref.read(userFilesProvider).asData?.value;
    if (cachedFiles != null) {
      for (final FileInfo file in cachedFiles) {
        final contentType = file.mimeType.trim();
        if (ids.contains(file.id) && contentType.isNotEmpty) {
          contentTypes[file.id] = contentType;
        }
      }
    }
  } catch (_) {}

  return contentTypes;
}

String _contentTypeFromFileInfo(Map<dynamic, dynamic> fileInfo) {
  final meta = fileInfo['meta'] ?? fileInfo['metadata'];
  Object? contentType;
  if (meta is Map) {
    contentType = meta['content_type'] ?? meta['mimeType'] ?? meta['mime_type'];
  }
  contentType ??=
      fileInfo['content_type'] ?? fileInfo['mimeType'] ?? fileInfo['mime_type'];
  return contentType?.toString().trim() ?? '';
}

List<Map<String, dynamic>> _durableFilesFor(
  List<String> attachments, {
  _AttachmentTypeMap contentTypes = const {},
}) {
  return [
    for (final id in attachments)
      if (id.startsWith('data:image/'))
        <String, dynamic>{'type': 'image', 'url': id}
      else
        _durableFileFor(id, contentType: contentTypes[id]),
  ];
}

Map<String, dynamic> _durableFileFor(String id, {String? contentType}) {
  final normalizedContentType = contentType?.trim() ?? '';
  final file = <String, dynamic>{
    'type': normalizedContentType.startsWith('image/') ? 'image' : 'file',
    'id': id,
    'url': id,
  };
  if (normalizedContentType.isNotEmpty) {
    file['content_type'] = normalizedContentType;
  }
  return file;
}

@visibleForTesting
List<Map<String, dynamic>> buildDurableFilesForTest(
  List<String> attachments, {
  Map<String, String> contentTypes = const {},
}) {
  return _durableFilesFor(attachments, contentTypes: contentTypes);
}

String _titleFromText(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return 'New Chat';
  return trimmed.length <= 50 ? trimmed : trimmed.substring(0, 50);
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

// Service-friendly wrapper (accepts generic Ref)
Future<void> sendMessageFromService(
  Ref ref,
  String message,
  List<String>? attachments, [
  List<String>? toolIds,
  bool isVoiceMode = false,
  String? pendingFolderIdOverride,
]) async {
  await _sendMessageInternal(
    ref,
    message,
    attachments,
    toolIds,
    isVoiceMode,
    pendingFolderIdOverride,
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

// Internal send message implementation
Future<void> _sendMessageInternal(
  dynamic ref,
  String message,
  List<String>? attachments, [
  List<String>? toolIds,
  bool isVoiceMode = false,
  String? pendingFolderIdOverride,
]) async {
  final reviewerMode = ref.read(reviewerModeProvider);
  final api = ref.read(apiServiceProvider);
  final selectedModel = ref.read(selectedModelProvider);

  if ((!reviewerMode && api == null) || selectedModel == null) {
    throw Exception('No API service or model selected');
  }

  final isLoadingConversation = ref.read(isLoadingConversationProvider);
  final currentConversation = ref.read(activeConversationProvider);
  // Guard against a race where the user opens an existing chat and sends
  // before its history loads, which would otherwise create a new chat.
  if (isLoadingConversation && currentConversation == null) {
    throw StateError('Conversation is still loading');
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

  // Create OpenWebUI-shaped user/assistant messages. Files will be updated
  // after fetching server info.
  final userMessageId = const Uuid().v4();
  final String assistantMessageId = const Uuid().v4();
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
    },
  );

  // Add assistant placeholder immediately to show typing indicator right away
  final assistantPlaceholder = ChatMessage(
    id: assistantMessageId,
    role: 'assistant',
    content: '',
    timestamp: DateTime.now(),
    model: selectedModel.id,
    isStreaming: true,
    metadata: {
      'parentId': userMessageId,
      'childrenIds': const <String>[],
      if (selectedModel.name.trim().isNotEmpty)
        'modelName': selectedModel.name.trim(),
    },
  );
  ref.read(chatMessagesProvider.notifier).addMessages([
    userMessage,
    assistantPlaceholder,
  ]);

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
        final filePayload = <String, dynamic>{
          'type': isImage ? 'image' : 'file',
          'id': fileId,
          'name': fileName,
          // OpenWebUI now stores just the file ID, not the full URL path
          // The frontend resolves it when displaying
          'url': fileId,
        };
        if (fileSize != null) {
          filePayload['size'] = fileSize;
        }
        if (collectionName != null) {
          filePayload['collection_name'] = collectionName;
        }
        if (contentType.isNotEmpty) {
          filePayload['content_type'] = contentType;
        }
        return filePayload;
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
    final pendingFolderId =
        pendingFolderIdOverride ?? ref.read(pendingFolderIdProvider);
    final isTemporary = ref.read(temporaryChatEnabledProvider);

    if (isTemporary) {
      // Temporary chat: use local ID, skip server creation entirely
      final socketId = ref.read(socketServiceProvider)?.sessionId ?? 'unknown';
      final localConversation = Conversation(
        id: 'local:${socketId}_${const Uuid().v4()}',
        title: 'New Chat',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        messages: [userMessage, assistantPlaceholder],
      );

      ref.read(activeConversationProvider.notifier).set(localConversation);
      activeConversation = localConversation;
      ref.read(pendingFolderIdProvider.notifier).clear();
    } else {
      // Create new conversation with user message AND assistant placeholder
      // so the listener doesn't remove the placeholder when setting active
      final localConversation = Conversation(
        id: const Uuid().v4(),
        title: 'New Chat',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        messages: [userMessage, assistantPlaceholder],
        folderId: pendingFolderId,
      );

      // Set as active conversation locally
      ref.read(activeConversationProvider.notifier).set(localConversation);
      activeConversation = localConversation;

      if (!reviewerMode) {
        // Try to create on server - use lightweight message without large
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
            folderId: pendingFolderId,
          );

          // Clear the pending folder ID after successful creation
          ref.read(pendingFolderIdProvider.notifier).clear();

          // Keep local messages (user + assistant placeholder) instead of server
          // messages, since we're in the middle of sending and streaming
          final currentMessages = ref.read(chatMessagesProvider);
          final updatedConversation = localConversation.copyWith(
            id: serverConversation.id,
            messages: currentMessages,
            folderId: serverConversation.folderId ?? pendingFolderId,
          );
          ref
              .read(activeConversationProvider.notifier)
              .set(updatedConversation);
          activeConversation = updatedConversation;

          ref
              .read(conversationsProvider.notifier)
              .upsertConversation(
                updatedConversation.copyWith(updatedAt: DateTime.now()),
                trustFolderConversation:
                    updatedConversation.folderId != null &&
                    updatedConversation.folderId!.isNotEmpty,
              );

          // CDT-RFC-001 Phase 1 (E4): materialize the chats row so the
          // stream-completion echo and pause checkpoint have a parent row.
          schedulePullChatNow(ref, serverConversation.id);

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
    // Skip in-progress assistant placeholders, but include assistant replies
    // that already settled their response content in the responseDone gap.
    if (_shouldIncludeConversationHistoryMessage(msg)) {
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
          if (msg.output != null) 'output': msg.output,
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
  final imageGenerationEnabled =
      ref.read(imageGenerationEnabledProvider) &&
      ref.read(imageGenerationAvailableProvider);
  final codeInterpreterEnabled =
      ref.read(codeInterpreterEnabledProvider) &&
      ref.read(codeInterpreterAvailableProvider);

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

    // Reconnect before choosing session_id so eligible sends stay on the
    // task/socket transport instead of falling back to fragile HTTP streaming.
    final socketService = ref.read(socketServiceProvider);
    final socketSessionId = await _ensureConnectedSocketSessionId(
      socketService,
    );

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
    final lastUserMessageId = _lastUserMessageId(messages);

    // Use transport-aware session dispatch
    // Build template variables for prompt substitution (matches OpenWebUI's
    // getPromptVariables). The backend replaces {{USER_NAME}} etc. in system
    // prompts and tool descriptions.
    Map<String, dynamic>? promptVariables;
    Map<String, dynamic>? userMessageMap;
    try {
      promptVariables = await _buildOpenWebUiPromptVariablesForRequest(
        ref,
        now: DateTime.now(),
        userSettings: userSettingsData,
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
        enableCodeInterpreter: codeInterpreterEnabled,
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

      final modelUsesReasoning2 = _modelUsesReasoning(selectedModel.id);

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

    return;
  } catch (e, st) {
    // Clean up buffering on error
    DebugLogger.error(
      '_sendMessageInternal failed: $e',
      scope: 'chat/providers',
      error: e,
      stackTrace: st,
    );
    // Convert the assistant placeholder in-place to an error-state
    // message. This preserves the placeholder's ID and any files that
    // may have arrived before the error, matching OpenWebUI's same-slot
    // failure semantics.
    // Explicit ChatMessage type on closures is required because `ref` is
    // `dynamic` — without it Dart infers (dynamic) => dynamic at runtime.
    final ChatMessagesNotifier notifier =
        ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier;
    notifier.failLastStreamingAssistant(e, assistantMessageId: assistantMessageId);
    if (e.toString().contains('401') || e.toString().contains('403')) {
      // Authentication errors - clear auth state and redirect to login.
      ref.invalidate(authStateManagerProvider);
    }
  }
}

/// Returns a user-friendly error description based on the exception.
String chatErrorContentForException(Object e) {
  final msg = e.toString();
  if (msg.contains('400')) {
    return 'There was an issue with the message format. This might be '
        'because the image attachment couldn\'t be processed, the request '
        'format is incompatible with the selected model, or the message '
        'contains unsupported content. Please try sending the message '
        'again, or try without attachments.';
  } else if (msg.contains('500')) {
    return 'Unable to connect to the AI model. The server returned an '
        'error (500). This is typically a server-side issue. Please try '
        'again or contact your administrator.';
  } else if (msg.contains('404')) {
    DebugLogger.log(
      'Model or endpoint not found (404)',
      scope: 'chat/providers',
    );
    return 'The selected AI model doesn\'t seem to be available. '
        'Please try selecting a different model or check with your '
        'administrator.';
  } else {
    return 'An unexpected error occurred while processing your request. '
        'Please try again or check your connection.';
  }
}

// Save current conversation to OpenWebUI server
// Removed server persistence; only local caching is used in mobile app.

// Fallback: Save current conversation to local storage
Future<void> _saveConversationLocally(dynamic ref) async {
  try {
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

    final db = _readAppDatabaseOrNull(ref);
    if (db != null && !isTemporaryChat(updatedConversation.id)) {
      final lastReadAt = updatedConversation.lastReadAt;
      // ChatLocks discipline: serialize with pull merges / turn echoes so a
      // stale optimistic stub can never overwrite a just-merged server row.
      final ChatLocks locks = ref.read(chatLocksProvider);
      await locks.runExclusive(updatedConversation.id, () async {
        await db.chatsDao.upsertEnvelopeStub(
          id: updatedConversation.id,
          title: updatedConversation.title,
          createdAt:
              updatedConversation.createdAt.millisecondsSinceEpoch ~/ 1000,
          updatedAt:
              updatedConversation.updatedAt.millisecondsSinceEpoch ~/ 1000,
          pinned: updatedConversation.pinned,
          archived: updatedConversation.archived,
          folderId: Value(updatedConversation.folderId),
          lastReadAt: lastReadAt == null
              ? null
              : lastReadAt.millisecondsSinceEpoch ~/ 1000,
        );
      });
    }
    ref.read(activeConversationProvider.notifier).set(updatedConversation);
    refreshConversationsCache(ref);
  } catch (e) {
    DebugLogger.error(
      'Failed to save conversation locally',
      scope: 'chat/providers',
      error: e,
    );
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
        .updateConversationFromRemote(
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
        .updateConversationFromRemote(
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
        .updateConversationFromRemote(
          conversationId,
          (conversation) => conversation.copyWith(
            shareId: shareId,
            updatedAt: DateTime.now(),
          ),
        );

    // Refresh conversations list to reflect the change
    refreshConversationsCache(ref);

    final activeConversation = ref.read(activeConversationProvider);
    if (activeConversation?.id == conversationId) {
      ref
          .read(activeConversationProvider.notifier)
          .set(activeConversation!.copyWith(shareId: shareId));
    }

    return shareId;
  } catch (e) {
    DebugLogger.log('Error sharing conversation: $e', scope: 'chat/providers');
    rethrow;
  }
}

Future<void> deleteSharedConversation(
  WidgetRef ref,
  String conversationId,
) async {
  try {
    final api = ref.read(apiServiceProvider);
    if (api == null) throw Exception('No API service available');

    await api.deleteSharedConversation(conversationId);

    ref
        .read(conversationsProvider.notifier)
        .updateConversationFromRemote(
          conversationId,
          (conversation) =>
              conversation.copyWith(shareId: null, updatedAt: DateTime.now()),
        );

    refreshConversationsCache(ref);

    final activeConversation = ref.read(activeConversationProvider);
    if (activeConversation?.id == conversationId) {
      ref
          .read(activeConversationProvider.notifier)
          .set(activeConversation!.copyWith(shareId: null));
    }
  } catch (e) {
    DebugLogger.log(
      'Error deleting shared conversation link: $e',
      scope: 'chat/providers',
    );
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
          trustFolderConversation:
              clonedConversation.folderId != null &&
              clonedConversation.folderId!.isNotEmpty,
        );
    refreshConversationsCache(ref);
  } catch (e) {
    DebugLogger.log('Error cloning conversation: $e', scope: 'chat/providers');
    rethrow;
  }
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
        ref
            .read(chatMessagesProvider.notifier)
            .cancelActiveMessageStreamPreservingContent();
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

        // Drop any PENDING requestCompletion op for this chat so a stopped
        // turn is not re-driven by the next drain (W14). An inFlight op (the
        // stream already started) is left to the transport-cancel above.
        try {
          final db = ref.read(appDatabaseProvider);
          if (db != null) {
            final chatLocks = ref.read(chatLocksProvider);
            // Fire-and-forget; the lock serializes against the drainer.
            // ignore: unawaited_futures
            chatLocks.runExclusive(
              activeConv.id,
              () => db.chatsDao.cancelPendingCompletion(activeConv.id),
            );
          }
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
          openapi = normalizeJsonLikeMap(doc);
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
