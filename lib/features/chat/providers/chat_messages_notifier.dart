part of 'chat_providers.dart';

@visibleForTesting
Duration debugRemoteTaskPollDelayForTesting({
  required int fastPollsRemaining,
  required int consecutiveFailures,
  required int consecutiveCompletionMisses,
  required bool hasActiveTask,
}) {
  final backoffStep = math.max(
    consecutiveFailures,
    consecutiveCompletionMisses,
  );
  if (backoffStep > 0) {
    const delays = <Duration>[
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 16),
      Duration(seconds: 30),
    ];
    return delays[math.min(backoffStep, delays.length) - 1];
  }
  if (fastPollsRemaining > 0) {
    return const Duration(seconds: 1);
  }
  return hasActiveTask
      ? const Duration(seconds: 3)
      : const Duration(seconds: 5);
}

// Chat messages notifier class
class ChatMessagesNotifier extends Notifier<List<ChatMessage>> {
  static const _passiveRefreshDebounce = Duration(milliseconds: 350);
  static const int _remoteTaskFastPollCount = 10;

  StreamingResponseController? _messageStream;
  ProviderSubscription? _conversationListener;
  final List<StreamSubscription> _subscriptions = [];
  final List<VoidCallback> _socketSubscriptions = [];
  VoidCallback? _socketTeardown;
  SocketEventSubscription? _passiveConversationSocketSubscription;
  StreamSubscription<List<MessageRow>>? _dbMessagesSubscription;
  String? _dbWatchedConversationKey;
  AppDatabase? _dbWatchedDatabase;
  Object? _dbWatchedApi;
  int _dbMessagesGeneration = 0;
  DateTime? _lastStreamingActivity;
  StringBuffer? _streamingBuffer;
  String Function()? _pendingStreamingSnapshot;
  Timer? _streamingSyncTimer;
  Timer? _streamingContentTimer;
  bool _streamingContentFrameScheduled = false;
  DateTime? _lastStreamingContentFlushAt;
  int _streamingBufferVersion = 0;
  int _lastFlushedStreamingBufferVersion = -1;
  _StreamingContentFlushReason _pendingStreamingFlushReason =
      _StreamingContentFlushReason.cadence;
  int _streamingVisibleFlushCount = 0;
  int _streamingCoalescedUpdateCount = 0;
  Timer? _taskStatusTimer;
  String? _remoteTaskMonitorMessageId;
  StreamSubscription<void>? _remoteTaskReconnectSubscription;
  SocketService? _remoteTaskWakeSocket;
  int _remoteTaskFastPollsRemaining = 0;
  int _remoteTaskConsecutiveFailures = 0;
  int _remoteTaskCompletionMisses = 0;
  bool _isAppForeground = true;
  Timer? _passiveConversationRefreshTimer;
  bool _taskStatusCheckInFlight = false;
  int _taskStatusGeneration = 0;
  final Set<Object> _nonTailToolTaskMonitors = <Object>{};
  bool _observedRemoteTask = false;
  // Feature C: number of consecutive polls that saw `tasksDone` while a socket
  // resume stream still held protection. The poll's force-adoption is deferred
  // for a short grace window so the socket's own `done` finalize wins and we
  // never double-finalize. Reset whenever tasks are active again.
  int _tasksDoneGracePolls = 0;
  // Consecutive `tasksDone` observations to wait before the poll force-adopts
  // server state over a still-protected socket resume stream.
  static const int _tasksDoneSocketGracePolls = 2;
  // Consecutive empty task-registry polls observed for a reopened tail whose
  // task lookup previously failed. Requiring a second empty observation keeps
  // a temporarily unregistered server task from being finalized immediately.
  int _unobservedReopenedEmptyPolls = 0;
  static const int _unobservedReopenedEmptyPollGrace = 1;
  bool _passiveConversationRefreshInFlight = false;
  int _passiveConversationGeneration = 0;
  int? _queuedPassiveConversationGeneration;
  String? _queuedPassiveConversationId;
  String? _queuedPassiveConversationSource;
  OpenWebUiCompletionOwner? _queuedPassiveConversationOwner;
  String? _passiveConversationId;
  SocketService? _passiveConversationSocket;
  OpenWebUiCompletionOwner? _passiveConversationOwner;
  AppDatabase? _activeOpenWebUiDatabase;
  Object? _activeOpenWebUiApi;
  SocketService? _activeOpenWebUiSocket;
  Object? _activeOpenWebUiAuthSessionEpoch;
  bool _activeOpenWebUiContextCoherent = false;
  bool _openWebUiContextChangedSinceConversation = false;
  int _openWebUiContextRebindGeneration = 0;
  int _modelRebindGeneration = 0;
  String? _activeStreamingTransportMessageId;
  // Foreign server-assigned message id bound to the streaming tail (socket
  // resume). Lets the poll fallback resolve server messages by this id if the
  // socket dies after binding but before delivering `done`.
  String? _boundRemoteMessageId;
  String? _boundRemoteMessageOwnerId;
  // The assistant tail currently being recovered after opening an existing
  // chat. Unlike a locally-started stream, this transport did not observe the
  // whole response, so server snapshots must keep reconciling it even after a
  // live socket attaches.
  String? _reopenedStreamingMessageId;
  int _reopenedSocketCatchUpPollsRemaining = 0;
  bool _awaitingFirstReopenedSocketActivity = false;
  DateTime? _lastReopenedSnapshotAt;
  static const int _reopenedSocketCatchUpPolls = 2;
  static const Duration _reopenedSocketStallThreshold = Duration(seconds: 3);
  String? _streamingProfileTaskKey;
  String? _streamingProfileMessageId;
  DateTime? _streamingProfileStartedAt;
  int _streamingProfileChunkCount = 0;
  int _streamingProfileCharacters = 0;
  int _streamingProfileUtf8Bytes = 0;
  int _coldHermesRecoveryGeneration = 0;
  CancelToken? _coldHermesRecoveryCancelToken;
  HermesRunKey? _coldHermesRecoveryKey;
  String? _coldHermesRecoveryMessageId;

  bool _initialized = false;
  bool _disposed = false;

  List<ChatMessage> get messagesSnapshot => state;

