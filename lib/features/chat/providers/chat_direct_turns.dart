part of 'chat_providers.dart';

Future<_DirectConversationOwner?> _persistDirectTurnStart(
  dynamic ref, {
  required _ResolvedDirectRoute route,
  required Conversation? expectedConversation,
  required String? expectedConversationId,
  required ChatMessage userMessage,
  required ChatMessage assistantMessage,
  required List<ChatMessage> allMessages,
  required bool Function(_DirectConversationOwner owner) bindOwner,
  required Object? sourceApi,
  required ApiAuthSnapshot? sourceAuthSnapshot,
  required Object? sourceAuthSessionEpoch,
  required Stream<RemapEvent>? remapEvents,
  required Object? openWebUiAuthSessionEpoch,
  required SyncEngine? openWebUiSyncEngine,
  String? pendingFolderId,
}) async {
  final active = expectedConversation;
  final storedActive = active != null && chatStorageKindOf(active) != null;
  final isTemporary =
      ref.read(temporaryChatEnabledProvider) ||
      (active != null && isTemporaryChat(active.id) && !storedActive);
  final now = ref.read(syncClockProvider).nowEpochSeconds();
  final title = active?.title.trim().isNotEmpty == true
      ? active!.title
      : _titleFromText(userMessage.content);

  if (isTemporary) {
    final id = active?.id ?? 'local:${const Uuid().v4()}';
    final conversation =
        (active ??
                Conversation(
                  id: id,
                  title: title,
                  createdAt: DateTime.now(),
                  updatedAt: DateTime.now(),
                ))
            .copyWith(
              model: route.model.id,
              messages: allMessages,
              updatedAt: DateTime.now(),
              metadata: <String, dynamic>{
                ...?active?.metadata,
                'backend': kDirectTransport,
                'directProfileId': route.binding.profileId,
              },
            );
    final owner = _DirectConversationOwner(
      conversationId: id,
      location: null,
      sourceApi: sourceApi,
      sourceAuthSnapshot: sourceAuthSnapshot,
      sourceAuthSessionEpoch: sourceAuthSessionEpoch,
      remapEvents: remapEvents,
    );
    if (!bindOwner(owner)) return null;
    if (_isDirectSendConversationOwnerActive(ref, expectedConversationId)) {
      ref.read(activeConversationProvider.notifier).set(conversation);
    }
    return owner;
  }

  final ChatDatabaseRepository repository = ref.read(
    chatDatabaseRepositoryProvider,
  );
  ChatDatabaseLocation? initiallyOwnedLocation;
  try {
    initiallyOwnedLocation = active == null
        ? repository.chooseForNewDirectChat(_directSyncPreference(ref))
        : repository.locationFor(
            chatStorageKindOf(active) ?? ChatStorageKind.openWebUi,
          );
  } on StateError {
    // A stale OpenWebUI conversation may be restored before its backend. The
    // existing fallback below will choose direct-local storage if appropriate.
  }
  AppDatabase? leasedDatabase = initiallyOwnedLocation?.database;
  String? persistenceOwnerId = initiallyOwnedLocation == null
      ? null
      : _directPersistenceOwnerIdForLocation(ref, initiallyOwnedLocation);
  DatabaseLifetimeLease? databaseLease = initiallyOwnedLocation == null
      ? null
      : _acquireDirectTurnStartDatabaseLease(ref, initiallyOwnedLocation);

  Future<void> ensureLocationLease(ChatDatabaseLocation location) async {
    if (identical(leasedDatabase, location.database)) return;
    final previousLease = databaseLease;
    final nextLease = _acquireDirectTurnStartDatabaseLease(ref, location);
    leasedDatabase = location.database;
    persistenceOwnerId = _directPersistenceOwnerIdForLocation(ref, location);
    databaseLease = nextLease;
    await previousLease?.release();
  }

  DatabaseLifetimeLease? takeDatabaseLease() {
    final lease = databaseLease;
    databaseLease = null;
    return lease;
  }

  try {
    ChatDatabaseLocation? location;
    if (active != null) {
      location = await repository.resolveChat(
        active.id,
        preferred: chatStorageKindOf(active) ?? ChatStorageKind.openWebUi,
      );
      if (location != null) {
        _requireDirectLocationAuthSession(
          ref,
          location: location,
          capturedEpoch: openWebUiAuthSessionEpoch,
        );
      }
    }

    if (active == null || location == null) {
      final newLocation = repository.chooseForNewDirectChat(
        _directSyncPreference(ref),
      );
      await ensureLocationLease(newLocation);
      location = newLocation;
      final id = newLocation.storage == ChatStorageKind.openWebUi
          ? 'local:${const Uuid().v4()}'
          : 'direct-local:${const Uuid().v4()}';
      final folderId = newLocation.storage == ChatStorageKind.openWebUi
          ? pendingFolderId
          : null;
      final blob = _directNewChatBlob(
        title: title,
        modelId: route.model.id,
        messages: allMessages,
      );
      final rows = ChatBlobMapper.blobToRows(
        chatId: id,
        blob: blob,
        title: title,
        folderId: folderId,
        createdAt: now,
        updatedAt: now,
      );
      final locks = ref.read(chatLocksProvider) as ChatLocks;
      await locks.runExclusive(id, () async {
        _requireDirectLocationAuthSession(
          ref,
          location: newLocation,
          capturedEpoch: openWebUiAuthSessionEpoch,
        );
        await repository.persistNewDirectChat(
          newLocation,
          rows,
          openWebUiContentHash: newLocation.storage == ChatStorageKind.openWebUi
              ? createChatContentHash(rows)
              : null,
        );
      });
      var conversation = Conversation(
        id: id,
        title: title,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        model: route.model.id,
        messages: allMessages,
        folderId: folderId,
        metadata: <String, dynamic>{
          'backend': kDirectTransport,
          'directProfileId': route.binding.profileId,
        },
      );
      conversation = withChatStorageProvenance(
        conversation,
        newLocation.storage,
      );
      final owner = _DirectConversationOwner(
        conversationId: id,
        location: newLocation,
        persistenceOwnerId: persistenceOwnerId,
        databaseLease: takeDatabaseLease(),
        sourceApi: sourceApi,
        sourceAuthSnapshot: sourceAuthSnapshot,
        sourceAuthSessionEpoch: sourceAuthSessionEpoch,
        remapEvents: remapEvents,
        openWebUiAuthSessionEpoch:
            newLocation.storage == ChatStorageKind.openWebUi
            ? openWebUiAuthSessionEpoch
            : null,
        openWebUiSyncEngine: newLocation.storage == ChatStorageKind.openWebUi
            ? openWebUiSyncEngine
            : null,
      );
      if (!bindOwner(owner)) {
        await owner.releaseDatabaseLease();
        return null;
      }
      // The commit above may have won the race with an auth-session change.
      // Bind its exact durable owner before the post-commit fence so the
      // caller can settle the streaming placeholder if this check throws.
      _requireDirectOwnerAuthSession(ref, owner);
      if (_isDirectSendConversationOwnerActive(ref, expectedConversationId)) {
        ref.read(activeConversationProvider.notifier).set(conversation);
        ref.read(pendingFolderIdProvider.notifier).clear();
      }
      return owner;
    }

    final existingLocation = location;
    await ensureLocationLease(existingLocation);
    final chatId = active.id;
    final parentId = userMessage.metadata?['parentId']?.toString();
    final parentMessage = parentId == null
        ? null
        : allMessages.where((message) => message.id == parentId).firstOrNull;
    final parentRow = parentMessage == null
        ? null
        : _directMessageRow(
            chatId: chatId,
            message: parentMessage,
            parentId: message_tree.chatMessageParentId(parentMessage),
            childrenIds: message_tree
                .chatMessageChildrenIds(parentMessage)
                .toList(growable: false),
            orderIndex: 0,
          );
    final userRow = _directMessageRow(
      chatId: chatId,
      message: userMessage,
      parentId: parentId,
      childrenIds: <String>[assistantMessage.id],
      orderIndex: 0,
    );
    final assistantRow = _directMessageRow(
      chatId: chatId,
      message: assistantMessage,
      parentId: userMessage.id,
      childrenIds: const <String>[],
      orderIndex: 1,
    );
    final locks = ref.read(chatLocksProvider) as ChatLocks;
    await locks.runExclusive(chatId, () async {
      _requireDirectLocationAuthSession(
        ref,
        location: existingLocation,
        capturedEpoch: openWebUiAuthSessionEpoch,
      );
      await repository.persistDirectMessages(
        existingLocation,
        chatId: chatId,
        messages: <MessageRowData>[?parentRow, userRow, assistantRow],
        currentMessageId: assistantMessage.id,
        updatedAt: now,
      );
    });
    final updated = withChatStorageProvenance(
      active.copyWith(
        model: route.model.id,
        messages: allMessages,
        updatedAt: DateTime.now(),
        metadata: <String, dynamic>{
          ...active.metadata,
          'backend': kDirectTransport,
          'directProfileId': route.binding.profileId,
        },
      ),
      existingLocation.storage,
    );
    final owner = _DirectConversationOwner(
      conversationId: chatId,
      location: existingLocation,
      persistenceOwnerId: persistenceOwnerId,
      databaseLease: takeDatabaseLease(),
      sourceApi: sourceApi,
      sourceAuthSnapshot: sourceAuthSnapshot,
      sourceAuthSessionEpoch: sourceAuthSessionEpoch,
      remapEvents: remapEvents,
      openWebUiAuthSessionEpoch:
          existingLocation.storage == ChatStorageKind.openWebUi
          ? openWebUiAuthSessionEpoch
          : null,
      openWebUiSyncEngine: existingLocation.storage == ChatStorageKind.openWebUi
          ? openWebUiSyncEngine
          : null,
    );
    if (!bindOwner(owner)) {
      await owner.releaseDatabaseLease();
      return null;
    }
    // See the new-chat branch above: cleanup ownership must escape the helper
    // before a post-commit auth failure escapes it.
    _requireDirectOwnerAuthSession(ref, owner);
    if (_isDirectSendConversationOwnerActive(ref, expectedConversationId)) {
      ref.read(activeConversationProvider.notifier).set(updated);
    }
    return owner;
  } catch (_) {
    await databaseLease?.release();
    rethrow;
  }
}

