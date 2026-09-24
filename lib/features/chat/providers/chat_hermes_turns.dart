part of 'chat_providers.dart';

typedef _HermesOpenWebUiBackendContext = ({
  AppDatabase? database,
  Object? api,
  Object authSessionEpoch,
});

final _hermesOpenWebUiBackendContextProvider =
    Provider<_HermesOpenWebUiBackendContext>((ref) {
      return (
        database: ref.watch(appDatabaseProvider),
        api: ref.watch(apiServiceProvider),
        authSessionEpoch: ref.watch(openWebUiAuthSessionEpochProvider),
      );
    });

ProviderSubscription<_HermesOpenWebUiBackendContext>
_listenForHermesOpenWebUiBackendChanges(
  dynamic ref,
  void Function(
    _HermesOpenWebUiBackendContext? previous,
    _HermesOpenWebUiBackendContext next,
  )
  listener,
) {
  if (ref is WidgetRef) {
    return ref.listenManual<_HermesOpenWebUiBackendContext>(
      _hermesOpenWebUiBackendContextProvider,
      listener,
      fireImmediately: true,
    );
  }
  if (ref is Ref) {
    return ref.listen<_HermesOpenWebUiBackendContext>(
      _hermesOpenWebUiBackendContextProvider,
      listener,
      fireImmediately: true,
    );
  }
  if (ref is ProviderContainer) {
    return ref.listen<_HermesOpenWebUiBackendContext>(
      _hermesOpenWebUiBackendContextProvider,
      listener,
      fireImmediately: true,
    );
  }
  throw StateError('Unsupported provider reader for Hermes streaming.');
}

class _HermesConversationOwner {
  _HermesConversationOwner._({
    required String? conversationId,
    required String scopedConversationId,
    required Conversation? conversationSnapshot,
    required ChatMutationOwnerToken mutationOwner,
    required HermesRunBackendIdentity? backendIdentity,
  }) : _conversationId = conversationId,
       _scopedConversationId = scopedConversationId,
       _conversationSnapshot = conversationSnapshot,
       _mutationOwner = mutationOwner,
       _backendIdentity = backendIdentity;

  factory _HermesConversationOwner.capture(
    dynamic ref,
    Conversation? conversation,
  ) => _HermesConversationOwner.fromMutationOwner(
    conversation,
    captureChatMutationOwner(ref, conversation),
  );

  factory _HermesConversationOwner.fromMutationOwner(
    Conversation? conversation,
    ChatMutationOwnerToken mutationOwner,
  ) {
    if (conversation != null) {
      return _HermesConversationOwner._(
        conversationId: conversation.id,
        scopedConversationId: chatMutationOwnerScopeForConversation(
          conversation,
        ),
        conversationSnapshot: conversation,
        mutationOwner: mutationOwner,
        backendIdentity: _hermesBackendIdentityForMutation(mutationOwner),
      );
    }
    return _HermesConversationOwner._(
      conversationId: null,
      scopedConversationId: 'conduit-hermes-pending://${const Uuid().v4()}',
      conversationSnapshot: null,
      mutationOwner: mutationOwner,
      backendIdentity: null,
    );
  }

  String? _conversationId;
  String _scopedConversationId;
  Conversation? _conversationSnapshot;
  final ChatMutationOwnerToken _mutationOwner;
  final HermesRunBackendIdentity? _backendIdentity;

  String get scopedConversationId => _scopedConversationId;
  String? get notifierConversationId =>
      _conversationId == null ? null : _scopedConversationId;
  bool get usesOpenWebUiBackend => _backendIdentity != null;

  HermesRunKey runKey(String assistantMessageId) => hermesRunKey(
    ownerConversationId: _scopedConversationId,
    assistantMessageId: assistantMessageId,
    backendIdentity: _backendIdentity,
  );

  bool canFollowOpenWebUiRemap(dynamic ref, {required String fromId}) =>
      _backendIdentity != null &&
      _conversationId == fromId &&
      ChatStorageIdentity.parse(_scopedConversationId).storage ==
          ChatStorageKind.openWebUi &&
      backendContextIsCurrent(ref);

  HermesRunKey openWebUiRunKey(
    String conversationId,
    String assistantMessageId,
  ) => hermesRunKey(
    ownerConversationId: openWebUiChatMutationOwnerScope(conversationId),
    assistantMessageId: assistantMessageId,
    backendIdentity: _backendIdentity,
  );

  void bindOpenWebUiRemap(String conversationId) {
    _conversationId = conversationId;
    _scopedConversationId = openWebUiChatMutationOwnerScope(conversationId);
    final snapshot = _conversationSnapshot;
    if (snapshot != null) {
      _conversationSnapshot = snapshot.copyWith(id: conversationId);
    }
  }

  bool isActive(dynamic ref) {
    if (_backendIdentity != null) {
      return chatMutationTokenStillActive(ref, _mutationOwner);
    }
    final active = ref.read(activeConversationProvider) as Conversation?;
    if (_conversationId == null) return active == null;
    return active != null &&
        chatMutationOwnerScopeForConversation(active) == _scopedConversationId;
  }

  bool backendContextIsCurrent(dynamic ref) {
    final backendIdentity = _backendIdentity;
    if (backendIdentity == null) return true;
    return identical(_readAppDatabaseOrNull(ref), backendIdentity.database) &&
        identical(_readApiServiceOrNull(ref), backendIdentity.api) &&
        identical(
          _readOpenWebUiAuthSessionEpoch(ref),
          backendIdentity.authSessionEpoch,
        );
  }

  void bind(Conversation conversation) {
    _conversationId = conversation.id;
    _scopedConversationId = chatMutationOwnerScopeForConversation(conversation);
    _conversationSnapshot = conversation;
  }
}

Future<String?> _resolveDurableHermesChatOwner(
  AppDatabase database,
  String candidateChatId,
) {
  return database.transaction(() async {
    final candidate = await database.chatsDao.getChat(candidateChatId);
    if (candidate != null) return candidate.deleted ? null : candidateChatId;

    final target = await database.syncMetaDao.getChatRemapTarget(
      candidateChatId,
    );
    if (target == null || target.isEmpty || target == candidateChatId) {
      return null;
    }
    final destination = await database.chatsDao.getChat(target);
    return destination == null || destination.deleted ? null : target;
  });
}

Future<void> _settleCommittedHermesTurnStart({
  required AppDatabase database,
  required ChatLocks locks,
  required String recordedChatId,
  required ChatMessage assistantMessage,
  required int updatedAt,
  String? failureContent,
}) async {
  final settled = assistantMessage.copyWith(
    isStreaming: false,
    error: failureContent == null
        ? assistantMessage.error
        : ChatMessageError(content: failureContent),
  );
  await persistWithResolvedDirectConversationOwner(
    locks: locks,
    recordedChatId: recordedChatId,
    resolveCurrentId: (candidate) => resolveDurableChatMessageOwner(
      database,
      recordedChatId: candidate,
      messageId: assistantMessage.id,
      expectedRole: 'assistant',
    ),
    persist: (currentId) => database.chatsDao.appendMessagesWithUpdateOp(
      chatId: currentId,
      messages: <MessageRowData>[
        _directMessageRow(
          chatId: currentId,
          message: settled,
          parentId: settled.metadata?['parentId']?.toString(),
          childrenIds: message_tree
              .chatMessageChildrenIds(settled)
              .toList(growable: false),
          orderIndex: 0,
          assistantTransport: kHermesTransport,
        ),
      ],
      currentMessageId: settled.id,
      updatedAt: updatedAt,
      enqueueUpdate: true,
      enqueueCompletion: false,
    ),
  );
}

typedef _HermesCommittedTurnStart = ({
  DatabaseLifetimeLease? databaseLease,
  Future<void> Function(ChatMessage assistantMessage) settle,
});

MessageRowData _hermesMessageRowForChat(MessageRowData row, String chatId) =>
    MessageRowData(
      id: row.id,
      chatId: chatId,
      parentId: row.parentId,
      role: row.role,
      content: row.content,
      model: row.model,
      createdAt: row.createdAt,
      orderIndex: row.orderIndex,
      payload: row.payload,
    );

