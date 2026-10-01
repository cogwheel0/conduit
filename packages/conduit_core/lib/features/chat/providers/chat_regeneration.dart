part of 'chat_providers.dart';

Future<void> _regenerateHermesMessage(
  dynamic ref, {
  required Model selectedModel,
  required String input,
  required HermesConfigController configController,
  required int configAdmission,
  required HermesBackendService? serviceGeneration,
}) async {
  final reasoningEffort = ref.read(configuredReasoningEffortProvider);
  final activeAtStart = ref.read(activeConversationProvider) as Conversation?;
  final mutationOwner = captureChatMutationOwner(ref, activeAtStart);
  final existingMessages = List<ChatMessage>.from(
    ref.read(chatMessagesProvider) as List<ChatMessage>,
    growable: false,
  );
  final previousAssistant = existingMessages.lastOrNull?.role == 'assistant'
      ? existingMessages.last
      : null;

  // Regeneration branches from the history before the replayed user turn. Do
  // not chain previous_response_id to the answer being replaced.
  var replayedUserIndex = -1;
  for (var index = existingMessages.length - 1; index >= 0; index--) {
    if (existingMessages[index].role == 'user') {
      replayedUserIndex = index;
      break;
    }
  }
  final continuityMessages = replayedUserIndex < 0
      ? const <ChatMessage>[]
      : existingMessages.sublist(0, replayedUserIndex);
  final replayedUser = replayedUserIndex < 0
      ? null
      : existingMessages[replayedUserIndex];
  final trustedReplayDocumentPrompt = _trustedHermesReplayDocumentPrompt(
    replayedUser,
  );

  final hasPreviousResponse =
      _lastHermesMetadataId(
        continuityMessages,
        'hermesResponseId',
        allowNativeHermesMetadata: true,
      ) !=
      null;
  final replayedFiles = replayedUser?.files ?? const <Map<String, dynamic>>[];
  final replayedAttachments = replayedUser?.attachmentIds ?? const <String>[];
  final assistantMessageId = previousAssistant?.id ?? const Uuid().v4();
  final notifier = ref.read(chatMessagesProvider.notifier);
  ChatMessage assistantMessage({
    required bool isStreaming,
    ChatMessageError? error,
  }) => ChatMessage(
    id: assistantMessageId,
    role: 'assistant',
    content: '',
    timestamp: DateTime.now(),
    model: selectedModel.id,
    isStreaming: isStreaming,
    error: error,
    versions: previousAssistant == null
        ? const <ChatMessageVersion>[]
        : _buildReplayVersions(previousAssistant),
    metadata: {'modelName': selectedModel.name, 'transport': kHermesTransport},
  );
  void installAssistant(ChatMessage message) {
    if (previousAssistant == null) {
      notifier.addMessage(message);
    } else {
      notifier.updateLastMessageWithFunction((_) => message);
    }
  }

  if (replayedFiles.any(
    (file) =>
        file['source'] == 'hermes_desktop_file' ||
        file['source'] == 'hermes_responses_file',
  )) {
    const error = HermesAttachmentsUnsupportedException(
      'File attachments cannot be regenerated. Send the file again.',
    );
    installAssistant(
      assistantMessage(
        isStreaming: false,
        error: ChatMessageError(content: chatErrorContentForException(error)),
      ),
    );
    throw error;
  }
  final useResponses =
      previousAssistant?.metadata?['hermesTransportMode'] ==
          kHermesResponsesMode ||
      hasPreviousResponse ||
      _persistedHermesReplayRequiresResponses(
        replayedFiles,
        replayedAttachments,
      );
  final inputImagesSupported = await _hermesInputImagesSupported(ref);
  if (!chatMutationTokenStillActive(ref, mutationOwner)) return;
  if (!configController.sessionActionAdmissionIsCurrent(configAdmission) ||
      !identical(ref.read(hermesApiServiceProvider), serviceGeneration)) {
    return;
  }

  // Historical regeneration leaves the selected assistant at the tail. Reuse
  // that message rather than retaining an archived record plus a second
  // placeholder; its previous content remains available through [versions].
  final assistant = assistantMessage(isStreaming: true);
  installAssistant(assistant);
  await _dispatchHermesRunFromChat(
    ref,
    assistantMessageId: assistantMessageId,
    assistantSeed: assistant,
    input: replayedUser?.content ?? input,
    existingMessages: continuityMessages,
    forceNewSession: true,
    // Regeneration branches from [continuityMessages]. Chaining the response
    // being replaced would restore the wrong tail and the wrong server session.
    previousResponseIdOverride: null,
    responseInput: useResponses
        ? replayedUser == null
              ? HermesChatInput.text(input)
              : _hermesInputFromPersistedMessage(
                  replayedUser,
                  inputImagesSupported: inputImagesSupported,
                )
        : null,
    localDocumentPromptText: trustedReplayDocumentPrompt?.promptText,
    localDocumentEnvelopes:
        trustedReplayDocumentPrompt?.documentEnvelopes ?? const <String>[],
    reasoningEffort: reasoningEffort,
    responseHistory: useResponses
        ? _hermesVisibleHistory(
            continuityMessages,
            inputImagesSupported: inputImagesSupported,
          )
        : null,
  );
}