Future<void> _persistDirectUserMessageUpdate(
  dynamic ref, {
  required _DirectConversationOwner owner,
  required ChatMessage userMessage,
  required bool Function() isCurrentGeneration,
}) async {
  // Repair only inside the storage that owns this placeholder. The global
  // active-conversation remap is raw-id-only and may describe Hermes or a
  // colliding backend. Unstored owners keep their backend-scoped runtime id;
  // OpenWebUI durable remaps are also delivered by the scoped sync listener.
  final location = owner.location;
  if (location == null || !isCurrentGeneration()) return;
  _requireDirectOwnerAuthSession(ref, owner);
  final ChatDatabaseRepository repository = ref.read(
    chatDatabaseRepositoryProvider,
  );
  final locks = ref.read(chatLocksProvider) as ChatLocks;
  final now = ref.read(syncClockProvider).nowEpochSeconds();
  final resolvedChatId = await persistWithResolvedDirectConversationOwner(
    locks: locks,
    recordedChatId: owner.conversationId,
    resolveCurrentId: (recordedId) async {
      _requireDirectOwnerAuthSession(ref, owner);
      final resolved = await repository.resolveCurrentChatIdForMessage(
        location,
        recordedChatId: recordedId,
        messageId: userMessage.id,
        expectedRole: 'user',
      );
      _requireDirectOwnerAuthSession(ref, owner);
      return resolved;
    },
    persist: (currentId) async {
      if (!isCurrentGeneration()) return;
      _requireDirectOwnerAuthSession(ref, owner);
      await repository.persistDirectMessages(
        location,
        chatId: currentId,
        messages: <MessageRowData>[
          _directMessageRow(
            chatId: currentId,
            message: userMessage,
            parentId: userMessage.metadata?['parentId']?.toString(),
            childrenIds: message_tree
                .chatMessageChildrenIds(userMessage)
                .toList(growable: false),
            orderIndex: 0,
          ),
        ],
        currentMessageId: null,
        updatedAt: now,
      );
      _requireDirectOwnerAuthSession(ref, owner);
    },
  );
  _requireDirectOwnerAuthSession(ref, owner);
  if (isCurrentGeneration()) owner.conversationId = resolvedChatId;
}

Future<String?> _resolveDirectImageFromOpenWebUi(
  dynamic api,
  String fileId,
  int maxBytes, {
  ApiAuthSnapshot? sourceAuthSnapshot,
  CancelToken? cancelToken,
  void Function()? requireSourceContext,
}) async {
  if (api == null || fileId.trim().isEmpty || maxBytes <= 0) return null;
  try {
    requireSourceContext?.call();
    final info = api is ApiService
        ? await api.getFileInfo(
            fileId,
            authSnapshot: sourceAuthSnapshot,
            cancelToken: cancelToken,
          )
        : await api.getFileInfo(fileId);
    requireSourceContext?.call();
    final contentType =
        info['meta']?['content_type'] ??
        info['content_type'] ??
        info['mime_type'] ??
        '';
    final mime = contentType.toString().trim().toLowerCase();
    if (!mime.startsWith('image/')) return null;
    requireSourceContext?.call();
    final content =
        (api is ApiService
                ? await api.getFileContent(
                    fileId,
                    maxBytes: maxBytes,
                    authSnapshot: sourceAuthSnapshot,
                    cancelToken: cancelToken,
                  )
                : await api.getFileContent(fileId, maxBytes: maxBytes))
            .toString();
    requireSourceContext?.call();
    if (content.startsWith('data:image/')) return content;
    return 'data:${mime.isEmpty ? 'image/png' : mime};base64,$content';
  } on _DirectOpenWebUiAuthSessionChanged {
    rethrow;
  } catch (_) {
    // A captured request is rejected locally if the shared ApiService token
    // changed before dispatch. Re-check the source epoch so this becomes an
    // ownership cancellation instead of a misleading unsupported-file error.
    requireSourceContext?.call();
    return null;
  }
}

@visibleForTesting
Future<String?> resolveDirectImageFromOpenWebUiForTest(
  dynamic api,
  String fileId, {
  int maxBytes = kDirectMaxDecodedImageBytes,
}) => _resolveDirectImageFromOpenWebUi(api, fileId, maxBytes);