/// Commits the optimistic mixed-backend turn before Hermes can receive it.
///
/// The captured database/auth owner and its lifetime lease remain attached to
/// the subsequent dispatch. A server-id remap is followed only when its
/// source-to-destination proof and destination chat are durable in that same
/// database; raw ids or the newly active backend are never consulted.
Future<_HermesCommittedTurnStart?> _persistHermesOpenWebUiTurnStart(
  dynamic ref, {
  required _HermesConversationOwner owner,
  required ChatMessage userMessage,
  required ChatMessage assistantMessage,
  required List<ChatMessage> allMessages,
  required ChatSendPlaceholderHandle sendHandle,
}) async {
  if (!owner.usesOpenWebUiBackend) return null;
  final database = owner._mutationOwner.openWebUiDatabase;
  final recordedChatId = owner._conversationId;
  if (database == null || recordedChatId == null || recordedChatId.isEmpty) {
    throw StateError('The OpenWebUI chat database is unavailable.');
  }
  if (!owner.backendContextIsCurrent(ref)) {
    throw StateError('The OpenWebUI backend changed before Hermes dispatch.');
  }

  final manager = ref.read(databaseManagerProvider) as DatabaseManager;
  final lease = manager.tryAcquireLease(database);
  if (manager.serverIdForDatabase(database) != null && lease == null) {
    throw StateError('The OpenWebUI chat database is closing.');
  }

  final locks = ref.read(chatLocksProvider) as ChatLocks;
  final now = ref.read(syncClockProvider).nowEpochSeconds();
  String? committedChatId;
  try {
    final parentId = userMessage.metadata?['parentId']?.toString();
    final parentMessage = parentId == null
        ? null
        : allMessages.where((message) => message.id == parentId).firstOrNull;
    final parentTransport = parentMessage?.metadata?['transport'];
    final parentRow = parentMessage == null
        ? null
        : _directMessageRow(
            chatId: recordedChatId,
            message: parentMessage,
            parentId: message_tree.chatMessageParentId(parentMessage),
            childrenIds: message_tree
                .chatMessageChildrenIds(parentMessage)
                .toList(growable: false),
            orderIndex: 0,
            // Updating an existing OpenWebUI parent link must not relabel that
            // earlier assistant as Hermes (or as a direct connection).
            assistantTransport: parentTransport is String
                ? parentTransport
                : null,
          );
    final userRow = _directMessageRow(
      chatId: recordedChatId,
      message: userMessage,
      parentId: parentId,
      childrenIds: <String>[assistantMessage.id],
      orderIndex: 0,
      assistantTransport: null,
    );
    final assistantRow = _directMessageRow(
      chatId: recordedChatId,
      message: assistantMessage,
      parentId: userMessage.id,
      childrenIds: const <String>[],
      orderIndex: 1,
      assistantTransport: kHermesTransport,
    );
    final resolvedChatId = await persistWithResolvedDirectConversationOwner(
      locks: locks,
      recordedChatId: recordedChatId,
      resolveCurrentId: (candidate) async {
        if (!owner.backendContextIsCurrent(ref)) return null;
        final resolved = await _resolveDurableHermesChatOwner(
          database,
          candidate,
        );
        return owner.backendContextIsCurrent(ref) ? resolved : null;
      },
      persist: (currentId) async {
        if (!owner.backendContextIsCurrent(ref)) {
          throw StateError(
            'The OpenWebUI backend changed before Hermes persistence.',
          );
        }
        List<MessageRowData> rowsFor(String chatId) => <MessageRowData>[
          if (parentRow != null) _hermesMessageRowForChat(parentRow, chatId),
          _hermesMessageRowForChat(userRow, chatId),
          _hermesMessageRowForChat(assistantRow, chatId),
        ];
        await database.chatsDao.appendMessagesWithUpdateOp(
          chatId: currentId,
          messages: rowsFor(currentId),
          currentMessageId: assistantMessage.id,
          updatedAt: now,
          enqueueUpdate: true,
          enqueueCompletion: false,
        );
        committedChatId = currentId;
        ref.read(hermesTurnStartPostCommitHookProvider)?.call();
        if (!owner.backendContextIsCurrent(ref)) {
          throw StateError(
            'The OpenWebUI backend changed during Hermes persistence.',
          );
        }
      },
    );
    if (resolvedChatId != recordedChatId) {
      owner.bindOpenWebUiRemap(resolvedChatId);
      sendHandle._bindOwnerScope(owner.scopedConversationId);
    }
    return (
      databaseLease: lease,
      settle: (settledAssistant) => _settleCommittedHermesTurnStart(
        database: database,
        locks: locks,
        recordedChatId: resolvedChatId,
        assistantMessage: settledAssistant,
        updatedAt: now,
      ),
    );
  } catch (_) {
    final committedOwner = committedChatId;
    if (committedOwner != null) {
      try {
        await _settleCommittedHermesTurnStart(
          database: database,
          locks: locks,
          recordedChatId: committedOwner,
          assistantMessage: assistantMessage,
          updatedAt: now,
          failureContent:
              'Hermes did not start because the OpenWebUI backend changed.',
        );
      } catch (_) {
        DebugLogger.error(
          'turn-start-failure-settlement-failed',
          scope: 'hermes/transport',
        );
      }
    }
    await lease?.release();
    rethrow;
  }
}

HermesRunBackendIdentity? _hermesBackendIdentityForMutation(
  ChatMutationOwnerToken owner,
) => owner.usesOpenWebUiContext
    ? HermesRunBackendIdentity.openWebUi(
        database: owner.openWebUiDatabase,
        api: owner.openWebUiApi,
        authSessionEpoch: owner.openWebUiAuthSessionEpoch,
      )
    : null;

/// Exact run address for a Hermes segment rendered inside [conversation].
/// OpenWebUI chats add their selected server/database identity so equal chat
/// and message ids on another configured server cannot expose or stop the run.
HermesRunKey hermesRunKeyForConversation(
  dynamic ref, {
  required Conversation conversation,
  required String assistantMessageId,
}) {
  final owner = captureChatMutationOwner(ref, conversation);
  return hermesRunKey(
    ownerConversationId: chatMutationOwnerScopeForConversation(conversation),
    assistantMessageId: assistantMessageId,
    backendIdentity: _hermesBackendIdentityForMutation(owner),
  );
}

typedef _HermesMixedSessionProvenance = ({
  String storageAccountIdentity,
  String conversationId,
});

_HermesMixedSessionProvenance? _captureHermesMixedSessionProvenance(
  dynamic ref, {
  required _HermesConversationOwner owner,
  required DatabaseManager databaseManager,
}) {
  final database = owner._mutationOwner.openWebUiDatabase;
  final conversationId = owner._conversationId;
  final authSessionEpoch = owner._mutationOwner.openWebUiAuthSessionEpoch;
  if (database == null ||
      conversationId == null ||
      conversationId.isEmpty ||
      authSessionEpoch == null) {
    return null;
  }

  final serverId = databaseManager.serverIdForDatabase(database);
  if (serverId == null) {
    return (
      storageAccountIdentity:
          HermesMixedSessionBindingTrustStore.runtimeStorageAccountIdentity(
            database: database,
            authSessionEpoch: authSessionEpoch,
          ),
      conversationId: conversationId,
    );
  }
  if (serverId.isEmpty) return null;

  try {
    final marker = ref
        .read(openWebUiAccountOwnerMarkerStoreProvider)
        .read(serverId);
    final token = ref.read(authTokenProvider3) as String?;
    final userId = ref.read(currentUserProvider2)?.id as String?;
    if (marker == null ||
        token == null ||
        userId == null ||
        !openWebUiAccountOwnerMarkerMatches(
          marker: marker,
          token: token,
          userId: userId,
        )) {
      return null;
    }
    return (
      storageAccountIdentity:
          HermesMixedSessionBindingTrustStore.durableStorageAccountIdentity(
            serverId: serverId,
            userId: marker.userId,
            tokenFingerprint: marker.tokenFingerprint,
          ),
      conversationId: conversationId,
    );
  } catch (_) {
    return null;
  }
}

bool _mixedHermesMessageHasLocalProvenance(
  ChatMessage message,
  _HermesMixedSessionProvenance provenance,
) {
  if (message.role != 'assistant') return false;
  final sessionId = validateHermesOpaqueIdentifier(
    message.metadata?['hermesSessionId'],
  );
  final connectionIdentity =
      message.metadata?[kHermesConnectionIdentityMetadataKey];
  if (sessionId == null ||
      connectionIdentity is! String ||
      connectionIdentity.isEmpty) {
    return false;
  }
  final responseId = message.metadata?['hermesResponseId'];
  final runId = message.metadata?['hermesRunId'];
  final transportMode = message.metadata?['hermesTransportMode'];
  return HermesMixedSessionBindingTrustStore.trusts(
    storageAccountIdentity: provenance.storageAccountIdentity,
    conversationId: provenance.conversationId,
    assistantMessageId: message.id,
    sessionId: sessionId,
    connectionIdentity: connectionIdentity,
    responseId: responseId is String ? responseId : null,
    runId: runId is String ? runId : null,
    transportMode: transportMode is String ? transportMode : null,
  );
}

Future<void> _rememberMixedHermesMessageProvenance(
  ChatMessage message,
  _HermesMixedSessionProvenance? provenance,
) async {
  if (provenance == null || message.role != 'assistant') return;
  final sessionId = validateHermesOpaqueIdentifier(
    message.metadata?['hermesSessionId'],
  );
  final connectionIdentity =
      message.metadata?[kHermesConnectionIdentityMetadataKey];
  if (sessionId == null ||
      connectionIdentity is! String ||
      connectionIdentity.isEmpty) {
    return;
  }
  final responseId = message.metadata?['hermesResponseId'];
  final runId = message.metadata?['hermesRunId'];
  final transportMode = message.metadata?['hermesTransportMode'];
  await HermesMixedSessionBindingTrustStore.remember(
    storageAccountIdentity: provenance.storageAccountIdentity,
    conversationId: provenance.conversationId,
    assistantMessageId: message.id,
    sessionId: sessionId,
    connectionIdentity: connectionIdentity,
    responseId: responseId is String ? responseId : null,
    runId: runId is String ? runId : null,
    transportMode: transportMode is String ? transportMode : null,
  );
}

@visibleForTesting
Future<void> rememberMixedHermesMessageProvenanceForTest(
  dynamic ref, {
  required Conversation conversation,
  required ChatMessage assistantMessage,
}) async {
  final owner = _HermesConversationOwner.capture(ref, conversation);
  if (!owner.usesOpenWebUiBackend) {
    throw StateError('Mixed Hermes provenance requires OpenWebUI storage.');
  }
  final manager = ref.read(databaseManagerProvider) as DatabaseManager;
  final provenance = _captureHermesMixedSessionProvenance(
    ref,
    owner: owner,
    databaseManager: manager,
  );
  if (provenance == null) {
    throw StateError('The OpenWebUI storage/account owner is unavailable.');
  }
  await _rememberMixedHermesMessageProvenance(assistantMessage, provenance);
}

Future<void> forgetMixedHermesConversationProvenance(
  dynamic ref, {
  required Conversation conversation,
}) async {
  final owner = _HermesConversationOwner.capture(ref, conversation);
  if (!owner.usesOpenWebUiBackend) return;
  final manager = ref.read(databaseManagerProvider) as DatabaseManager;
  final provenance = _captureHermesMixedSessionProvenance(
    ref,
    owner: owner,
    databaseManager: manager,
  );
  if (provenance == null) {
    throw StateError('The OpenWebUI storage/account owner is unavailable.');
  }
  await HermesMixedSessionBindingTrustStore.forgetConversation(
    storageAccountIdentity: provenance.storageAccountIdentity,
    conversationId: provenance.conversationId,
  );
}

String? _lastHermesMetadataId(
  Iterable<ChatMessage> messages,
  String key, {
  required bool allowNativeHermesMetadata,
  _HermesMixedSessionProvenance? mixedProvenance,
}) {
  for (final message in messages.toList(growable: false).reversed) {
    if (message.role != 'assistant') continue;
    final value = message.metadata?[key];
    final validated = validateHermesOpaqueIdentifier(value);
    if (validated == null) continue;
    if (allowNativeHermesMetadata ||
        (mixedProvenance != null &&
            _mixedHermesMessageHasLocalProvenance(message, mixedProvenance))) {
      return validated;
    }
  }
  return null;
}