Future<void> _regenerateDirectMessage(
  dynamic ref, {
  required _ResolvedDirectRoute route,
}) async {
  final reasoningEffort = ref.read(configuredReasoningEffortProvider);
  final enableWebSearch =
      ref.read(webSearchEnabledProvider) &&
      ref.read(webSearchAvailableProvider);
  final enableImageGeneration =
      ref.read(imageGenerationEnabledProvider) &&
      ref.read(imageGenerationAvailableProvider);
  final localMcpToolIds =
      (ref.read(selectedToolIdsProvider) as Iterable<String>)
          .where((id) => id.startsWith(kDirectMcpToolIdPrefix))
          .toList(growable: false);
  final active = ref.read(activeConversationProvider) as Conversation?;
  if (active == null) throw StateError('No active conversation');
  final directMutationOwner = captureChatMutationOwner(ref, active);
  final Object? sourceApi = directMutationOwner.usesOpenWebUiContext
      ? directMutationOwner.openWebUiApi
      : ref.read(apiServiceProvider);
  final sourceAuthSnapshot = sourceApi is ApiService
      ? sourceApi.captureAuthSnapshot()
      : null;
  final Object? sourceAuthSessionEpoch = sourceApi == null
      ? null
      : _readOpenWebUiAuthSessionEpoch(ref);
  Stream<RemapEvent>? remapEvents;
  SyncEngine? openWebUiSyncEngine;
  if (directMutationOwner.usesOpenWebUiContext) {
    try {
      final engine = ref.read(syncEngineProvider.notifier);
      openWebUiSyncEngine = engine;
      remapEvents = engine.remapEvents;
    } catch (_) {}
  }
  final existing = List<ChatMessage>.from(
    ref.read(chatMessagesProvider) as List<ChatMessage>,
    growable: false,
  );
  var userIndex = -1;
  for (var index = existing.length - 1; index >= 0; index--) {
    if (existing[index].role == 'user') {
      userIndex = index;
      break;
    }
  }
  if (userIndex < 0) return;

  final visiblePreviousAssistant = existing.lastOrNull?.role == 'assistant'
      ? existing.last
      : null;
  final previousAssistant = visiblePreviousAssistant == null
      ? null
      : _directRegenerationCompletedBase(visiblePreviousAssistant);
  final assistantId = previousAssistant?.id ?? const Uuid().v4();
  final metadata =
      <String, dynamic>{
          ...?previousAssistant?.metadata,
          'parentId': existing[userIndex].id,
          'childrenIds': const <String>[],
          'transport': kDirectTransport,
          'modelName': route.model.name,
        }
        ..remove('archivedVariant')
        ..remove(kDirectMcpApprovalMetadataKey);
  final assistant = ChatMessage(
    id: assistantId,
    role: 'assistant',
    content: '',
    timestamp: DateTime.now(),
    model: route.model.id,
    isStreaming: true,
    versions: previousAssistant == null
        ? const <ChatMessageVersion>[]
        : _buildReplayVersions(previousAssistant),
    metadata: metadata,
  );
  final notifier =
      ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier;
  if (previousAssistant == null) {
    notifier.addMessage(assistant);
  } else {
    notifier.updateLastMessageWithFunction((_) => assistant);
  }
  final DirectRunRegistry registry = ref.read(directRunRegistryProvider);
  final stopIndex = ref.read(_directRunStopIndexProvider);
  final initialRunKey = _directRunKeyForConversation(ref, active, assistant.id);
  final reservation = registry.reserve(initialRunKey, route.binding.profileId);
  stopIndex.track(initialRunKey);
  final preflightCancelToken = CancelToken();
  ChatDatabaseLocation? location;
  DatabaseLifetimeLease? databaseLease;
  String? persistenceOwnerId;
  Object? ownerAuthSessionEpoch(ChatDatabaseLocation? ownerLocation) =>
      ownerLocation?.storage == ChatStorageKind.openWebUi
      ? directMutationOwner.openWebUiAuthSessionEpoch
      : null;
  SyncEngine? ownerSyncEngine(ChatDatabaseLocation? ownerLocation) =>
      ownerLocation?.storage == ChatStorageKind.openWebUi
      ? openWebUiSyncEngine
      : null;
  try {
    final stored = chatStorageKindOf(active) != null;
    final temporary =
        ref.read(temporaryChatEnabledProvider) ||
        (isTemporaryChat(active.id) && !stored);
    if (!temporary) {
      final ChatDatabaseRepository repository = ref.read(
        chatDatabaseRepositoryProvider,
      );
      final preferredStorage =
          chatStorageKindOf(active) ?? ChatStorageKind.openWebUi;
      ChatDatabaseLocation? initiallyOwnedLocation;
      try {
        initiallyOwnedLocation = repository.locationFor(preferredStorage);
      } on StateError {
        // Resolve below preserves the historical unavailable-storage behavior.
      }
      if (initiallyOwnedLocation != null) {
        persistenceOwnerId = _directPersistenceOwnerIdForLocation(
          ref,
          initiallyOwnedLocation,
        );
        databaseLease = _tryAcquireDirectDatabaseLease(
          ref,
          initiallyOwnedLocation,
        );
      }
      location = await repository.resolveChat(
        active.id,
        preferred: preferredStorage,
      );
      if (location != null) {
        _requireDirectLocationAuthSession(
          ref,
          location: location,
          capturedEpoch: directMutationOwner.openWebUiAuthSessionEpoch,
        );
      }
      if (registry.isCancelled(reservation)) {
        throw const _DirectRunStoppedDuringPreflight();
      }
      final resolvedLocation = location;
      if (resolvedLocation == null) {
        throw StateError('Conversation storage is unavailable');
      }
      if (!identical(
        initiallyOwnedLocation?.database,
        resolvedLocation.database,
      )) {
        // Acquire the actual resolved owner before yielding to release a stale
        // candidate, so no server switch can close it in between.
        final resolvedLease = _tryAcquireDirectDatabaseLease(
          ref,
          resolvedLocation,
        );
        await databaseLease?.release();
        databaseLease = resolvedLease;
        persistenceOwnerId = _directPersistenceOwnerIdForLocation(
          ref,
          resolvedLocation,
        );
      }
      registry.bindPersistenceIdentity(
        reservation,
        persistenceOwnerId!,
        authSessionEpoch: ownerAuthSessionEpoch(resolvedLocation),
      );
      final row = _directMessageRow(
        chatId: active.id,
        message: assistant,
        parentId: existing[userIndex].id,
        childrenIds: const <String>[],
        orderIndex: existing.length,
      );
      final locks = ref.read(chatLocksProvider) as ChatLocks;
      await locks.runExclusive(active.id, () async {
        if (!registry.isLatest(reservation)) return;
        _requireDirectLocationAuthSession(
          ref,
          location: resolvedLocation,
          capturedEpoch: directMutationOwner.openWebUiAuthSessionEpoch,
        );
        await repository.persistDirectMessages(
          resolvedLocation,
          chatId: active.id,
          messages: <MessageRowData>[row],
          currentMessageId: assistant.id,
          updatedAt: ref.read(syncClockProvider).nowEpochSeconds(),
        );
        _requireDirectLocationAuthSession(
          ref,
          location: resolvedLocation,
          capturedEpoch: directMutationOwner.openWebUiAuthSessionEpoch,
        );
      });
      if (!registry.isLatest(reservation)) return;
    }
    final replayAnnotationEnvelope =
        previousAssistant?.metadata?[kOpenRouterFileAnnotationsMetadataKey];
    final requestMessages = withDirectConversationSystemPrompt(
      messages: <ChatMessage>[
        ...existing.sublist(0, userIndex + 1),
        if (replayAnnotationEnvelope != null)
          ChatMessage(
            id: 'direct-openrouter-regeneration-annotations',
            role: 'assistant',
            content: '',
            timestamp: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
            metadata: <String, dynamic>{
              'transport': kDirectTransport,
              kOpenRouterFileAnnotationsMetadataKey: replayAnnotationEnvelope,
            },
          ),
      ],
      systemPrompt: active.systemPrompt,
    );
    await _dispatchDirectRunFromChat(
      ref,
      route: route,
      assistantMessageId: assistant.id,
      assistantSeed: assistant,
      requestMessages: requestMessages,
      owner: _DirectConversationOwner(
        conversationId: active.id,
        location: location,
        persistenceOwnerId: persistenceOwnerId,
        sourceApi: sourceApi,
        sourceAuthSnapshot: sourceAuthSnapshot,
        sourceAuthSessionEpoch: sourceAuthSessionEpoch,
        remapEvents: remapEvents,
        openWebUiAuthSessionEpoch: ownerAuthSessionEpoch(location),
        openWebUiSyncEngine: ownerSyncEngine(location),
        unstoredOwnerScope: _directRunOwnerScopeForConversation(ref, active),
      ),
      reservation: reservation,
      preflightCancelToken: preflightCancelToken,
      enableWebSearch: enableWebSearch,
      enableImageGeneration: enableImageGeneration,
      reasoningEffort: reasoningEffort,
      localMcpToolIds: localMcpToolIds,
    );
  } on _DirectOpenWebUiAuthSessionChanged {
    registry.discardFinalizedOutput(reservation);
    final owner = _DirectConversationOwner(
      conversationId: active.id,
      location: location,
      persistenceOwnerId: persistenceOwnerId,
      sourceApi: sourceApi,
      sourceAuthSnapshot: sourceAuthSnapshot,
      sourceAuthSessionEpoch: sourceAuthSessionEpoch,
      remapEvents: remapEvents,
      openWebUiAuthSessionEpoch: ownerAuthSessionEpoch(location),
      openWebUiSyncEngine: ownerSyncEngine(location),
      unstoredOwnerScope: _directRunOwnerScopeForConversation(ref, active),
    );
    try {
      await _settleDirectAssistantAfterAuthSessionChange(
        ref,
        owner: owner,
        assistantMessageId: assistant.id,
        isCurrentGeneration: () => registry.isLatest(reservation),
      );
    } catch (settlementError, stackTrace) {
      DebugLogger.error(
        'auth-change-placeholder-settlement-failed',
        scope: 'direct-connections/chat',
        error: settlementError,
        stackTrace: stackTrace,
        data: {'conversationId': owner.conversationId},
      );
    }
    return;
  } on _DirectRunStoppedDuringPreflight {
    if (!registry.isLatest(reservation)) return;
    final owner = _DirectConversationOwner(
      conversationId: active.id,
      location: location,
      persistenceOwnerId: persistenceOwnerId,
      sourceApi: sourceApi,
      sourceAuthSnapshot: sourceAuthSnapshot,
      sourceAuthSessionEpoch: sourceAuthSessionEpoch,
      remapEvents: remapEvents,
      openWebUiAuthSessionEpoch: ownerAuthSessionEpoch(location),
      openWebUiSyncEngine: ownerSyncEngine(location),
      unstoredOwnerScope: _directRunOwnerScopeForConversation(ref, active),
    );
    final ownerIsActive = _isDirectConversationOwnerActive(ref, owner);
    final stopped =
        (ownerIsActive
            ? (ref.read(chatMessagesProvider) as List<ChatMessage>)
                  .where((message) => message.id == assistant.id)
                  .firstOrNull
            : null) ??
        assistant;
    // Regeneration replaces the previous answer with a same-id placeholder
    // before attachment/message preflight. If that preflight is cancelled,
    // restore the completed answer rather than making the empty replacement
    // the default visible and durable version.
    final stoppedSnapshot =
        previousAssistant?.copyWith(isStreaming: false) ??
        stopped.copyWith(isStreaming: false);
    if (ownerIsActive) {
      notifier.updateMessageById(assistant.id, (_) => stoppedSnapshot);
    }
    if (location != null) {
      await _persistCompletedDirectAssistant(
        ref,
        owner: owner,
        assistant: stoppedSnapshot,
        isCurrentGeneration: () => registry.isLatest(reservation),
      );
      if (registry.isLatest(reservation) &&
          _isDirectConversationOwnerActive(ref, owner)) {
        notifier.updateMessageById(assistant.id, (_) => stoppedSnapshot);
      }
    }
  } catch (error) {
    DebugLogger.error(
      'regenerate-failed',
      scope: 'direct-connections/chat',
      data: {'errorType': error.runtimeType.toString()},
    );
    if (registry.isOutputFinalized(reservation)) rethrow;
    // Superseded work has no error surface to report. Propagating it would let
    // an outer id-only recovery handler attach the stale failure to the newer
    // same-id assistant generation.
    if (!registry.isLatest(reservation)) return;
    final owner = _DirectConversationOwner(
      conversationId: active.id,
      location: location,
      persistenceOwnerId: persistenceOwnerId,
      sourceApi: sourceApi,
      sourceAuthSnapshot: sourceAuthSnapshot,
      sourceAuthSessionEpoch: sourceAuthSessionEpoch,
      remapEvents: remapEvents,
      openWebUiAuthSessionEpoch: ownerAuthSessionEpoch(location),
      openWebUiSyncEngine: ownerSyncEngine(location),
      unstoredOwnerScope: _directRunOwnerScopeForConversation(ref, active),
    );
    final ownerIsActive = _isDirectConversationOwnerActive(ref, owner);
    final failed =
        (ownerIsActive
            ? (ref.read(chatMessagesProvider) as List<ChatMessage>)
                  .where((message) => message.id == assistant.id)
                  .firstOrNull
            : null) ??
        assistant;
    final failedSnapshot = failed.copyWith(
      isStreaming: false,
      error: ChatMessageError(content: chatErrorContentForException(error)),
    );
    if (ownerIsActive) {
      notifier.failLastStreamingAssistant(
        error,
        assistantMessageId: assistant.id,
      );
      // `failLastStreamingAssistant` releases streaming bookkeeping and may
      // synchronously enable a database-watch adoption. Reinstall the exact
      // failure snapshot and persist that same value so the earlier
      // error-free placeholder can never win this race.
      notifier.updateMessageById(assistant.id, (_) => failedSnapshot);
    }
    if (location != null) {
      await _persistCompletedDirectAssistant(
        ref,
        owner: owner,
        assistant: failedSnapshot,
        isCurrentGeneration: () => registry.isLatest(reservation),
      );
      if (registry.isLatest(reservation) &&
          _isDirectConversationOwnerActive(ref, owner)) {
        notifier.updateMessageById(assistant.id, (_) => failedSnapshot);
      }
    }
    rethrow;
  } finally {
    await databaseLease?.release();
    stopIndex.untrack(initialRunKey);
    registry.releaseReservation(reservation);
  }
}