Future<void> _persistCompletedDirectAssistant(
  dynamic ref, {
  required _DirectConversationOwner owner,
  required ChatMessage assistant,
  required bool Function() isCurrentGeneration,
}) async {
  // Do not consult the raw-id-only active remap here: it may belong to Hermes
  // or another colliding backend. Stored owners repair inside their database;
  // unstored owners retain their backend-scoped runtime identity.
  final location = owner.location;
  if (location == null || !isCurrentGeneration()) return;
  _requireDirectOwnerAuthSession(ref, owner);
  final ChatDatabaseRepository repository = ref.read(
    chatDatabaseRepositoryProvider,
  );
  final now = ref.read(syncClockProvider).nowEpochSeconds();
  final locks = ref.read(chatLocksProvider) as ChatLocks;
  var persisted = false;
  final resolvedChatId = await persistWithResolvedDirectConversationOwner(
    locks: locks,
    recordedChatId: owner.conversationId,
    resolveCurrentId: (recordedId) async {
      _requireDirectOwnerAuthSession(ref, owner);
      final resolved = await repository.resolveCurrentChatIdForMessage(
        location,
        recordedChatId: recordedId,
        messageId: assistant.id,
        expectedRole: 'assistant',
      );
      _requireDirectOwnerAuthSession(ref, owner);
      return resolved;
    },
    persist: (currentId) async {
      // This callback executes under the chat lock. A replacement writes its
      // placeholder under the same lock, so this final check either suppresses
      // the stale generation or orders its older write before the replacement.
      if (!isCurrentGeneration()) return;
      _requireDirectOwnerAuthSession(ref, owner);
      final row = _directMessageRow(
        chatId: currentId,
        message: assistant,
        parentId: assistant.metadata?['parentId']?.toString(),
        childrenIds: const <String>[],
        orderIndex: 0,
      );
      await repository.persistDirectMessages(
        location,
        chatId: currentId,
        messages: <MessageRowData>[row],
        currentMessageId: assistant.id,
        updatedAt: now,
      );
      _requireDirectOwnerAuthSession(ref, owner);
      persisted = true;
    },
  );
  _requireDirectOwnerAuthSession(ref, owner);
  if (!persisted || !isCurrentGeneration()) return;
  owner.conversationId = resolvedChatId;
  if (location.storage == ChatStorageKind.openWebUi) {
    try {
      _requireDirectOwnerAuthSession(ref, owner);
      await owner.openWebUiSyncEngine?.drainNowForDatabase(location.database);
      _requireDirectOwnerAuthSession(ref, owner);
    } on _DirectOpenWebUiAuthSessionChanged {
      rethrow;
    } catch (error, stackTrace) {
      // The durable row and outbox operation already committed. A later sync
      // trigger can retry; surfacing this as a completion failure would let an
      // outer recovery path overwrite the authoritative accumulator snapshot.
      DebugLogger.error(
        'completion-sync-drain-failed',
        scope: 'direct-connections/chat',
        error: error,
        stackTrace: stackTrace,
        data: {'conversationId': owner.conversationId},
      );
    }
  }
}

/// Settles the exact durable placeholder after its OpenWebUI account is no
/// longer current.
///
/// Normal completion persistence is deliberately fenced by the live auth
/// epoch. This cleanup is narrower: it uses the database location already
/// held alive by the run lease, resolves only the captured assistant row (and
/// its committed remap), and changes it only while its durable payload still
/// says it is streaming. It therefore cannot write into the newly active
/// account or overwrite a completion that won the race.
Future<void> _settleDirectAssistantAfterAuthSessionChange(
  dynamic ref, {
  required _DirectConversationOwner owner,
  required String assistantMessageId,
  required bool Function() isCurrentGeneration,
}) async {
  final location = owner.location;
  if (location == null) return;
  final database = location.database;
  final repository =
      ref.read(chatDatabaseRepositoryProvider) as ChatDatabaseRepository;
  final locks = ref.read(chatLocksProvider) as ChatLocks;
  final now = (ref.read(syncClockProvider) as SyncClock).nowEpochSeconds();
  var settled = false;
  final resolvedChatId = await persistWithResolvedDirectConversationOwner(
    locks: locks,
    recordedChatId: owner.conversationId,
    resolveCurrentId: (recordedId) => resolveDurableChatMessageOwner(
      database,
      recordedChatId: recordedId,
      messageId: assistantMessageId,
      expectedRole: 'assistant',
    ),
    persist: (currentId) async {
      if (!isCurrentGeneration()) return;
      final existing = await database.messagesDao.getMessage(
        currentId,
        assistantMessageId,
      );
      if (existing == null || existing.role != 'assistant') return;
      Map<String, dynamic> payload;
      try {
        final decoded = jsonDecode(existing.payload);
        payload = decoded is Map
            ? decoded.map((key, value) => MapEntry(key.toString(), value))
            : <String, dynamic>{};
      } catch (_) {
        return;
      }
      if (payload['isStreaming'] != true) return;
      if (!isCurrentGeneration()) return;
      payload
        ..['isStreaming'] = false
        ..['done'] = true;
      await repository.persistDirectMessages(
        location,
        chatId: currentId,
        messages: <MessageRowData>[
          MessageRowData(
            id: existing.id,
            chatId: currentId,
            parentId: existing.parentId,
            role: existing.role,
            content: existing.content,
            model: existing.model,
            createdAt: existing.createdAt,
            orderIndex: existing.orderIndex,
            payload: payload,
          ),
        ],
        currentMessageId: null,
        updatedAt: now,
      );
      settled = true;
    },
  );
  if (settled) owner.conversationId = resolvedChatId;
}

Future<bool> _refreshDirectConversationOwner(
  dynamic ref, {
  required _DirectConversationOwner owner,
  required String assistantMessageId,
  required DirectRunRegistry registry,
  required DirectRunReservation reservation,
  ChatSendPlaceholderHandle? sendHandle,
  void Function(DirectRunKey key)? onRebound,
}) async {
  final location = owner.location;
  var resolvedConversationId = owner.conversationId;
  if (location != null) {
    _requireDirectOwnerAuthSession(ref, owner);
    final ChatDatabaseRepository repository = ref.read(
      chatDatabaseRepositoryProvider,
    );
    final resolved = await repository.resolveCurrentChatIdForMessage(
      location,
      recordedChatId: owner.conversationId,
      messageId: assistantMessageId,
      expectedRole: 'assistant',
    );
    _requireDirectOwnerAuthSession(ref, owner);
    if (resolved == null) {
      final placeholderWasDurablyDeleted = await location.database.transaction(
        () async {
          final recordedChat = await location.database.chatsDao.getChat(
            owner.conversationId,
          );
          if (recordedChat == null || recordedChat.deleted) return false;
          final placeholder = await location.database.messagesDao.getMessage(
            owner.conversationId,
            assistantMessageId,
          );
          return placeholder == null;
        },
      );
      _requireDirectOwnerAuthSession(ref, owner);
      throw _DirectConversationOwnerUnavailable(
        placeholderWasDurablyDeleted: placeholderWasDurablyDeleted,
      );
    }
    resolvedConversationId = resolved;
  }
  final resolvedOwnerScope = owner.scopedConversationIdFor(
    resolvedConversationId,
  );
  final rebound = registry.rebindIfVacant(
    reservation,
    _directRunKeyForOwner(resolvedOwnerScope, assistantMessageId),
  );
  if (rebound) {
    owner.conversationId = resolvedConversationId;
    sendHandle?._bindOwnerScope(resolvedOwnerScope);
    onRebound?.call(
      _directRunKeyForOwner(resolvedOwnerScope, assistantMessageId),
    );
  }
  return rebound;
}

@visibleForTesting
({bool enableWebSearch, List<String> localMcpToolIds})
normalizeDirectToolSelectionForBinding({
  required DirectModelBinding binding,
  required bool enableWebSearch,
  required List<String> localMcpToolIds,
}) {
  final effectiveToolIds = directBindingSupportsLocalMcp(binding)
      ? localMcpToolIds
      : const <String>[];
  return (
    enableWebSearch: enableWebSearch && effectiveToolIds.isEmpty,
    localMcpToolIds: effectiveToolIds,
  );
}