({String? sessionId, String? connectionIdentity}) _lastHermesSessionBinding(
  Iterable<ChatMessage> messages,
  _HermesMixedSessionProvenance? provenance,
) {
  if (provenance == null) {
    return (sessionId: null, connectionIdentity: null);
  }
  for (final message in messages.toList(growable: false).reversed) {
    if (message.role != 'assistant') continue;
    final sessionId = validateHermesOpaqueIdentifier(
      message.metadata?['hermesSessionId'],
    );
    if (sessionId == null) continue;
    final connectionIdentity =
        message.metadata?[kHermesConnectionIdentityMetadataKey];
    if (!_mixedHermesMessageHasLocalProvenance(message, provenance)) continue;
    return (
      sessionId: sessionId,
      connectionIdentity:
          connectionIdentity is String && connectionIdentity.isNotEmpty
          ? connectionIdentity
          : null,
    );
  }
  return (sessionId: null, connectionIdentity: null);
}

@visibleForTesting
String? reusableHermesSessionId({
  required Object? candidateSessionId,
  required Object? candidateConnectionIdentity,
  required String? currentConnectionIdentity,
  Iterable<String> sensitiveValues = const <String>[],
}) {
  if (currentConnectionIdentity == null ||
      candidateConnectionIdentity != currentConnectionIdentity) {
    return null;
  }
  return validateHermesOpaqueIdentifier(
    candidateSessionId,
    sensitiveValues: sensitiveValues,
  );
}

String? _hermesMessageTransportId(ChatMessage message) {
  for (final key in const <String>['hermesResponseId', 'hermesRunId']) {
    final value = message.metadata?[key];
    if (value is String && value.isNotEmpty) return '$key:$value';
  }
  return null;
}

bool _hermesProjectionStatusEquivalent(
  ChatStatusUpdate previous,
  ChatStatusUpdate next,
) =>
    previous.action == next.action &&
    previous.description == next.description &&
    previous.done == next.done &&
    previous.hidden == next.hidden &&
    previous.count == next.count &&
    previous.query == next.query &&
    listEquals(previous.queries, next.queries) &&
    listEquals(previous.urls, next.urls) &&
    listEquals(previous.items, next.items);

ChatMessage _appendHermesProjectionStatus(
  ChatMessage current,
  ChatStatusUpdate update,
) {
  final withTimestamp = update.occurredAt == null
      ? update.copyWith(occurredAt: DateTime.now())
      : update;
  final history = [...current.statusHistory];
  final action = withTimestamp.action;
  if (action == 'reasoning') {
    final index = history.lastIndexWhere((status) => status.action == action);
    if (index >= 0) {
      if (_hermesProjectionStatusEquivalent(history[index], withTimestamp)) {
        return current;
      }
      history[index] = withTimestamp;
      return current.copyWith(statusHistory: history);
    }
  }
  final isHermesTool = action?.startsWith('hermes_tool_') ?? false;
  if (isHermesTool) {
    final index = history.lastIndexWhere(
      (status) => status.action == action && status.done != true,
    );
    if (index >= 0) {
      if (_hermesProjectionStatusEquivalent(history[index], withTimestamp)) {
        return current;
      }
      history[index] = withTimestamp;
      return current.copyWith(statusHistory: history);
    }
  }
  if (history.isNotEmpty) {
    final last = history.last;
    if (_hermesProjectionStatusEquivalent(last, withTimestamp)) return current;
    final sameAction = last.action != null && last.action == action;
    final sameDescription =
        (withTimestamp.description?.isNotEmpty ?? false) &&
        withTimestamp.description == last.description;
    if (sameAction && sameDescription && !isHermesTool) {
      history[history.length - 1] = withTimestamp;
      return current.copyWith(statusHistory: history);
    }
  }
  history.add(withTimestamp);
  return current.copyWith(statusHistory: history);
}

typedef HermesApprovalProjectionStateUpdater =
    ({bool found, bool changed, HermesRunKey? key}) Function({
      required String expectedState,
      required String nextState,
    });

/// Captures a ref-independent compare-and-set closure for one approval.
///
/// The widget can be disposed while its HTTP decision is in flight. Capturing
/// the store and exact cancel-token generation before that await lets the
/// owner projection settle without reading a disposed WidgetRef.
HermesApprovalProjectionStateUpdater
captureHermesApprovalProjectionStateUpdater(
  dynamic ref, {
  required CancelToken cancelToken,
  required String messageId,
  required String runId,
  required String approvalId,
}) {
  _HermesRunProjectionStore? store;
  try {
    store = ref.read(_hermesRunProjectionStoreProvider);
  } catch (_) {}
  return ({required String expectedState, required String nextState}) {
    final capturedStore = store;
    if (capturedStore == null) {
      return (found: false, changed: false, key: null);
    }
    try {
      return capturedStore.updateApprovalForGeneration(
        cancelToken: cancelToken,
        messageId: messageId,
        runId: runId,
        approvalId: approvalId,
        expectedState: expectedState,
        nextState: nextState,
      );
    } catch (_) {
      // A narrow unit container can dispose its store while the card's async
      // callback unwinds. The visible fallback remains generation-guarded.
      return (found: false, changed: false, key: null);
    }
  };
}

Iterable<String> _hermesIdentifierSensitiveValues(
  HermesBackendService service,
) => service.config.sensitiveValues;

String? _validatedHermesHistoryMessageId(
  Object? value,
  HermesBackendService service,
) => validateHermesOpaqueIdentifier(
  value,
  sensitiveValues: _hermesIdentifierSensitiveValues(service),
  // Collection IDs can be short and may incidentally contain a short test or
  // user credential. Exact credential values remain forbidden.
  rejectShortSensitiveSubstrings: false,
);

Future<void> _rememberCommittedHermesLocalDocumentPrompt({
  required HermesBackendService service,
  required String connectionIdentity,
  required String sessionId,
  required String promptText,
  required List<String> documentEnvelopes,
  required Set<String> baselineMessageIds,
  required CancelToken cancelToken,
}) async {
  try {
    final rawMessages = await service.getSessionMessages(
      sessionId,
      cancelToken: cancelToken,
    );
    if (cancelToken.isCancelled) return;
    for (final raw in rawMessages.reversed) {
      final roleValue = raw['role'] ?? raw['author'];
      if (!_isHermesUserHistoryRole(roleValue)) {
        continue;
      }
      final messageId = _validatedHermesHistoryMessageId(raw['id'], service);
      if (messageId == null) continue;
      if (baselineMessageIds.contains(messageId)) continue;
      if (hermesMessageTextContent(raw['content'] ?? raw['text']) !=
          promptText) {
        continue;
      }
      if (cancelToken.isCancelled) return;
      await HermesLocalDocumentTrustStore.remember(
        connectionIdentity: connectionIdentity,
        sessionId: sessionId,
        messageId: messageId,
        promptText: promptText,
        documentEnvelopes: documentEnvelopes,
      );
      return;
    }
  } catch (_) {
    // The chat turn is already committed. Provenance persistence is a local
    // display enhancement and must not turn a successful response into an
    // apparent send failure.
    DebugLogger.warning(
      'local-document-trust-persist-failed',
      scope: 'hermes/sessions',
    );
  }
}

/// Binds a server-side Hermes session without converting an existing
/// OpenWebUI conversation into a Hermes conversation. A fresh Hermes chat (or
/// a branch of an already-Hermes chat) gets the local session-backed shell used
/// by the Hermes history browser.
void _bindHermesSessionToConversation(
  dynamic ref, {
  required _HermesConversationOwner owner,
  required HermesRunRegistry registry,
  required _HermesRunProjectionStore projectionStore,
  required _HermesRunProjection projection,
  required CancelToken cancelToken,
  required String assistantMessageId,
  required String sessionId,
  required String? connectionIdentity,
  required String input,
  required List<ChatMessage> ownerMessages,
  ChatSendPlaceholderHandle? sendHandle,
}) {
  final normalizedSessionId = validateHermesOpaqueIdentifier(sessionId);
  if (normalizedSessionId == null) return;

  final currentRunKey = owner.runKey(assistantMessageId);
  if (!registry.owns(currentRunKey, cancelToken: cancelToken) ||
      !projectionStore.isCurrent(projection)) {
    return;
  }

  final ownerIsActive = owner.isActive(ref);
  projectionStore.update(projection, (message) {
    final metadata = Map<String, dynamic>.from(message.metadata ?? const {});
    metadata['hermesSessionId'] = normalizedSessionId;
    if (connectionIdentity == null) {
      metadata.remove(kHermesConnectionIdentityMetadataKey);
    } else {
      metadata[kHermesConnectionIdentityMetadataKey] = connectionIdentity;
    }
    return message.copyWith(metadata: metadata);
  });
  if (ownerIsActive) {
    ref.read(hermesActiveSessionProvider.notifier).set(normalizedSessionId);
    final notifier =
        ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier;
    notifier.updateMessageById(assistantMessageId, (message) {
      final metadata = Map<String, dynamic>.from(message.metadata ?? const {});
      metadata['hermesSessionId'] = normalizedSessionId;
      if (connectionIdentity == null) {
        metadata.remove(kHermesConnectionIdentityMetadataKey);
      } else {
        metadata[kHermesConnectionIdentityMetadataKey] = connectionIdentity;
      }
      return message.copyWith(metadata: metadata);
    });
  }
  final ownedConversation = owner._conversationSnapshot;
  if (ownedConversation != null &&
      !isNativeHermesConversation(ownedConversation)) {
    // A Hermes turn inside an OpenWebUI chat remains owned by that chat. The
    // message metadata above is enough to recover this Hermes segment later.
    return;
  }

  final nextConversationId = 'local:hermes_$normalizedSessionId';
  final now = DateTime.now();
  final selectedModel = ref.read(selectedModelProvider) as Model?;
  final messages = List<ChatMessage>.unmodifiable(<ChatMessage>[
    for (final message in ownerMessages)
      if (message.id == assistantMessageId) projection.message else message,
    if (!ownerMessages.any((message) => message.id == assistantMessageId))
      projection.message,
  ]);
  final Conversation nextConversation;
  if (ownedConversation == null) {
    nextConversation = markNativeHermesConversation(
      Conversation(
        id: nextConversationId,
        title: _deriveHermesSessionTitle(input),
        createdAt: now,
        updatedAt: now,
        model: selectedModel?.id,
        messages: messages,
        metadata: <String, dynamic>{
          'backend': 'hermes',
          'hermesSessionId': normalizedSessionId,
          kHermesConnectionIdentityMetadataKey: ?connectionIdentity,
        },
      ),
    );
  } else {
    nextConversation = markNativeHermesConversation(
      ownedConversation.copyWith(
        id: nextConversationId,
        updatedAt: now,
        model: selectedModel?.id ?? ownedConversation.model,
        messages: messages,
        metadata: <String, dynamic>{
          ...ownedConversation.metadata,
          'backend': 'hermes',
          'hermesSessionId': normalizedSessionId,
          kHermesConnectionIdentityMetadataKey: ?connectionIdentity,
        },
      ),
    );
  }
  final nextRunKey = hermesRunKey(
    ownerConversationId: chatMutationOwnerScopeForConversation(
      nextConversation,
    ),
    assistantMessageId: assistantMessageId,
    backendIdentity: null,
  );
  if (!registry.rebind(currentRunKey, nextRunKey, cancelToken: cancelToken)) {
    return;
  }
  projectionStore.rebind(projection, nextRunKey);
  if (ownerIsActive &&
      ownedConversation != null &&
      ownedConversation.id != nextConversationId) {
    ref
        .read(activeConversationInPlaceRemapProvider.notifier)
        .mark(
          fromId: ownedConversation.id,
          toId: nextConversationId,
          namespace: ActiveConversationRemapNamespace.hermes,
        );
  }
  owner.bind(nextConversation);
  sendHandle?._bindConversation(nextConversation);
  if (ownerIsActive) {
    ref.read(activeConversationProvider.notifier).set(nextConversation);
  }
}