/// Replays an edited user turn in a Hermes session while retaining Conduit's
/// persisted local image/document descriptors. Reopened local documents no
/// longer have a source filesystem attachment, so sending their old opaque id
/// through the normal composer pipeline would either fail or silently drop the
/// reference text.
Future<void> regenerateEditedHermesUserMessage(
  dynamic ref, {
  required String messageId,
  required String content,
}) async {
  final active = ref.read(activeConversationProvider) as Conversation?;
  if (!isNativeHermesConversation(active)) {
    throw StateError('The active conversation is not a Hermes session.');
  }
  final activeConversationId = conversationScopedId(active!);
  final messages = List<ChatMessage>.from(
    ref.read(chatMessagesProvider) as List<ChatMessage>,
    growable: false,
  );
  final index = messages.indexWhere(
    (message) => message.id == messageId && message.role == 'user',
  );
  if (index < 0) throw StateError('The Hermes user message was not found.');

  final edited = messages[index].copyWith(
    content: content,
    metadata: <String, dynamic>{
      ...?messages[index].metadata,
      'childrenIds': const <String>[],
    },
  );
  final notifier =
      ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier;
  final optimisticMessages = List<ChatMessage>.unmodifiable(<ChatMessage>[
    ...messages.sublist(0, index),
    edited,
  ]);
  notifier.setMessages(optimisticMessages);
  try {
    await regenerateMessage(ref, content, null);
  } catch (_) {
    // Editing is a branch operation, but the original branch must remain
    // intact when the replacement cannot even be started. Restore only while
    // our exact optimistic list still owns this storage-scoped conversation;
    // a chat switch or independent same-chat mutation wins the race.
    final current = ref.read(activeConversationProvider) as Conversation?;
    final currentMessages = ref.read(chatMessagesProvider) as List<ChatMessage>;
    if (current != null &&
        conversationMatchesScopedId(current, activeConversationId) &&
        identical(currentMessages, optimisticMessages)) {
      notifier.setMessages(messages);
    }
    rethrow;
  }
}