Future<void> _dispatchDirectRunFromChat(
  dynamic ref, {
  required _ResolvedDirectRoute route,
  required String assistantMessageId,
  required ChatMessage assistantSeed,
  required List<ChatMessage> requestMessages,
  required _DirectConversationOwner owner,
  required DirectRunReservation reservation,
  required CancelToken preflightCancelToken,
  required bool enableWebSearch,
  required bool enableImageGeneration,
  required String? reasoningEffort,
  required List<String> localMcpToolIds,
  Map<String, DirectFilePart> ephemeralFilePartsByAttachmentId = const {},
  ChatSendPlaceholderHandle? sendHandle,
}) async {
  final releaseGeneration = holdLocalChatGeneration(ref);
  try {
    final toolSelection = normalizeDirectToolSelectionForBinding(
      binding: route.binding,
      enableWebSearch: enableWebSearch,
      localMcpToolIds: localMcpToolIds,
    );
    final DirectRunRegistry registry = ref.read(directRunRegistryProvider);
    final stopIndex = ref.read(_directRunStopIndexProvider);
    var indexedRunKey = _directRunKeyForOwner(
      owner.scopedConversationId,
      assistantMessageId,
    );
    stopIndex.track(indexedRunKey);
    void rebindStopIndex(DirectRunKey nextKey) {
      if (nextKey == indexedRunKey) return;
      stopIndex.rebind(indexedRunKey, nextKey);
      indexedRunKey = nextKey;
    }

    StreamSubscription<RemapEvent>? remapSubscription;
    final ownerRemapEvents = owner.remapEvents;
    if (owner.location?.storage == ChatStorageKind.openWebUi &&
        ownerRemapEvents != null) {
      remapSubscription = trackDirectConversationRemaps(
        events: ownerRemapEvents,
        currentId: () => owner.conversationId,
        setId: (id) {
          final resolvedOwnerScope = owner.scopedConversationIdFor(id);
          final rebound = registry.rebindIfVacant(
            reservation,
            _directRunKeyForOwner(resolvedOwnerScope, assistantMessageId),
          );
          if (!rebound) return;
          owner.conversationId = id;
          sendHandle?._bindOwnerScope(resolvedOwnerScope);
          rebindStopIndex(
            _directRunKeyForOwner(resolvedOwnerScope, assistantMessageId),
          );
        },
      );
    }
    try {
      // Subscribe first, then repair from durable/active remap state. A remap
      // before the subscription is found by the repair; one after it is observed
      // by the synchronous listener above.
      if (!await _refreshDirectConversationOwner(
        ref,
        owner: owner,
        assistantMessageId: assistantMessageId,
        registry: registry,
        reservation: reservation,
        sendHandle: sendHandle,
        onRebound: rebindStopIndex,
      )) {
        return;
      }
      await _dispatchDirectRunFromChatWithTrackedOwner(
        ref,
        route: route,
        assistantMessageId: assistantMessageId,
        assistantSeed: assistantSeed,
        requestMessages: requestMessages,
        owner: owner,
        reservation: reservation,
        preflightCancelToken: preflightCancelToken,
        enableWebSearch: toolSelection.enableWebSearch,
        enableImageGeneration: enableImageGeneration,
        reasoningEffort: reasoningEffort,
        localMcpToolIds: toolSelection.localMcpToolIds,
        ephemeralFilePartsByAttachmentId: ephemeralFilePartsByAttachmentId,
      );
    } finally {
      stopIndex.untrack(indexedRunKey);
      final subscription = remapSubscription;
      if (subscription != null) {
        try {
          // Remap delivery is revoked synchronously. The stream provider owns
          // the returned cleanup future, which must not hold a completed direct
          // turn or its database lease if provider teardown never settles.
          _observeDetachedCancellation(
            subscription.cancel(),
            scope: 'direct-connections/remap-subscription',
          );
        } catch (_) {
          DebugLogger.error(
            'remap-subscription-cleanup-failed',
            scope: 'direct-connections/transport',
          );
        }
      }
    }
  } finally {
    releaseGeneration();
  }
}