Future<void> _dispatchHermesRunFromChat(
  dynamic ref, {
  required String assistantMessageId,
  required ChatMessage assistantSeed,
  required String input,
  required List<ChatMessage> existingMessages,
  bool forceNewSession = false,
  String? previousResponseIdOverride,
  HermesChatInput? responseInput,
  List<Map<String, dynamic>>? responseHistory,
  String? localDocumentPromptText,
  List<String> localDocumentEnvelopes = const <String>[],
  required String? reasoningEffort,
  ChatSendPlaceholderHandle? sendHandle,
  _HermesConversationOwner? capturedOwner,
  DatabaseLifetimeLease? databaseLease,
  CancelToken? preRegisteredCancelToken,
  Duration lateSessionCleanupDeadline = _hermesLateSessionCleanupDeadline,
}) async {
  final releaseGeneration = holdLocalChatGeneration(ref);
  try {
    // Capture both ownership and session continuity before the first await. A
    // keychain write can rebuild providers while the user navigates; the turn
    // must never re-read the newly active Hermes chat and send this input there.
    final originConversation =
        capturedOwner?._conversationSnapshot ??
        ref.read(activeConversationProvider) as Conversation?;
    final owner =
        capturedOwner ??
        _HermesConversationOwner.capture(ref, originConversation);
    var ownedDatabaseLease = databaseLease;
    var allowCapturedDatabasePersistence = false;
    if (owner.usesOpenWebUiBackend && ownedDatabaseLease == null) {
      final database = owner._mutationOwner.openWebUiDatabase;
      if (database == null) {
        throw StateError('The OpenWebUI chat database is unavailable.');
      }
      final manager = ref.read(databaseManagerProvider) as DatabaseManager;
      ownedDatabaseLease = manager.tryAcquireLease(database);
      if (manager.serverIdForDatabase(database) != null &&
          ownedDatabaseLease == null) {
        throw StateError('The OpenWebUI chat database is closing.');
      }
      allowCapturedDatabasePersistence =
          ownedDatabaseLease != null ||
          manager.serverIdForDatabase(database) == null;
    } else if (owner.usesOpenWebUiBackend) {
      allowCapturedDatabasePersistence = true;
    }
    try {
      await _dispatchOwnedHermesRunFromChat(
        ref,
        assistantMessageId: assistantMessageId,
        assistantSeed: assistantSeed,
        input: input,
        existingMessages: existingMessages,
        forceNewSession: forceNewSession,
        previousResponseIdOverride: previousResponseIdOverride,
        responseInput: responseInput,
        responseHistory: responseHistory,
        localDocumentPromptText: localDocumentPromptText,
        localDocumentEnvelopes: localDocumentEnvelopes,
        reasoningEffort: reasoningEffort,
        sendHandle: sendHandle,
        originConversation: originConversation,
        owner: owner,
        preRegisteredCancelToken: preRegisteredCancelToken,
        allowCapturedDatabasePersistence: allowCapturedDatabasePersistence,
        lateSessionCleanupDeadline: lateSessionCleanupDeadline,
      );
    } finally {
      await ownedDatabaseLease?.release();
    }
  } finally {
    releaseGeneration();
  }
}