// Regenerate a message without duplicating its user prompt. Image replay uses
// a request-scoped force flag so it never mutates the persisted composer
// preference while provider preflight is in flight.
Future<void> regenerateMessage(
  dynamic ref,
  String userMessageContent,
  List<String>? attachments, {
  bool forceImageGeneration = false,
  bool Function()? ownsPreparationState,
}) async {
  final conversationAtRegenerationStart =
      ref.read(activeConversationProvider) as Conversation?;
  final regenerationMutationOwner = captureChatMutationOwner(
    ref,
    conversationAtRegenerationStart,
  );
  bool ownsCurrentPreparationState() {
    try {
      return ownsPreparationState?.call() ?? true;
    } catch (_) {
      return false;
    }
  }

  final reviewerMode = ref.read(reviewerModeProvider);
  final api = ref.read(apiServiceProvider);
  final selectedModelCandidate = ref.read(selectedModelProvider) as Model?;
  final usesHermesAtRegenerationStart =
      !reviewerMode &&
      selectedModelCandidate != null &&
      usesHermesTransportForRegeneration(
        selectedModel: selectedModelCandidate,
        activeConversation: conversationAtRegenerationStart,
      );
  final HermesConfigController? hermesConfigController =
      usesHermesAtRegenerationStart
      ? ref.read(hermesConfigProvider.notifier)
      : null;
  final int? hermesConfigAdmission = hermesConfigController
      ?.captureSessionActionAdmission();
  if (usesHermesAtRegenerationStart && hermesConfigAdmission == null) return;
  final HermesBackendService? hermesServiceGeneration =
      usesHermesAtRegenerationStart ? ref.read(hermesApiServiceProvider) : null;
  final resolvedDirectRoute = await _resolveDirectRoute(
    ref,
    selectedModelCandidate,
  );
  final directRoute =
      resolvedDirectRoute?.binding.source == DirectModelSource.device
      ? resolvedDirectRoute
      : null;
  final openWebUiDirectRoute =
      resolvedDirectRoute?.binding.source == DirectModelSource.openWebUi
      ? resolvedDirectRoute
      : null;
  if (!ownsCurrentPreparationState()) {
    return;
  }
  if (!chatMutationTokenStillActive(ref, regenerationMutationOwner)) {
    throw StateError('The conversation changed while preparing regeneration.');
  }
  if (usesHermesAtRegenerationStart &&
      (!hermesConfigController!.sessionActionAdmissionIsCurrent(
            hermesConfigAdmission!,
          ) ||
          !identical(
            ref.read(hermesApiServiceProvider),
            hermesServiceGeneration,
          ))) {
    return;
  }

  // Standalone transports do not require an OpenWebUI API. Reserved direct
  // identities still fail closed unless this exact model object has a current
  // registry binding.
  if (isSendBlocked(
    reviewerMode: reviewerMode,
    api: api,
    selectedModel: selectedModelCandidate,
    hasTrustedDirectBinding: resolvedDirectRoute != null,
  )) {
    throw Exception('No API service or model selected');
  }
  if (!reviewerMode && openWebUiDirectRoute != null && api == null) {
    throw Exception('Open WebUI direct connections require a server session.');
  }
  final Model selectedModel = selectedModelCandidate!;
  final serverModelId = openWebUiDirectRoute == null
      ? selectedModel.id
      : _openWebUiDirectWireModelId(openWebUiDirectRoute);

  var activeConversation = ref.read(activeConversationProvider);
  if (!isModelCompatibleWithConversation(
    conversation: activeConversation,
    hasTrustedDirectBinding: directRoute != null,
  )) {
    throw StateError(
      'On-device direct chats can only continue with a direct connection model.',
    );
  }
  if (!reviewerMode &&
      usesHermesTransportForRegeneration(
        selectedModel: selectedModel,
        activeConversation: activeConversation,
      )) {
    await _regenerateHermesMessage(
      ref,
      selectedModel: selectedModel,
      input: userMessageContent,
      configController: hermesConfigController!,
      configAdmission: hermesConfigAdmission!,
      serviceGeneration: hermesServiceGeneration,
    );
    return;
  }
  if (activeConversation == null) {
    throw Exception('No active conversation');
  }
  if (!reviewerMode && directRoute != null) {
    await _regenerateDirectMessage(ref, route: directRoute);
    return;
  }
  final regenerationOwner = captureOpenWebUiCompletionOwner(
    ref,
    chatId: activeConversation.id,
    api: api,
  );
  ChatSendPlaceholderHandle? regenerationPlaceholder;
  var regenerationPlaceholderWasEstablished = false;
  ChatCompletionSession? submittedSession;
  void requireRegenerationOwner() {
    final activeChatId = activeOpenWebUiChatIdForMutation(
      ref,
      regenerationOwner,
    );
    if (activeChatId == null) {
      throw StateError('The conversation changed while regenerating.');
    }
    regenerationOwner.chatId = activeChatId;
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
      if (!chatMutationTokenStillActive(ref, regenerationMutationOwner)) {
        return;
      }
      ref.read(chatMessagesProvider.notifier).appendToLastMessage('$word ');
    }

    if (!chatMutationTokenStillActive(ref, regenerationMutationOwner)) return;
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
    if (!ownsCurrentPreparationState()) return;
    requireRegenerationOwner();

    // Include selected tool ids so provider-native tool calling is triggered
    final selectedToolIds = ref.read(selectedToolIdsProvider);
    final toolIdsForApi = _extractToolIdsForApi(selectedToolIds);
    final selectedTerminalId = ref.read(selectedTerminalIdProvider);
    // Include selected filter ids (toggle filters enabled by user)
    final selectedFilterIds = selectedFilterIdsForModel(ref, selectedModel);
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
        final cleaned = outboundProviderReplayText(msg);

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
          if (!ownsCurrentPreparationState()) return;
          requireRegenerationOwner();
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
    if (!ownsCurrentPreparationState()) return;
    requireRegenerationOwner();

    // Pre-seed assistant skeleton and persist chain; always use a new id so
    // server history can branch like OpenWebUI.
    final assistantMessageId = const Uuid().v4();
    final regenerationAttemptId = const Uuid().v4();
    final regenerationPlaceholderForAttempt = ChatSendPlaceholderHandle._(
      assistantMessageId: assistantMessageId,
      mutationOwner: regenerationMutationOwner,
      regenerationAttemptId: regenerationAttemptId,
    );
    regenerationPlaceholder = regenerationPlaceholderForAttempt;
    bool ownsLiveRegenerationPlaceholder() {
      try {
        final activeChatId = activeOpenWebUiChatIdForMutation(
          ref,
          regenerationOwner,
        );
        if (activeChatId == null) return false;
        // Keep the request destination synchronized with an in-place local ->
        // remote OpenWebUI id remap that lands during any preflight await.
        regenerationOwner.chatId = activeChatId;
        return _tailOwnedOpenWebUiRegenerationPlaceholder(
              ref,
              regenerationPlaceholderForAttempt,
            ) !=
            null;
      } catch (_) {
        return false;
      }
    }

    await _preseedAssistantAndPersist(
      ref,
      existingAssistantId: assistantMessageId,
      modelId: selectedModel.id,
      modelName: selectedModel.name,
      placeholderMetadata: <String, dynamic>{
        _openWebUiRegenerationAttemptMetadataKey: regenerationAttemptId,
      },
    );
    regenerationPlaceholderWasEstablished = true;
    if (!ownsLiveRegenerationPlaceholder()) {
      _clearOpenWebUiRegenerationAttemptMarker(
        ref,
        regenerationPlaceholderForAttempt,
      );
      return;
    }

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
        (forceImageGeneration || ref.read(imageGenerationEnabledProvider)) &&
        ref.read(imageGenerationAvailableProvider);

    final modelItem = _buildLocalModelItem(
      selectedModel,
      trustedDirectBinding: openWebUiDirectRoute?.binding,
      wireModelId: serverModelId,
    );

    // Reconnect before choosing session_id so eligible sends stay on the
    // task/socket transport instead of falling back to fragile HTTP streaming.
    final socketService = _readOpenWebUiSocketForApi(ref, api);
    final socketSessionId = await _ensureConnectedSocketSessionId(
      socketService,
    );
    if (openWebUiDirectRoute != null && socketSessionId == null) {
      throw StateError(
        'Open WebUI direct connections require an active server socket.',
      );
    }
    if (!ownsLiveRegenerationPlaceholder()) {
      _clearOpenWebUiRegenerationAttemptMarker(
        ref,
        regenerationPlaceholderForAttempt,
      );
      return;
    }

    List<Map<String, dynamic>>? toolServers;
    try {
      toolServers = await _resolveToolServersForRequest(
        api: api,
        userSettings: userSettingsData,
        selectedToolIds: selectedToolIds,
      );
    } catch (_) {}
    if (!ownsLiveRegenerationPlaceholder()) {
      _clearOpenWebUiRegenerationAttemptMarker(
        ref,
        regenerationPlaceholderForAttempt,
      );
      return;
    }
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
        modelId: serverModelId,
        assistantChildMessageId: assistantMessageId,
        useModelIdForModels: openWebUiDirectRoute != null,
      );
    } catch (_) {}
    if (!ownsLiveRegenerationPlaceholder()) {
      _clearOpenWebUiRegenerationAttemptMarker(
        ref,
        regenerationPlaceholderForAttempt,
      );
      return;
    }

    // Start buffering socket events before sending to avoid timing races.
    // Include session/message aliases because some early taskSocket events are
    // emitted before the handler attaches and may not carry chat_id yet.
    final regenSocketService = socketService;
    final bufferedChatId = regenerationOwner.chatId;
    regenSocketService?.startBuffering(
      bufferedChatId,
      sessionId: socketSessionId,
      messageId: assistantMessageId,
    );

    try {
      if (!ownsLiveRegenerationPlaceholder()) {
        _clearOpenWebUiRegenerationAttemptMarker(
          ref,
          regenerationPlaceholderForAttempt,
        );
        return;
      }
      // Use transport-aware session dispatch
      final session = await api!.sendMessageSession(
        messages: requestMessages,
        model: serverModelId,
        conversationId: regenerationOwner.chatId,
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
        reasoningEffort: reasoningEffortForModel(ref.read, selectedModel),
        parentId: parentMsgMap?['parentId']?.toString(),
        userMessage: parentMsgMap,
        variables: promptVars2,
        files: _extractTopLevelRequestFiles(parentMsgMap),
      );
      submittedSession = session;

      // Stop/replacement can race the completion POST itself. The request may
      // now own a remote task, but it must never attach that task to a row the
      // user already stopped or another mutation replaced.
      if (_openWebUiRegenerationPlaceholderOwnerIsActive(
            ref,
            regenerationPlaceholderForAttempt,
          ) &&
          !ownsLiveRegenerationPlaceholder()) {
        await _abortQuietly(session);
        _stopOpenWebUiTaskQuietly(api, session.taskId);
        _clearOpenWebUiRegenerationAttemptMarker(
          ref,
          regenerationPlaceholderForAttempt,
        );
        return;
      }

      regenerationOwner.chatId = await resolveOpenWebUiCompletionChatId(
        ref,
        owner: regenerationOwner,
        assistantMessageId: assistantMessageId,
      );
      final activeOwnerChatId = activeOpenWebUiChatIdForMutation(
        ref,
        regenerationOwner,
      );
      if (activeOwnerChatId == null) {
        DebugLogger.log(
          'regeneration-owner-changed-after-submit',
          scope: 'chat/completion',
          data: {
            'chatId': regenerationOwner.chatId,
            'assistantMessageId': assistantMessageId,
          },
        );
        if (isTemporary) {
          await _abortQuietly(session);
        } else {
          await _finishSubmittedOpenWebUiCompletionHeadlessly(
            ref,
            session: session,
            owner: regenerationOwner,
            assistantMessageId: assistantMessageId,
            // Regeneration is an inline request, not a replayable outbox op.
            requireDurableSubmittedMarker: false,
          );
        }
        return;
      }
      regenerationOwner.chatId = activeOwnerChatId;
      if (!ownsLiveRegenerationPlaceholder()) {
        await _abortQuietly(session);
        _stopOpenWebUiTaskQuietly(api, session.taskId);
        _clearOpenWebUiRegenerationAttemptMarker(
          ref,
          regenerationPlaceholderForAttempt,
        );
        return;
      }

      final modelUsesReasoning = _modelUsesReasoning(selectedModel.id);

      final bool isBackgroundFlow =
          isBackgroundToolsFlowPre ||
          isBackgroundWebSearchPre ||
          imageGenerationEnabled ||
          bgTasks.isNotEmpty;

      final attached = await dispatchChatTransport(
        ref: ref,
        session: session,
        assistantMessageId: assistantMessageId,
        modelId: serverModelId,
        modelItem: modelItem,
        activeConversationId: regenerationOwner.chatId,
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
        ownsActiveConversation: () =>
            activeOpenWebUiChatIdForMutation(ref, regenerationOwner) != null,
        ownsPendingPlaceholder: ownsLiveRegenerationPlaceholder,
      );
      if (!attached) {
        final ownerIsStillActive =
            activeOpenWebUiChatIdForMutation(ref, regenerationOwner) != null;
        if (ownerIsStillActive && !ownsLiveRegenerationPlaceholder()) {
          await _abortQuietly(session);
          _stopOpenWebUiTaskQuietly(api, session.taskId);
          _clearOpenWebUiRegenerationAttemptMarker(
            ref,
            regenerationPlaceholderForAttempt,
          );
        } else if (isTemporary) {
          await _abortQuietly(session);
        } else {
          await _finishSubmittedOpenWebUiCompletionHeadlessly(
            ref,
            session: session,
            owner: regenerationOwner,
            assistantMessageId: assistantMessageId,
            requireDurableSubmittedMarker: false,
          );
        }
      } else {
        _clearOpenWebUiRegenerationAttemptMarker(
          ref,
          regenerationPlaceholderForAttempt,
        );
      }
    } finally {
      regenSocketService?.stopBuffering(
        bufferedChatId,
        sessionId: socketSessionId,
        messageId: assistantMessageId,
      );
    }
    return;
  } catch (error, stackTrace) {
    final session = submittedSession;
    if (session != null) {
      await _abortQuietly(session);
    }
    _stopOpenWebUiTaskQuietly(api, session?.taskId);
    final placeholder = regenerationPlaceholder;
    if (regenerationPlaceholderWasEstablished &&
        placeholder != null &&
        _openWebUiRegenerationPlaceholderOwnerIsActive(ref, placeholder) &&
        _ownedMarkedOpenWebUiRegenerationPlaceholder(ref, placeholder) ==
            null) {
      // Stop or exact replacement revoked this attempt while an awaited
      // preflight/request was failing. That stale failure has no UI owner and
      // must not escape into the historical rollback path.
      _clearOpenWebUiRegenerationAttemptMarker(ref, placeholder);
      return;
    }
    _settleFailedOpenWebUiRegeneration(
      ref: ref,
      api: api,
      error: error,
      placeholder: regenerationPlaceholder,
      submittedTaskId: session?.taskId,
    );
    Error.throwWithStackTrace(error, stackTrace);
  }
}