  @override
  List<ChatMessage> build() {
    if (!_initialized) {
      _initialized = true;
      final lifecycle = ref.read(appLifecycleProvider);
      // Seeded from `current` rather than waited for: a notifier built after
      // launch never receives the transition that put the app where it
      // already is. Null means the host has observed nothing yet, which is
      // indistinguishable from foreground and is treated as such.
      _isAppForeground = lifecycle.current?.isForeground ?? true;
      _subscriptions.add(lifecycle.changes.listen(_onLifecycleChanged));
      _captureActiveOpenWebUiContext();
      ref.listen(appDatabaseProvider, (_, _) => _onOpenWebUiContextChanged());
      ref.listen(apiServiceProvider, (_, _) => _onOpenWebUiContextChanged());
      ref.listen(socketServiceProvider, (_, _) => _onOpenWebUiContextChanged());
      ref.listen(
        openWebUiAuthSessionEpochProvider,
        (_, _) => _onOpenWebUiContextChanged(),
      );
      ref.listen<HermesBackendService?>(hermesApiServiceProvider, (_, next) {
        // A cold recovery is authorized and routed by the concrete Hermes
        // service that started it. Retire that attempt on every owner change;
        // otherwise the old poll blocks the new service behind the same-message
        // guard and can leave the checkpoint streaming forever.
        _cancelColdHermesRecovery();
        if (next == null) return;
        final active = ref.read(activeConversationProvider);
        if (active != null) {
          unawaited(_recoverColdHermesCheckpointIfNeeded(active));
        }
      });
      _conversationListener = ref.listen(activeConversationProvider, (
        previous,
        next,
      ) {
        DebugLogger.log(
          'Conversation changed: ${previous?.id} -> ${next?.id}',
          scope: 'chat/providers',
        );

        if (conversationUsesOpenWebUiStorage(next) &&
            !openWebUiAccountStorageIsCertified(ref)) {
          _modelRebindGeneration += 1;
          _cancelMessageStream();
          _stopRemoteTaskMonitor();
          _stopNonTailToolTaskMonitor();
          _teardownPassiveConversationSync();
          _cancelDbMessagesWatch();
          state = const <ChatMessage>[];
          _clearStaleOpenWebUiActiveConversation(next);
          return;
        }

        final openWebUiContextStayedExact =
            !_openWebUiContextChangedSinceConversation &&
            _activeOpenWebUiContextCoherent &&
            identical(
              _activeOpenWebUiAuthSessionEpoch,
              _readOpenWebUiAuthSessionEpoch(ref),
            ) &&
            identical(_activeOpenWebUiDatabase, _readAppDatabaseOrNull(ref)) &&
            identical(_activeOpenWebUiApi, _readApiServiceOrNull(ref)) &&
            identical(
              _activeOpenWebUiSocket,
              _readOpenWebUiSocketForApi(ref, _readApiServiceOrNull(ref)),
            ) &&
            _openWebUiContextTupleIsCoherent(
              ref,
              database: _readAppDatabaseOrNull(ref),
              api: _readApiServiceOrNull(ref),
              socket: _readOpenWebUiSocketForApi(
                ref,
                _readApiServiceOrNull(ref),
              ),
            );
        _openWebUiContextChangedSinceConversation = false;
        _captureActiveOpenWebUiContext();

        _configurePassiveConversationSync(next);
        _configureDbMessagesWatch(next);

        // Only react when the conversation actually changes
        if ((isSameStoredConversation(previous, next) &&
                (!conversationUsesOpenWebUiStorage(previous) ||
                    openWebUiContextStayedExact)) ||
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

        final modelRebindGeneration = ++_modelRebindGeneration;
        // Cancel any existing message stream when switching conversations
        _cancelMessageStream();
        _stopRemoteTaskMonitor();
        _stopNonTailToolTaskMonitor();
        _cancelColdHermesRecovery();

        if (next != null) {
          final nextMessages = _restoreLiveTransportRunState(
            _preserveFreshLocalMessageState(next.messages),
            next,
            settleOrphanedDirect: true,
          );
          final currentMessagesAlreadyVisible =
              state.isNotEmpty &&
              !_messagesDifferByStreamingSignatures(nextMessages, state);
          if (!currentMessagesAlreadyVisible) {
            state = nextMessages;
          }
          _syncStreamingProfileWithState();
          final restoredHermesCheckpoint =
              nextMessages.isNotEmpty &&
                  nextMessages.last.role == 'assistant' &&
                  nextMessages.last.isStreaming &&
                  nextMessages.last.metadata?['transport'] == kHermesTransport
              ? nextMessages.last
              : null;
          if (restoredHermesCheckpoint != null) {
            unawaited(
              _recoverColdHermesCheckpointIfNeeded(
                next,
                settleUnrecoverable: true,
                expectedMessageId: restoredHermesCheckpoint.id,
              ),
            );
          }

          // Update selected model if conversation has a different model
          _updateModelForConversation(next, generation: modelRebindGeneration);

          if (_hasOpenWebUiTaskRecoverableTail(next, requireStreaming: false)) {
            if (_shouldProtectLocalStreamingState) {
              _ensureRemoteTaskMonitor();
            } else {
              // A restored `isStreaming` flag is only a local checkpoint, not
              // proof that the task is still alive. Probe both streaming and
              // settled tails so a cold reopen can either resume or finalize
              // from the authoritative server transcript.
              unawaited(_detectActiveOnOpen(next));
            }
          } else {
            _stopRemoteTaskMonitor();
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
        _stopNonTailToolTaskMonitor();
        _cancelColdHermesRecovery();
        _streamingSyncTimer?.cancel();
        _streamingSyncTimer = null;
        _streamingContentTimer?.cancel();
        _streamingContentTimer = null;

        _conversationListener?.close();
        _conversationListener = null;
      });
    }

    final activeConversation = ref.read(activeConversationProvider);
    _captureActiveOpenWebUiContext();
    if (conversationUsesOpenWebUiStorage(activeConversation) &&
        !openWebUiAccountStorageIsCertified(ref)) {
      _clearStaleOpenWebUiActiveConversation(activeConversation);
      return const <ChatMessage>[];
    }
    _configurePassiveConversationSync(activeConversation);
    _configureDbMessagesWatch(activeConversation);
    final initialMessages = _restoreLiveTransportRunState(
      activeConversation?.messages ?? const [],
      activeConversation,
      settleOrphanedDirect: true,
    );
    final initialHermesCheckpoint =
        initialMessages.isNotEmpty &&
            initialMessages.last.role == 'assistant' &&
            initialMessages.last.isStreaming &&
            initialMessages.last.metadata?['transport'] == kHermesTransport
        ? initialMessages.last
        : null;
    if (activeConversation != null && initialHermesCheckpoint != null) {
      Future.microtask(() {
        if (_disposed ||
            !isSameStoredConversation(
              ref.read(activeConversationProvider),
              activeConversation,
            )) {
          return;
        }
        unawaited(
          _recoverColdHermesCheckpointIfNeeded(
            activeConversation,
            settleUnrecoverable: true,
            expectedMessageId: initialHermesCheckpoint.id,
          ),
        );
      });
    }
    if (activeConversation != null && _activeOpenWebUiApi is ApiService) {
      Future.microtask(() {
        if (_disposed ||
            !isSameStoredConversation(
              ref.read(activeConversationProvider),
              activeConversation,
            ) ||
            !_hasOpenWebUiTaskRecoverableTail(
              activeConversation,
              requireStreaming: false,
            ) ||
            _shouldProtectLocalStreamingState) {
          return;
        }
        unawaited(_detectActiveOnOpen(activeConversation));
      });
    }
    return initialMessages;
  }

  void _clearStaleOpenWebUiActiveConversation(Conversation? expected) {
    if (expected == null) return;
    Future.microtask(() {
      if (_disposed || openWebUiAccountStorageIsCertified(ref)) return;
      final current = ref.read(activeConversationProvider);
      if (identical(current, expected) ||
          isSameStoredConversation(current, expected)) {
        ref.read(activeConversationProvider.notifier).set(null);
      }
    });
  }

  void _captureActiveOpenWebUiContext() {
    _activeOpenWebUiDatabase = _readAppDatabaseOrNull(ref);
    _activeOpenWebUiApi = _readApiServiceOrNull(ref);
    _activeOpenWebUiSocket = _readOpenWebUiSocketForApi(
      ref,
      _activeOpenWebUiApi,
    );
    _activeOpenWebUiAuthSessionEpoch = _readOpenWebUiAuthSessionEpoch(ref);
    _activeOpenWebUiContextCoherent = _openWebUiContextTupleIsCoherent(
      ref,
      database: _activeOpenWebUiDatabase,
      api: _activeOpenWebUiApi,
      socket: _activeOpenWebUiSocket,
    );
  }

  void _onOpenWebUiContextChanged() {
    final database = _readAppDatabaseOrNull(ref);
    final api = _readApiServiceOrNull(ref);
    final socket = _readOpenWebUiSocketForApi(ref, api);
    final authSessionEpoch = _readOpenWebUiAuthSessionEpoch(ref);
    final coherent = _openWebUiContextTupleIsCoherent(
      ref,
      database: database,
      api: api,
      socket: socket,
    );
    if (identical(database, _activeOpenWebUiDatabase) &&
        identical(api, _activeOpenWebUiApi) &&
        identical(socket, _activeOpenWebUiSocket) &&
        identical(authSessionEpoch, _activeOpenWebUiAuthSessionEpoch) &&
        coherent == _activeOpenWebUiContextCoherent) {
      return;
    }
    _openWebUiContextChangedSinceConversation = true;
    _captureActiveOpenWebUiContext();

    final active = ref.read(activeConversationProvider);
    if (!conversationUsesOpenWebUiStorage(active)) return;

    // Tear down A synchronously. Rebind after the provider switch batch settles
    // so equal raw ids cannot retain A's stream, DB watch, or socket callback.
    _cancelMessageStream();
    _stopRemoteTaskMonitor();
    _stopNonTailToolTaskMonitor();
    _teardownPassiveConversationSync();
    _cancelDbMessagesWatch();
    state = const <ChatMessage>[];
    _finishStreamingProfile(reason: 'openwebui_context_changed');
    final generation = ++_openWebUiContextRebindGeneration;
    Future.microtask(() {
      if (_disposed || generation != _openWebUiContextRebindGeneration) return;
      final current = ref.read(activeConversationProvider);
      if (!conversationUsesOpenWebUiStorage(current)) return;
      _configurePassiveConversationSync(current);
      _configureDbMessagesWatch(current);
      if (current != null) {
        unawaited(_detectActiveOnOpen(current));
      }
    });
  }

  /// One narrow Drift watch over the active chat's message rows
  /// (CDT-RFC-001 §10.2: always `WHERE chatId = ?`). Resubscribed on
  /// conversation change, cancelled on null/dispose.
  void _configureDbMessagesWatch(Conversation? conversation) {
    final conversationId = conversation?.id;
    if (conversation == null ||
        conversationId == null ||
        conversationId.isEmpty ||
        isTemporaryChat(conversationId)) {
      _cancelDbMessagesWatch();
      return;
    }
    final explicitStorage = chatStorageKindOf(conversation);
    // Native Hermes/runtime-direct chats have no Conduit database owner. An
    // absent provenance marker means OpenWebUI only for historical OpenWebUI
    // conversations, not for an explicitly backend-owned runtime session.
    if (explicitStorage == null &&
        !conversationUsesOpenWebUiStorage(conversation)) {
      _cancelDbMessagesWatch();
      return;
    }
    final storage = explicitStorage ?? ChatStorageKind.openWebUi;
    final conversationKey = ChatStorageIdentity(
      rawId: conversationId,
      storage: storage,
    ).scopedId;
    final db = _databaseForStorage(storage);
    final api = storage == ChatStorageKind.openWebUi
        ? _readApiServiceOrNull(ref)
        : null;
    if (storage == ChatStorageKind.openWebUi &&
        !_openWebUiContextTupleIsCoherent(
          ref,
          database: db,
          api: api,
          socket: _readOpenWebUiSocketForApi(ref, api),
        )) {
      _cancelDbMessagesWatch();
      return;
    }
    if (_dbWatchedConversationKey == conversationKey &&
        identical(_dbWatchedDatabase, db) &&
        identical(_dbWatchedApi, api) &&
        _dbMessagesSubscription != null) {
      return;
    }
    _cancelDbMessagesWatch();
    if (db == null) {
      return;
    }
    _dbWatchedConversationKey = conversationKey;
    _dbWatchedDatabase = db;
    _dbWatchedApi = api;
    final openWebUiOwner = storage == ChatStorageKind.openWebUi
        ? captureOpenWebUiCompletionOwner(
            ref,
            chatId: conversationId,
            database: db,
            api: api,
          )
        : null;
    _dbMessagesSubscription = db.messagesDao
        .watchForChat(conversationId)
        .listen(
          (rows) {
            if (_dbWatchedConversationKey != conversationKey ||
                !identical(_dbWatchedDatabase, db) ||
                !identical(_dbWatchedApi, api)) {
              return;
            }
            final generation = ++_dbMessagesGeneration;
            unawaited(
              _onDbMessagesChanged(
                conversation,
                db,
                rows,
                generation,
                openWebUiOwner,
              ),
            );
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
    _dbWatchedConversationKey = null;
    _dbWatchedDatabase = null;
    _dbWatchedApi = null;
    _dbMessagesGeneration++;
  }

  /// Database emissions adopt through the exact same protected path as
  /// server snapshots: streaming state is never touched while
  /// [_shouldProtectLocalStreamingState] or [_isResumeStreamingActive] holds,
  /// and all dedupe/protection lives in [_adoptServerMessages].
  Future<void> _onDbMessagesChanged(
    Conversation watchedConversation,
    AppDatabase db,
    List<MessageRow> rows,
    int generation,
    OpenWebUiCompletionOwner? openWebUiOwner,
  ) async {
    final conversationId = watchedConversation.id;
    if (_disposed ||
        generation != _dbMessagesGeneration ||
        _shouldProtectLocalStreamingState ||
        _isResumeStreamingActive) {
      return;
    }
    if (openWebUiOwner != null &&
        activeOpenWebUiChatIdForMutation(ref, openWebUiOwner) == null) {
      return;
    }
    if (!isSameStoredConversation(
      ref.read(activeConversationProvider),
      watchedConversation,
    )) {
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
      final conversation = await assembleConversationGuarded(
        chat,
        rows,
        offload: (envelope) => ref
            .read(workerManagerProvider)
            .schedule(
              parseFullConversationModelWorker,
              envelope,
              debugLabel: 'chat.dbWatch.assembleConversation',
            ),
      );
      if (_disposed ||
          !ref.mounted ||
          generation != _dbMessagesGeneration ||
          _shouldProtectLocalStreamingState ||
          _isResumeStreamingActive) {
        return;
      }
      if (openWebUiOwner != null &&
          activeOpenWebUiChatIdForMutation(ref, openWebUiOwner) == null) {
        return;
      }
      if (!isSameStoredConversation(
        ref.read(activeConversationProvider),
        watchedConversation,
      )) {
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

  AppDatabase? _databaseForStorage(ChatStorageKind storage) {
    if (storage == ChatStorageKind.directLocal) {
      try {
        return ref.read(directLocalDatabaseProvider);
      } catch (_) {
        return null;
      }
    }
    // Database dependencies unavailable (e.g. teardown or test harness
    // without an active server) resolve to null.
    return _readAppDatabaseOrNull(ref);
  }

  AppDatabase? _maybeDatabase() {
    final active = ref.read(activeConversationProvider);
    return _databaseForStorage(
      chatStorageKindOf(active) ?? ChatStorageKind.openWebUi,
    );
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

    // Preserve while `_boundRemoteMessageId` is still set. Dropping transport
    // first cleared that binding (and the resume task monitor), so a stale
    // empty echo under the foreign server id could replace the local streaming
    // tail and retire the stream early.
    state = _restoreLiveTransportRunState(
      _preserveFreshLocalMessageState(serverMessages),
      ref.read(activeConversationProvider),
    );
    _syncStreamingProfileWithState();

    // Only tear down transport when this adopt ends the stream. A preserved
    // still-streaming echo must keep the resume monitor / socket binding /
    // bound remote id intact for later polls and socket deltas.
    // Genuine completion uses the full cancellation path so streaming profile
    // state is finalized. The fallback below only retires stale transport
    // ownership after adoption leaves no streaming assistant.
    if (needsCleanup) {
      _cancelMessageStream();
    } else if (!_hasStreamingAssistant) {
      if (_hasTrackedStreamingTransport) {
        _dropStreamingTransportState(source: 'server adoption from $source');
      }
    }

    DebugLogger.log(
      'Adopted server conversation snapshot from $source '
      '(${serverMessages.length} messages)',
      scope: 'chat/providers',
    );
  }

  void _configurePassiveConversationSync(Conversation? conversation) {
    final conversationId = conversation?.id;
    if (conversationId == null ||
        conversationId.isEmpty ||
        isTemporaryChat(conversationId) ||
        !_conversationUsesOpenWebUiContext(conversation)) {
      _teardownPassiveConversationSync();
      return;
    }

    // Do not instantiate OpenWebUI auth/network providers merely because the
    // shared message notifier is displaying a native Hermes/direct chat.
    final database = _readAppDatabaseOrNull(ref);
    final api = _readApiServiceOrNull(ref);
    final socket = _readOpenWebUiSocketForApi(ref, api);
    if (socket == null ||
        !_openWebUiContextTupleIsCoherent(
          ref,
          database: database,
          api: api,
          socket: socket,
        )) {
      _teardownPassiveConversationSync();
      return;
    }

    final owner = captureOpenWebUiCompletionOwner(ref, chatId: conversationId);
    if (_passiveConversationId == conversationId &&
        identical(_passiveConversationSocket, socket) &&
        _sameOpenWebUiOwnerContext(_passiveConversationOwner, owner) &&
        _passiveConversationSocketSubscription != null) {
      return;
    }

    _teardownPassiveConversationSync();
    _passiveConversationId = conversationId;
    _passiveConversationSocket = socket;
    _passiveConversationOwner = owner;
    _passiveConversationSocketSubscription = socket.addChatEventHandler(
      conversationId: conversationId,
      requireFocus: true,
      handler: (event, _) {
        if (!identical(_passiveConversationSocket, socket) ||
            !identical(_passiveConversationOwner, owner) ||
            activeOpenWebUiChatIdForMutation(ref, owner) == null) {
          return;
        }
        // The server emits `chat:message:follow_ups` only AFTER
        // `chat:completion {done:true}`, and the per-stream socket
        // subscription is disposed synchronously by that done event — this
        // passive handler is the only delivery path for follow-ups. Apply
        // the payload directly: the debounced full refetch below races the
        // server's own persistence of the suggestions (the event is emitted
        // before the upsert) and can be rejected by adoption guards.
        if (_applyPassiveFollowUpsEvent(event)) {
          return;
        }
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

  /// Applies a pushed `chat:message:follow_ups` payload straight to the
  /// target message. Returns true when the event was consumed.
  bool _applyPassiveFollowUpsEvent(Map<String, dynamic> event) {
    final parsed = parseFollowUpsSocketEvent(event);
    if (parsed == null) {
      return false;
    }
    // An unknown message id must fall through to the debounced refetch —
    // consuming the event here would silently drop the payload.
    final messageIndex = state.indexWhere(
      (message) => message.id == parsed.messageId,
    );
    if (messageIndex == -1) {
      return false;
    }
    DebugLogger.log(
      'follow-ups-received',
      scope: 'chat/passive-sync',
      data: {'messageId': parsed.messageId, 'count': parsed.followUps.length},
    );
    updateMessageById(parsed.messageId, (current) {
      if (listEquals(current.followUps, parsed.followUps)) {
        return current;
      }
      return current.copyWith(followUps: parsed.followUps);
    });
    // The turn echo was persisted at completion, before this event fired.
    // Re-persist the message so the suggestions survive a conversation
    // switch (the local Drift copy would otherwise reload without them).
    // Re-resolve the index: updateMessageById rebuilt the list above.
    _persistCompletedTurnForMessage(
      state.indexWhere((message) => message.id == parsed.messageId),
    );
    return true;
  }

  List<ChatMessage> _preserveFreshLocalMessageState(
    List<ChatMessage> serverMessages,
  ) {
    if (state.isEmpty || serverMessages.isEmpty) {
      return serverMessages;
    }

    final localTrailingUserId = state
        .where((message) => message.role == 'user')
        .lastOrNull
        ?.id;
    final serverTrailingUserId = serverMessages
        .where((message) => message.role == 'user')
        .lastOrNull
        ?.id;
    final localById = <String, ChatMessage>{
      for (final message in state)
        // Also index empty placeholders that still carry a local-only
        // streaming state or `modelName`, so a stale pre-first-token snapshot
        // can't drop local turn state before the metadata merge runs. Keep the
        // trailing user's attachments for the same lagging-snapshot window.
        if ((message.role == 'assistant' &&
                (message.isStreaming ||
                    message.content.trim().isNotEmpty ||
                    message.statusHistory.isNotEmpty ||
                    message.followUps.isNotEmpty ||
                    _messageModelName(message) != null)) ||
            (message.id == localTrailingUserId &&
                message.id == serverTrailingUserId &&
                (message.attachmentIds?.isNotEmpty == true ||
                    message.files?.isNotEmpty == true)))
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
    final serverHasAdditionalMessages = serverMessages.length > state.length;

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
      if (localMessage == null) {
        merged.add(serverMessage);
        continue;
      }
      final isStreamingTail = serverMessage.id == localTailId || boundToTail;
      final preserveContent =
          isStreamingTail &&
          _shouldPreserveLocalAssistantContent(localMessage, serverMessage);
      final shouldPreserveStreamingState =
          _shouldPreserveLocalAssistantStreamingState(
            localMessage,
            serverMessage,
            isStreamingTail: isStreamingTail,
            serverHasAdditionalMessages: serverHasAdditionalMessages,
          );
      final sameResponseContent = _sameAssistantResponseText(
        localMessage.content,
        serverMessage.content,
      );
      final shouldPreserveFollowUps =
          localMessage.followUps.isNotEmpty &&
          serverMessage.role == 'assistant' &&
          serverMessage.followUps.isEmpty &&
          (sameResponseContent || preserveContent);
      final serverStatusHistory = serverMessage.statusHistory;
      final mergedStatusHistory =
          localMessage.statusHistory.isNotEmpty &&
              serverMessage.role == 'assistant' &&
              isStreamingTail &&
              (sameResponseContent || preserveContent)
          ? mergeStatusHistoryPreservingSettledLocal(
              localMessage.statusHistory,
              serverStatusHistory,
            )
          : serverStatusHistory;
      final shouldPreserveStatusHistory = !identical(
        mergedStatusHistory,
        serverStatusHistory,
      );
      final shouldPreserveUserAttachments =
          localMessage.role == 'user' &&
          serverMessage.role == 'user' &&
          localMessage.content == serverMessage.content &&
          (localMessage.attachmentIds?.isNotEmpty == true ||
              localMessage.files?.isNotEmpty == true) &&
          serverMessage.attachmentIds?.isNotEmpty != true &&
          serverMessage.files?.isNotEmpty != true;
      // Preserve a local-only modelName the server snapshot hasn't caught up to
      // (notably an empty placeholder whose first token hasn't landed).
      final shouldPreserveModelName =
          serverMessage.role == 'assistant' &&
          _messageModelName(localMessage) != null &&
          _messageModelName(serverMessage) == null;
      if (!preserveContent &&
          !shouldPreserveFollowUps &&
          !shouldPreserveStatusHistory &&
          !shouldPreserveUserAttachments &&
          !shouldPreserveModelName &&
          !shouldPreserveStreamingState) {
        merged.add(serverMessage);
        continue;
      }

      changed = true;
      final preservedLocalMessage = localMessage;
      // Merge local + server metadata so local-only fields (e.g. `modelName`)
      // survive a server snapshot captured before the durable payload was
      // finalized. Server values take precedence; local fills only the gaps.
      final metadata = <String, dynamic>{
        ...?preservedLocalMessage.metadata,
        ...?serverMessage.metadata,
      };
      if (shouldPreserveFollowUps) {
        // Overwrite (not putIfAbsent): the merged map may carry a stale
        // `followUps` from the server snapshot (e.g. an explicit empty list),
        // which must mirror the preserved typed `.followUps` field below.
        metadata['followUps'] = List<String>.from(
          preservedLocalMessage.followUps,
        );
      }
      if (shouldPreserveModelName) {
        // The raw server map may carry an empty/whitespace `modelName` that the
        // union spread on top of the local one; restore the normalized local
        // value so an empty server field can't blank the displayed model name.
        metadata['modelName'] = _messageModelName(preservedLocalMessage);
      }
      merged.add(
        serverMessage.copyWith(
          isStreaming: shouldPreserveStreamingState
              ? true
              : serverMessage.isStreaming,
          content: preserveContent
              ? preservedLocalMessage.content
              : serverMessage.content,
          followUps: shouldPreserveFollowUps
              ? List<String>.from(preservedLocalMessage.followUps)
              : serverMessage.followUps,
          statusHistory: mergedStatusHistory,
          attachmentIds: shouldPreserveUserAttachments
              ? preservedLocalMessage.attachmentIds
              : serverMessage.attachmentIds,
          files: shouldPreserveUserAttachments
              ? preservedLocalMessage.files
              : serverMessage.files,
          metadata: metadata.isEmpty ? null : metadata,
        ),
      );
    }

    return changed ? List<ChatMessage>.unmodifiable(merged) : serverMessages;
  }

  List<ChatMessage> _restoreLiveDirectRunState(
    List<ChatMessage> messages,
    Conversation? conversation, {
    bool settleOrphaned = false,
  }) {
    if (conversation == null || messages.isEmpty) return messages;
    DirectRunRegistry registry;
    try {
      registry = ref.read(directRunRegistryProvider);
    } catch (_) {
      return messages;
    }
    final owner = _directRunOwnerScopeForConversation(ref, conversation);
    ChatDatabaseLocation? location;
    String? persistenceOwnerId;
    final storage = _directStoredStorageOf(conversation);
    final authSessionEpoch = storage == ChatStorageKind.openWebUi
        ? _readOpenWebUiAuthSessionEpoch(ref)
        : null;
    if (storage != null) {
      try {
        location = ref
            .read(chatDatabaseRepositoryProvider)
            .locationFor(storage);
        persistenceOwnerId = _directPersistenceOwnerIdForLocation(
          ref,
          location,
        );
      } catch (_) {
        // The server database may still be opening. A later conversation/DB
        // emission will retry restoration without exposing another server's
        // retained output.
      }
    }
    var changed = false;
    final restored = <ChatMessage>[];
    for (final message in messages) {
      final key = _directRunKeyForOwner(owner, message.id);
      final retained = persistenceOwnerId == null
          ? null
          : registry.retainedFinalizedOutput(
              key,
              persistenceOwnerId,
              authSessionEpoch: authSessionEpoch,
            );
      if (retained != null &&
          message.role == 'assistant' &&
          message.metadata?['transport'] == kDirectTransport) {
        restored.add(retained.message);
        changed = changed || retained.message != message;
        unawaited(
          _retryRetainedDirectFinalOutput(
            registry: registry,
            output: retained,
            conversation: conversation,
            location: location!,
            persistenceOwnerId: persistenceOwnerId!,
            authSessionEpoch: authSessionEpoch,
          ),
        );
        continue;
      }
      final shouldStream =
          message.role == 'assistant' &&
          message.metadata?['transport'] == kDirectTransport &&
          registry.hasLiveIntent(key);
      if (shouldStream && !message.isStreaming) {
        restored.add(message.copyWith(isStreaming: true));
        changed = true;
      } else if (!shouldStream &&
          settleOrphaned &&
          message.isStreaming &&
          message.role == 'assistant' &&
          message.metadata?['transport'] == kDirectTransport) {
        // Direct transports are client-owned. After process death there is no
        // server task to resume, so an orphaned pause checkpoint is a retained
        // partial answer rather than a live stream.
        restored.add(message.copyWith(isStreaming: false));
        changed = true;
      } else {
        restored.add(message);
      }
    }
    return changed ? List<ChatMessage>.unmodifiable(restored) : messages;
  }

  List<ChatMessage> _restoreLiveTransportRunState(
    List<ChatMessage> messages,
    Conversation? conversation, {
    bool settleOrphanedDirect = false,
  }) => _restoreLiveHermesRunState(
    _restoreLiveDirectRunState(
      messages,
      conversation,
      settleOrphaned: settleOrphanedDirect,
    ),
    conversation,
  );

  List<ChatMessage> _restoreLiveHermesRunState(
    List<ChatMessage> messages,
    Conversation? conversation,
  ) {
    if (conversation == null) return messages;
    _HermesRunProjectionStore store;
    HermesRunBackendIdentity? backendIdentity;
    try {
      store = ref.read(_hermesRunProjectionStoreProvider);
      backendIdentity = _hermesBackendIdentityForMutation(
        captureChatMutationOwner(ref, conversation),
      );
    } catch (_) {
      return messages;
    }
    final projections = store.forOwner(
      ownerConversationId: chatMutationOwnerScopeForConversation(conversation),
      backendIdentity: backendIdentity,
    );
    if (projections.isEmpty) return messages;

    final restored = List<ChatMessage>.from(messages);
    final matched = <_HermesRunProjection>{};
    for (var index = 0; index < restored.length; index++) {
      final message = restored[index];
      if (message.role != 'assistant') continue;
      final messageTransportId = _hermesMessageTransportId(message);
      _HermesRunProjection? projection = projections
          .where(
            (candidate) =>
                !matched.contains(candidate) &&
                candidate.message.id == message.id,
          )
          .firstOrNull;
      if (projection == null && messageTransportId != null) {
        projection = projections
            .where(
              (candidate) =>
                  !matched.contains(candidate) &&
                  _hermesMessageTransportId(candidate.message) ==
                      messageTransportId,
            )
            .firstOrNull;
      }
      if (projection == null) continue;
      matched.add(projection);
      restored[index] = projection.message;
      if (projection.finalized && projection.dispatchSettled) {
        // A final projection is a single-use recovery bridge once its captured
        // OpenWebUI write is durable. Failed writes remain owner-bound and are
        // retried below; native Hermes can retire immediately because its
        // session server is authoritative.
        store.markRecoveryDelivered(projection);
        _retryHermesProjectionPersistenceAfterAdoption(
          ref,
          conversation: conversation,
          projectionStore: store,
          projection: projection,
        );
      }
    }

    // A live approval/stream may not have a server transcript row yet. Append
    // every unmatched owner-bound projection so a lagging transcript cannot
    // silently lose concurrent turns merely because it already contains some
    // other assistant. Final snapshots are consumed after this one recovery
    // adoption only when their OpenWebUI write is durable; otherwise adoption
    // starts an owner-bound retry. Live snapshots remain bound for later
    // deltas. Content is deliberately never an identity: repeated short
    // answers such as "OK" are common across independent turns.
    for (final projection in projections) {
      if (matched.contains(projection)) continue;
      restored.add(projection.message);
      if (projection.finalized && projection.dispatchSettled) {
        store.markRecoveryDelivered(projection);
        _retryHermesProjectionPersistenceAfterAdoption(
          ref,
          conversation: conversation,
          projectionStore: store,
          projection: projection,
        );
      }
    }
    return List<ChatMessage>.unmodifiable(restored);
  }

  bool _hasLiveHermesProjection(
    Conversation conversation,
    ChatMessage message,
  ) {
    try {
      final owner = captureChatMutationOwner(ref, conversation);
      final projections = ref
          .read(_hermesRunProjectionStoreProvider)
          .forOwner(
            ownerConversationId: chatMutationOwnerScopeForConversation(
              conversation,
            ),
            backendIdentity: _hermesBackendIdentityForMutation(owner),
          );
      final transportId = _hermesMessageTransportId(message);
      return projections.any(
        (projection) =>
            projection.message.id == message.id ||
            (transportId != null &&
                _hermesMessageTransportId(projection.message) == transportId),
      );
    } catch (_) {
      return false;
    }
  }

  bool _canRecoverHermesCheckpointFromProvider(
    Conversation conversation,
    ChatMessage message,
  ) {
    if (!conversationUsesOpenWebUiStorage(conversation)) {
      return true;
    }
    try {
      final owner = _HermesConversationOwner.capture(ref, conversation);
      final provenance = _captureHermesMixedSessionProvenance(
        ref,
        owner: owner,
        databaseManager: ref.read(databaseManagerProvider),
      );
      return provenance != null &&
          _mixedHermesMessageHasLocalProvenance(message, provenance);
    } catch (_) {
      return false;
    }
  }

  void _cancelColdHermesRecovery() {
    _coldHermesRecoveryGeneration += 1;
    final token = _coldHermesRecoveryCancelToken;
    final key = _coldHermesRecoveryKey;
    _coldHermesRecoveryCancelToken = null;
    _coldHermesRecoveryKey = null;
    _coldHermesRecoveryMessageId = null;
    if (token == null || token.isCancelled) return;
    try {
      if (key != null) {
        // Owner changes only detach this local recovery attempt. They must not
        // invoke the registry's user-stop callback or stop the durable remote
        // run; a replacement service can immediately resume the same checkpoint.
        ref.read(hermesRunRegistryProvider).complete(key, cancelToken: token);
      }
      token.cancel('Hermes checkpoint owner changed');
    } catch (_) {
      token.cancel('Hermes checkpoint owner changed');
    }
  }

  ChatMessageError? _coldHermesTerminalError(String status) {
    return switch (status) {
      'completed' => null,
      'cancelled' || 'canceled' => const ChatMessageError(
        content: 'Hermes run was cancelled.',
      ),
      'stopped' => const ChatMessageError(content: 'Hermes run was stopped.'),
      'incomplete' => const ChatMessageError(
        content: 'Hermes stopped this response before it completed.',
      ),
      _ => const ChatMessageError(content: 'Hermes run failed.'),
    };
  }

  void _settleColdHermesCheckpoint(
    _HermesConversationOwner owner,
    ChatMessage checkpoint, {
    String? authoritativeContent,
    ChatMessageError? error,
  }) {
    if (!owner.isActive(ref)) return;
    updateMessageById(checkpoint.id, (current) {
      if (current.metadata?['transport'] != kHermesTransport) return current;
      return current.copyWith(
        content: authoritativeContent != null && authoritativeContent.isNotEmpty
            ? authoritativeContent
            : current.content,
        error: error,
      );
    });
    finishStreamingMessage(
      checkpoint.id,
      ownerConversationId: owner.scopedConversationId,
      requireConversationOwner: true,
    );
  }

  Future<void> _recoverColdHermesCheckpointIfNeeded(
    Conversation conversation, {
    bool settleUnrecoverable = false,
    String? expectedMessageId,
  }) async {
    if (_disposed || state.isEmpty) return;
    final checkpoint = state.last;
    if (checkpoint.role != 'assistant' ||
        (expectedMessageId != null && checkpoint.id != expectedMessageId) ||
        !checkpoint.isStreaming ||
        isRestoredHermesDesktopRunningMessage(checkpoint) ||
        checkpoint.metadata?['transport'] != kHermesTransport ||
        _hasLiveHermesProjection(conversation, checkpoint) ||
        _coldHermesRecoveryMessageId == checkpoint.id) {
      return;
    }

    final owner = _HermesConversationOwner.capture(ref, conversation);
    final service = ref.read(hermesApiServiceProvider);
    if (service == null) {
      if (settleUnrecoverable) {
        _settleColdHermesCheckpoint(
          owner,
          checkpoint,
          error: const ChatMessageError(
            content: 'Hermes recovery service is unavailable.',
          ),
        );
      }
      return;
    }
    if (service is! HermesApiService) {
      if (settleUnrecoverable) {
        _settleColdHermesCheckpoint(
          owner,
          checkpoint,
          error: const ChatMessageError(
            content: 'Hermes Desktop will reconcile this session when opened.',
          ),
        );
      }
      return;
    }
    if (!_canRecoverHermesCheckpointFromProvider(conversation, checkpoint)) {
      if (settleUnrecoverable) {
        _settleColdHermesCheckpoint(
          owner,
          checkpoint,
          error: const ChatMessageError(
            content: 'Hermes checkpoint ownership could not be verified.',
          ),
        );
      }
      return;
    }

    final metadata = checkpoint.metadata ?? const <String, dynamic>{};
    final runId = metadata['hermesRunId'] is String
        ? metadata['hermesRunId'] as String
        : null;
    final responseId = metadata['hermesResponseId'] is String
        ? metadata['hermesResponseId'] as String
        : null;
    final transportMode = metadata['hermesTransportMode'] is String
        ? metadata['hermesTransportMode'] as String
        : null;
    if ((transportMode == kHermesResponsesMode && responseId == null) ||
        (transportMode != kHermesResponsesMode && runId == null)) {
      if (settleUnrecoverable) {
        _settleColdHermesCheckpoint(
          owner,
          checkpoint,
          error: const ChatMessageError(
            content: 'Hermes checkpoint is missing its recovery identifier.',
          ),
        );
      }
      return;
    }

    _cancelColdHermesRecovery();
    final generation = _coldHermesRecoveryGeneration;
    final cancelToken = CancelToken();
    final key = owner.runKey(checkpoint.id);
    final registry = ref.read(hermesRunRegistryProvider);
    final recoverySettled = Completer<void>();
    _coldHermesRecoveryCancelToken = cancelToken;
    _coldHermesRecoveryKey = key;
    _coldHermesRecoveryMessageId = checkpoint.id;
    registry.registerPending(
      key,
      cancelToken: cancelToken,
      cancellationSettled: recoverySettled.future,
      onCancelled: () {
        _settleColdHermesCheckpoint(owner, checkpoint);
      },
    );
    final cleanupSubscription = const Stream<void>.empty().listen((_) {});
    final attached = transportMode == kHermesResponsesMode
        ? registry.attachStream(
            key,
            cancelToken: cancelToken,
            subscription: cleanupSubscription,
          )
        : registry.attachRun(
            key,
            cancelToken: cancelToken,
            runId: runId!,
            subscription: cleanupSubscription,
            stopRemote: (id) => service.stopRun(id),
          );
    if (!attached) {
      if (!recoverySettled.isCompleted) recoverySettled.complete();
      registry.complete(key, cancelToken: cancelToken);
      if (identical(_coldHermesRecoveryCancelToken, cancelToken)) {
        _coldHermesRecoveryCancelToken = null;
        _coldHermesRecoveryKey = null;
        _coldHermesRecoveryMessageId = null;
      }
      return;
    }

    try {
      final recovered = await recoverHermesCheckpoint(
        service: service,
        runId: runId,
        responseId: responseId,
        transportMode: transportMode,
        cancelToken: cancelToken,
      );
      if (recovered == null ||
          cancelToken.isCancelled ||
          _disposed ||
          generation != _coldHermesRecoveryGeneration ||
          !identical(ref.read(hermesApiServiceProvider), service) ||
          !owner.isActive(ref) ||
          !registry.owns(key, cancelToken: cancelToken)) {
        return;
      }
      _settleColdHermesCheckpoint(
        owner,
        checkpoint,
        authoritativeContent: recovered.text,
        error: _coldHermesTerminalError(recovered.status),
      );
    } catch (_) {
      if (!cancelToken.isCancelled &&
          !_disposed &&
          generation == _coldHermesRecoveryGeneration &&
          identical(ref.read(hermesApiServiceProvider), service) &&
          owner.isActive(ref) &&
          registry.owns(key, cancelToken: cancelToken)) {
        _settleColdHermesCheckpoint(
          owner,
          checkpoint,
          error: const ChatMessageError(
            content: 'Hermes could not recover this interrupted response.',
          ),
        );
      }
    } finally {
      if (!recoverySettled.isCompleted) recoverySettled.complete();
      registry.complete(key, cancelToken: cancelToken);
      if (identical(_coldHermesRecoveryCancelToken, cancelToken)) {
        _coldHermesRecoveryCancelToken = null;
        _coldHermesRecoveryKey = null;
        _coldHermesRecoveryMessageId = null;
      }
    }
  }

  Future<void> _retryRetainedDirectFinalOutput({
    required DirectRunRegistry registry,
    required DirectFinalizedOutput output,
    required Conversation conversation,
    required ChatDatabaseLocation location,
    required String persistenceOwnerId,
    required Object? authSessionEpoch,
  }) async {
    await output.primaryPersistenceSettled;
    if (_disposed) return;
    if (!registry.beginRetainedPersistenceRetry(output)) return;
    final manager = _directDatabaseManager(ref, location);
    final managedDatabase =
        manager.serverIdForDatabase(location.database) != null ||
        _knownManagedDirectDatabases[location.database] == true;
    final lease = manager.tryAcquireLease(location.database);
    var persisted = false;
    try {
      // A null lease is expected for provider-test databases that were not
      // opened by DatabaseManager. For a managed database it means close or
      // deletion has already claimed the executor, so a retained retry must
      // wait for a later adoption against the reopened location.
      if (managedDatabase && lease == null) return;
      if (!registry.retainedFinalizedOutputIsCurrent(output)) return;
      SyncEngine? capturedSyncEngine;
      if (location.storage == ChatStorageKind.openWebUi) {
        try {
          capturedSyncEngine = ref.read(syncEngineProvider.notifier);
        } catch (_) {}
      }
      final owner = _DirectConversationOwner(
        conversationId: conversation.id,
        location: location,
        persistenceOwnerId: persistenceOwnerId,
        openWebUiAuthSessionEpoch: authSessionEpoch,
        openWebUiSyncEngine: capturedSyncEngine,
      );
      await _persistCompletedDirectAssistant(
        ref,
        owner: owner,
        assistant: output.message,
        isCurrentGeneration: () =>
            registry.retainedFinalizedOutputIsCurrent(output),
      );
      persisted = registry.retainedFinalizedOutputIsCurrent(output);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'retained-completion-persist-failed',
        scope: 'direct-connections/chat',
        error: error,
        stackTrace: stackTrace,
        data: {'conversationId': conversation.id},
      );
    } finally {
      registry.finishRetainedPersistenceRetry(output, persisted: persisted);
      await lease?.release();
    }
  }

  bool _shouldPreserveLocalAssistantStreamingState(
    ChatMessage localMessage,
    ChatMessage serverMessage, {
    required bool isStreamingTail,
    required bool serverHasAdditionalMessages,
  }) {
    if (!isStreamingTail || serverHasAdditionalMessages) {
      return false;
    }
    // The role / streaming / responseDone / error guards are all re-checked by
    // _isStaleStreamingAssistantEcho, so delegate directly rather than
    // duplicating them here.
    return _isStaleStreamingAssistantEcho(localMessage, serverMessage);
  }

  bool _isStaleStreamingAssistantEcho(
    ChatMessage localMessage,
    ChatMessage serverMessage,
  ) {
    if (localMessage.role != 'assistant' ||
        serverMessage.role != 'assistant' ||
        !localMessage.isStreaming ||
        serverMessage.isStreaming) {
      return false;
    }
    if (serverMessage.metadata?['responseDone'] == true ||
        serverMessage.error != null) {
      return false;
    }
    // Deliberately does NOT gate on statusHistory, versions, or usage. Those
    // fields are populated on the assistant message *during* streaming — the
    // server pushes status/usage updates as content-empty, non-streaming
    // snapshots before the answer tokens arrive (see streaming_helper's status/
    // usage patches). Treating their presence as "a real completed update"
    // therefore retires the active stream prematurely and drops the typing
    // footer mid-turn. Real completion is proven by responseDone/error (guarded
    // above) or by non-empty content/output/files/embeds/followUps/sources/
    // codeExecutions, so a genuinely finished turn is never a metadata-only echo.
    return serverMessage.content.trim().isEmpty &&
        serverMessage.output?.isNotEmpty != true &&
        serverMessage.files?.isNotEmpty != true &&
        serverMessage.embeds?.isNotEmpty != true &&
        serverMessage.followUps.isEmpty &&
        serverMessage.sources.isEmpty &&
        serverMessage.codeExecutions.isEmpty;
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
    if (serverBodyDropsLocalSemanticDetails(
      localMessage.content,
      serverMessage.content,
    )) {
      return true;
    }
    if (serverBodyDropsLocalReasoningTiming(
      localMessage.content,
      serverMessage.content,
    )) {
      return true;
    }
    // Compare answer bodies with rendered semantic <details> wrappers
    // stripped. Local and server renders of the same turn carry different
    // details attributes (e.g. the locally measured reasoning duration vs the
    // server's own, or none at all), which would otherwise defeat both the
    // length and the prefix checks and let a mid-write server body replace a
    // complete local answer on every reasoning turn.
    final localContent = comparableAssistantBody(localMessage.content);
    final serverContent = comparableAssistantBody(serverMessage.content);
    if (localContent.isEmpty) {
      return localMessage.content.trim().isNotEmpty &&
          serverMessage.content.trim().isEmpty;
    }
    if (serverContent.isEmpty) {
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
    _passiveConversationGeneration++;
    _passiveConversationSocketSubscription?.dispose();
    _passiveConversationSocketSubscription = null;
    _passiveConversationRefreshTimer?.cancel();
    _passiveConversationRefreshTimer = null;
    _passiveConversationRefreshInFlight = false;
    _queuedPassiveConversationGeneration = null;
    _queuedPassiveConversationId = null;
    _queuedPassiveConversationSource = null;
    _queuedPassiveConversationOwner = null;
    _passiveConversationId = null;
    _passiveConversationSocket = null;
    _passiveConversationOwner = null;
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
    final generation = _passiveConversationGeneration;
    final owner = _passiveConversationOwner;
    if (owner == null) return;
    _passiveConversationRefreshTimer?.cancel();
    _passiveConversationRefreshTimer = Timer(_passiveRefreshDebounce, () {
      if (generation != _passiveConversationGeneration ||
          !identical(owner, _passiveConversationOwner) ||
          _passiveConversationId != conversationId ||
          activeOpenWebUiChatIdForMutation(ref, owner) == null) {
        return;
      }
      if (_passiveConversationRefreshInFlight) {
        _queuedPassiveConversationGeneration = generation;
        _queuedPassiveConversationId = conversationId;
        _queuedPassiveConversationSource = source;
        _queuedPassiveConversationOwner = owner;
        return;
      }

      unawaited(
        _refreshConversationFromServer(
          conversationId,
          source: source,
          generation: generation,
          owner: owner,
        ),
      );
    });
  }

  Future<void> _refreshConversationFromServer(
    String conversationId, {
    required String source,
    required int generation,
    required OpenWebUiCompletionOwner owner,
  }) async {
    if (generation != _passiveConversationGeneration ||
        !identical(owner, _passiveConversationOwner) ||
        _passiveConversationId != conversationId ||
        _passiveConversationRefreshInFlight ||
        _shouldProtectLocalStreamingState ||
        _isResumeStreamingActive) {
      return;
    }

    final activeConversation = ref.read(activeConversationProvider);
    if (activeConversation == null ||
        activeOpenWebUiChatIdForMutation(ref, owner) == null ||
        isDirectLocalConversation(activeConversation) ||
        activeConversation.id != conversationId) {
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
      if (generation != _passiveConversationGeneration ||
          !identical(_passiveConversationOwner, owner) ||
          _passiveConversationId != conversationId ||
          activeOpenWebUiChatIdForMutation(ref, owner) == null) {
        return;
      }

      final currentActive = ref.read(activeConversationProvider);
      if (currentActive == null ||
          isDirectLocalConversation(currentActive) ||
          currentActive.id != conversationId) {
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
      if (generation == _passiveConversationGeneration &&
          identical(owner, _passiveConversationOwner)) {
        _passiveConversationRefreshInFlight = false;
        final queuedGeneration = _queuedPassiveConversationGeneration;
        final queuedConversationId = _queuedPassiveConversationId;
        final queuedSource = _queuedPassiveConversationSource;
        final queuedOwner = _queuedPassiveConversationOwner;
        _queuedPassiveConversationGeneration = null;
        _queuedPassiveConversationId = null;
        _queuedPassiveConversationSource = null;
        _queuedPassiveConversationOwner = null;
        if (queuedGeneration == generation &&
            queuedConversationId != null &&
            queuedSource != null &&
            identical(queuedOwner, owner)) {
          _scheduleConversationRefreshFromServer(
            queuedConversationId,
            source: 'queued after $queuedSource',
          );
        }
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
    _pendingStreamingFlushReason = _StreamingContentFlushReason.cadence;
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
    _streamingProfileCharacters = message.content.length;
    _streamingProfileUtf8Bytes = PerformanceProfiler.isEnabled
        ? utf8.encode(message.content).length
        : 0;
    _streamingVisibleFlushCount = 0;
    _streamingCoalescedUpdateCount = 0;
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
    _streamingProfileCharacters += content.length;
    final chunkUtf8Bytes = PerformanceProfiler.isEnabled
        ? utf8.encode(content).length
        : 0;
    _streamingProfileUtf8Bytes += chunkUtf8Bytes;
    if (_streamingProfileChunkCount == 1 ||
        _streamingProfileChunkCount % 25 == 0) {
      PerformanceProfiler.instance.instant(
        'chat_stream_chunk',
        scope: 'chat',
        data: {
          'messageId': lastMessage.id,
          'chunkCount': _streamingProfileChunkCount,
          'chunkCharacters': content.length,
          'chunkUtf8Bytes': chunkUtf8Bytes,
          'bufferCharacters': _streamingProfileCharacters,
          'bufferUtf8Bytes': _streamingProfileUtf8Bytes,
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
    _streamingProfileCharacters = lastMessage.content.length;
    _streamingProfileUtf8Bytes = PerformanceProfiler.isEnabled
        ? utf8.encode(lastMessage.content).length
        : 0;
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
    final buffer = _streamingBuffer;
    _streamingProfileCharacters = buffer?.length ?? lastMessage.content.length;
    _streamingProfileUtf8Bytes = PerformanceProfiler.isEnabled
        ? utf8.encode(buffer?.toString() ?? lastMessage.content).length
        : 0;
  }

  void _finishStreamingProfile({required String reason, ChatMessage? message}) {
    final taskKey = _streamingProfileTaskKey;
    final messageId = _streamingProfileMessageId;
    if (taskKey == null || messageId == null) {
      _streamingProfileTaskKey = null;
      _streamingProfileMessageId = null;
      _streamingProfileStartedAt = null;
      _streamingProfileChunkCount = 0;
      _streamingProfileCharacters = 0;
      _streamingProfileUtf8Bytes = 0;
      return;
    }

    final elapsed = _streamingProfileStartedAt == null
        ? null
        : DateTime.now().difference(_streamingProfileStartedAt!);
    final finalMessage = message ?? (_disposed ? null : state.lastOrNull);
    PerformanceProfiler.instance.finishTask(
      taskKey,
      data: {
        'messageId': messageId,
        'reason': reason,
        'chunkCount': _streamingProfileChunkCount,
        'bufferCharacters': _streamingProfileCharacters,
        'bufferUtf8Bytes': _streamingProfileUtf8Bytes,
        'visibleFlushCount': _streamingVisibleFlushCount,
        'coalescedUpdateCount': _streamingCoalescedUpdateCount,
        'elapsedMs': elapsed?.inMilliseconds ?? 0,
        'finalLength': finalMessage?.content.length ?? 0,
      },
    );
    _streamingProfileTaskKey = null;
    _streamingProfileMessageId = null;
    _streamingProfileStartedAt = null;
    _streamingProfileChunkCount = 0;
    _streamingProfileCharacters = 0;
    _streamingProfileUtf8Bytes = 0;
  }

  void _markStreamingBufferChanged() {
    _streamingBufferVersion += 1;
  }

  void _clearStreamingBuffer() {
    _streamingBuffer = null;
    _pendingStreamingSnapshot = null;
    _streamingBufferVersion = 0;
    _lastFlushedStreamingBufferVersion = -1;
  }

  void _realizePendingStreamingSnapshot() {
    final snapshot = _pendingStreamingSnapshot;
    if (snapshot == null) return;
    _pendingStreamingSnapshot = null;
    try {
      _streamingBuffer = StringBuffer(_stripStreamingPlaceholders(snapshot()));
    } catch (error) {
      DebugLogger.log(
        'Deferred streaming projection failed: $error',
        scope: 'chat/providers',
      );
    }
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
    _boundRemoteMessageOwnerId = localMessageId;
  }

  void _clearBoundRemoteMessageId({String? ownedByMessageId}) {
    if (ownedByMessageId != null &&
        _boundRemoteMessageOwnerId != ownedByMessageId) {
      return;
    }
    _boundRemoteMessageId = null;
    _boundRemoteMessageOwnerId = null;
  }

  void _cancelMessageStream({bool clearStreamingContent = true}) {
    final controller = _messageStream;
    _messageStream = null;
    _activeStreamingTransportMessageId = null;
    _clearBoundRemoteMessageId();
    if (controller != null && controller.isActive) {
      unawaited(controller.cancel());
    }
    cancelSocketSubscriptions();
    // Fold any un-flushed streamed content into state before dropping the
    // buffer — it is not periodically synced, so clearing it here would
    // silently discard the whole tail of an in-flight response (e.g. on
    // conversation switch or message deletion mid-stream). Skipped during
    // provider dispose, where touching state is forbidden and pointless.
    if (!_disposed) {
      _syncStreamingBufferToState();
    }
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

    // Find the same message in server messages by local id, or by the foreign
    // id a socket resume bound to this tail (`_boundRemoteMessageId`).
    final serverMsg = serverMessages.where(
      (m) =>
          m.id == localStreamingMsg.id ||
          (_boundRemoteMessageId != null && m.id == _boundRemoteMessageId),
    );
    if (serverMsg.isNotEmpty && !serverMsg.first.isStreaming) {
      final serverMessage = serverMsg.first;
      // A stale empty non-streaming echo of the in-flight assistant must not
      // retire the stream — UNLESS the server has already moved past this turn
      // (it carries more messages than we hold locally), which proves the turn
      // completed and the echo is no longer the tail. Mirrors the
      // additional-messages guard in _shouldPreserveLocalAssistantStreamingState
      // so the cleanup and preserve paths agree.
      final serverHasAdditionalMessages = serverMessages.length > state.length;
      if (!serverHasAdditionalMessages &&
          _isStaleStreamingAssistantEcho(localStreamingMsg, serverMessage)) {
        DebugLogger.log(
          'Ignoring stale non-streaming server echo for active message '
          '${localStreamingMsg.id}',
          scope: 'chat/providers',
        );
        return false;
      }
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

  @visibleForTesting
  bool debugShouldCleanupStreamingFromServer(
    List<ChatMessage> serverMessages,
  ) => _shouldCleanupStreamingFromServer(serverMessages);

  bool get _hasStreamingAssistant {
    if (state.isEmpty) return false;
    final last = state.last;
    return last.role == 'assistant' && last.isStreaming;
  }

  /// Whether the visible tail can be recovered through OpenWebUI's task API.
  ///
  /// Storage and transport are independent: a Hermes/direct turn may live in
  /// an OpenWebUI-backed chat, but its lifecycle remains owned by that provider
  /// and must never start an OpenWebUI task poll. A null transport marker is a
  /// normal OpenWebUI preseed/resume shape and therefore remains eligible.
  bool _hasOpenWebUiTaskRecoverableTail(
    Conversation? conversation, {
    bool requireStreaming = true,
  }) {
    if (state.isEmpty ||
        state.last.role != 'assistant' ||
        (requireStreaming && !state.last.isStreaming) ||
        !_conversationUsesOpenWebUiContext(conversation)) {
      return false;
    }
    final transport = state.last.metadata?['transport'];
    return transport != kDirectTransport && transport != kHermesTransport;
  }

  bool get _hasTrackedStreamingTransport {
    return _activeStreamingTransportMessageId != null ||
        _messageStream != null ||
        _socketSubscriptions.isNotEmpty ||
        _socketTeardown != null ||
        _taskStatusTimer != null ||
        _remoteTaskMonitorMessageId != null ||
        _taskStatusCheckInFlight;
  }

  bool get _isReopenedStreamingTail =>
      _reopenedStreamingMessageId != null &&
      state.isNotEmpty &&
      state.last.role == 'assistant' &&
      state.last.isStreaming &&
      (state.last.id == _reopenedStreamingMessageId ||
          state.last.id == _boundRemoteMessageId);

  bool get _shouldProtectLocalStreamingState {
    if (!_hasStreamingAssistant || state.isEmpty) {
      return false;
    }

    final lastMessageId = state.last.id;
    // Direct and Hermes reservations/runs do not use the notifier's HTTP/socket
    // transport fields. Their streaming placeholders are nevertheless locally
    // authoritative until dispatch finalizes them; a Drift echo emitted during
    // preflight must not roll an optimistic turn back to the previous tip.
    final transport = state.last.metadata?['transport'];
    if (transport == kDirectTransport || transport == kHermesTransport) {
      return true;
    }
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

  @visibleForTesting
  bool get debugHasOpenWebUiTaskRecoverableTail =>
      _hasOpenWebUiTaskRecoverableTail(ref.read(activeConversationProvider));

  /// Test-only view of the socket-resume grace-poll counter so the
  /// double-finalize race guard (Feature C: "socket done wins / poll defers")
  /// can be asserted across poll iterations without coupling to private state.
  @visibleForTesting
  int get debugTasksDoneGracePolls => _tasksDoneGracePolls;

  @visibleForTesting
  int get debugReopenedSocketCatchUpPollsRemaining =>
      _reopenedSocketCatchUpPollsRemaining;

  @visibleForTesting
  void debugPrimeReopenedSnapshotAttempt({int catchUpPolls = 0}) {
    _reopenedSocketCatchUpPollsRemaining = catchUpPolls;
    _lastReopenedSnapshotAt = null;
  }

  /// Test-only entry point that drives one remote-task monitor iteration. Lets
  /// grace-window regression tests exercise [_syncRemoteTaskStatus]
  /// deterministically.
  @visibleForTesting
  Future<void> debugSyncRemoteTaskStatus() =>
      _syncRemoteTaskStatus(scheduleNext: false);

  /// Test-only hook that cancels just the scheduled poll timer without
  /// clearing observed-task / grace state, so a test can drive poll iterations
  /// manually via [debugSyncRemoteTaskStatus] without the timer racing them.
  @visibleForTesting
  void debugCancelRemoteTaskMonitorTimer() {
    _taskStatusTimer?.cancel();
    _taskStatusTimer = null;
  }

  @visibleForTesting
  bool get debugHasRemoteTaskMonitor => _remoteTaskMonitorMessageId != null;

  @visibleForTesting
  bool get debugHasRemoteTaskPollScheduled =>
      _taskStatusTimer?.isActive ?? false;

  @visibleForTesting
  String? get debugBoundRemoteMessageId => _boundRemoteMessageId;

  /// Installs a dormant task monitor owned by [messageId]. This models a
  /// reopened poll-only stream without starting a real status request.
  @visibleForTesting
  void debugInstallRemoteTaskMonitor(String messageId) {
    _stopRemoteTaskMonitor();
    _remoteTaskMonitorMessageId = messageId;
    _taskStatusTimer = Timer(const Duration(days: 1), () {});
  }

  /// Test-only view of the poll re-entry guard so a test can confirm no
  /// background poll is mid-flight before driving deterministic manual polls.
  @visibleForTesting
  bool get debugTaskStatusCheckInFlight => _taskStatusCheckInFlight;

  /// True while streaming was re-engaged for a reopened, server-active chat
  /// (typing indicator + recovery monitor) with no genuine local transport. The
  /// progressive poll owns content updates during this window; passive server
  /// refreshes must not clobber the streaming state and end it prematurely.
  bool get _isResumeStreamingActive =>
      _remoteTaskMonitorMessageId != null &&
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
    final remoteMonitorMessageId = _remoteTaskMonitorMessageId;
    final ownsPrimaryTransport =
        messageId == null || trackedMessageId == messageId;
    final ownsRemoteMonitor =
        messageId == null || remoteMonitorMessageId == messageId;
    if (!ownsPrimaryTransport && !ownsRemoteMonitor) {
      return;
    }

    DebugLogger.log(
      'Dropping stale transport state during $source '
      '(trackedMessage=${trackedMessageId ?? "unknown"}, '
      'monitorMessage=${remoteMonitorMessageId ?? "unknown"})',
      scope: 'chat/providers',
    );

    if (ownsPrimaryTransport) {
      // Cancel before releasing the only controller reference so late
      // transport callbacks cannot mutate state after it has been retired.
      final controller = _messageStream;
      _messageStream = null;
      _activeStreamingTransportMessageId = null;
      _clearBoundRemoteMessageId(ownedByMessageId: messageId);
      if (controller != null && controller.isActive) {
        unawaited(controller.cancel());
      }
      cancelSocketSubscriptions();
      _clearStreamingBuffer();
      _streamingSyncTimer?.cancel();
      _streamingSyncTimer = null;
      _streamingContentTimer?.cancel();
      _streamingContentTimer = null;
      _clearStreamingContent();
    }
    if (ownsRemoteMonitor) {
      _stopRemoteTaskMonitor(retiringMessageId: messageId);
    }
  }

  void retireObsoleteStreamingTransport(String messageId) {
    _dropStreamingTransportState(
      source: 'obsolete stream retirement',
      messageId: messageId,
    );
    if (_streamingProfileMessageId == messageId) {
      _finishStreamingProfile(reason: 'obsolete_stream_retirement');
    }
  }

  /// When a chat is opened that is still generating on the server, mark its
  /// last assistant message as streaming so the typing indicator + remote-task
  /// monitor engage. The server never sends `isStreaming`, so a reopened
  /// in-flight chat would otherwise render as an empty/partial response.
  Future<void> _detectActiveOnOpen(Conversation conversation) async {
    final chatId = conversation.id;
    if (_disposed ||
        isTemporaryChat(chatId) ||
        !_hasOpenWebUiTaskRecoverableTail(
          conversation,
          requireStreaming: false,
        )) {
      return;
    }
    // A genuine local stream owns this chat. A restored `isStreaming` value,
    // however, is only a crash/switch checkpoint and must be verified.
    if (_shouldProtectLocalStreamingState || state.isEmpty) {
      return;
    }
    final openedTail = state.last;
    if (openedTail.role != 'assistant') return;
    final openedMessageId = openedTail.id;
    final openedAsStreaming = openedTail.isStreaming;

    // Fast path: the active-chats set (populated by ActiveChatsSync) may already
    // know. Otherwise ask the server's task registry directly. Either way we
    // try to capture an active task id so the resumed message carries stoppable
    // task metadata (stop/delete can then cancel the server task, not just the
    // local subscription).
    final apiValue = _readApiServiceOrNull(ref);
    if (apiValue is! ApiService) return;
    final api = apiValue;
    final owner = captureOpenWebUiCompletionOwner(
      ref,
      chatId: chatId,
      api: api,
    );
    if (activeOpenWebUiChatIdForMutation(ref, owner) == null) return;
    String? resumeTaskId;
    var isActive = ref.read(activeChatIdsProvider).contains(chatId);
    if (!isActive) {
      try {
        final taskIds = await api.getTaskIdsByChat(chatId);
        if (activeOpenWebUiChatIdForMutation(ref, owner) == null) return;
        isActive = taskIds.isNotEmpty;
        resumeTaskId = taskIds.isNotEmpty ? taskIds.first : null;
      } catch (_) {
        // Keep a restored checkpoint recoverable while offline. A later monitor
        // poll will retry both the task registry and authoritative transcript.
        if (openedAsStreaming &&
            _stillOwnsReopenedTail(owner, openedMessageId)) {
          _engageReopenedTailMonitor(openedMessageId);
        }
        return;
      }
    } else {
      // Already known-active; best-effort task-id fetch for stoppable metadata.
      try {
        final taskIds = await api.getTaskIdsByChat(chatId);
        if (activeOpenWebUiChatIdForMutation(ref, owner) == null) return;
        resumeTaskId = taskIds.isNotEmpty ? taskIds.first : null;
      } catch (_) {
        // Best-effort only; resume still proceeds without a task id.
      }
    }

    if (_disposed ||
        !_stillOwnsReopenedTail(owner, openedMessageId) ||
        _shouldProtectLocalStreamingState) {
      return;
    }

    if (!isActive) {
      if (!openedAsStreaming) {
        _reopenedStreamingMessageId = null;
        _stopRemoteTaskMonitor();
        return;
      }

      // The app may have closed after the server task completed but before the
      // local checkpoint was finalized. Zero tasks is therefore a terminal
      // signal for an already-streaming restored tail: fetch the final branch
      // instead of waiting forever for a task this process never observed.
      final reconciled = await _refreshReopenedStreamFromServer(
        api: api,
        owner: owner,
        expectedLocalMessageId: openedMessageId,
        streaming: false,
        source: 'cold-open completion',
        persist: true,
      );
      if (reconciled) {
        _cancelMessageStream();
      } else if (_stillOwnsReopenedTail(owner, openedMessageId) &&
          _hasStreamingAssistant) {
        _engageReopenedTailMonitor(openedMessageId);
      }
      return;
    }

    // Rebase the entire active branch before attaching live deltas. Copying
    // only the assistant body leaves stale/missing user and assistant turns
    // around it after a DB-first reopen.
    _reopenedStreamingMessageId = openedMessageId;
    final rebaselined = await _refreshReopenedStreamFromServer(
      api: api,
      owner: owner,
      expectedLocalMessageId: openedMessageId,
      streaming: true,
      source: 'active-open baseline',
      persist: true,
    );
    if (!rebaselined) {
      if (openedAsStreaming && _stillOwnsReopenedTail(owner, openedMessageId)) {
        // Keep a durable checkpoint recoverable without attaching live socket
        // deltas to an assistant branch that the server snapshot could not
        // identify. The owner-fenced monitor can retry reconciliation later.
        _engageReopenedTailMonitor(openedMessageId);
      } else {
        _reopenedStreamingMessageId = null;
      }
      return;
    }

    if (_disposed ||
        activeOpenWebUiChatIdForMutation(ref, owner) == null ||
        state.isEmpty ||
        state.last.role != 'assistant' ||
        _shouldProtectLocalStreamingState) {
      return;
    }

    final currentConversation = ref.read(activeConversationProvider);
    if (!_hasOpenWebUiTaskRecoverableTail(
      currentConversation,
      requireStreaming: false,
    )) {
      return;
    }

    final last = state.last;
    if (!last.isStreaming) {
      state = [
        ...state.sublist(0, state.length - 1),
        last.copyWith(isStreaming: true),
      ];
    }
    _reopenedStreamingMessageId = state.last.id;
    // Pre-seed so the monitor's tasksDone finalization resolves once the server
    // task disappears (otherwise tasksDone could never become true).
    _observedRemoteTask = true;
    // Arm the authoritative fallback before socket attachment. The connection
    // can drop between the optimistic connected check and transport binding,
    // which may otherwise leave this chat without deltas or polling while the
    // socket reconnect attempt waits.
    _engageReopenedTailMonitor(state.last.id);
    // Attach a socket resume stream so deltas render token-by-token (mirroring
    // Open WebUI) instead of waiting on the recovery poll. The poll stays armed
    // as a safety-net fallback below. When no connected socket is available the
    // attach is a no-op and behaviour is identical to today's poll-only resume.
    await _attachResumeSocketStream(
      currentConversation ?? conversation,
      state.last,
      taskId: resumeTaskId,
    );
    if (_disposed ||
        activeOpenWebUiChatIdForMutation(ref, owner) == null ||
        !_hasStreamingAssistant) {
      return;
    }
    if (_shouldProtectLocalStreamingState) {
      // One fetch immediately after attachment and one on the next tick close
      // the emit-before-DB-write window in Open WebUI's event emitter. Beyond
      // that, full snapshots are only needed when socket activity stalls.
      _reopenedSocketCatchUpPollsRemaining = _reopenedSocketCatchUpPolls;
      _awaitingFirstReopenedSocketActivity = true;
      _lastStreamingActivity = DateTime.now();
    }
    _engageReopenedTailMonitor(state.last.id);
  }

  void _engageReopenedTailMonitor(String messageId) {
    _reopenedStreamingMessageId = messageId;
    _ensureRemoteTaskMonitor();
    // `_ensureRemoteTaskMonitor` may retire a monitor left by an earlier probe
    // and clear the recovery owner while it re-arms.
    _reopenedStreamingMessageId = messageId;
  }

  bool _stillOwnsReopenedTail(
    OpenWebUiCompletionOwner owner,
    String expectedMessageId,
  ) {
    if (_disposed ||
        activeOpenWebUiChatIdForMutation(ref, owner) == null ||
        state.isEmpty ||
        state.last.role != 'assistant') {
      return false;
    }
    return state.last.id == expectedMessageId ||
        state.last.id == _boundRemoteMessageId;
  }

  Future<bool> _refreshReopenedStreamFromServer({
    required ApiService api,
    required OpenWebUiCompletionOwner owner,
    required String expectedLocalMessageId,
    required bool streaming,
    required String source,
    bool persist = false,
  }) async {
    try {
      _lastReopenedSnapshotAt = DateTime.now();
      final serverConversation = await api.getConversation(owner.chatId);
      if (!_stillOwnsReopenedTail(owner, expectedLocalMessageId)) {
        return false;
      }
      final adopted = _reconcileReopenedServerSnapshot(
        serverConversation.messages,
        expectedLocalMessageId: expectedLocalMessageId,
        streaming: streaming,
        source: source,
      );
      if (adopted && persist) {
        schedulePullChatNow(ref, owner.chatId);
      }
      return adopted;
    } catch (error) {
      DebugLogger.log(
        'Reopened stream snapshot failed: $error',
        scope: 'chat/resume',
      );
      return false;
    }
  }

  bool _reconcileReopenedServerSnapshot(
    List<ChatMessage> serverMessages, {
    required String expectedLocalMessageId,
    required bool streaming,
    required String source,
  }) {
    if (serverMessages.isEmpty || state.isEmpty) return false;

    if (_hasStreamingAssistant) {
      // Socket chunks may still be waiting in the coalescing buffer. Fold them
      // into the comparison state before deciding whether the server snapshot
      // is newer.
      _readStreamingMessageComparisonSnapshot(state.last.id);
    }
    if (state.isEmpty || state.last.role != 'assistant') return false;

    final localTail = state.last;
    var remoteId = _boundRemoteMessageId;
    var serverIndex = serverMessages.lastIndexWhere(
      (message) =>
          message.role == 'assistant' &&
          (message.id == localTail.id ||
              message.id == expectedLocalMessageId ||
              (remoteId != null && message.id == remoteId)),
    );
    if (serverIndex < 0) {
      final inferredIndex = _inferReopenedRemoteAssistantIndex(
        serverMessages,
        localTail: localTail,
      );
      if (inferredIndex != null) {
        remoteId = serverMessages[inferredIndex].id;
        recordResumeBoundRemoteMessageId(localTail.id, remoteId);
        serverIndex = inferredIndex;
      }
    }
    if (serverIndex < 0) return false;
    // Open WebUI advances history.currentId on every streamed upsert. The
    // assistant being resumed must therefore be the fetched active-branch tip;
    // never mark an older assistant and the current tip as streaming together.
    if (streaming && serverIndex != serverMessages.length - 1) return false;

    final authoritativeServerTail = serverMessages[serverIndex];
    if (!streaming &&
        (authoritativeServerTail.content.trim().isEmpty ||
            _shouldPreserveLocalAssistantContent(
              localTail,
              authoritativeServerTail,
            ))) {
      DebugLogger.log(
        'Deferring reopened completion until the authoritative assistant '
        'body catches up',
        scope: 'chat/resume',
        data: {
          'messageId': localTail.id,
          'serverLength': authoritativeServerTail.content.length,
          'localLength': localTail.content.length,
        },
      );
      return false;
    }

    final mergedServerMessages = _preserveFreshLocalMessageState(
      serverMessages,
    );
    var serverTail = mergedServerMessages[serverIndex];
    final foreignLiveBinding =
        streaming &&
        remoteId != null &&
        serverTail.id == remoteId &&
        serverTail.id != localTail.id;
    if (foreignLiveBinding) {
      // Keep the local widget/transport identity until completion; every live
      // callback is scoped to it. The final settled snapshot may adopt the
      // server id once transport ownership is released.
      serverTail = serverTail.copyWith(id: localTail.id);
    }
    serverTail = serverTail.copyWith(isStreaming: streaming);

    final reconciled = List<ChatMessage>.from(mergedServerMessages);
    reconciled[serverIndex] = serverTail;
    state = List<ChatMessage>.unmodifiable(reconciled);

    if (streaming && state.last.role == 'assistant') {
      _streamingContentTimer?.cancel();
      _streamingContentTimer = null;
      _streamingBuffer = StringBuffer(state.last.content);
      _markStreamingBufferChanged();
      ref
          .read(streamingContentProvider.notifier)
          .set(state.last.content.isEmpty ? null : state.last.content);
      _syncStreamingProfileWithState();
    } else {
      _clearStreamingBuffer();
      _clearStreamingContent();
      _syncStreamingProfileWithState();
    }

    DebugLogger.log(
      'Reconciled reopened chat from $source '
      '(${serverMessages.length} authoritative messages)',
      scope: 'chat/resume',
    );
    return true;
  }

  int? _inferReopenedRemoteAssistantIndex(
    List<ChatMessage> serverMessages, {
    required ChatMessage localTail,
  }) {
    final localTailIndex = state.length - 1;
    final localParentId = _durableBranchParentId(state, localTailIndex);
    if (localParentId == null || localParentId.isEmpty) return null;

    int? match;
    for (var index = 0; index < serverMessages.length; index++) {
      final message = serverMessages[index];
      if (message.role != 'assistant' ||
          message.id == localTail.id ||
          _durableBranchParentId(serverMessages, index) != localParentId) {
        continue;
      }
      // Ambiguous siblings must wait for a socket binding or an exact ID. A
      // single assistant with the same durable user-parent is the only safe
      // foreign-ID mapping after process-local socket state has been lost.
      if (match != null) return null;
      match = index;
    }
    return match;
  }

  String? _durableBranchParentId(List<ChatMessage> messages, int messageIndex) {
    final metadataParent = messages[messageIndex].metadata?['parentId']
        ?.toString();
    if (metadataParent != null && metadataParent.isNotEmpty) {
      return metadataParent;
    }
    if (messageIndex <= 0) return null;
    return messages[messageIndex - 1].id;
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
  Future<void> _attachResumeSocketStream(
    Conversation conversation,
    ChatMessage last, {
    String? taskId,
  }) async {
    if (_disposed ||
        isTemporaryChat(conversation.id) ||
        !_hasOpenWebUiTaskRecoverableTail(conversation)) {
      return;
    }
    // A genuine local stream already owns this chat — never overwrite it.
    if (_shouldProtectLocalStreamingState) {
      return;
    }
    if (last.role != 'assistant') {
      return;
    }

    final api = ref.read(apiServiceProvider);
    if (api == null) {
      return;
    }
    final socketService = _readOpenWebUiSocketForApi(ref, api);
    if (socketService == null || !socketService.isConnected) {
      // No live socket — rely on the poll fallback (today's behaviour).
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
        : <String, dynamic>{'id': resolvedModelId, 'name': resolvedModelId};

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
    final resumeOwner = captureOpenWebUiCompletionOwner(
      ref,
      chatId: conversation.id,
      api: api,
    );

    try {
      await dispatchChatTransport(
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
        messageNotifier: this,
        ownsActiveConversation: () =>
            activeOpenWebUiChatIdForMutation(ref, resumeOwner) != null,
        ownsPendingPlaceholder: () =>
            _hasStreamingAssistant &&
            _stillOwnsReopenedTail(resumeOwner, last.id),
      );
    } catch (error) {
      DebugLogger.log(
        'Socket resume attachment failed: $error',
        scope: 'chat/resume',
      );
    }
  }

  void _ensureRemoteTaskMonitor() {
    if (!_hasOpenWebUiTaskRecoverableTail(
      ref.read(activeConversationProvider),
    )) {
      _stopRemoteTaskMonitor();
      return;
    }
    final messageId = state.last.id;
    if (_remoteTaskMonitorMessageId == messageId) {
      _bindRemoteTaskMonitorWakeups();
      if (_taskStatusTimer == null &&
          !_taskStatusCheckInFlight &&
          _isAppForeground) {
        _scheduleRemoteTaskPoll(Duration.zero);
      }
      return;
    }
    if (_remoteTaskMonitorMessageId != null || _taskStatusTimer != null) {
      _stopRemoteTaskMonitor(retiringMessageId: _remoteTaskMonitorMessageId);
    }

    // Recover aggressively for the first few seconds, then move to a bounded
    // cadence. A one-shot timer allows errors and server-body lag to back off
    // without leaving a fixed one-second radio wake running indefinitely.
    _remoteTaskMonitorMessageId = messageId;
    _remoteTaskFastPollsRemaining = _remoteTaskFastPollCount;
    _remoteTaskConsecutiveFailures = 0;
    _remoteTaskCompletionMisses = 0;
    _bindRemoteTaskMonitorWakeups();
    _scheduleRemoteTaskPoll(Duration.zero);
  }

  void _scheduleRemoteTaskPoll(Duration delay, {bool replace = false}) {
    if (_disposed || !_isAppForeground || _remoteTaskMonitorMessageId == null) {
      return;
    }
    if (!replace && (_taskStatusTimer?.isActive ?? false)) return;
    _taskStatusTimer?.cancel();
    _taskStatusTimer = Timer(delay, () {
      _taskStatusTimer = null;
      if (!_taskStatusCheckInFlight) {
        unawaited(_syncRemoteTaskStatus());
      }
    });
  }

  void _bindRemoteTaskMonitorWakeups() {
    final socket = ref.read(socketServiceProvider);
    if (identical(socket, _remoteTaskWakeSocket) &&
        _remoteTaskReconnectSubscription != null) {
      return;
    }
    unawaited(_remoteTaskReconnectSubscription?.cancel());
    _remoteTaskReconnectSubscription = null;
    _remoteTaskWakeSocket = socket;
    if (socket == null) return;
    _remoteTaskReconnectSubscription = socket.onReconnect.listen((_) {
      _wakeRemoteTaskMonitor();
    });
  }

  void _wakeRemoteTaskMonitor() {
    if (_disposed ||
        !_isAppForeground ||
        _remoteTaskMonitorMessageId == null ||
        !_hasOpenWebUiTaskRecoverableTail(
          ref.read(activeConversationProvider),
        )) {
      return;
    }
    _remoteTaskFastPollsRemaining = math.max(_remoteTaskFastPollsRemaining, 2);
    _remoteTaskConsecutiveFailures = 0;
    _scheduleRemoteTaskPoll(Duration.zero, replace: true);
  }

  void _stopRemoteTaskMonitor({String? retiringMessageId}) {
    _taskStatusTimer?.cancel();
    _taskStatusTimer = null;
    unawaited(_remoteTaskReconnectSubscription?.cancel());
    _remoteTaskReconnectSubscription = null;
    _remoteTaskWakeSocket = null;
    _remoteTaskMonitorMessageId = null;
    _taskStatusCheckInFlight = false;
    _taskStatusGeneration++;
    _remoteTaskFastPollsRemaining = 0;
    _remoteTaskConsecutiveFailures = 0;
    _remoteTaskCompletionMisses = 0;
    _observedRemoteTask = false;
    _tasksDoneGracePolls = 0;
    _unobservedReopenedEmptyPolls = 0;
    _reopenedStreamingMessageId = null;
    _reopenedSocketCatchUpPollsRemaining = 0;
    _awaitingFirstReopenedSocketActivity = false;
    _lastReopenedSnapshotAt = null;
    _clearBoundRemoteMessageId(ownedByMessageId: retiringMessageId);
  }

  void _stopNonTailToolTaskMonitor() {
    _nonTailToolTaskMonitors.clear();
  }

  bool _serverToolCallIsTerminal(
    Conversation conversation, {
    required String messageId,
    required String callId,
  }) {
    final message = conversation.messages
        .where((candidate) => candidate.id == messageId)
        .firstOrNull;
    final output = message?.output;
    if (output == null) return false;
    if (output.any(
      (item) =>
          item['type']?.toString() == 'function_call_output' &&
          item['call_id']?.toString().trim() == callId,
    )) {
      return true;
    }
    final call = output
        .where(
          (item) =>
              item['type']?.toString() == 'function_call' &&
              (item['call_id']?.toString().trim() ??
                      item['id']?.toString().trim()) ==
                  callId,
        )
        .firstOrNull;
    return const {
      'completed',
      'rejected',
      'failed',
      'cancelled',
      'canceled',
      'denied',
      'done',
    }.contains(call?['status']?.toString());
  }

  void _monitorNonTailToolTask({
    required ApiService api,
    required Conversation conversation,
    required String messageId,
    required String callId,
    required List<String> taskIds,
  }) {
    final monitor = Object();
    _nonTailToolTaskMonitors.add(monitor);
    final owner = captureOpenWebUiCompletionOwner(
      ref,
      chatId: conversation.id,
      api: api,
    );
    final expectedTaskIds = taskIds.toSet();
    final activeChats = ref.read(activeChatIdsProvider.notifier);
    activeChats.setActive(conversation.id);
    final activationToken = activeChats.activationToken(conversation.id);

    unawaited(() async {
      try {
        var fastPollsRemaining = _remoteTaskFastPollCount;
        var consecutiveFailures = 0;
        var hasActiveTask = true;

        while (!_disposed && _nonTailToolTaskMonitors.contains(monitor)) {
          if (!_isAppForeground) {
            await Future<void>.delayed(const Duration(seconds: 3));
            continue;
          }

          try {
            final activeChatId = activeOpenWebUiChatIdForMutation(ref, owner);
            if (activeChatId == null) return;
            final activeTaskIds = await api.getTaskIdsByChat(activeChatId);
            if (_disposed || !_nonTailToolTaskMonitors.contains(monitor)) {
              return;
            }
            if (activeOpenWebUiChatIdForMutation(ref, owner) != activeChatId) {
              return;
            }
            hasActiveTask = activeTaskIds.any(expectedTaskIds.contains);

            final serverConversation = await api.getConversation(activeChatId);
            if (_disposed || !_nonTailToolTaskMonitors.contains(monitor)) {
              return;
            }
            if (activeOpenWebUiChatIdForMutation(ref, owner) != activeChatId) {
              return;
            }
            // A returned task ID can remain absent from the registry for more
            // than one poll, and multiple returned tasks can register in
            // sequence. Only an authoritative terminal call result proves
            // that monitoring can stop while none of them is active.
            final awaitingTaskOrTerminal =
                !hasActiveTask &&
                !_serverToolCallIsTerminal(
                  serverConversation,
                  messageId: messageId,
                  callId: callId,
                );
            if (!awaitingTaskOrTerminal) {
              _adoptServerMessages(
                serverConversation.messages,
                source: 'non-tail tool task poll',
              );
            }
            if (hasActiveTask) {
              updateMessageById(messageId, (message) {
                return message.copyWith(
                  isStreaming: false,
                  metadata: <String, dynamic>{
                    ...?message.metadata,
                    'taskId': taskIds.first,
                    'taskConversationId': activeChatId,
                  },
                );
              });
            } else if (!awaitingTaskOrTerminal) {
              if (activeTaskIds.isEmpty) {
                activeChats.setInactiveIfUnchanged(
                  activeChatId,
                  activationToken,
                );
              }
              schedulePullChatNow(ref, activeChatId);
              return;
            }

            consecutiveFailures = 0;
            if (fastPollsRemaining > 0) fastPollsRemaining--;
          } catch (error, stack) {
            consecutiveFailures++;
            DebugLogger.error(
              'non-tail-tool-task-poll-failed',
              scope: 'chat/resume',
              error: error,
              stackTrace: stack,
            );
          }

          await Future<void>.delayed(
            debugRemoteTaskPollDelayForTesting(
              fastPollsRemaining: fastPollsRemaining,
              consecutiveFailures: consecutiveFailures,
              consecutiveCompletionMisses: 0,
              hasActiveTask: hasActiveTask,
            ),
          );
        }
      } finally {
        _nonTailToolTaskMonitors.remove(monitor);
      }
    }());
  }

  Future<void> _syncRemoteTaskStatus({bool scheduleNext = true}) async {
    if (_taskStatusCheckInFlight) {
      return;
    }
    final activeConversation = ref.read(activeConversationProvider);
    if (!_hasOpenWebUiTaskRecoverableTail(activeConversation)) {
      _stopRemoteTaskMonitor();
      return;
    }

    final api = ref.read(apiServiceProvider);
    if (api == null || activeConversation == null) {
      _stopRemoteTaskMonitor();
      return;
    }
    final owner = captureOpenWebUiCompletionOwner(
      ref,
      chatId: activeConversation.id,
      api: api,
    );
    final generation = _taskStatusGeneration;
    if (activeOpenWebUiChatIdForMutation(ref, owner) == null) return;

    _taskStatusCheckInFlight = true;
    var hasActiveTasks = false;
    var taskLookupSucceeded = false;
    var completionNeedsRetry = false;
    var completionGraceActive = false;
    try {
      // Check both task status and server message state
      final taskIds = await api.getTaskIdsByChat(activeConversation.id);
      taskLookupSucceeded = true;
      if (generation != _taskStatusGeneration ||
          activeOpenWebUiChatIdForMutation(ref, owner) == null) {
        return;
      }
      hasActiveTasks = taskIds.isNotEmpty;
      final reopenedTail = _isReopenedStreamingTail;

      if (hasActiveTasks) {
        _observedRemoteTask = true;
        _unobservedReopenedEmptyPolls = 0;
      } else if (reopenedTail && !_observedRemoteTask) {
        _unobservedReopenedEmptyPolls++;
      } else {
        _unobservedReopenedEmptyPolls = 0;
      }

      // A reopened checkpoint may have completed before this process observed
      // any task. If the initial task lookup failed, require two consecutive
      // empty registry observations before treating that checkpoint as done.
      // This retains eventual settlement without racing task registration.
      final tasksDone =
          !hasActiveTasks &&
          (_observedRemoteTask ||
              (reopenedTail &&
                  _unobservedReopenedEmptyPolls >
                      _unobservedReopenedEmptyPollGrace));
      DebugLogger.log(
        'Remote task recovery status',
        scope: 'chat/resume',
        data: {
          'chatId': activeConversation.id,
          'messageId': state.last.id,
          'active': hasActiveTasks,
          'reopened': reopenedTail,
          'protected': _shouldProtectLocalStreamingState,
        },
      );

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
      completionGraceActive = socketResumeGraceActive;
      final now = DateTime.now();
      final protectedResumeNeedsSnapshot =
          reopenedTail &&
          _shouldProtectLocalStreamingState &&
          (_reopenedSocketCatchUpPollsRemaining > 0 ||
              ((_lastStreamingActivity == null ||
                      now.difference(_lastStreamingActivity!) >=
                          _reopenedSocketStallThreshold) &&
                  (_lastReopenedSnapshotAt == null ||
                      now.difference(_lastReopenedSnapshotAt!) >=
                          _reopenedSocketStallThreshold)));
      final unprotectedResumeNeedsSnapshot =
          reopenedTail &&
          !_shouldProtectLocalStreamingState &&
          (_lastReopenedSnapshotAt == null ||
              now.difference(_lastReopenedSnapshotAt!) >=
                  _reopenedSocketStallThreshold);

      // Resume case: reconcile the complete authoritative branch while the
      // server task runs. A reattached socket only sees future events, so its
      // transport protection must not suppress snapshots that fill the gap
      // accumulated while another chat (or no app process) owned the screen.
      if (_hasStreamingAssistant &&
          hasActiveTasks &&
          (unprotectedResumeNeedsSnapshot || protectedResumeNeedsSnapshot)) {
        final expectedMessageId = _reopenedStreamingMessageId ?? state.last.id;
        if (_shouldProtectLocalStreamingState &&
            _reopenedSocketCatchUpPollsRemaining > 0) {
          // Consume the finite catch-up budget on attempt, even when the
          // fetched snapshot cannot bind to the local assistant branch.
          _reopenedSocketCatchUpPollsRemaining--;
        }
        await _refreshReopenedStreamFromServer(
          api: api,
          owner: owner,
          expectedLocalMessageId: expectedMessageId,
          streaming: true,
          source: 'active task poll',
        );
        if (_disposed ||
            generation != _taskStatusGeneration ||
            activeOpenWebUiChatIdForMutation(ref, owner) == null) {
          return;
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
        final expectedMessageId = _reopenedStreamingMessageId ?? state.last.id;
        final reconciled = await _refreshReopenedStreamFromServer(
          api: api,
          owner: owner,
          expectedLocalMessageId: expectedMessageId,
          streaming: false,
          source: 'completed task poll',
          persist: true,
        );
        if (generation != _taskStatusGeneration ||
            activeOpenWebUiChatIdForMutation(ref, owner) == null) {
          return;
        }
        if (reconciled) {
          _cancelMessageStream();
        } else {
          completionNeedsRetry = true;
        }
      }
    } catch (err, stack) {
      // Any failure in the iteration, including authoritative transcript
      // reconciliation after a successful task lookup, should cool the monitor
      // down rather than re-entering the steady cadence.
      taskLookupSucceeded = false;
      DebugLogger.error(
        'remote-task-poll-failed',
        scope: 'chat/resume',
        error: err,
        stackTrace: stack,
      );
    } finally {
      if (generation == _taskStatusGeneration) {
        _taskStatusCheckInFlight = false;
        if (taskLookupSucceeded) {
          _remoteTaskConsecutiveFailures = 0;
          _remoteTaskCompletionMisses = completionNeedsRetry
              ? _remoteTaskCompletionMisses + 1
              : 0;
        } else {
          _remoteTaskConsecutiveFailures++;
        }
        if (scheduleNext &&
            _remoteTaskMonitorMessageId != null &&
            _hasOpenWebUiTaskRecoverableTail(
              ref.read(activeConversationProvider),
            )) {
          final delay = completionGraceActive
              ? const Duration(seconds: 1)
              : debugRemoteTaskPollDelayForTesting(
                  fastPollsRemaining: _remoteTaskFastPollsRemaining,
                  consecutiveFailures: _remoteTaskConsecutiveFailures,
                  consecutiveCompletionMisses: _remoteTaskCompletionMisses,
                  hasActiveTask: hasActiveTasks,
                );
          if (_remoteTaskConsecutiveFailures == 0 &&
              _remoteTaskCompletionMisses == 0 &&
              _remoteTaskFastPollsRemaining > 0) {
            _remoteTaskFastPollsRemaining--;
          }
          _scheduleRemoteTaskPoll(delay, replace: true);
        }
      }
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
    if (_isReopenedStreamingTail &&
        _shouldProtectLocalStreamingState &&
        _awaitingFirstReopenedSocketActivity) {
      // The first live delta may follow a gap accumulated between the baseline
      // fetch and socket attachment. Guarantee one post-delta rebase without
      // paying for a full conversation fetch on every subsequent token.
      _awaitingFirstReopenedSocketActivity = false;
      _reopenedSocketCatchUpPollsRemaining = math.max(
        _reopenedSocketCatchUpPollsRemaining,
        1,
      );
    }
    if (!_hasOpenWebUiTaskRecoverableTail(
      ref.read(activeConversationProvider),
    )) {
      _stopRemoteTaskMonitor();
      return;
    }
    if (_hasStreamingAssistant) {
      // Reset observed flag each time a new streaming session starts.
      if (_remoteTaskMonitorMessageId == null) {
        _observedRemoteTask = false;
      }
      _ensureRemoteTaskMonitor();
    } else {
      _stopRemoteTaskMonitor();
    }
  }

  /// Reacts to the host's foreground/background transitions.
  ///
  /// The three-branch shape of the previous version collapses into two,
  /// because `inactive` and `resumed` were already being treated alike --
  /// which is exactly what `AppLifecyclePhase.isForeground` says. Defining
  /// that once, in the port, is what stops "foreground" meaning one thing
  /// here and another in the socket service.
  void _onLifecycleChanged(AppLifecyclePhase phase) {
    if (phase.isBackground) {
      _isAppForeground = false;
      // Flush whatever was buffered for the next frame: there will not be
      // another frame until the app comes back, and the text is already
      // parsed.
      if (_streamingContentFrameScheduled || _streamingContentTimer != null) {
        _scheduleStreamingContentFrame(reason: _pendingStreamingFlushReason);
      }
      _taskStatusTimer?.cancel();
      _taskStatusTimer = null;
      return;
    }
    if (!phase.isForeground) return;

    final wasForeground = _isAppForeground;
    _isAppForeground = true;
    if (!wasForeground) _wakeRemoteTaskMonitor();
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
    _flushStreamingContentUpdate(reason: _StreamingContentFlushReason.stop);
    _syncStreamingBufferToState();
    _cancelMessageStream(clearStreamingContent: false);
  }

  Future<void> _updateModelForConversation(
    Conversation conversation, {
    required int generation,
  }) async {
    // Check if conversation has a model specified
    if (conversation.model == null || conversation.model!.isEmpty) {
      return;
    }

    final conversationModelId = conversation.model!.trim();
    final currentSelectedModel = ref.read(selectedModelProvider);
    final directRegistry = ref.read(directModelRegistryProvider);
    final mutationOwner = captureChatMutationOwner(ref, conversation);

    bool stillOwnsSelection() =>
        !_disposed &&
        generation == _modelRebindGeneration &&
        identical(ref.read(directModelRegistryProvider), directRegistry) &&
        identical(ref.read(selectedModelProvider), currentSelectedModel) &&
        chatMutationTokenStillActive(ref, mutationOwner);

    final currentDirectBinding = currentSelectedModel == null
        ? null
        : directRegistry.resolve(currentSelectedModel);

    final currentMatchesPersistedModel =
        currentSelectedModel?.id == conversationModelId;
    final currentMatchesOpenWebUiDirectModel =
        currentDirectBinding?.source == DirectModelSource.openWebUi &&
        currentDirectBinding?.openWebUiModelId == conversationModelId;
    if (currentMatchesOpenWebUiDirectModel ||
        (currentMatchesPersistedModel &&
            !directRegistry.hasOpenWebUiWireModel(conversationModelId))) {
      return;
    }

    // Open WebUI persists the provider-facing id for direct models. Prefer the
    // current trusted synthetic model that owns that wire id before considering
    // a same-id server model, matching Open WebUI's direct-model last-wins rule.
    // Existing chats must keep using their saved model, even if an admin later
    // hides it from selectors.
    try {
      final api = ref.read(apiServiceProvider);
      final visibleModels = await ref.read(modelsProvider.future);
      if (!stillOwnsSelection()) return;
      Model? conversationModel = directRegistry.resolveOpenWebUiWireModel(
        visibleModels,
        conversationModelId,
      );
      conversationModel ??= visibleModels
          .where((model) => model.id == conversationModelId)
          .firstOrNull;

      // Locally minted direct models live only in modelsProvider and must never
      // be replaced by an untrusted server object with the same id.
      if (conversationModel == null && api != null) {
        final serverModels = await api.getModels(includeHidden: true);
        if (!stillOwnsSelection()) return;
        conversationModel = serverModels
            .where((model) => model.id == conversationModelId)
            .firstOrNull;
      }

      if (conversationModel == null ||
          identical(conversationModel, currentSelectedModel) ||
          !stillOwnsSelection()) {
        return;
      }
      ref
          .read(selectedModelProvider.notifier)
          .set(conversationModel, allowHidden: true);
    } catch (e) {
      // Model update failed - silently continue
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
    if (subscriptions.isNotEmpty && _isReopenedStreamingTail) {
      _reopenedSocketCatchUpPollsRemaining = math.max(
        _reopenedSocketCatchUpPollsRemaining,
        1,
      );
    }
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

  void removeMessageById(String messageId) {
    final next = state
        .where((message) => message.id != messageId)
        .toList(growable: false);
    if (next.length == state.length) return;
    state = next;
    _syncStreamingProfileWithState();
  }

  void clearMessages() {
    _streamingContentTimer?.cancel();
    _streamingContentTimer = null;
    _streamingSyncTimer?.cancel();
    _streamingSyncTimer = null;
    _clearStreamingBuffer();
    _clearStreamingContent();
    state = [];
    _finishStreamingProfile(reason: 'cleared');
  }

  void failLastStreamingAssistant(Object error, {String? assistantMessageId}) {
    if (state.isEmpty) {
      if (assistantMessageId != null) return;
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
      // An explicit id is an ownership boundary. Its late failure may arrive
      // after navigation, deletion, or replacement; it must never finalize the
      // unrelated assistant that happens to be visible now.
      if (assistantMessageId != null) return;
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
    if (state.last.id == target.id) {
      updateMessageById(
        target.id,
        (message) => message.copyWith(error: chatError),
      );
      finishStreaming();
      return;
    }
    // Update by id so the error lands on the captured message even if it is no
    // longer the list tail, and clear its streaming flag directly: finishStreaming()
    // only completes state.last, so a non-tail failed message would otherwise stay
    // stuck in isStreaming: true.
    updateMessageById(
      target.id,
      (message) => message.copyWith(error: chatError, isStreaming: false),
    );
    // The failed assistant can stop being the tail while its original
    // transport still owns callbacks and buffered timers. Retire only that
    // message's ownership; finishStreaming() would instead settle the newer,
    // unrelated tail.
    retireObsoleteStreamingTransport(target.id);
  }

  void setMessages(List<ChatMessage> messages) {
    state = _restoreLiveTransportRunState(
      messages,
      ref.read(activeConversationProvider),
    );
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

  Future<void> resumeAfterOpenWebUiToolCall({
    required String messageId,
    required String callId,
    required OpenWebUiToolCallAction action,
    required List<String> taskIds,
    Map<String, dynamic>? answers,
  }) async {
    final conversation = ref.read(activeConversationProvider);
    if (_disposed ||
        conversation == null ||
        isTemporaryChat(conversation.id) ||
        state.indexWhere((message) => message.id == messageId) == -1) {
      return;
    }
    final resumeTailOwnsTask =
        taskIds.isNotEmpty &&
        state.isNotEmpty &&
        state.last.id == messageId &&
        state.last.role == 'assistant';

    updateMessageById(messageId, (message) {
      final output = message.output;
      if (output == null) return message;
      final metadata = _metadataWithoutResponseDone(message.metadata);
      return message.copyWith(
        output: applyOpenWebUiToolCallResolution(
          output: output,
          callId: callId,
          action: action.name,
          answers: answers,
        ),
        isStreaming: resumeTailOwnsTask,
        metadata: taskIds.isNotEmpty
            ? <String, dynamic>{
                ...?metadata,
                'taskId': taskIds.first,
                'taskConversationId': conversation.id,
              }
            : metadata,
      );
    });

    if (taskIds.isNotEmpty && !resumeTailOwnsTask) {
      final api = ref.read(apiServiceProvider);
      if (api != null) {
        _monitorNonTailToolTask(
          api: api,
          conversation: conversation,
          messageId: messageId,
          callId: callId,
          taskIds: taskIds,
        );
      }
      return;
    }

    if (taskIds.isEmpty) {
      try {
        final pulled = await ref
            .read(syncEngineProvider.notifier)
            .pullChatNow(conversation.id);
        if (!_disposed &&
            ref.read(activeConversationProvider)?.id == conversation.id &&
            pulled != null) {
          _adoptServerMessages(pulled.messages, source: 'tool-call resolution');
        }
      } catch (_) {}
      return;
    }

    _reopenedStreamingMessageId = messageId;
    _observedRemoteTask = true;
    ref.read(activeChatIdsProvider.notifier).setActive(conversation.id);
    _engageReopenedTailMonitor(messageId);
    await _attachResumeSocketStream(
      conversation,
      state.last,
      taskId: taskIds.first,
    );
    if (!_disposed &&
        ref.read(activeConversationProvider)?.id == conversation.id &&
        state.isNotEmpty &&
        state.last.id == messageId &&
        state.last.isStreaming) {
      _engageReopenedTailMonitor(messageId);
    }
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
      final action = withTimestamp.action;
      if (action == 'reasoning') {
        final reasoningIndex = history.lastIndexWhere(
          (status) => status.action == action,
        );
        if (reasoningIndex >= 0) {
          if (_statusUpdatesEquivalent(
            history[reasoningIndex],
            withTimestamp,
          )) {
            return current;
          }
          history[reasoningIndex] = withTimestamp;
          return current.copyWith(statusHistory: history);
        }
      }

      final isHermesTool = action?.startsWith('hermes_tool_') ?? false;
      if (isHermesTool) {
        final pendingToolIndex = history.lastIndexWhere(
          (status) => status.action == action && status.done != true,
        );
        if (pendingToolIndex >= 0) {
          if (_statusUpdatesEquivalent(
            history[pendingToolIndex],
            withTimestamp,
          )) {
            return current;
          }
          history[pendingToolIndex] = withTimestamp;
          return current.copyWith(statusHistory: history);
        }
      }

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
        final updatesMatchingStatus =
            sameAction && sameDescription && !isHermesTool;
        if (updatesMatchingStatus) {
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

    // A direct append supersedes any deferred full projection. In practice the
    // reasoning path finalizes through replaceLastMessageContent first, but
    // realizing here keeps this public seam authoritative for every caller.
    _realizePendingStreamingSnapshot();
    // Initialize buffer with existing content on first chunk
    _streamingBuffer ??= StringBuffer(lastMessage.content);
    _streamingBuffer!.write(content);
    _markStreamingBufferChanged();
    _recordStreamingChunk(content);

    _scheduleStreamingContentUpdate();
    _touchStreamingActivity();
  }

  /// Appends a Hermes chunk to the assistant message that owns the run.
  ///
  /// Hermes runs can outlive a navigation transition. Never redirect a late
  /// chunk to whichever assistant happens to be the list tail at that point.
  void appendToMessageById(String messageId, String content) {
    if (content.isEmpty) return;
    final index = state.indexWhere((message) => message.id == messageId);
    if (index < 0) return;
    final message = state[index];
    if (message.role != 'assistant' || !message.isStreaming) return;
    if (index == state.length - 1) {
      appendToLastMessage(content);
      return;
    }
    updateMessageById(
      messageId,
      (current) => current.copyWith(content: '${current.content}$content'),
    );
  }

  void replaceMessageContentById(String messageId, String content) {
    final index = state.indexWhere((message) => message.id == messageId);
    if (index < 0) return;
    final message = state[index];
    if (message.role != 'assistant' || !message.isStreaming) return;
    if (index == state.length - 1) {
      replaceLastMessageContent(content);
      return;
    }
    updateMessageById(
      messageId,
      (current) => current.copyWith(content: content),
    );
  }

  /// Restores an authoritative direct-run placeholder after its persisted
  /// preflight echo was reloaded as non-streaming. The dispatcher must verify
  /// run-generation ownership before calling this method.
  void reconcileDirectStreamingMessageById(String messageId) {
    final index = state.indexWhere((message) => message.id == messageId);
    if (index < 0) return;
    final message = state[index];
    if (message.role != 'assistant' || message.isStreaming) return;
    final next = [...state];
    next[index] = message.copyWith(isStreaming: true);
    state = next;
    if (index == state.length - 1) {
      _beginStreamingProfile(next[index]);
      _touchStreamingActivity();
    }
  }

  bool isMessageStreaming(String messageId) => state.any(
    (message) =>
        message.id == messageId &&
        message.role == 'assistant' &&
        message.isStreaming,
  );

  /// Opaque identity for the visible projection owned by [messageId].
  ///
  /// Tail streaming updates retain their StringBuffer across appends. A chat
  /// reload clears that buffer even when the same assistant id is restored,
  /// allowing direct dispatch to detect A → B → A navigation that happened
  /// entirely between provider events without comparing the growing content.
  Object? directStreamingProjectionTokenForMessage(String messageId) {
    final index = state.indexWhere((message) => message.id == messageId);
    if (index < 0) return null;
    final message = state[index];
    if (message.role != 'assistant' || !message.isStreaming) return null;
    if (index == state.length - 1 && _streamingBuffer != null) {
      return _streamingBuffer;
    }
    return message;
  }

  void _scheduleStreamingContentUpdate({
    bool immediate = false,
    _StreamingContentFlushReason reason = _StreamingContentFlushReason.cadence,
  }) {
    if (_disposed || _streamingBuffer == null) {
      return;
    }
    if (!_isAppForeground) {
      _scheduleStreamingContentFrame(reason: reason);
      return;
    }
    final currentVisible = ref.read(streamingContentProvider);
    if (currentVisible == null || currentVisible.isEmpty) {
      _scheduleStreamingContentFrame(
        reason: _StreamingContentFlushReason.firstContent,
      );
      return;
    }
    if (immediate) {
      _scheduleStreamingContentFrame(reason: reason);
      return;
    }
    if (_streamingContentFrameScheduled || _streamingContentTimer != null) {
      return;
    }
    final lastFlushAt = _lastStreamingContentFlushAt;
    if (lastFlushAt == null) {
      _scheduleStreamingContentFrame(reason: reason);
      return;
    }
    final elapsed = DateTime.now().difference(lastFlushAt);
    final remaining = streamingContentUpdateInterval - elapsed;
    if (remaining <= Duration.zero) {
      _scheduleStreamingContentFrame(reason: reason);
      return;
    }
    _streamingContentTimer = Timer(
      remaining,
      () => _scheduleStreamingContentFrame(reason: reason),
    );
  }

  void _scheduleStreamingContentFrame({
    _StreamingContentFlushReason reason = _StreamingContentFlushReason.cadence,
  }) {
    _streamingContentTimer?.cancel();
    _streamingContentTimer = null;
    _pendingStreamingFlushReason = reason;
    if (_disposed) {
      return;
    }
    if (!_isAppForeground) {
      _streamingContentFrameScheduled = false;
      final flushReason = _pendingStreamingFlushReason;
      _pendingStreamingFlushReason = _StreamingContentFlushReason.cadence;
      _flushStreamingContentUpdate(reason: flushReason);
      return;
    }
    if (_streamingContentFrameScheduled) return;
    _streamingContentFrameScheduled = true;
    // Flush at the beginning of the requested frame so Riverpod can rebuild
    // the live tail in that same frame; `FlutterFlushScheduler` documents why
    // a frame callback rather than a post-frame one. The host decides, because
    // the conduitd sidecar runs this same pipeline with no frames at all.
    ref.read(flushSchedulerProvider).scheduleFlush(() {
      _streamingContentFrameScheduled = false;
      if (_disposed) {
        return;
      }
      final flushReason = _pendingStreamingFlushReason;
      _pendingStreamingFlushReason = _StreamingContentFlushReason.cadence;
      _flushStreamingContentUpdate(reason: flushReason);
    });
  }

  void _flushStreamingContentUpdate({
    _StreamingContentFlushReason reason = _StreamingContentFlushReason.cadence,
  }) {
    if (_disposed) {
      return;
    }
    _realizePendingStreamingSnapshot();
    final buffer = _streamingBuffer;
    if (buffer == null) return;
    if (_streamingBufferVersion == _lastFlushedStreamingBufferVersion) {
      return;
    }
    final previousVersion = _lastFlushedStreamingBufferVersion < 0
        ? 0
        : _lastFlushedStreamingBufferVersion;
    final coalescedUpdates = math.max(
      0,
      _streamingBufferVersion - previousVersion - 1,
    );
    final nextContent = buffer.toString();
    if (ref.read(streamingContentProvider) == nextContent) {
      _lastFlushedStreamingBufferVersion = _streamingBufferVersion;
      _streamingCoalescedUpdateCount += coalescedUpdates;
      return;
    }
    _lastStreamingContentFlushAt = DateTime.now();
    _lastFlushedStreamingBufferVersion = _streamingBufferVersion;
    _streamingVisibleFlushCount += 1;
    _streamingCoalescedUpdateCount += coalescedUpdates;
    PerformanceProfiler.instance.instant(
      'chat_stream_visible_flush',
      scope: 'chat',
      data: {
        'reason': reason.name,
        'bufferVersion': _streamingBufferVersion,
        'coalescedUpdates': coalescedUpdates,
        'contentCharacters': nextContent.length,
        if (PerformanceProfiler.isEnabled)
          'contentUtf8Bytes': utf8.encode(nextContent).length,
        'intervalMs': streamingContentUpdateInterval.inMilliseconds,
      },
    );
    ref.read(streamingContentProvider.notifier).set(nextContent);
  }

  ChatMessage _messageWithBufferedStreamingContent(ChatMessage message) {
    _realizePendingStreamingSnapshot();
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
    _flushStreamingContentUpdate(
      reason: _StreamingContentFlushReason.comparison,
    );
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
    _realizePendingStreamingSnapshot();
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
  void bufferLastMessageContent(String content, {bool immediate = true}) {
    if (state.isEmpty) return;

    final lastMessage = state.last;
    if (lastMessage.role != 'assistant' || !lastMessage.isStreaming) return;

    final sanitized = _stripStreamingPlaceholders(content);
    final hadPendingSnapshot = _pendingStreamingSnapshot != null;
    _pendingStreamingSnapshot = null;
    if (!hadPendingSnapshot && _streamingBuffer?.toString() == sanitized) {
      return;
    }
    _streamingBuffer = StringBuffer(sanitized);
    _markStreamingBufferChanged();
    _scheduleStreamingContentUpdate(
      immediate: immediate,
      reason: immediate
          ? _StreamingContentFlushReason.replacement
          : _StreamingContentFlushReason.cadence,
    );
    _touchStreamingActivity();
    _syncStreamingProfileWithBufferedContent();
  }

  /// Defers an expensive cumulative streaming projection until the same
  /// cadence that publishes visible content. Repeated transport deltas replace
  /// the pending snapshot without materializing or semantic-rendering every
  /// intermediate state.
  void bufferLastMessageContentSnapshot(String Function() snapshot) {
    if (state.isEmpty) return;

    final lastMessage = state.last;
    if (lastMessage.role != 'assistant' || !lastMessage.isStreaming) return;

    _streamingBuffer ??= StringBuffer(lastMessage.content);
    _pendingStreamingSnapshot = snapshot;
    _markStreamingBufferChanged();
    _scheduleStreamingContentUpdate();
    _touchStreamingActivity();
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
    final hadPendingSnapshot = _pendingStreamingSnapshot != null;
    _pendingStreamingSnapshot = null;
    if (!hadPendingSnapshot && _streamingBuffer?.toString() == sanitized) {
      return;
    }
    _streamingBuffer = StringBuffer(sanitized);
    _markStreamingBufferChanged();
    _scheduleStreamingContentUpdate(
      immediate: true,
      reason: _StreamingContentFlushReason.replacement,
    );
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
      final updatedActive = inheritNativeHermesConversationProvenance(
        activeConversation,
        activeConversation.copyWith(
          messages: List<ChatMessage>.unmodifiable(state),
          updatedAt: DateTime.now(),
        ),
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
                if (isSameStoredConversation(conversation, updatedActive)) {
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
    if (activeConversation != null &&
        !isTemporaryChat(activeConversation.id) &&
        !isDirectLocalConversation(activeConversation)) {
      try {
        refreshConversationsCache(ref);
      } catch (_) {}
    }
  }

  void _completeStreamingMessage({
    required bool releaseTransport,
    bool persistTurn = true,
  }) {
    _streamingContentTimer?.cancel();
    _streamingContentTimer = null;
    _flushStreamingContentUpdate(reason: _StreamingContentFlushReason.terminal);
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
    if (persistTurn) {
      _persistCompletedTurn();
    }
  }

  /// Ends a direct-provider run in memory without invoking the generic
  /// Open WebUI local-echo writer. The direct completion owner persists the
  /// stopped assistant in its recorded store once preflight/dispatch unwinds.
  void completeStoppedDirectStreamingUi(String messageId) {
    if (state.lastOrNull?.id != messageId) return;
    _completeStreamingMessage(releaseTransport: true, persistTurn: false);
  }

  /// Installs the final snapshot produced by a direct run's accumulator.
  /// Unlike generic stream completion this deliberately does not trust the
  /// current UI row: navigation may have reloaded a stale empty placeholder.
  void completeDirectStreamingMessage(
    ChatMessage completed, {
    required String ownerConversationId,
  }) {
    final active = ref.read(activeConversationProvider);
    if (active == null ||
        !_conversationMatchesDirectRunOwner(ref, active, ownerConversationId)) {
      return;
    }
    final index = state.indexWhere((message) => message.id == completed.id);
    if (index < 0 || state[index].role != 'assistant') return;
    final isTail = index == state.length - 1;
    if (isTail) {
      _streamingContentTimer?.cancel();
      _streamingContentTimer = null;
      _streamingSyncTimer?.cancel();
      _streamingSyncTimer = null;
      _clearStreamingBuffer();
      _clearStreamingContent();
    }
    final next = [...state];
    next[index] = completed.copyWith(
      isStreaming: false,
      content: _stripStreamingPlaceholders(completed.content),
    );
    state = next;
    if (isTail) {
      _finishStreamingProfile(reason: 'direct_completed', message: next[index]);
    }
    _syncConversationStateAfterStreamingUpdate();
  }

  void completeStreamingUi() {
    _completeStreamingMessage(releaseTransport: false);
  }

  void completeStreamingUiForMessage(
    String messageId, {
    String? ownerConversationId,
    bool requireConversationOwner = false,
  }) {
    if (requireConversationOwner &&
        !_isActiveConversationOwner(ownerConversationId)) {
      return;
    }
    if (state.lastOrNull?.id == messageId) {
      completeStreamingUi();
      return;
    }
    _completeNonTailStreamingMessage(
      messageId,
      ownerConversationId: ownerConversationId,
      requireConversationOwner: requireConversationOwner,
    );
  }

  void finishStreaming() {
    _completeStreamingMessage(releaseTransport: true);
  }

  void finishStreamingMessage(
    String messageId, {
    String? ownerConversationId,
    bool requireConversationOwner = false,
    bool persistTurn = true,
  }) {
    if (requireConversationOwner &&
        !_isActiveConversationOwner(ownerConversationId)) {
      return;
    }
    if (state.lastOrNull?.id == messageId) {
      _completeStreamingMessage(
        releaseTransport: true,
        persistTurn: persistTurn,
      );
      return;
    }
    _completeNonTailStreamingMessage(
      messageId,
      ownerConversationId: ownerConversationId,
      requireConversationOwner: requireConversationOwner,
      persistTurn: persistTurn,
    );
  }

  bool _isActiveConversationOwner(String? ownerConversationId) {
    final active = ref.read(activeConversationProvider);
    if (ownerConversationId == null) return active == null;
    return active != null &&
        (conversationMatchesScopedId(active, ownerConversationId) ||
            chatMutationOwnerScopeForConversation(active) ==
                ownerConversationId);
  }

  void _completeNonTailStreamingMessage(
    String messageId, {
    String? ownerConversationId,
    bool requireConversationOwner = false,
    bool persistTurn = true,
  }) {
    // A Hermes run can finish after navigation. Its callbacks own the chat
    // that launched the run, never whichever conversation is active now.
    if (requireConversationOwner &&
        !_isActiveConversationOwner(ownerConversationId)) {
      return;
    }
    final index = state.indexWhere((message) => message.id == messageId);
    if (index < 0) return;
    final message = state[index];
    if (message.role != 'assistant' || !message.isStreaming) return;

    final completed = message.copyWith(
      isStreaming: false,
      content: _stripStreamingPlaceholders(message.content),
    );
    state = [
      ...state.sublist(0, index),
      completed,
      ...state.sublist(index + 1),
    ];
    _syncConversationStateAfterStreamingUpdate();
    if (persistTurn) {
      _persistCompletedTurnForMessage(index);
    }
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

  void _persistCompletedTurnForMessage(int assistantIndex) {
    final activeId = ref.read(activeConversationProvider)?.id;
    if (activeId == null || activeId.isEmpty || isTemporaryChat(activeId)) {
      return;
    }
    if (assistantIndex < 0 || assistantIndex >= state.length) return;
    final assistant = state[assistantIndex];
    if (assistant.role != 'assistant' || assistant.isStreaming) return;

    ChatMessage? trailingUser;
    for (var index = assistantIndex - 1; index >= 0; index--) {
      if (state[index].role == 'user') {
        trailingUser = state[index];
        break;
      }
    }
    final db = _maybeDatabase();
    if (db == null) return;
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

  /// Reconciles stream leases the native background service could no longer
  /// protect. Live client transports keep their registry ownership; orphaned
  /// direct/Hermes checkpoints use their cold-recovery paths, while OpenWebUI
  /// streams re-enter the task/socket reconciliation flow.
  Future<void> reconcileBackgroundServiceFailure(
    Iterable<String> streamIds,
  ) async {
    const prefix = 'chat-stream-';
    final failedMessageIds = <String>{
      for (final streamId in streamIds)
        if (streamId.startsWith(prefix) && streamId.length > prefix.length)
          streamId.substring(prefix.length),
    };
    if (failedMessageIds.isEmpty || state.isEmpty) return;
    final target = state.last;
    if (target.role != 'assistant' ||
        !target.isStreaming ||
        !failedMessageIds.contains(target.id)) {
      return;
    }

    final activeAtFailure = ref.read(activeConversationProvider);
    if (activeAtFailure == null) return;
    await persistPauseCheckpoint();
    if (_disposed) return;
    final active = ref.read(activeConversationProvider);
    if (active == null || !isSameStoredConversation(activeAtFailure, active)) {
      return;
    }
    if (state.isEmpty ||
        state.last.id != target.id ||
        !state.last.isStreaming) {
      return;
    }

    final transport = target.metadata?['transport'];
    if (transport == kDirectTransport) {
      final restored = _restoreLiveDirectRunState(
        state,
        active,
        settleOrphaned: true,
      );
      if (!identical(restored, state)) {
        state = restored;
        _syncConversationStateAfterStreamingUpdate();
        _persistCompletedTurn();
      }
      return;
    }
    if (transport == kHermesTransport) {
      await _recoverColdHermesCheckpointIfNeeded(
        active,
        settleUnrecoverable: true,
      );
      return;
    }
    if (_hasOpenWebUiTaskRecoverableTail(active)) {
      if (_shouldProtectLocalStreamingState) {
        _ensureRemoteTaskMonitor();
      } else {
        await _detectActiveOnOpen(active);
      }
    }
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
              : localEchoRowForMessage(chatId, trailingUser),
          assistant: localEchoRowForMessage(chatId, assistant),
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
}

/// History-message shape for the local turn echo.
///
/// Top-level (rather than a notifier method) so tests can pin payload
/// completeness against the ChatMessage model.
///
/// The `parentId` written here is only a placeholder for the payload map:
/// `MessagesDao.upsertLocalEchoTurn` re-parents these rows via `_withParent`,
/// rewriting both the row and `payload['parentId']` to the branch tip.
///
/// The payload must carry every durable server-shape field the message has:
/// the sync outbox rebuilds the full chat blob from these rows and the
/// server's merge replaces each message object wholesale, so any field
/// omitted here (`output`, `sources`, `usage`, …) would be wiped from the
/// server copy on the next push.
///
/// `content` is stored the way the Open WebUI web client stores it: the plain
/// output text when `output` carries the turn (see
/// [persistedMessageContent]); the rendered `<details>` presentation is
/// re-synthesized from `output` on load.
MessageRowData localEchoRowForMessage(String chatId, ChatMessage message) {
  final timestamp = message.timestamp.millisecondsSinceEpoch ~/ 1000;
  final resolvedParentId = message_tree.chatMessageParentId(message);
  final childrenIds = message_tree
      .chatMessageChildrenIds(message)
      .toList(growable: false);
  final sanitizedFiles = sanitizeFilesForWebUi(message.files);
  return MessageRowData(
    id: message.id,
    chatId: chatId,
    parentId: resolvedParentId,
    role: message.role,
    content: persistedMessageContent(message),
    model: message.model,
    createdAt: timestamp,
    // Recomputed by upsertLocalEcho for new rows.
    orderIndex: 0,
    payload: <String, dynamic>{
      'id': message.id,
      'parentId': resolvedParentId,
      'childrenIds': childrenIds,
      'role': message.role,
      'content': persistedMessageContent(message),
      'timestamp': timestamp,
      'isStreaming': message.isStreaming,
      if (message.role == 'assistant' && !message.isStreaming) 'done': true,
      if (message.model != null) 'model': message.model,
      if (message.metadata != null && message.metadata!.isNotEmpty)
        'metadata': message.metadata,
      if (message.output != null && message.output!.isNotEmpty)
        'output': message.output,
      'files': ?sanitizedFiles,
      if (message.embeds != null && message.embeds!.isNotEmpty)
        'embeds': message.embeds,
      if (message.usage != null) 'usage': message.usage,
      // The OWUI web client reads `sources` in citation shape and
      // `code_executions` in snake_case; the local parser accepts both
      // shapes, so the server shape is the only safe one to persist.
      if (message.sources.isNotEmpty)
        'sources': convertSourcesToOpenWebUIFormat(message.sources),
      if (message.statusHistory.isNotEmpty)
        'statusHistory': message.statusHistory
            .map((status) => status.toJson())
            .toList(growable: false),
      if (message.codeExecutions.isNotEmpty)
        'code_executions': convertCodeExecutionsToOpenWebUIFormat(
          message.codeExecutions,
        ),
      if (message.followUps.isNotEmpty)
        'followUps': List<String>.from(message.followUps),
      if (message.error != null) 'error': message.error!.toJson(),
    },
  );
}