Future<void> _dispatchOwnedHermesRunFromChat(
  dynamic ref, {
  required String assistantMessageId,
  required ChatMessage assistantSeed,
  required String input,
  required List<ChatMessage> existingMessages,
  required bool forceNewSession,
  required String? previousResponseIdOverride,
  required HermesChatInput? responseInput,
  required List<Map<String, dynamic>>? responseHistory,
  required String? localDocumentPromptText,
  required List<String> localDocumentEnvelopes,
  required String? reasoningEffort,
  required ChatSendPlaceholderHandle? sendHandle,
  required Conversation? originConversation,
  required _HermesConversationOwner owner,
  required CancelToken? preRegisteredCancelToken,
  required bool allowCapturedDatabasePersistence,
  required Duration lateSessionCleanupDeadline,
}) async {
  final ChatMessagesNotifier notifier =
      ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier;
  final registry = ref.read(hermesRunRegistryProvider) as HermesRunRegistry;
  final projectionStore = ref.read(_hermesRunProjectionStoreProvider);
  final DatabaseManager? persistenceDatabaseManager = owner.usesOpenWebUiBackend
      ? ref.read(databaseManagerProvider) as DatabaseManager
      : null;
  final persistenceDatabase = owner._mutationOwner.openWebUiDatabase;
  final persistenceContext = owner.usesOpenWebUiBackend
      ? _HermesProjectionPersistenceContext(
          databaseManager: persistenceDatabaseManager!,
          chatLocks: ref.read(chatLocksProvider) as ChatLocks,
          clock: ref.read(syncClockProvider) as SyncClock,
          databaseRequiresLifetimeLease:
              persistenceDatabase != null &&
              persistenceDatabaseManager.serverIdForDatabase(
                    persistenceDatabase,
                  ) !=
                  null,
          mixedSessionProvenance: _captureHermesMixedSessionProvenance(
            ref,
            owner: owner,
            databaseManager: persistenceDatabaseManager,
          ),
        )
      : null;
  final originIsHermes = isNativeHermesConversation(originConversation);
  final originSessionValue = originConversation?.metadata['hermesSessionId'];
  final originConnectionIdentityValue =
      originConversation?.metadata[kHermesConnectionIdentityMetadataKey];
  final previousMixedSessionBinding = _lastHermesSessionBinding(
    existingMessages,
    persistenceContext?.mixedSessionProvenance,
  );
  final capturedSessionId = forceNewSession
      ? null
      : originIsHermes
      ? (originSessionValue is String
            ? originSessionValue
            : ref.read(hermesActiveSessionProvider))
      : originConversation == null
      ? null
      : previousMixedSessionBinding.sessionId;
  final capturedSessionConnectionIdentity = forceNewSession
      ? null
      : originIsHermes
      ? (originConnectionIdentityValue is String
            ? originConnectionIdentityValue
            : null)
      : originConversation == null
      ? null
      : previousMixedSessionBinding.connectionIdentity;
  final initialRunKey = owner.runKey(assistantMessageId);
  final cancellationSettled = Completer<void>();
  final cleanupSettled = Completer<void>();
  final latePersistence = <Future<void>>[];
  late final CancelToken cancelToken;
  late final _HermesRunProjection projection;
  if (assistantSeed.id != assistantMessageId ||
      assistantSeed.role != 'assistant' ||
      assistantSeed.metadata?['transport'] != kHermesTransport) {
    throw StateError('Hermes dispatch received an invalid assistant seed.');
  }
  cancelToken = registry.registerPending(
    initialRunKey,
    cancelToken: preRegisteredCancelToken,
    onCancelled: () {
      if (registry.hasReplacement(
        owner.runKey(assistantMessageId),
        cancelToken: cancelToken,
      )) {
        return;
      }
      if (!projectionStore.finalize(projection)) return;
      if (!owner.isActive(ref)) return;
      notifier.finishStreamingMessage(
        assistantMessageId,
        ownerConversationId: owner.notifierConversationId,
        requireConversationOwner: true,
        // The captured Hermes projection writes the rich final snapshot in
        // this dispatcher's finally block. Do not enqueue the generic turn
        // echo against the same chat lock as a second persistence owner.
        persistTurn: false,
      );
    },
    cancellationSettled: cancellationSettled.future,
    onCleanupSettled: () {
      if (!cleanupSettled.isCompleted) cleanupSettled.complete();
    },
  );
  final visibleMessages = ref.read(chatMessagesProvider) as List<ChatMessage>;
  projection = projectionStore.begin(
    initialRunKey,
    cancelToken: cancelToken,
    requiresDurablePersistence: owner.usesOpenWebUiBackend,
    initialMessage: assistantSeed,
  );
  if (owner.usesOpenWebUiBackend) {
    final approvalPersistenceCoordinator =
        _HermesApprovalPersistenceCoordinator(
          owner: owner,
          projectionStore: projectionStore,
          projection: projection,
          persistenceContext: persistenceContext!,
          allowCapturedContextAfterRevocation: allowCapturedDatabasePersistence,
        );
    projectionStore.bindApprovalPersistenceScheduler(
      projection,
      approvalPersistenceCoordinator.schedule,
    );
  }

  StreamSubscription<RemapEvent>? remapSubscription;
  ProviderSubscription<_HermesOpenWebUiBackendContext>?
  backendContextSubscription;

  if (owner.usesOpenWebUiBackend) {
    backendContextSubscription = _listenForHermesOpenWebUiBackendChanges(ref, (
      _,
      _,
    ) {
      if (owner.backendContextIsCurrent(ref)) return;
      final cancellation = registry.cancelOwned(
        owner.runKey(assistantMessageId),
        cancelToken: cancelToken,
      );
      _observeDetachedCancellation(
        cancellation,
        scope: 'hermes/backend-revocation',
      );
    });
  }

  void followOpenWebUiRemap(String fromId, String toId) {
    if (!owner.canFollowOpenWebUiRemap(ref, fromId: fromId)) return;
    final fromKey = owner.runKey(assistantMessageId);
    if (!registry.owns(fromKey, cancelToken: cancelToken)) return;
    final toKey = owner.openWebUiRunKey(toId, assistantMessageId);
    final rebound = registry.rebindIfVacant(
      fromKey,
      toKey,
      cancelToken: cancelToken,
    );

    // Registry mutation and owner mutation are synchronous, so no stop/event
    // callback can observe a half-remapped key. On a destination collision,
    // move callback scope first so cancellation sees the replacement and
    // cannot finish its newer placeholder.
    owner.bindOpenWebUiRemap(toId);
    sendHandle?._bindOwnerScope(owner.scopedConversationId);
    if (rebound) {
      projectionStore.rebind(projection, toKey);
      return;
    }

    projectionStore.discard(projection);
    final cancellation = registry.cancelOwned(
      fromKey,
      cancelToken: cancelToken,
    );
    if (cancellation == null && !cancelToken.isCancelled) {
      cancelToken.cancel('Hermes chat remap ownership changed');
    }
    _observeDetachedCancellation(cancellation, scope: 'hermes/remap');
  }

  if (owner._backendIdentity != null) {
    try {
      final events = ref.read(syncEngineProvider.notifier).remapEvents;
      remapSubscription = trackHermesConversationRemaps(
        events: events,
        currentConversationId: () => owner._conversationId,
        onRemap: followOpenWebUiRemap,
      );

      // Subscribe first, then repair the only missed-event window from the
      // context-bound in-place marker. A later remap is delivered synchronously
      // by SyncEngine's broadcast stream.
      final active = ref.read(activeConversationProvider) as Conversation?;
      final remap = ref.read(activeConversationInPlaceRemapProvider);
      if (active != null &&
          remap != null &&
          active.id == remap.toId &&
          remap.matchesOpenWebUiContext(
            database: owner._mutationOwner.openWebUiDatabase,
            api: owner._mutationOwner.openWebUiApi,
            authSessionEpoch: owner._mutationOwner.openWebUiAuthSessionEpoch,
          )) {
        followOpenWebUiRemap(remap.fromId, remap.toId);
      }
    } catch (_) {
      // A narrow/offline test may not install SyncEngine. The immutable owner
      // checks remain authoritative; only live id tracking is unavailable.
    }
  }

  try {
    await _dispatchRegisteredHermesRunFromChat(
      ref,
      assistantMessageId: assistantMessageId,
      input: input,
      existingMessages: existingMessages,
      forceNewSession: forceNewSession,
      previousResponseIdOverride: previousResponseIdOverride,
      responseInput: responseInput,
      responseHistory: responseHistory,
      localDocumentPromptText: localDocumentPromptText,
      localDocumentEnvelopes: localDocumentEnvelopes,
      reasoningEffort: reasoningEffort,
      capturedSessionId: capturedSessionId,
      capturedSessionConnectionIdentity: capturedSessionConnectionIdentity,
      capturedSessionRequiresConnectionIdentity: !originIsHermes,
      mixedSessionProvenance: persistenceContext?.mixedSessionProvenance,
      notifier: notifier,
      registry: registry,
      cancelToken: cancelToken,
      owner: owner,
      projectionStore: projectionStore,
      projection: projection,
      persistenceContext: persistenceContext,
      ownerMessages: visibleMessages,
      sendHandle: sendHandle,
      allowCapturedDatabasePersistence: allowCapturedDatabasePersistence,
      trackLatePersistence: latePersistence.add,
      lateSessionCleanupDeadline: lateSessionCleanupDeadline,
    );
  } finally {
    var primaryProjectionPersisted = !owner.usesOpenWebUiBackend;
    final primaryPersistenceRevision = projection.persistenceRevision;
    if (projection.finalized && projectionStore.isCurrent(projection)) {
      try {
        primaryProjectionPersisted = await _persistCompletedHermesProjection(
          ref,
          owner: owner,
          projectionStore: projectionStore,
          projection: projection,
          persistenceContext: persistenceContext,
          allowCapturedContextAfterRevocation: allowCapturedDatabasePersistence,
        );
      } catch (_) {
        // Provider/database errors may contain reflected credentials. Keep the
        // retained projection for replay and log only the fixed failure site.
        DebugLogger.error(
          'completed-projection-persistence-failed',
          scope: 'hermes/transport',
        );
      }
    }
    projectionStore.markPrimaryPersistenceSettled(
      projection,
      persisted:
          primaryProjectionPersisted &&
          projection.persistenceRevision == primaryPersistenceRevision,
    );
    // Remote stop cleanup may report a terminal diagnostic after cancellation
    // settles the stream. Release the registry's cancellation waiter, then
    // keep the captured database lease alive until that cleanup has finished
    // publishing and every resulting persistence write has joined us.
    if (!cancellationSettled.isCompleted) cancellationSettled.complete();
    if (!cleanupSettled.isCompleted &&
        registry.owns(
          owner.runKey(assistantMessageId),
          cancelToken: cancelToken,
        )) {
      final cleanup = registry.cancelOwned(
        owner.runKey(assistantMessageId),
        cancelToken: cancelToken,
      );
      if (cleanup != null) {
        try {
          await cleanup;
        } catch (_) {
          DebugLogger.error('run-cleanup-failed', scope: 'hermes/transport');
        }
      }
    }
    await cleanupSettled.future;
    if (latePersistence.isNotEmpty) {
      await Future.wait<void>(latePersistence);
    }
    // Do this only after every durable attempt: active-conversation sync can
    // adopt messages while finishStreaming runs, and consuming the projection
    // before this point would make the captured persistence owner disappear.
    projectionStore.markDispatchSettled(projection);
    final subscription = remapSubscription;
    if (subscription != null) {
      try {
        // Calling cancel revokes event delivery synchronously; the returned
        // future belongs to the stream provider's cleanup and may never
        // settle. Do not hold the completed dispatch (or its database lease)
        // behind a hostile/stalled remap-stream teardown.
        _observeDetachedCancellation(
          subscription.cancel(),
          scope: 'hermes/remap-subscription',
        );
      } catch (_) {
        DebugLogger.error(
          'remap-subscription-cleanup-failed',
          scope: 'hermes/transport',
        );
      }
    }
    backendContextSubscription?.close();
  }
}

/// Tracks only the current chat's committed local-to-server remap. Keeping the
/// event filter separate makes subscription teardown and unrelated-id behavior
/// directly testable without exposing [_HermesConversationOwner].
@visibleForTesting
StreamSubscription<RemapEvent> trackHermesConversationRemaps({
  required Stream<RemapEvent> events,
  required String? Function() currentConversationId,
  required void Function(String fromId, String toId) onRemap,
}) {
  return events.listen((event) {
    if (event.entityKind != 'chat' || event.fromId != currentConversationId()) {
      return;
    }
    onRemap(event.fromId, event.toId);
  });
}

Future<void> _deleteLateHermesSessionWithinDeadline(
  HermesBackendService service,
  String sessionId, {
  required Duration deadline,
}) async {
  if (deadline <= Duration.zero) {
    throw ArgumentError.value(deadline, 'deadline');
  }

  // The run token is already cancelled in this branch. Cleanup needs an
  // independent token so Dio can send the best-effort DELETE, while the outer
  // timeout remains an absolute bound even if the peer keeps trickling bytes.
  final cleanupCancelToken = CancelToken();
  await service
      .deleteSession(sessionId, cancelToken: cleanupCancelToken)
      .timeout(
        deadline,
        onTimeout: () {
          if (!cleanupCancelToken.isCancelled) {
            cleanupCancelToken.cancel('late-session-cleanup-timeout');
          }
          throw TimeoutException(
            'Hermes late-session cleanup exceeded its deadline.',
          );
        },
      );
}

void _deleteLateHermesSessionBestEffort(
  HermesBackendService service,
  String sessionId, {
  required Duration deadline,
}) {
  unawaited(
    _deleteLateHermesSessionWithinDeadline(
      service,
      sessionId,
      deadline: deadline,
    ).then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {
        // Provider errors and stacks may reflect credentials or opaque ids.
        // This cleanup is detached from run/database ownership by design.
        DebugLogger.error(
          'late-session-cleanup-failed',
          scope: 'hermes/transport',
        );
      },
    ),
  );
}