const String _openWebUiRegenerationAttemptMetadataKey =
    'conduitOpenWebUiRegenerationAttemptId';

bool _openWebUiRegenerationPlaceholderOwnerIsActive(
  dynamic ref,
  ChatSendPlaceholderHandle placeholder,
) {
  try {
    final active = ref.read(activeConversationProvider) as Conversation?;
    placeholder._followOpenWebUiRemap(
      ref.read(activeConversationInPlaceRemapProvider),
      active,
    );
    return placeholder._owns(ref, active);
  } catch (_) {
    return false;
  }
}

/// Finds the still-streaming row minted by this exact regeneration attempt,
/// regardless of its list position. Failure settlement uses this predicate so
/// a late setup error can mark its own non-tail row without touching a newer
/// assistant.
ChatMessage? _ownedMarkedOpenWebUiRegenerationPlaceholder(
  dynamic ref,
  ChatSendPlaceholderHandle placeholder,
) {
  if (!_openWebUiRegenerationPlaceholderOwnerIsActive(ref, placeholder)) {
    return null;
  }
  final attemptId = placeholder._regenerationAttemptId;
  if (attemptId == null || attemptId.isEmpty) return null;
  try {
    final messages = ref.read(chatMessagesProvider) as List<ChatMessage>;
    return messages
        .where(
          (message) =>
              message.id == placeholder.assistantMessageId &&
              message.role == 'assistant' &&
              message.isStreaming &&
              message.metadata?[_openWebUiRegenerationAttemptMetadataKey] ==
                  attemptId,
        )
        .firstOrNull;
  } catch (_) {
    return null;
  }
}