Future<void> _dispatchDirectRunFromChatWithTrackedOwner(
  dynamic ref, {
  required _ResolvedDirectRoute route,
  required String assistantMessageId,
  required ChatMessage assistantSeed,
  required List<ChatMessage> requestMessages,
  required _DirectConversationOwner owner,
  required DirectRunReservation reservation,
  required CancelToken preflightCancelToken,
  required bool enableWebSearch,
  required bool enableImageGeneration,
  required String? reasoningEffort,
  required List<String> localMcpToolIds,
  Map<String, DirectFilePart> ephemeralFilePartsByAttachmentId = const {},
}) async {
  final notifier =
      ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier;
  final DirectRunRegistry registry = ref.read(directRunRegistryProvider);
  if (localMcpToolIds.isNotEmpty && enableImageGeneration) {
    throw const DirectChatInputException(
      'Local MCP tools cannot be combined with image generation.',
    );
  }
  final api = owner.sourceApi;
  final imageCache = <String, String?>{};
  Future<String?> resolveImage(String id, int maxBytes) async {
    if (imageCache.containsKey(id)) return imageCache[id];
    final resolved = await _resolveDirectImageFromOpenWebUi(
      api,
      id,
      maxBytes,
      sourceAuthSnapshot: owner.sourceAuthSnapshot,
      cancelToken: preflightCancelToken,
      requireSourceContext: () =>
          _requireDirectOwnerSourceAuthSession(ref, owner),
    );
    imageCache[id] = resolved;
    return resolved;
  }

  final contextLength = directModelContextLength(
    route.model,
    fallbackContextLength: ref.read(
      directContextLengthOverridesProvider,
    )[route.model.id],
  );
  final compactionThreshold = contextLength * 70 ~/ 100;
  final requiresReplayVerificationKey = requestMessages.any(
    (message) =>
        (message.files ?? const <Map<String, dynamic>>[]).any(
          (file) => file['source'] == 'direct_local',
        ) ||
        message.metadata?[kOpenRouterFileAnnotationsMetadataKey] != null,
  );
  final hasContextSummary = requestMessages.any(
    (message) => message.metadata?[kDirectContextSummaryMetadataKey] != null,
  );
  List<int>? verificationKey;
  late DirectContextHistory contextHistory;
  var directMessages = await _awaitDirectPreflightOrCancellation(
    registry: registry,
    reservation: reservation,
    cancelToken: preflightCancelToken,
    operation: () async {
      if (requiresReplayVerificationKey) {
        verificationKey = await ref.read(directDeviceTrustKeyProvider.future);
      } else if (hasContextSummary) {
        verificationKey = await _tryReadDirectContextVerificationKey(ref);
      }
      contextHistory = directContextHistory(
        requestMessages,
        verificationKey: verificationKey ?? const <int>[],
      );
      return buildDirectChatMessages(
        messages: directContextRequestMessages(
          systemMessages: contextHistory.systemMessages,
          activeMessages: contextHistory.activeMessages,
          summary: contextHistory.previousSummary,
        ),
        resolveImage: resolveImage,
        directDocumentVerificationKey: verificationKey,
        openRouterProfile: route.profile.isOpenRouter ? route.profile : null,
        ephemeralFilePartsByAttachmentId: ephemeralFilePartsByAttachmentId,
      );
    },
  );
  _requireDirectOwnerAuthSession(ref, owner);
  if (directMessages.isEmpty) {
    throw const DirectChatInputException('There is no content to send.');
  }
  ensureDirectMessagesCompatibleWithModel(
    model: route.model,
    messages: directMessages,
  );
  if (registry.isCancelled(reservation)) {
    throw const _DirectRunStoppedDuringPreflight();
  }
  if (!_directRouteIsStillSelected(ref, route)) {
    throw const _DirectRunStoppedDuringPreflight();
  }
  final estimatedContextTokens = estimateDirectContextTokens(directMessages);
  if (verificationKey == null &&
      !hasContextSummary &&
      estimatedContextTokens > compactionThreshold) {
    verificationKey = await _awaitDirectPreflightOrCancellation(
      registry: registry,
      reservation: reservation,
      cancelToken: preflightCancelToken,
      operation: () => _tryReadDirectContextVerificationKey(ref),
    );
  }
  final DirectProviderAdapter adapter = ref
      .read(directProviderAdapterRegistryProvider)
      .require(route.binding.adapterKey);
  _requireDirectOwnerAuthSession(ref, owner);
  final sensitiveProviderValues = directProfileSensitiveValues(route.profile);
  final streamLimits = ref.read(directNormalizedStreamLimitsProvider);
  if (streamLimits.idleTimeout <= Duration.zero) {
    throw ArgumentError.value(
      streamLimits.idleTimeout,
      'direct normalized stream idle timeout',
    );
  }
  if (streamLimits.maxDuration <= Duration.zero) {
    throw ArgumentError.value(
      streamLimits.maxDuration,
      'direct normalized stream max duration',
    );
  }
  final compactionPlan = verificationKey == null
      ? null
      : estimatedContextTokens <= compactionThreshold
      ? null
      : planDirectContextCompaction(contextHistory.activeMessages);
  if (compactionPlan != null) {
    final compactionContextLength = contextLength;
    final compactionVerificationKey = verificationKey!;
    String? summary;
    try {
      final compactedDirectMessages = await _awaitDirectPreflightOrCancellation(
        registry: registry,
        reservation: reservation,
        cancelToken: preflightCancelToken,
        operation: () => buildDirectChatMessages(
          messages: compactionPlan.compactedMessages,
          resolveImage: resolveImage,
          directDocumentVerificationKey: verificationKey,
          openRouterProfile: route.profile.isOpenRouter ? route.profile : null,
          ephemeralFilePartsByAttachmentId: ephemeralFilePartsByAttachmentId,
        ),
      );
      summary = await _awaitDirectPreflightOrCancellation(
        registry: registry,
        reservation: reservation,
        cancelToken: preflightCancelToken,
        operation: () => _generateDirectContextSummary(
          adapter: adapter,
          profile: route.profile,
          remoteModelId: route.binding.remoteModelId,
          compactedMessages: compactedDirectMessages,
          previousSummary: contextHistory.previousSummary,
          contextLength: compactionContextLength,
          preflightCancelToken: preflightCancelToken,
        ),
      );
    } on _DirectRunStoppedDuringPreflight {
      rethrow;
    } on _DirectOpenWebUiAuthSessionChanged {
      rethrow;
    } catch (error) {
      DebugLogger.warning(
        'context-compaction-failed',
        scope: 'direct-connections/compaction',
        data: {'errorType': error.runtimeType.toString()},
      );
    }

    if (summary != null) {
      _requireDirectOwnerAuthSession(ref, owner);
      if (registry.isCancelled(reservation) ||
          !_directRouteIsStillSelected(ref, route)) {
        throw const _DirectRunStoppedDuringPreflight();
      }
      ChatMessage attachSummary(ChatMessage current) => current.copyWith(
        metadata: <String, dynamic>{
          ...?current.metadata,
          kDirectContextSummaryMetadataKey: signedDirectContextSummary(
            checkpoint: current,
            summary: summary!,
            signingKey: compactionVerificationKey,
          ),
        },
      );
      var checkpoint = attachSummary(compactionPlan.checkpoint);
      if (_isDirectConversationOwnerActive(ref, owner)) {
        notifier.updateMessageById(checkpoint.id, (current) {
          checkpoint = attachSummary(current);
          return checkpoint;
        });
      }
      try {
        await _persistDirectUserMessageUpdate(
          ref,
          owner: owner,
          userMessage: checkpoint,
          isCurrentGeneration: () =>
              registry.isLatest(reservation) &&
              !registry.isCancelled(reservation),
        );
      } on _DirectOpenWebUiAuthSessionChanged {
        rethrow;
      } catch (error) {
        DebugLogger.warning(
          'context-checkpoint-persist-failed',
          scope: 'direct-connections/compaction',
          data: {'errorType': error.runtimeType.toString()},
        );
      }
      directMessages = await _awaitDirectPreflightOrCancellation(
        registry: registry,
        reservation: reservation,
        cancelToken: preflightCancelToken,
        operation: () => buildDirectChatMessages(
          messages: directContextRequestMessages(
            systemMessages: contextHistory.systemMessages,
            activeMessages: compactionPlan.recentMessages,
            summary: summary,
          ),
          resolveImage: resolveImage,
          directDocumentVerificationKey: verificationKey,
          openRouterProfile: route.profile.isOpenRouter ? route.profile : null,
          ephemeralFilePartsByAttachmentId: ephemeralFilePartsByAttachmentId,
        ),
      );
      directMessages = fitDirectContextMessages(
        directMessages,
        maxTokens: contextLength,
      );
      ensureDirectMessagesCompatibleWithModel(
        model: route.model,
        messages: directMessages,
      );
      DebugLogger.log(
        'context-compacted',
        scope: 'direct-connections/compaction',
        data: {
          'compactedMessages': compactionPlan.compactedMessages.length,
          'retainedMessages': compactionPlan.recentMessages.length,
        },
      );
    }
  }
  DirectMcpToolSession? mcpSession;
  Future<void> closeMcpSessionBestEffort() async {
    try {
      await mcpSession?.close();
    } catch (_) {}
  }

  DirectToolRuntime? toolRuntime;
  if (localMcpToolIds.isNotEmpty) {
    final servers = await _awaitDirectPreflightOrCancellation(
      registry: registry,
      reservation: reservation,
      cancelToken: preflightCancelToken,
      operation: () => ref.read(directMcpServersProvider.future),
    );
    final serversById = <String, DirectMcpServer>{
      for (final server in servers) server.id: server,
    };
    registry.synchronizeMcpServers(servers);
    final selectedServers = <DirectMcpServer>[];
    final seen = <String>{};
    for (final selection in localMcpToolIds) {
      final id = selection.substring(kDirectMcpToolIdPrefix.length);
      final server = serversById[id];
      if (id.isEmpty || server == null || !server.enabled) {
        throw const DirectChatInputException(
          'A selected MCP server is unavailable.',
        );
      }
      server.validate();
      if (seen.add(id)) selectedServers.add(server);
    }
    final sessionFuture = ref.read(directMcpSessionBuilderProvider)(
      selectedServers,
    );
    unawaited(
      registry.cancellationSignal(reservation).then((_) async {
        try {
          await (await sessionFuture).close();
        } catch (_) {}
      }),
    );
    mcpSession = await _awaitDirectPreflightOrCancellation(
      registry: registry,
      reservation: reservation,
      cancelToken: preflightCancelToken,
      operation: () => sessionFuture,
    );
    try {
      _requireDirectOwnerAuthSession(ref, owner);
      if (!_directRouteIsStillSelected(ref, route)) {
        throw const DirectChatInputException(
          'The selected Direct connection changed before sending.',
        );
      }
    } catch (_) {
      await closeMcpSessionBestEffort();
      rethrow;
    }
    final session = mcpSession!;
    final toolServersByName = {
      for (final definition in session.definitions)
        definition.modelName: serversById[definition.serverId]!,
    };
    toolRuntime = DirectToolRuntime(
      definitions: <DirectToolDefinition>[
        for (final definition in session.definitions)
          DirectToolDefinition(
            name: definition.modelName,
            serverId: definition.serverId,
            serverName: definition.serverName,
            remoteName: definition.remoteName,
            displayName: definition.displayName,
            description: definition.description,
            approvalFingerprint: definition.approvalFingerprint,
            inputSchema: definition.inputSchema,
          ),
      ],
      requestApproval: (callId, definition, arguments) {
        final expectedServer = serversById[definition.serverId]!;
        if (!registry.isMcpServerCurrent(expectedServer)) {
          throw const DirectProviderException(
            'The MCP server changed. Start a new model turn.',
          );
        }
        return registry.requestMcpApproval(
          reservation,
          callId: callId,
          definition: definition,
          arguments: arguments,
          expectedServer: expectedServer,
        );
      },
      execute: (name, arguments) async {
        final expectedServer = toolServersByName[name];
        if (expectedServer == null ||
            !registry.isMcpServerCurrent(expectedServer)) {
          throw const DirectProviderException(
            'The MCP server changed. Start a new model turn.',
          );
        }
        final result = await session.execute(name, arguments);
        return DirectToolResult(text: result.text, isError: result.isError);
      },
    );
  }
  final normalizedBudget = DirectStreamBudget(
    maxCharacters: streamLimits.maxCharacters,
    maxEvents: streamLimits.maxEvents,
    maxWorkUnits: streamLimits.maxWorkUnits,
  );
  late final DirectCompletionRun run;
  final consumesImageGenerationAction =
      route.profile.isOpenRouter &&
      enableImageGeneration &&
      ref.read(imageGenerationEnabledProvider);
  if (consumesImageGenerationAction) {
    // OpenRouter image generation is a one-shot composer action. Consume it
    // at the provider submission boundary so canceled preflight keeps the
    // user's intent, while send and regeneration share the same behavior.
    ref.read(imageGenerationEnabledProvider.notifier).set(false);
  }
  try {
    run = adapter.startCompletion(
      route.profile,
      DirectCompletionRequest(
        remoteModelId: route.binding.remoteModelId,
        messages: directMessages,
        enableWebSearch: enableWebSearch,
        enableImageGeneration: enableImageGeneration,
        imageGenerationModel:
            route.profile.isOpenRouter && enableImageGeneration
            ? ref.read(appSettingsProvider).openRouterImageGenerationModel
            : null,
        tools: toolRuntime,
        parameters:
            route.profile.adapterKey == kOllamaAdapterKey ||
                reasoningEffort == null
            ? const <String, dynamic>{}
            : <String, dynamic>{'reasoning_effort': reasoningEffort},
      ),
    );
  } catch (error) {
    // A runtime adapter can supply an arbitrary StackTrace. Throw the
    // normalized failure from this local boundary so downstream diagnostics
    // never persist or log provider-controlled stack text.
    if (consumesImageGenerationAction) {
      ref.read(imageGenerationEnabledProvider.notifier).set(true);
    }
    await closeMcpSessionBestEffort();
    throw _normalizeDirectDispatcherFailure(
      error,
      sensitiveValues: sensitiveProviderValues,
    );
  }
  try {
    // Runtime adapters can reject cleanup before their event stream settles.
    // Observe that independent future immediately; cancellation still attaches
    // its own waiter, but an early rejection must never escape through the zone.
    unawaited(
      run.done.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  } catch (_) {
    // A non-conforming Future implementation may throw from `then` itself.
    // Event delivery remains the dispatcher's normalized completion contract.
  }
  if (!registry.register(reservation, run)) {
    // register() already revokes and observes cleanup. Transport cleanup is not
    // part of the caller contract: a hostile run.done must not hold preflight.
    await closeMcpSessionBestEffort();
    throw const _DirectRunStoppedDuringPreflight();
  }
  final accumulator = DirectStreamingAccumulator();
  var generatedImageBytes = 0;
  Object? terminalFailure;
  StackTrace? terminalFailureStack;
  var uiProjectionIsCurrent = false;
  Object? uiProjectionToken;

  try {
    final iterator = StreamIterator<DirectStreamEvent>(run.events);
    final streamElapsed = Stopwatch()..start();
    var cancellationWasSignalled = false;
    var ownerAuthWasRevoked = false;
    var sawTerminalEvent = false;
    Completer<_DirectStreamMove>? pendingMove;
    ProviderSubscription<Object>? ownerAuthEpochSubscription;
    void detachPendingMove() {
      final pending = pendingMove;
      if (pending != null && !pending.isCompleted) {
        pending.complete((
          cancelled: true,
          done: false,
          event: null,
          error: null,
          stackTrace: null,
        ));
      }
    }

    unawaited(
      registry.cancellationSignal(reservation).then((_) {
        cancellationWasSignalled = true;
        detachPendingMove();
      }),
    );
    final capturedOwnerAuthEpoch = owner.openWebUiAuthSessionEpoch;
    if (owner.location?.storage == ChatStorageKind.openWebUi &&
        capturedOwnerAuthEpoch != null) {
      ownerAuthEpochSubscription = _listenForDirectOwnerAuthSessionChanges(
        ref,
        (_, next) {
          if (identical(next, capturedOwnerAuthEpoch)) return;
          ownerAuthWasRevoked = true;
          detachPendingMove();
        },
      );
    }
    try {
      while (true) {
        final move = Completer<_DirectStreamMove>();
        pendingMove = move;
        Timer? moveDeadline;
        if (cancellationWasSignalled || ownerAuthWasRevoked) {
          move.complete((
            cancelled: true,
            done: false,
            event: null,
            error: null,
            stackTrace: null,
          ));
        } else {
          final remaining = streamLimits.maxDuration - streamElapsed.elapsed;
          if (remaining <= Duration.zero) {
            move.complete((
              cancelled: false,
              done: false,
              event: null,
              error: const DirectProviderException(
                'The provider stream exceeded Conduit\'s time limit.',
              ),
              stackTrace: StackTrace.current,
            ));
          } else {
            final reachesAbsoluteDeadline =
                remaining.compareTo(streamLimits.idleTimeout) <= 0;
            final wait = reachesAbsoluteDeadline
                ? remaining
                : streamLimits.idleTimeout;
            moveDeadline = Timer(wait, () {
              if (move.isCompleted) return;
              move.complete((
                cancelled: false,
                done: false,
                event: null,
                error: DirectProviderException(
                  reachesAbsoluteDeadline
                      ? 'The provider stream exceeded Conduit\'s time limit.'
                      : 'The provider stream timed out while waiting for data.',
                ),
                stackTrace: StackTrace.current,
              ));
            });
            try {
              iterator.moveNext().then(
                (hasEvent) {
                  if (move.isCompleted) return;
                  move.complete((
                    cancelled: false,
                    done: !hasEvent,
                    event: hasEvent ? iterator.current : null,
                    error: null,
                    stackTrace: null,
                  ));
                },
                onError: (Object error, StackTrace stackTrace) {
                  if (move.isCompleted) return;
                  move.complete((
                    cancelled: false,
                    done: false,
                    event: null,
                    error: error,
                    stackTrace: stackTrace,
                  ));
                },
              );
            } catch (error, stackTrace) {
              if (!move.isCompleted) {
                move.complete((
                  cancelled: false,
                  done: false,
                  event: null,
                  error: error,
                  stackTrace: stackTrace,
                ));
              }
            }
          }
        }
        final outcome = await move.future;
        moveDeadline?.cancel();
        pendingMove = null;
        if (outcome.cancelled) break;
        if (outcome.done) {
          if (!sawTerminalEvent &&
              !cancellationWasSignalled &&
              registry.owns(reservation, run)) {
            throw const DirectProviderException(
              'The direct provider stream ended before a terminal event.',
            );
          }
          break;
        }
        if (outcome.error != null) {
          Error.throwWithStackTrace(outcome.error!, outcome.stackTrace!);
        }
        final event = outcome.event!;
        // Cancellation revokes delivery synchronously. The provider may still
        // emit buffered events before its stream closes; those events belong
        // neither to a stopped snapshot nor to a same-id replacement.
        if (!registry.owns(reservation, run)) continue;
        normalizedBudget.addEvent();
        DirectStreamEvent normalizedEvent = event;
        switch (event) {
          case DirectContentDelta():
            normalizedBudget.add(event.content);
            break;
          case DirectReasoningDelta():
            normalizedBudget.add(event.content);
            break;
          case DirectToolCallStarted():
            normalizedBudget
              ..add(event.name)
              ..add(jsonEncode(event.arguments));
            break;
          case DirectToolCallCompleted():
            normalizedBudget
              ..add(event.name)
              ..add(jsonEncode(event.arguments))
              ..add(jsonEncode(event.result));
            break;
          case DirectMcpApprovalRequested():
            normalizedBudget
              ..add(event.request.id)
              ..add(event.request.serverName)
              ..add(event.request.toolName)
              ..add(event.request.callId)
              ..add(event.request.argumentsJson);
            break;
          case DirectMcpApprovalResolved():
            normalizedBudget
              ..add(event.request.id)
              ..add(event.request.serverName)
              ..add(event.request.toolName)
              ..add(event.request.callId)
              ..add(event.request.argumentsJson);
            break;
          case DirectStreamError():
            normalizedBudget.add(event.message);
            normalizedEvent = DirectStreamError(
              sanitizeDirectProviderErrorMessage(
                event.message,
                sensitiveValues: sensitiveProviderValues,
              ),
              statusCode: event.statusCode,
            );
            break;
          case DirectUsageUpdate():
            final normalizedUsage = normalizeDirectUsageMetadataWithCost(
              event.usage,
            );
            normalizedBudget
              ..addCharacters(normalizedUsage.stringCharacters)
              ..addWork(normalizedUsage.nodes);
            normalizedEvent = DirectUsageUpdate(normalizedUsage.usage);
            break;
          case DirectProviderMetadataUpdate():
            final normalizedMetadata = normalizeDirectUsageMetadataWithCost(
              event.metadata,
            );
            normalizedBudget
              ..addCharacters(normalizedMetadata.stringCharacters)
              ..addWork(normalizedMetadata.nodes);
            normalizedEvent = DirectProviderMetadataUpdate(
              normalizedMetadata.usage,
            );
            break;
          case DirectFileAnnotationsUpdate():
            final annotations = normalizeOpenRouterFileAnnotations(
              event.annotations,
            );
            normalizedBudget.add(jsonEncode(annotations));
            normalizedEvent = DirectFileAnnotationsUpdate(annotations);
            break;
          case DirectSourceFound():
            normalizedBudget
              ..add(event.url)
              ..add(event.title ?? '')
              ..add(event.snippet ?? '');
            break;
          case DirectGeneratedImage():
            final normalizedImage = normalizeDirectGeneratedImage(
              event,
              maxDecodedBytes:
                  kDirectMaxDecodedImageBytes - generatedImageBytes,
            );
            generatedImageBytes += normalizedImage.decodedBytes;
            normalizedEvent = normalizedImage.image;
            normalizedBudget.add(normalizedImage.image.mediaType);
            break;
          case DirectStreamDone():
            break;
        }
        if (normalizedEvent is DirectStreamError &&
            accumulator.hasGeneratedImages) {
          // A generated asset is authoritative. A later parent narration
          // failure settles the turn without attaching an error to the image.
          normalizedEvent = const DirectStreamDone();
        }
        accumulator.apply(normalizedEvent);
        final projectedEvent =
            normalizedEvent is DirectStreamDone && !accumulator.hasUsableOutput
            ? const DirectStreamError(
                'The direct provider returned no usable completion content.',
              )
            : normalizedEvent;
        if (!identical(projectedEvent, normalizedEvent)) {
          accumulator.apply(projectedEvent);
        }
        sawTerminalEvent =
            normalizedEvent is DirectStreamDone ||
            normalizedEvent is DirectStreamError;
        if (_isDirectConversationOwnerActive(ref, owner)) {
          final placeholderWasStreaming = notifier.isMessageStreaming(
            assistantMessageId,
          );
          final visibleProjectionToken = notifier
              .directStreamingProjectionTokenForMessage(assistantMessageId);
          final visibleProjectionIsCurrent =
              uiProjectionIsCurrent &&
              identical(visibleProjectionToken, uiProjectionToken);
          notifier.reconcileDirectStreamingMessageById(assistantMessageId);
          if (projectedEvent is DirectUsageUpdate) {
            notifier.updateMessageById(
              assistantMessageId,
              (current) => current.copyWith(usage: accumulator.usage),
            );
          } else if (projectedEvent is DirectProviderMetadataUpdate) {
            notifier.updateMessageById(
              assistantMessageId,
              (current) => current.copyWith(
                metadata: <String, dynamic>{
                  ...?current.metadata,
                  if (accumulator.providerMetadata != null)
                    kDirectProviderMetadataKey: accumulator.providerMetadata,
                },
              ),
            );
          } else if (projectedEvent is DirectMcpApprovalRequested ||
              projectedEvent is DirectMcpApprovalResolved) {
            notifier.updateMessageById(
              assistantMessageId,
              (current) => current.copyWith(
                metadata: <String, dynamic>{
                  ...?current.metadata,
                  if (accumulator.mcpApproval != null)
                    kDirectMcpApprovalMetadataKey: accumulator.mcpApproval,
                },
              ),
            );
          } else if (projectedEvent is DirectStreamError) {
            notifier.updateMessageById(
              assistantMessageId,
              (current) => current.copyWith(
                error: ChatMessageError(content: projectedEvent.message),
              ),
            );
          } else if (projectedEvent is DirectToolCallStarted ||
              projectedEvent is DirectToolCallCompleted ||
              projectedEvent is DirectSourceFound) {
            notifier.updateMessageById(
              assistantMessageId,
              (current) => current.copyWith(
                output: accumulator.toolOutput,
                sources: accumulator.sources,
              ),
            );
          } else if (projectedEvent is DirectGeneratedImage) {
            notifier.updateMessageById(
              assistantMessageId,
              (current) => current.copyWith(
                files: mergeDirectGeneratedImageFiles(
                  current.files,
                  accumulator.generatedImageFiles,
                ),
                usage: accumulator.usage,
              ),
            );
          }

          final visibleMessages =
              ref.read(chatMessagesProvider) as List<ChatMessage>;
          final canAppend =
              visibleMessages.lastOrNull?.id == assistantMessageId &&
              visibleMessages.lastOrNull?.isStreaming == true;
          final projection = accumulator.projectStreamingEvent(
            projectedEvent,
            forceReplace:
                !visibleProjectionIsCurrent || !placeholderWasStreaming,
            canAppend: canAppend,
          );
          switch (projection) {
            case DirectStreamingAppend():
              notifier.appendToMessageById(
                assistantMessageId,
                projection.content,
              );
              uiProjectionIsCurrent = true;
              break;
            case DirectStreamingReplace():
              notifier.replaceMessageContentById(
                assistantMessageId,
                projection.content,
              );
              uiProjectionIsCurrent = true;
              break;
            case null:
              break;
          }
          if (uiProjectionIsCurrent) {
            uiProjectionToken = notifier
                .directStreamingProjectionTokenForMessage(assistantMessageId);
          }
        } else {
          // The accumulator remains authoritative while the chat is hidden.
          // Its next visible event must replace any persisted/reloaded echo
          // before incremental appends can resume safely.
          uiProjectionIsCurrent = false;
          uiProjectionToken = null;
        }
        if ((projectedEvent is DirectMcpApprovalRequested ||
                projectedEvent is DirectMcpApprovalResolved) &&
            accumulator.mcpApproval != null) {
          final approvalBase = _isDirectConversationOwnerActive(ref, owner)
              ? (ref.read(chatMessagesProvider) as List<ChatMessage>)
                    .where((message) => message.id == assistantMessageId)
                    .firstOrNull
              : null;
          final base = approvalBase ?? assistantSeed;
          final approvalSnapshot = base.copyWith(
            content: accumulator.render(done: false),
            output: accumulator.toolOutput,
            usage: accumulator.usage,
            sources: accumulator.sources,
            metadata: <String, dynamic>{
              ...?base.metadata,
              kDirectMcpApprovalMetadataKey: accumulator.mcpApproval,
            },
            isStreaming: true,
          );
          streamElapsed.stop();
          try {
            await _persistCompletedDirectAssistant(
              ref,
              owner: owner,
              assistant: approvalSnapshot,
              isCurrentGeneration: () => registry.isLatest(reservation),
            );
          } finally {
            streamElapsed.start();
          }
        }
        if (projectedEvent is DirectGeneratedImage) {
          final assetBase = _isDirectConversationOwnerActive(ref, owner)
              ? (ref.read(chatMessagesProvider) as List<ChatMessage>)
                    .where((message) => message.id == assistantMessageId)
                    .firstOrNull
              : null;
          final assetSnapshot = (assetBase ?? assistantSeed).copyWith(
            content: accumulator.render(done: false),
            files: mergeDirectGeneratedImageFiles(
              (assetBase ?? assistantSeed).files,
              accumulator.generatedImageFiles,
            ),
            usage: accumulator.usage,
            isStreaming: true,
          );
          // Local durability is independent of provider processing time. A
          // slow database write must not consume the stream's duration budget
          // and discard already-buffered acknowledgement events.
          streamElapsed.stop();
          try {
            await _persistCompletedDirectAssistant(
              ref,
              owner: owner,
              assistant: assetSnapshot,
              isCurrentGeneration: () => registry.isLatest(reservation),
            );
          } finally {
            streamElapsed.start();
          }
        }
        // The normalized terminal event is the protocol boundary. Provider
        // stream closure and transport cleanup are best-effort implementation
        // details and must not keep the completed message shimmering forever.
        if (sawTerminalEvent) break;
      }
    } catch (error) {
      // Adapter cancellation can surface as a stream error after ownership was
      // revoked. It is expected cleanup, not a failed assistant. A genuine
      // current-generation failure is finalized from the accumulator below and
      // then rethrown so the public send/regenerate contract remains intact.
      if (registry.owns(reservation, run)) {
        terminalFailure = _normalizeDirectDispatcherFailure(
          error,
          sensitiveValues: sensitiveProviderValues,
        );
        // Never retain a stack supplied by a runtime adapter's error channel.
        // The local boundary still gives diagnostics a useful Conduit stack.
        terminalFailureStack = StackTrace.current;
      }
    } finally {
      streamElapsed.stop();
      ownerAuthEpochSubscription?.close();
      // A hostile adapter may never close its stream and may return a cancel
      // future that never settles. Detach without awaiting it; the registry's
      // synchronous cancellation signal already revoked event ownership.
      try {
        unawaited(run.cancel('dispatcher detached').catchError((_) {}));
      } catch (_) {}
      try {
        unawaited(iterator.cancel().catchError((_) {}));
      } catch (_) {}
    }
    if (!registry.isLatest(reservation)) return;
    _requireDirectOwnerAuthSession(ref, owner);

    Map<String, dynamic>? signedFileAnnotations;
    if (route.profile.isOpenRouter && accumulator.fileAnnotations.isNotEmpty) {
      try {
        signedFileAnnotations = signedOpenRouterFileAnnotations(
          annotations: accumulator.fileAnnotations,
          signingKey: await ref.read(directDeviceTrustKeyProvider.future),
          profile: route.profile,
          attachmentIds: openRouterPdfAttachmentIdsForAnnotations(
            ephemeralFilePartsByAttachmentId: ephemeralFilePartsByAttachmentId,
            annotations: accumulator.fileAnnotations,
          ),
        );
      } catch (error) {
        DebugLogger.warning(
          'file-annotation-signing-failed',
          scope: 'direct-connections/openrouter',
          data: {'errorType': error.runtimeType.toString()},
        );
      }
    }
    // Signing is best-effort and may suspend after the stream's auth listener
    // has closed. Re-establish both generation and auth ownership before
    // projecting or persisting provider output.
    if (!registry.isLatest(reservation)) return;
    _requireDirectOwnerAuthSession(ref, owner);

    final ownerIsActive = _isDirectConversationOwnerActive(ref, owner);
    if (terminalFailure != null && accumulator.hasGeneratedImages) {
      DebugLogger.warning(
        'post-image-event-rejected',
        scope: 'direct-connections/chat',
        data: {'errorType': terminalFailure.runtimeType.toString()},
      );
    }
    final completedContent = accumulator.render(done: true);
    final visible = ownerIsActive
        ? (ref.read(chatMessagesProvider) as List<ChatMessage>)
              .where((message) => message.id == assistantMessageId)
              .firstOrNull
        : null;
    final base = visible ?? assistantSeed;
    final completedMetadata =
        <String, dynamic>{
            ...?base.metadata,
            kDirectRawAssistantContentMetadataKey: accumulator.text,
          }
          ..remove(kDirectRawAssistantReasoningMetadataKey)
          ..remove(kDirectProviderMetadataKey)
          ..remove(kDirectMcpApprovalMetadataKey)
          ..remove(kOpenRouterFileAnnotationsMetadataKey);
    if (accumulator.reasoning.trim().isNotEmpty) {
      completedMetadata[kDirectRawAssistantReasoningMetadataKey] =
          accumulator.reasoning;
    }
    if (accumulator.providerMetadata != null) {
      completedMetadata[kDirectProviderMetadataKey] =
          accumulator.providerMetadata;
    }
    if (signedFileAnnotations != null) {
      completedMetadata[kOpenRouterFileAnnotationsMetadataKey] =
          signedFileAnnotations;
    }
    if (accumulator.mcpApproval != null) {
      completedMetadata[kDirectMcpApprovalMetadataKey] =
          accumulator.mcpApproval;
    }
    final completed = base.copyWith(
      content: completedContent,
      files: mergeDirectGeneratedImageFiles(
        base.files,
        accumulator.generatedImageFiles,
      ),
      output: <Map<String, dynamic>>[
        ...accumulator.toolOutput,
        ...?directProviderReplayOutput(
          assistantMessageId: assistantMessageId,
          rawContent: accumulator.text,
          useIncompleteAnswerSentinel:
              accumulator.text.trim().isEmpty &&
              (accumulator.reasoning.trim().isNotEmpty ||
                  accumulator.toolOutput.isNotEmpty),
        ),
      ],
      sources: accumulator.sources,
      metadata: completedMetadata,
      usage: accumulator.usage,
      error: accumulator.error != null
          ? ChatMessageError(content: accumulator.error!.message)
          : terminalFailure != null && !accumulator.hasGeneratedImages
          ? ChatMessageError(
              content: chatErrorContentForException(terminalFailure),
            )
          : base.error,
      isStreaming: false,
    );
    if (ownerIsActive && registry.isLatest(reservation)) {
      notifier.completeDirectStreamingMessage(
        completed,
        ownerConversationId: owner.scopedConversationId,
      );
    }
    // Provider output and durable commit are separate phases. Retain the exact
    // finalized message before the write so a pre-commit I/O failure can be
    // projected and retried when this same database-backed chat is reopened.
    registry.markOutputFinalized(
      reservation,
      completed,
      persistenceOwnerId: owner.persistenceOwnerId,
      authSessionEpoch: owner.openWebUiAuthSessionEpoch,
    );
    try {
      await _persistCompletedDirectAssistant(
        ref,
        owner: owner,
        assistant: completed,
        isCurrentGeneration: () => registry.isLatest(reservation),
      );
    } on _DirectOpenWebUiAuthSessionChanged {
      registry.discardFinalizedOutput(reservation);
      rethrow;
    }
    registry.markDurablyPersisted(reservation);
    if (terminalFailure != null && !accumulator.hasGeneratedImages) {
      Error.throwWithStackTrace(terminalFailure, terminalFailureStack!);
    }
  } finally {
    registry.complete(reservation, run);
    await closeMcpSessionBestEffort();
  }
}