Future<void> _dispatchRegisteredHermesRunFromChat(
  dynamic ref, {
  required String assistantMessageId,
  required String input,
  required List<ChatMessage> existingMessages,
  required bool forceNewSession,
  required String? previousResponseIdOverride,
  required HermesChatInput? responseInput,
  required List<Map<String, dynamic>>? responseHistory,
  required String? localDocumentPromptText,
  required List<String> localDocumentEnvelopes,
  required String? reasoningEffort,
  required String? capturedSessionId,
  required String? capturedSessionConnectionIdentity,
  required bool capturedSessionRequiresConnectionIdentity,
  required _HermesMixedSessionProvenance? mixedSessionProvenance,
  required ChatMessagesNotifier notifier,
  required HermesRunRegistry registry,
  required CancelToken cancelToken,
  required _HermesConversationOwner owner,
  required _HermesRunProjectionStore projectionStore,
  required _HermesRunProjection projection,
  required _HermesProjectionPersistenceContext? persistenceContext,
  required List<ChatMessage> ownerMessages,
  required ChatSendPlaceholderHandle? sendHandle,
  required bool allowCapturedDatabasePersistence,
  required void Function(Future<void> persistence) trackLatePersistence,
  required Duration lateSessionCleanupDeadline,
}) async {
  final configController =
      ref.read(hermesConfigProvider.notifier) as HermesConfigController;
  HermesRunKey currentRunKey() => owner.runKey(assistantMessageId);
  bool ownsRun() => registry.owns(currentRunKey(), cancelToken: cancelToken);
  bool cancelled() =>
      cancelToken.isCancelled ||
      !ownsRun() ||
      !owner.backendContextIsCurrent(ref);

  void updateProjectionIfOwned(
    ChatMessage Function(ChatMessage current) updater,
    void Function() visibleMutation,
  ) {
    // Some transport failure branches atomically remove their registry entry
    // before publishing the final error. Projection identity is the remaining
    // generation boundary in that synchronous window; a replacement has
    // already displaced this handle and an explicit stop has finalized it.
    if (!projectionStore.update(projection, updater)) return;
    if (owner.isActive(ref)) visibleMutation();
  }

  void appendProjectedContent(String content) {
    if (content.isEmpty) return;
    if (!projectionStore.appendContent(projection, content)) return;
    if (owner.isActive(ref)) {
      notifier.appendToMessageById(assistantMessageId, content);
    }
  }

  void replaceProjectedContent(String content) {
    updateProjectionIfOwned(
      (message) => message.copyWith(content: content),
      () => notifier.replaceMessageContentById(assistantMessageId, content),
    );
  }

  void appendProjectedStatus(ChatStatusUpdate update) {
    updateProjectionIfOwned(
      (message) => _appendHermesProjectionStatus(message, update),
      () => notifier.appendStatusUpdate(assistantMessageId, update),
    );
  }

  void updateProjectedMessage(
    ChatMessage Function(ChatMessage current) updater,
  ) {
    if (!projectionStore.update(projection, updater)) return;
    if (owner.isActive(ref)) {
      notifier.updateMessageById(assistantMessageId, updater);
    }
  }

  void reportTerminalCleanupError(ChatMessageError error) {
    ChatMessage updater(ChatMessage message) => message.copyWith(error: error);
    final updatedLiveProjection = projectionStore.update(projection, updater);
    final updatedFinalizedError =
        !updatedLiveProjection &&
        projectionStore.updateFinalizedError(projection, updater);
    if (updatedLiveProjection && owner.isActive(ref)) {
      notifier.updateMessageById(assistantMessageId, updater);
    } else if (updatedFinalizedError && owner.isActive(ref)) {
      // A stop-cleanup callback is allowed to add only its terminal error to a
      // finalized projection. Apply that same narrow mutation to the visible
      // row instead of re-running a provider-owned updater that could also
      // rewrite already-sealed content or status state.
      final terminalError = projection.message.error;
      notifier.updateMessageById(
        assistantMessageId,
        (message) => message.copyWith(error: terminalError),
      );
    }
    if (updatedFinalizedError) {
      // Registry cancellation settles the dispatcher before remote stop
      // cleanup necessarily finishes. Persist the late cleanup diagnostic as
      // a second idempotent snapshot so an OpenWebUI-backed Hermes segment
      // cannot lose it on process restart.
      final persistenceRevision = projection.persistenceRevision;
      trackLatePersistence(() async {
        try {
          final persisted = await _persistCompletedHermesProjection(
            ref,
            owner: owner,
            projectionStore: projectionStore,
            projection: projection,
            persistenceContext: persistenceContext,
            allowCapturedContextAfterRevocation:
                allowCapturedDatabasePersistence,
          );
          if (persisted &&
              projection.persistenceRevision == persistenceRevision) {
            projectionStore.markDurablyPersisted(projection);
          }
        } catch (_) {
          DebugLogger.error(
            'terminal-cleanup-persistence-failed',
            scope: 'hermes/transport',
          );
        }
      }());
    }
  }

  void finishOwned() {
    if (!projectionStore.finalize(projection)) return;
    if (!owner.isActive(ref)) return;
    notifier.finishStreamingMessage(
      assistantMessageId,
      ownerConversationId: owner.notifierConversationId,
      requireConversationOwner: true,
      // Live Hermes dispatches persist their projection explicitly after all
      // terminal/cleanup mutations have settled.
      persistTurn: false,
    );
  }

  void completeStreamingUiOwned() {
    if (!projectionStore.finalize(projection)) return;
    if (!owner.isActive(ref)) return;
    notifier.completeStreamingUiForMessage(
      assistantMessageId,
      ownerConversationId: owner.notifierConversationId,
      requireConversationOwner: true,
    );
  }

  void failPreflight(Object error) {
    if (!registry.complete(currentRunKey(), cancelToken: cancelToken)) return;
    ChatMessage updater(ChatMessage message) => message.copyWith(
      error: ChatMessageError(content: chatErrorContentForException(error)),
    );
    projectionStore.update(projection, updater);
    if (owner.isActive(ref)) {
      notifier.updateMessageById(assistantMessageId, updater);
    }
    finishOwned();
    completeStreamingUiOwned();
  }

  // Ensure a stable long-term memory key before reading the service (mutating
  // the key rebuilds hermesApiServiceProvider, so read it afterwards).
  if (ref.read(hermesConfigProvider).mode == HermesBackendMode.responsesApi) {
    try {
      await configController.ensureSessionKey();
    } catch (error) {
      if (!cancelled()) failPreflight(error);
      return;
    }
  }
  if (cancelled()) return;
  final HermesBackendService? service = ref.read(hermesApiServiceProvider);
  if (service == null) {
    if (!registry.complete(currentRunKey(), cancelToken: cancelToken)) return;
    ChatMessage updater(ChatMessage message) => message.copyWith(
      error: const ChatMessageError(
        content:
            'Hermes is not configured. Add the server URL and API key in '
            'Settings → Hermes Agent.',
      ),
    );
    projectionStore.update(projection, updater);
    if (owner.isActive(ref)) {
      notifier.updateMessageById(assistantMessageId, updater);
    }
    finishOwned();
    completeStreamingUiOwned();
    return;
  }
  if (service is! HermesResponsesTurnService &&
      service is! HermesDesktopTurnService) {
    if (!registry.complete(currentRunKey(), cancelToken: cancelToken)) return;
    finishOwned();
    completeStreamingUiOwned();
    return;
  }
  final isDesktop = service is HermesDesktopTurnService;
  HermesDesktopSessionOptions? desktopOptions;
  if (service is HermesDesktopTurnService) {
    final selected = ref.read(selectedModelProvider);
    final metadata = selected?.metadata;
    final usesConfiguredDefault = metadata?['hermesConfiguredDefault'] == true;
    desktopOptions = HermesDesktopSessionOptions(
      model: usesConfiguredDefault
          ? null
          : metadata?['hermesModelId']?.toString(),
      provider: usesConfiguredDefault
          ? null
          : metadata?['hermesProvider']?.toString(),
      reasoningEffort: reasoningEffort,
      fast: hermesFastTierSelection(
        supported: metadata?['hermesFast'] == true,
        selected: ref.read(hermesFastTierSelectionProvider),
      ),
    );
  }
  final endpointIdentity = HermesConfigController.connectionEndpoint(
    service.config.baseUrl,
  );
  final documentTrustConnectionIdentity = endpointIdentity == null
      ? null
      : HermesLocalDocumentTrustStore.connectionIdentity(
          endpointIdentity: endpointIdentity,
          principalId: configController.documentTrustPrincipalId(),
        );

  // Bind a server-side Hermes session so the transcript persists and is
  // reloadable from the sessions browser. For a Hermes segment embedded in an
  // OpenWebUI chat, reuse only a session recorded by that segment—not global
  // session state that may belong to another conversation.
  var sessionId = capturedSessionRequiresConnectionIdentity
      ? reusableHermesSessionId(
          candidateSessionId: capturedSessionId,
          candidateConnectionIdentity: capturedSessionConnectionIdentity,
          currentConnectionIdentity: documentTrustConnectionIdentity,
          sensitiveValues: _hermesIdentifierSensitiveValues(service),
        )
      : validateHermesOpaqueIdentifier(
          capturedSessionId,
          sensitiveValues: _hermesIdentifierSensitiveValues(service),
        );
  var responsePreviousResponseId = responseInput == null
      ? null
      : previousResponseIdOverride;
  responsePreviousResponseId ??= responseInput == null || forceNewSession
      ? null
      : _lastHermesMetadataId(
          existingMessages,
          'hermesResponseId',
          allowNativeHermesMetadata: !capturedSessionRequiresConnectionIdentity,
          mixedProvenance: mixedSessionProvenance,
        );
  final responseStartsNewChain =
      !isDesktop && responseInput != null && responsePreviousResponseId == null;
  if (responseStartsNewChain) {
    // The official Responses endpoint owns the session id for a new chain; it
    // does not bind to a pre-created /api/sessions row via request headers.
    sessionId = null;
  }
  if ((sessionId == null || sessionId.isEmpty) && !responseStartsNewChain) {
    try {
      // Title the session from the first user message when this is turn one.
      final title = existingMessages.isEmpty
          ? _deriveHermesSessionTitle(input)
          : null;
      final createdSessionId = service is HermesDesktopTurnService
          ? await service.createDesktopSession(
              title: title,
              options: desktopOptions!,
              cancelToken: cancelToken,
            )
          : await service.createSession(title: title, cancelToken: cancelToken);
      if (cancelled()) {
        _deleteLateHermesSessionBestEffort(
          service,
          createdSessionId,
          deadline: lateSessionCleanupDeadline,
        );
        return;
      }
      sessionId = createdSessionId;
      if (documentTrustConnectionIdentity != null) {
        try {
          await HermesLocalDocumentTrustStore.prepareNewSession(
            connectionIdentity: documentTrustConnectionIdentity,
            sessionId: createdSessionId,
          );
        } catch (_) {
          _deleteLateHermesSessionBestEffort(
            service,
            createdSessionId,
            deadline: lateSessionCleanupDeadline,
          );
          failPreflight(
            StateError('Hermes could not safely initialize this session.'),
          );
          return;
        }
        if (cancelled()) {
          _deleteLateHermesSessionBestEffort(
            service,
            createdSessionId,
            deadline: lateSessionCleanupDeadline,
          );
          return;
        }
      }
      _bindHermesSessionToConversation(
        ref,
        owner: owner,
        registry: registry,
        projectionStore: projectionStore,
        projection: projection,
        cancelToken: cancelToken,
        assistantMessageId: assistantMessageId,
        sessionId: createdSessionId,
        connectionIdentity: documentTrustConnectionIdentity,
        input: input,
        ownerMessages: ownerMessages,
        sendHandle: sendHandle,
      );
      ref.invalidate(hermesSessionsProvider);
    } catch (error) {
      if (cancelled()) return;
      if (isDesktop || forceNewSession) {
        failPreflight(error);
        return;
      }
      // Session creation failed (older server / disabled): fall back to an
      // ephemeral run with no persistence rather than failing the turn.
      sessionId = null;
    }
  }

  if (sessionId != null && sessionId.isNotEmpty) {
    _bindHermesSessionToConversation(
      ref,
      owner: owner,
      registry: registry,
      projectionStore: projectionStore,
      projection: projection,
      cancelToken: cancelToken,
      assistantMessageId: assistantMessageId,
      sessionId: sessionId,
      connectionIdentity: documentTrustConnectionIdentity,
      input: input,
      ownerMessages: ownerMessages,
      sendHandle: sendHandle,
    );
  }

  // Attachments require Responses. Once a conversation enters that response
  // chain, callers continue supplying [responseInput] for later text turns.
  if (responseInput != null || isDesktop) {
    final hasLocalDocumentProvenance =
        localDocumentPromptText != null && localDocumentEnvelopes.isNotEmpty;
    Set<String>? baselineServerMessageIds;
    if (hasLocalDocumentProvenance) {
      final baselineSessionId = sessionId;
      if (baselineSessionId != null) {
        try {
          baselineServerMessageIds =
              (await service.getSessionMessages(
                    baselineSessionId,
                    cancelToken: cancelToken,
                  ))
                  .map(
                    (raw) =>
                        _validatedHermesHistoryMessageId(raw['id'], service),
                  )
                  .whereType<String>()
                  .toSet();
        } catch (error) {
          // Without a server-history baseline, an older identical prompt
          // cannot be distinguished from the row committed by this request.
          // Fail closed and leave the envelope visible on a later reopen.
          DebugLogger.warning(
            'local-document-trust-baseline-failed',
            scope: 'hermes/sessions',
            data: <String, Object?>{'errorType': error.runtimeType.toString()},
          );
        }
        if (cancelled()) return;
      }
      // Responses owns creation of a new chain. Its returned session is
      // prepared below before the known-empty history baseline is recorded.
    }
    if (cancelled()) return;
    await dispatchHermesTurn(
      startTurn: (turnCancelToken) => switch (service) {
        HermesDesktopTurnService() => service.streamDesktopResponse(
          responseInput ?? HermesChatInput.text(input),
          sessionId: sessionId,
          options: desktopOptions!,
          cancelToken: turnCancelToken,
        ),
        HermesResponsesTurnService() => service.streamResponseWithReasoning(
          responseInput ?? HermesChatInput.text(input),
          sessionId: sessionId,
          previousResponseId: responsePreviousResponseId,
          conversationHistory: responseStartsNewChain ? responseHistory : null,
          reasoningEffort: reasoningEffort,
          cancelToken: turnCancelToken,
        ),
        _ => throw StateError('Hermes turn transport is unavailable.'),
      },
      sensitiveValues: service.config.sensitiveValues,
      recoverResponse: service is HermesApiService
          ? hermesResponseRecoverer(service)
          : null,
      registry: registry,
      assistantMessageId: assistantMessageId,
      runKey: currentRunKey(),
      currentRunKey: currentRunKey,
      cancelToken: cancelToken,
      onSessionEstablished: (establishedSessionId) async {
        if (establishedSessionId == null || cancelled()) return;
        final requestedSessionId = sessionId;
        if (!responseStartsNewChain &&
            requestedSessionId != null &&
            establishedSessionId != requestedSessionId) {
          throw StateError(
            'Hermes returned a different session for an existing-session '
            'request.',
          );
        }
        final responseCreatedSession = responseStartsNewChain;
        if (responseCreatedSession && documentTrustConnectionIdentity != null) {
          try {
            await HermesLocalDocumentTrustStore.prepareNewSession(
              connectionIdentity: documentTrustConnectionIdentity,
              sessionId: establishedSessionId,
            );
          } catch (_) {
            _deleteLateHermesSessionBestEffort(
              service,
              establishedSessionId,
              deadline: lateSessionCleanupDeadline,
            );
            rethrow;
          }
          if (cancelled()) {
            _deleteLateHermesSessionBestEffort(
              service,
              establishedSessionId,
              deadline: lateSessionCleanupDeadline,
            );
            return;
          }
          if (hasLocalDocumentProvenance) {
            // A new Responses chain gets a server-owned, newly allocated
            // session. Its pre-turn history is therefore known to be empty;
            // establishing that boundary lets exact document provenance be
            // recorded after the turn without trusting an older lookalike.
            baselineServerMessageIds = <String>{};
          }
        }
        sessionId = establishedSessionId;
        _bindHermesSessionToConversation(
          ref,
          owner: owner,
          registry: registry,
          projectionStore: projectionStore,
          projection: projection,
          cancelToken: cancelToken,
          assistantMessageId: assistantMessageId,
          sessionId: establishedSessionId,
          connectionIdentity: documentTrustConnectionIdentity,
          input: input,
          ownerMessages: ownerMessages,
          sendHandle: sendHandle,
        );
        if (responseCreatedSession) {
          ref.invalidate(hermesSessionsProvider);
        }
      },
      onCompletedSuccessfully: () async {
        final committedSessionId = sessionId;
        final committedBaselineMessageIds = baselineServerMessageIds;
        if (committedSessionId == null ||
            localDocumentPromptText == null ||
            localDocumentEnvelopes.isEmpty ||
            committedBaselineMessageIds == null ||
            documentTrustConnectionIdentity == null ||
            !owner.backendContextIsCurrent(ref)) {
          return;
        }
        await _rememberCommittedHermesLocalDocumentPrompt(
          service: service,
          connectionIdentity: documentTrustConnectionIdentity,
          sessionId: committedSessionId,
          promptText: localDocumentPromptText,
          documentEnvelopes: localDocumentEnvelopes,
          baselineMessageIds: committedBaselineMessageIds,
          cancelToken: cancelToken,
        );
      },
      appendContent: appendProjectedContent,
      replaceContent: replaceProjectedContent,
      appendStatus: appendProjectedStatus,
      prefillComposer: (text) {
        if (!owner.isActive(ref)) return;
        ref
            .read(composerTextInsertionProvider.notifier)
            .insert(targetId: chatComposerTextInsertionTargetId, text: text);
      },
      updateMessage: updateProjectedMessage,
      finishStreaming: finishOwned,
      completeStreamingUi: completeStreamingUiOwned,
    );
    return;
  }

  if (cancelled()) return;

  // Hermes Runs does not interpret a prior run id as conversation state.
  // Replay a bounded visible transcript explicitly on every text turn; this
  // is the documented Runs contract and also lets reopened server sessions
  // continue when their message rows do not expose response identifiers.
  final conversationHistory = _hermesVisibleHistory(
    existingMessages,
    inputImagesSupported: false,
  );

  if (service is! HermesApiService) {
    failPreflight(StateError('Hermes Responses API is unavailable.'));
    return;
  }

  await dispatchHermesRun(
    service: service,
    registry: registry,
    assistantMessageId: assistantMessageId,
    runKey: currentRunKey(),
    currentRunKey: currentRunKey,
    input: input,
    sessionId: sessionId,
    conversationHistory: conversationHistory,
    reasoningEffort: reasoningEffort,
    cancelToken: cancelToken,
    appendContent: appendProjectedContent,
    replaceContent: replaceProjectedContent,
    appendStatus: appendProjectedStatus,
    updateMessage: updateProjectedMessage,
    reportStopError: reportTerminalCleanupError,
    finishStreaming: finishOwned,
    completeStreamingUi: completeStreamingUiOwned,
  );
}