/// Dispatch callbacks in the shared OpenWebUI transport are tail-based.
/// Therefore transport admission is stricter than failure settlement: the
/// exact marked row must also be the current list tail.
ChatMessage? _tailOwnedOpenWebUiRegenerationPlaceholder(
  dynamic ref,
  ChatSendPlaceholderHandle placeholder,
) {
  final owned = _ownedMarkedOpenWebUiRegenerationPlaceholder(ref, placeholder);
  if (owned == null) return null;
  try {
    final messages = ref.read(chatMessagesProvider) as List<ChatMessage>;
    return identical(messages.lastOrNull, owned) ? owned : null;
  } catch (_) {
    return null;
  }
}

void _clearOpenWebUiRegenerationAttemptMarker(
  dynamic ref,
  ChatSendPlaceholderHandle placeholder,
) {
  final attemptId = placeholder._regenerationAttemptId;
  if (attemptId == null || attemptId.isEmpty) return;
  _clearOpenWebUiRegenerationAttemptMarkerById(
    ref,
    assistantMessageId: placeholder.assistantMessageId,
    attemptId: attemptId,
  );
}

void _clearOpenWebUiRegenerationAttemptMarkerById(
  dynamic ref, {
  required String assistantMessageId,
  required String attemptId,
}) {
  try {
    (ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier)
        .updateMessageById(assistantMessageId, (message) {
          if (message.metadata?[_openWebUiRegenerationAttemptMetadataKey] !=
              attemptId) {
            return message;
          }
          final metadata = Map<String, dynamic>.from(message.metadata!);
          metadata.remove(_openWebUiRegenerationAttemptMetadataKey);
          return message.copyWith(metadata: metadata.isEmpty ? null : metadata);
        });
  } catch (_) {
    // Attempt metadata is advisory cleanup. Disposal/navigation must not turn
    // a successfully stopped or attached transport into a send failure.
  }
}