@visibleForTesting
Future<void> dispatchHermesRunFromChatForTest(
  dynamic ref, {
  required String assistantMessageId,
  ChatMessage? assistantSeed,
  required String input,
  required List<ChatMessage> existingMessages,
  bool forceNewSession = false,
  String? previousResponseIdOverride,
  HermesChatInput? responseInput,
  List<Map<String, dynamic>>? responseHistory,
  String? localDocumentPromptText,
  List<String> localDocumentEnvelopes = const <String>[],
  Duration lateSessionCleanupDeadline = _hermesLateSessionCleanupDeadline,
}) {
  // This seam deliberately snapshots before invoking the async dispatcher so
  // tests exercise the same ownership boundary as production callers.
  final capturedSeed =
      assistantSeed ??
      (ref.read(chatMessagesProvider) as List<ChatMessage>)
          .where((message) => message.id == assistantMessageId)
          .firstOrNull ??
      ChatMessage(
        id: assistantMessageId,
        role: 'assistant',
        content: '',
        timestamp: DateTime.now(),
        isStreaming: true,
        metadata: const <String, dynamic>{'transport': kHermesTransport},
      );
  return _dispatchHermesRunFromChat(
    ref,
    assistantMessageId: assistantMessageId,
    assistantSeed: capturedSeed,
    input: input,
    existingMessages: existingMessages,
    forceNewSession: forceNewSession,
    previousResponseIdOverride: previousResponseIdOverride,
    responseInput: responseInput,
    responseHistory: responseHistory,
    localDocumentPromptText: localDocumentPromptText,
    localDocumentEnvelopes: localDocumentEnvelopes,
    reasoningEffort: ref.read(configuredReasoningEffortProvider),
    lateSessionCleanupDeadline: lateSessionCleanupDeadline,
  );
}

Future<bool> _persistCompletedHermesProjection(
  dynamic ref, {
  required _HermesConversationOwner owner,
  required _HermesRunProjectionStore projectionStore,
  required _HermesRunProjection projection,
  _HermesProjectionPersistenceContext? persistenceContext,
  bool allowCapturedContextAfterRevocation = false,
}) async {
  if (!owner.usesOpenWebUiBackend) return true;
  // Freeze the exact generation before the first provider/lease/lock await.
  // A concurrent approval callback may replace [projection.message], but it
  // must never change the bytes this attempt writes.
  final messageSnapshot = projection.message;
  final revisionSnapshot = projection.persistenceRevision;
  final compactApprovalSnapshot = projection.approvalCompacted;
  bool ownsCapturedPersistence() =>
      projectionStore.isCurrent(projection) &&
      (allowCapturedContextAfterRevocation ||
          (ref != null && owner.backendContextIsCurrent(ref)));
  if (!projection.finalized || !ownsCapturedPersistence()) {
    return false;
  }
  bool ownsSnapshotRevision() =>
      ownsCapturedPersistence() &&
      projection.persistenceRevision == revisionSnapshot;
  final database = owner._mutationOwner.openWebUiDatabase;
  final recordedChatId = owner._conversationId;
  if (database == null || recordedChatId == null || recordedChatId.isEmpty) {
    return false;
  }
  if (persistenceContext == null && ref == null) return false;
  final manager =
      persistenceContext?.databaseManager ??
      ref.read(databaseManagerProvider) as DatabaseManager;
  final lease = manager.tryAcquireLease(database);
  // Captured ownership permits an old account's exact database to finish its
  // write; it never permits writing through a managed database that has begun
  // closing. Every detached/late attempt must hold its own lifetime lease.
  final databaseRequiresLifetimeLease =
      persistenceContext?.databaseRequiresLifetimeLease == true ||
      manager.serverIdForDatabase(database) != null;
  if (databaseRequiresLifetimeLease && lease == null) {
    return false;
  }
  try {
    final locks =
        persistenceContext?.chatLocks ??
        ref.read(chatLocksProvider) as ChatLocks;
    final now =
        (persistenceContext?.clock ?? ref.read(syncClockProvider) as SyncClock)
            .nowEpochSeconds();
    var wroteSnapshot = false;
    final resolvedChatId = await persistWithResolvedDirectConversationOwner(
      locks: locks,
      recordedChatId: recordedChatId,
      resolveCurrentId: (candidate) async {
        if (!ownsCapturedPersistence()) {
          return null;
        }
        return resolveDurableChatMessageOwner(
          database,
          recordedChatId: candidate,
          messageId: messageSnapshot.id,
          expectedRole: 'assistant',
        );
      },
      persist: (currentId) async {
        if (!ownsSnapshotRevision()) return;
        MessageRowData row;
        if (compactApprovalSnapshot) {
          final durable = await database.messagesDao.getMessage(
            currentId,
            messageSnapshot.id,
          );
          if (durable == null || !ownsSnapshotRevision()) return;
          final payload = jsonDecode(durable.payload) as Map<String, dynamic>;
          final metadata = Map<String, dynamic>.from(
            payload['metadata'] is Map
                ? (payload['metadata'] as Map).cast<String, dynamic>()
                : const <String, dynamic>{},
          );
          final durableApproval = metadata[kHermesApprovalMeta];
          final snapshotApproval =
              messageSnapshot.metadata?[kHermesApprovalMeta];
          if (snapshotApproval is! Map) return;
          if (durableApproval is Map &&
              (durableApproval['runId'] != snapshotApproval['runId'] ||
                  durableApproval['approvalId'] !=
                      snapshotApproval['approvalId'])) {
            return;
          }
          metadata[kHermesApprovalMeta] = <String, dynamic>{
            if (durableApproval is Map)
              ...durableApproval.cast<String, dynamic>(),
            'runId': snapshotApproval['runId'],
            'approvalId': snapshotApproval['approvalId'],
            'state': snapshotApproval['state'],
          };
          payload['metadata'] = metadata;
          final snapshotError = messageSnapshot.error;
          if (snapshotError != null) {
            // A compact approval write normally patches metadata only. A stop
            // cleanup diagnostic is also terminal state, and must survive a
            // process restart when it arrives after compaction.
            payload['error'] = snapshotError.toJson();
          }
          row = MessageRowData(
            id: durable.id,
            chatId: currentId,
            parentId: durable.parentId,
            role: durable.role,
            content: durable.content,
            model: durable.model,
            createdAt: durable.createdAt,
            orderIndex: durable.orderIndex,
            payload: payload,
          );
        } else {
          row = _directMessageRow(
            chatId: currentId,
            message: messageSnapshot,
            parentId: messageSnapshot.metadata?['parentId']?.toString(),
            childrenIds: message_tree
                .chatMessageChildrenIds(messageSnapshot)
                .toList(growable: false),
            orderIndex: 0,
            assistantTransport: kHermesTransport,
          );
        }
        // The lock may have waited behind another writer. Suppress a stale
        // snapshot before it can enqueue an obsolete updateChat operation.
        if (!ownsSnapshotRevision()) return;
        await database.chatsDao.appendMessagesWithUpdateOp(
          chatId: currentId,
          messages: <MessageRowData>[row],
          currentMessageId: compactApprovalSnapshot ? null : messageSnapshot.id,
          updatedAt: now,
          enqueueUpdate: true,
          enqueueCompletion: false,
        );
        wroteSnapshot = true;
      },
    );
    if (!wroteSnapshot || !ownsSnapshotRevision()) return false;
    final capturedProvenance =
        persistenceContext?.mixedSessionProvenance ??
        (ref == null
            ? null
            : _captureHermesMixedSessionProvenance(
                ref,
                owner: owner,
                databaseManager: manager,
              ));
    if (capturedProvenance != null) {
      try {
        await _rememberMixedHermesMessageProvenance(messageSnapshot, (
          storageAccountIdentity: capturedProvenance.storageAccountIdentity,
          conversationId: resolvedChatId,
        ));
      } catch (_) {
        // The assistant row is durable, but without the separate local proof
        // its serialized session/continuation metadata remains untrusted and
        // the next turn safely creates a fresh Hermes session.
        DebugLogger.warning(
          'mixed-session-provenance-persist-failed',
          scope: 'hermes/transport',
        );
      }
    }
    if (!ownsSnapshotRevision()) return false;
    if (resolvedChatId == owner._conversationId) {
      return true;
    }
    owner.bindOpenWebUiRemap(resolvedChatId);
    projectionStore.rebind(projection, owner.runKey(messageSnapshot.id));
    return ownsSnapshotRevision();
  } finally {
    await lease?.release();
  }
}

/// Serializes approval-state snapshots that arrive after stream persistence.
///
/// Approval HTTP callbacks can outlive both the card and the run dispatcher.
/// This coordinator retains only the dispatch's exact owner/projection and
/// coalesces revisions through the store's existing persistence CAS. A failed
/// exact revision stays retained for the ordinary owner-adoption retry instead
/// of spinning in the background.
final class _HermesApprovalPersistenceCoordinator {
  _HermesApprovalPersistenceCoordinator({
    required this.owner,
    required this.projectionStore,
    required this.projection,
    required this.persistenceContext,
    required this.allowCapturedContextAfterRevocation,
  });

  final _HermesConversationOwner owner;
  final _HermesRunProjectionStore projectionStore;
  final _HermesRunProjection projection;
  final _HermesProjectionPersistenceContext persistenceContext;
  final bool allowCapturedContextAfterRevocation;
  bool _draining = false;

  void schedule() {
    if (_draining || !projectionStore.approvalPersistenceIsReady(projection)) {
      return;
    }
    _draining = true;
    unawaited(_drain());
  }

  Future<void> _drain() async {
    int? attemptedRevision;
    try {
      while (projectionStore.approvalPersistenceIsReady(projection)) {
        if (!projectionStore.beginPersistenceRetry(projection)) break;
        final persistenceRevision = projection.persistenceRevision;
        attemptedRevision = persistenceRevision;
        var persisted = false;
        try {
          persisted = await _persistCompletedHermesProjection(
            null,
            owner: owner,
            projectionStore: projectionStore,
            projection: projection,
            persistenceContext: persistenceContext,
            allowCapturedContextAfterRevocation:
                allowCapturedContextAfterRevocation,
          );
        } catch (_) {
          // Provider/database failures may contain reflected credentials.
          DebugLogger.error(
            'approval-projection-persistence-failed',
            scope: 'hermes/transport',
          );
        }
        final persistedExactRevision =
            persisted &&
            projectionStore.isCurrent(projection) &&
            projection.persistenceRevision == persistenceRevision;
        final revisionChanged =
            projectionStore.isCurrent(projection) &&
            projection.persistenceRevision != persistenceRevision;
        projectionStore.finishPersistenceRetry(
          projection,
          persisted: persistedExactRevision,
          retryLatestRevision: !persistedExactRevision && revisionChanged,
        );
        if (persistedExactRevision ||
            !projectionStore.isCurrent(projection) ||
            projection.persistenceRevision == persistenceRevision) {
          break;
        }
      }
    } catch (_) {
      // Keep this detached task incapable of reporting an unhandled error if
      // its provider container is disposed while the HTTP callback unwinds.
      DebugLogger.error(
        'approval-persistence-coordinator-failed',
        scope: 'hermes/transport',
      );
    } finally {
      _draining = false;
      if (projectionStore.approvalPersistenceIsReady(projection) &&
          attemptedRevision != projection.persistenceRevision) {
        schedule();
      }
    }
  }
}

void _retryHermesProjectionPersistenceAfterAdoption(
  dynamic ref, {
  required Conversation conversation,
  required _HermesRunProjectionStore projectionStore,
  required _HermesRunProjection projection,
}) {
  if (!projectionStore.beginPersistenceRetry(projection)) return;
  final owner = _HermesConversationOwner.capture(ref, conversation);
  if (!owner.usesOpenWebUiBackend ||
      owner.runKey(projection.message.id) != projection.key) {
    projectionStore.finishPersistenceRetry(projection, persisted: false);
    return;
  }

  unawaited(() async {
    var persisted = false;
    final persistenceRevision = projection.persistenceRevision;
    try {
      persisted = await _persistCompletedHermesProjection(
        ref,
        owner: owner,
        projectionStore: projectionStore,
        projection: projection,
      );
    } catch (_) {
      // Database/provider errors can contain reflected credentials. The next
      // owner adoption retries again; diagnostics identify only this site.
      DebugLogger.error('projection-retry-failed', scope: 'hermes/transport');
    } finally {
      projectionStore.finishPersistenceRetry(
        projection,
        persisted:
            persisted && projection.persistenceRevision == persistenceRevision,
      );
    }
  }());
}