/// Settles only the OpenWebUI placeholder minted by one regeneration attempt.
///
/// A later turn may already be streaming in the same conversation when this
/// failure arrives. The owner-bound handle and message id prevent that late
/// failure from stopping, finalizing, or attaching an error to the newer turn.
void _settleFailedOpenWebUiRegeneration({
  required dynamic ref,
  required ApiService? api,
  required Object error,
  required ChatSendPlaceholderHandle? placeholder,
  required String? submittedTaskId,
}) {
  if (placeholder == null) return;
  final ownedAssistant = _ownedMarkedOpenWebUiRegenerationPlaceholder(
    ref,
    placeholder,
  );
  if (ownedAssistant == null) return;

  // Never use the chat-wide task fallback here: a newer generation can be
  // active in this same conversation. Cancel only handles uniquely bound to
  // this assistant/session and leave an unaddressable remote task alone.
  final metadata = ownedAssistant.metadata;
  if (metadata?['transport'] == 'httpStream' ||
      metadata?['hasActiveAbortHandle'] == true) {
    api?.cancelStreamingMessage(ownedAssistant.id);
  }
  final metadataTaskId = metadata?['taskId']?.toString();
  if (metadataTaskId != submittedTaskId) {
    _stopOpenWebUiTaskQuietly(api, metadataTaskId);
  }
  (ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier)
      .failLastStreamingAssistant(
        error,
        assistantMessageId: placeholder.assistantMessageId,
      );
  _clearOpenWebUiRegenerationAttemptMarker(ref, placeholder);
}

void _stopOpenWebUiTaskQuietly(ApiService? api, String? taskId) {
  if (api == null || taskId == null || taskId.isEmpty) return;
  unawaited(() async {
    try {
      await api.stopTask(taskId);
    } catch (_) {}
  }());
}
