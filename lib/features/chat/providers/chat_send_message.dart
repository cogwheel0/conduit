part of 'chat_providers.dart';

Future<void> _sendMessageInternal(
  dynamic ref,
  String message,
  List<String>? attachments, [
  List<String>? toolIds,
  bool isVoiceMode = false,
  String? pendingFolderIdOverride,
  void Function(ChatSendPlaceholderHandle handle)?
  onAssistantPlaceholderCreated,
]) async {
  final conversationAtSendStart =
      ref.read(activeConversationProvider) as Conversation?;
  final sendMutationOwner = captureChatMutationOwner(
    ref,
    conversationAtSendStart,
  );
  final reviewerMode = ref.read(reviewerModeProvider);
  final api = ref.read(apiServiceProvider);
  final Object? directSourceApi = sendMutationOwner.usesOpenWebUiContext
      ? sendMutationOwner.openWebUiApi
      : api;
  final directSourceAuthSnapshot = directSourceApi is ApiService
      ? directSourceApi.captureAuthSnapshot()
      : null;
  final Object? directSourceAuthSessionEpoch = directSourceApi == null
      ? null
      : _readOpenWebUiAuthSessionEpoch(ref);
  final selectedModelCandidate = ref.read(selectedModelProvider) as Model?;
  final reasoningEffortAtSendStart = ref.read(
    configuredReasoningEffortProvider,
  );
  final webSearchAtSendStart =
      ref.read(webSearchEnabledProvider) &&
      ref.read(webSearchAvailableProvider);
  final imageGenerationAtSendStart =
      ref.read(imageGenerationEnabledProvider) &&
      ref.read(imageGenerationAvailableProvider);
  final localMcpToolIdsAtSendStart = (toolIds ?? const <String>[])
      .where((id) => id.startsWith(kDirectMcpToolIdPrefix))
      .toList(growable: false);
  final usesHermes =
      selectedModelCandidate != null && isHermesModel(selectedModelCandidate);
  final HermesConfigController? hermesConfigController = usesHermes
      ? ref.read(hermesConfigProvider.notifier)
      : null;
  final int? hermesConfigAdmission = hermesConfigController
      ?.captureSessionActionAdmission();
  if (usesHermes && hermesConfigAdmission == null) return;
  final HermesBackendService? hermesServiceGeneration = usesHermes
      ? ref.read(hermesApiServiceProvider)
      : null;
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
  if (!chatMutationTokenStillActive(ref, sendMutationOwner)) {
    throw StateError('The conversation changed while preparing the message.');
  }
  if (resolvedDirectRoute != null &&
      !_directRouteIsStillSelected(ref, resolvedDirectRoute)) {
    throw StateError(
      'The selected direct connection changed while preparing the message.',
    );
  }
  if (usesHermes &&
      (!hermesConfigController!.sessionActionAdmissionIsCurrent(
            hermesConfigAdmission!,
          ) ||
          !identical(
            ref.read(hermesApiServiceProvider),
            hermesServiceGeneration,
          ))) {
    return;
  }

  // App-owned transports do not require an OpenWebUI API. A reserved direct
  // identity without a current trusted registry binding remains blocked.
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

  final isLoadingConversation = ref.read(isLoadingConversationProvider);
  final currentConversation = ref.read(activeConversationProvider);
  final directSendConversationId = currentConversation == null
      ? null
      : _directRunOwnerScopeForConversation(ref, currentConversation);
  final directAttachmentContentTypes = _durableAttachmentContentTypesFromState(
    ref,
    attachments ?? const <String>[],
  );
  Stream<RemapEvent>? directRemapEvents;
  SyncEngine? directOpenWebUiSyncEngine;
  if (sendMutationOwner.usesOpenWebUiContext) {
    try {
      final engine = ref.read(syncEngineProvider.notifier);
      directOpenWebUiSyncEngine = engine;
      directRemapEvents = engine.remapEvents;
    } catch (_) {}
  }
  // Guard against a race where the user opens an existing chat and sends
  // before its history loads, which would otherwise create a new chat.
  if (isLoadingConversation && currentConversation == null) {
    throw StateError('Conversation is still loading');
  }
  if (!isModelCompatibleWithConversation(
    conversation: currentConversation,
    hasTrustedDirectBinding: directRoute != null,
  )) {
    throw StateError(
      'On-device direct chats can only continue with a direct connection model.',
    );
  }

  // Get context attachments synchronously (no API calls)
  final contextAttachments = ref.read(contextAttachmentsProvider);
  final contextFiles = _contextAttachmentsToFiles(contextAttachments);
  final _PreparedHermesTurn? preparedHermesTurn = usesHermes
      ? await _prepareHermesTurn(
          ref,
          selectedModel: selectedModel,
          text: message,
          attachmentIds: attachments,
          contextAttachments: contextAttachments,
        )
      : null;
  final _PreparedDirectDocuments? preparedDirectDocuments = directRoute != null
      ? await _prepareDirectDocuments(
          ref,
          attachmentIds: attachments,
          supportsOpenRouterPdfInputs:
              directRoute.profile.supportsOpenRouterPdfInputs,
        )
      : null;
  if (!chatMutationTokenStillActive(ref, sendMutationOwner)) {
    throw StateError('The conversation changed while preparing the message.');
  }
  if (resolvedDirectRoute != null &&
      !_directRouteIsStillSelected(ref, resolvedDirectRoute)) {
    throw StateError(
      'The selected direct connection changed while preparing the message.',
    );
  }
  if (usesHermes &&
      (!hermesConfigController!.sessionActionAdmissionIsCurrent(
            hermesConfigAdmission!,
          ) ||
          !identical(
            ref.read(hermesApiServiceProvider),
            hermesServiceGeneration,
          ))) {
    return;
  }

  // All attachments are now server file IDs (images uploaded like OpenWebUI)
  // Legacy base64 support kept for backwards compatibility
  final legacyBase64Images = <Map<String, dynamic>>[];
  final serverFileIds = <String>[];

  if (attachments != null && preparedHermesTurn == null) {
    for (final attachment in attachments) {
      if (attachment.startsWith('data:image/')) {
        // Legacy base64 format - keep for backwards compatibility
        legacyBase64Images.add({'type': 'image', 'url': attachment});
      } else if (!(preparedDirectDocuments?.attachmentIds.contains(
            attachment,
          ) ??
          false)) {
        // Server file ID (both images and documents)
        serverFileIds.add(attachment);
      }
    }
  }

  // Build initial user files with legacy base64 and context (server files added later)
  final List<Map<String, dynamic>>? initialUserFiles =
      preparedHermesTurn != null
      ? (preparedHermesTurn.files.isEmpty ? null : preparedHermesTurn.files)
      : (legacyBase64Images.isNotEmpty ||
            contextFiles.isNotEmpty ||
            (preparedDirectDocuments?.files.isNotEmpty ?? false))
      ? [
          ...legacyBase64Images,
          ...contextFiles,
          ...?preparedDirectDocuments?.files,
        ]
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
      if (isHermesModel(selectedModel)) 'transport': kHermesTransport,
      if (directRoute != null) 'transport': kDirectTransport,
      if (selectedModel.name.trim().isNotEmpty)
        'modelName': selectedModel.name.trim(),
    },
  );
  final messagesNotifier =
      ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier;
  if ((directRoute != null || isHermesModel(selectedModel)) &&
      openWebUiParentId != null) {
    messagesNotifier.updateMessageById(openWebUiParentId, (parent) {
      final childrenIds = message_tree
          .chatMessageChildrenIds(parent)
          .toList(growable: true);
      if (childrenIds.contains(userMessageId)) return parent;
      childrenIds.add(userMessageId);
      return parent.copyWith(
        metadata: <String, dynamic>{
          ...?parent.metadata,
          'childrenIds': childrenIds,
        },
      );
    });
  }
  messagesNotifier.addMessages([userMessage, assistantPlaceholder]);
  final optimisticTurnMessages = List<ChatMessage>.from(
    ref.read(chatMessagesProvider) as List<ChatMessage>,
    growable: false,
  );
  final sendHandle = ChatSendPlaceholderHandle._(
    userMessageId: userMessageId,
    assistantMessageId: assistantMessageId,
    mutationOwner: sendMutationOwner,
  );
  onAssistantPlaceholderCreated?.call(sendHandle);
  final DirectRunRegistry? directRegistry = directRoute == null
      ? null
      : ref.read(directRunRegistryProvider);
  if (directRoute != null && !_directRouteIsStillSelected(ref, directRoute)) {
    // No durable owner or run reservation exists yet. Roll back the complete
    // optimistic turn (including its parent edge) instead of leaving an empty,
    // apparently completed assistant behind.
    if (openWebUiParentId != null) {
      messagesNotifier.updateMessageById(openWebUiParentId, (parent) {
        final childrenIds = message_tree
            .chatMessageChildrenIds(parent)
            .where((id) => id != userMessageId)
            .toList(growable: false);
        return parent.copyWith(
          metadata: <String, dynamic>{
            ...?parent.metadata,
            'childrenIds': childrenIds,
          },
        );
      });
    }
    messagesNotifier.removeMessageById(assistantMessageId);
    messagesNotifier.removeMessageById(userMessageId);
    throw StateError(
      'The selected direct connection changed while preparing the message.',
    );
  }
  final directStopIndex = directRoute == null
      ? null
      : ref.read(_directRunStopIndexProvider);
  var directIndexedRunKey = directRoute == null
      ? null
      : _directRunKeyForOwner(
          directSendConversationId ??
              _pendingDirectRunOwner(assistantMessageId),
          assistantMessageId,
        );
  final DirectRunReservation? directReservation = directRegistry?.reserve(
    directIndexedRunKey!,
    directRoute!.binding.profileId,
  );
  if (directIndexedRunKey != null) {
    directStopIndex!.track(directIndexedRunKey);
  }
  final directPreflightCancelToken = directRoute == null ? null : CancelToken();

  // Hermes agent: route to Conduit's Hermes transport instead of the OpenWebUI
  // chat-completions pipeline. Native Hermes chats use server-side session
  // memory; Hermes segments in stored OpenWebUI chats also persist their local
  // message tree and sync it through the ordinary OpenWebUI chat outbox.
  if (usesHermes) {
    final hermesOwner = _HermesConversationOwner.fromMutationOwner(
      currentConversation,
      sendMutationOwner,
    );
    final hermesRegistry = ref.read(hermesRunRegistryProvider);
    var pendingRunKey = hermesOwner.runKey(assistantMessageId);
    var pendingRunHandedOff = false;
    final pendingCancelToken = hermesRegistry.registerPending(
      pendingRunKey,
      onCancelled: () {
        if (pendingRunHandedOff || !hermesOwner.isActive(ref)) return;
        messagesNotifier.finishStreamingMessage(
          assistantMessageId,
          ownerConversationId: hermesOwner.notifierConversationId,
          requireConversationOwner: true,
        );
      },
    );
    final configController = hermesConfigController!;
    final configAdmission = hermesConfigAdmission!;
    final serviceGeneration = hermesServiceGeneration;
    _HermesCommittedTurnStart? committedTurnStart;
    DatabaseLifetimeLease? hermesDatabaseLease;
    Future<void>? committedTurnSettlement;
    var databaseLeaseHandedOff = false;

    Future<void> cancelPendingRun() async {
      final cancellation = hermesRegistry.cancelOwned(
        pendingRunKey,
        cancelToken: pendingCancelToken,
      );
      if (cancellation != null) await cancellation.catchError((_) {});
    }

    bool pendingRunIsCurrent() =>
        !pendingCancelToken.isCancelled &&
        hermesRegistry.owns(pendingRunKey, cancelToken: pendingCancelToken) &&
        configController.sessionActionAdmissionIsCurrent(configAdmission) &&
        identical(ref.read(hermesApiServiceProvider), serviceGeneration);

    Future<void> settleCommittedTurnStart() {
      final committed = committedTurnStart;
      if (committed == null) return Future<void>.value();
      return committedTurnSettlement ??= (() {
        final visible = (ref.read(chatMessagesProvider) as List<ChatMessage>)
            .where((entry) => entry.id == assistantMessageId)
            .firstOrNull;
        return committed.settle(
          (visible ?? assistantPlaceholder).copyWith(isStreaming: false),
        );
      })();
    }

    Future<void> cancelPendingRunAndSettleCommittedTurn() async {
      await cancelPendingRun();
      await settleCommittedTurnStart();
    }

    try {
      if (!pendingRunIsCurrent()) {
        await cancelPendingRun();
        return;
      }
      if (hermesOwner.usesOpenWebUiBackend &&
          currentConversation != null &&
          !isTemporaryChat(currentConversation.id)) {
        committedTurnStart = await _persistHermesOpenWebUiTurnStart(
          ref,
          owner: hermesOwner,
          userMessage: userMessage,
          assistantMessage: assistantPlaceholder,
          allMessages: optimisticTurnMessages,
          sendHandle: sendHandle,
        );
        hermesDatabaseLease = committedTurnStart?.databaseLease;
        if (!pendingRunIsCurrent()) {
          await cancelPendingRunAndSettleCommittedTurn();
          return;
        }
      }
      final reboundRunKey = hermesOwner.runKey(assistantMessageId);
      if (reboundRunKey != pendingRunKey) {
        final rebound = hermesRegistry.rebindIfVacant(
          pendingRunKey,
          reboundRunKey,
          cancelToken: pendingCancelToken,
        );
        if (!rebound) {
          await cancelPendingRunAndSettleCommittedTurn();
          return;
        }
        pendingRunKey = reboundRunKey;
      }
      if (!pendingRunIsCurrent()) {
        await cancelPendingRunAndSettleCommittedTurn();
        return;
      }
      final nativeHermesOwner = isNativeHermesConversation(currentConversation);
      final mixedSessionProvenance = hermesOwner.usesOpenWebUiBackend
          ? _captureHermesMixedSessionProvenance(
              ref,
              owner: hermesOwner,
              databaseManager:
                  ref.read(databaseManagerProvider) as DatabaseManager,
            )
          : null;
      final continuesResponses =
          _lastHermesMetadataId(
                existingMessages,
                'hermesResponseId',
                allowNativeHermesMetadata: nativeHermesOwner,
                mixedProvenance: mixedSessionProvenance,
              ) !=
              null ||
          existingMessages.any(
            (item) =>
                item.metadata?['hermesTransportMode'] == kHermesResponsesMode &&
                (nativeHermesOwner ||
                    (mixedSessionProvenance != null &&
                        _mixedHermesMessageHasLocalProvenance(
                          item,
                          mixedSessionProvenance,
                        ))),
          );
      final useResponses =
          (attachments?.isNotEmpty ?? false) || continuesResponses;
      final inputImagesSupported = useResponses
          ? await _hermesInputImagesSupported(ref)
          : false;
      if (!pendingRunIsCurrent()) {
        await cancelPendingRunAndSettleCommittedTurn();
        return;
      }
      pendingRunHandedOff = true;
      databaseLeaseHandedOff = true;
      await _dispatchHermesRunFromChat(
        ref,
        assistantMessageId: assistantMessageId,
        assistantSeed: assistantPlaceholder,
        input: message,
        existingMessages: existingMessages,
        responseInput: useResponses ? preparedHermesTurn!.input : null,
        localDocumentPromptText: useResponses
            ? preparedHermesTurn!.localDocumentPromptText
            : null,
        localDocumentEnvelopes: useResponses
            ? preparedHermesTurn!.localDocumentEnvelopes
            : const <String>[],
        responseHistory: useResponses
            ? _hermesVisibleHistory(
                existingMessages,
                inputImagesSupported: inputImagesSupported,
              )
            : null,
        sendHandle: sendHandle,
        capturedOwner: hermesOwner,
        databaseLease: hermesDatabaseLease,
        preRegisteredCancelToken: pendingCancelToken,
        reasoningEffort: reasoningEffortAtSendStart,
      );
    } catch (error) {
      final visible = hermesOwner.isActive(ref)
          ? (ref.read(chatMessagesProvider) as List<ChatMessage>)
                .where((entry) => entry.id == assistantMessageId)
                .firstOrNull
          : null;
      final failed = (visible ?? assistantPlaceholder).copyWith(
        isStreaming: false,
        error: ChatMessageError(content: chatErrorContentForException(error)),
      );
      if (hermesOwner.isActive(ref)) {
        messagesNotifier.updateMessageById(assistantMessageId, (_) => failed);
      }
      if (!pendingRunHandedOff && committedTurnStart != null) {
        committedTurnSettlement ??= committedTurnStart.settle(
          failed.copyWith(isStreaming: false),
        );
        await committedTurnSettlement;
      }
      rethrow;
    } finally {
      if (!pendingRunHandedOff) {
        hermesRegistry.complete(pendingRunKey, cancelToken: pendingCancelToken);
      }
      if (!databaseLeaseHandedOff) {
        await hermesDatabaseLease?.release();
      }
    }
    try {
      if (chatMutationTokenStillActive(ref, sendMutationOwner) &&
          identical(ref.read(contextAttachmentsProvider), contextAttachments)) {
        ref.read(contextAttachmentsProvider.notifier).clear();
      }
    } catch (_) {}
    return;
  }

  if (directRoute != null) {
    final registry = directRegistry!;
    final reservation = directReservation!;
    final preflightCancelToken = directPreflightCancelToken!;
    _DirectConversationOwner? owner;
    try {
      if (contextAttachments.isNotEmpty) {
        throw const DirectChatInputException(
          'Direct chats cannot use OpenWebUI context attachments.',
        );
      }

      // Commit the optimistic turn before attachment/network preflight. Once
      // this returns, navigation may hide the turn but cannot silently discard
      // it: the captured conversation and database remain its durable owner.
      owner = await _persistDirectTurnStart(
        ref,
        route: directRoute,
        expectedConversation: currentConversation,
        expectedConversationId: directSendConversationId,
        userMessage: userMessage,
        assistantMessage: assistantPlaceholder,
        allMessages: optimisticTurnMessages,
        bindOwner: (resolvedOwner) {
          final nextKey = _directRunKeyForOwner(
            resolvedOwner.scopedConversationId,
            assistantMessageId,
          );
          final rebound = registry.rebindIfVacant(reservation, nextKey);
          if (rebound) {
            // Retain cleanup ownership synchronously. The helper performs a
            // post-commit auth fence after this callback and may throw instead
            // of returning the owner through the awaited assignment.
            owner = resolvedOwner;
            directStopIndex!.rebind(directIndexedRunKey!, nextKey);
            directIndexedRunKey = nextKey;
            sendHandle._bindOwnerScope(resolvedOwner.scopedConversationId);
          }
          return rebound;
        },
        sourceApi: directSourceApi,
        sourceAuthSnapshot: directSourceAuthSnapshot,
        sourceAuthSessionEpoch: directSourceAuthSessionEpoch,
        remapEvents: directRemapEvents,
        openWebUiAuthSessionEpoch: sendMutationOwner.openWebUiAuthSessionEpoch,
        openWebUiSyncEngine: directOpenWebUiSyncEngine,
        pendingFolderId:
            pendingFolderIdOverride ?? ref.read(pendingFolderIdProvider),
      );
      final runOwner = owner;
      if (runOwner == null) return;
      final ownerLocation = runOwner.location;
      if (ownerLocation != null) {
        registry.bindPersistenceIdentity(
          reservation,
          runOwner.persistenceOwnerId!,
          authSessionEpoch: runOwner.openWebUiAuthSessionEpoch,
        );
      }

      // A server file id is acceptable only when it resolves to an image. This
      // check prevents documents from being silently omitted by the normalized
      // direct request builder.
      for (final attachment in attachments ?? const <String>[]) {
        if (attachment.startsWith('data:image/') ||
            (preparedDirectDocuments?.attachmentIds.contains(attachment) ??
                false)) {
          continue;
        }
        final resolved = await _awaitDirectPreflightOrCancellation(
          registry: registry,
          reservation: reservation,
          cancelToken: preflightCancelToken,
          operation: () => _resolveDirectImageFromOpenWebUi(
            directSourceApi,
            attachment,
            kDirectMaxDecodedImageBytes,
            sourceAuthSnapshot: directSourceAuthSnapshot,
            cancelToken: preflightCancelToken,
            requireSourceContext: () =>
                _requireDirectOwnerSourceAuthSession(ref, runOwner),
          ),
        );
        if (resolved == null) {
          throw const DirectChatInputException(
            'This direct model does not support this attachment.',
          );
        }
      }

      final durableFiles = await _awaitDirectPreflightOrCancellation(
        registry: registry,
        reservation: reservation,
        cancelToken: preflightCancelToken,
        operation: () => _resolveDurableFilesFor(
          ref,
          <String>[
            for (final attachment in attachments ?? const <String>[])
              if (!(preparedDirectDocuments?.attachmentIds.contains(
                    attachment,
                  ) ??
                  false))
                attachment,
          ],
          sourceApi: directSourceApi,
          sourceAuthSnapshot: directSourceAuthSnapshot,
          cancelToken: preflightCancelToken,
          capturedContentTypes: directAttachmentContentTypes,
          requireSourceContext: () =>
              _requireDirectOwnerSourceAuthSession(ref, runOwner),
        ),
      );
      if (durableFiles.isNotEmpty) {
        userMessage = userMessage.copyWith(
          files: <Map<String, dynamic>>[
            ...?preparedDirectDocuments?.files,
            ...durableFiles,
          ],
        );
        if (_isDirectConversationOwnerActive(ref, runOwner)) {
          final notifier =
              ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier;
          notifier.updateMessageById(userMessage.id, (_) => userMessage);
        }
        await _persistDirectUserMessageUpdate(
          ref,
          owner: runOwner,
          userMessage: userMessage,
          isCurrentGeneration: () => registry.isLatest(reservation),
        );
      }

      final requestMessages = withDirectConversationSystemPrompt(
        messages: <ChatMessage>[...existingMessages, userMessage],
        systemPrompt: currentConversation?.systemPrompt,
      );
      await _dispatchDirectRunFromChat(
        ref,
        route: directRoute,
        assistantMessageId: assistantMessageId,
        assistantSeed: assistantPlaceholder,
        requestMessages: requestMessages,
        owner: runOwner,
        reservation: reservation,
        preflightCancelToken: preflightCancelToken,
        enableWebSearch: webSearchAtSendStart,
        enableImageGeneration: imageGenerationAtSendStart,
        reasoningEffort: reasoningEffortAtSendStart,
        localMcpToolIds: localMcpToolIdsAtSendStart,
        ephemeralFilePartsByAttachmentId:
            preparedDirectDocuments?.ephemeralFilePartsByAttachmentId ??
            const <String, DirectFilePart>{},
        sendHandle: sendHandle,
      );
      if (_isDirectConversationOwnerActive(ref, runOwner) &&
          identical(ref.read(contextAttachmentsProvider), contextAttachments)) {
        ref.read(contextAttachmentsProvider.notifier).clear();
      }
      return;
    } catch (error) {
      if (error is _DirectOpenWebUiAuthSessionChanged) {
        registry.discardFinalizedOutput(reservation);
        final authChangedOwner = owner;
        if (authChangedOwner != null) {
          try {
            await _settleDirectAssistantAfterAuthSessionChange(
              ref,
              owner: authChangedOwner,
              assistantMessageId: assistantMessageId,
              isCurrentGeneration: () => registry.isLatest(reservation),
            );
          } catch (settlementError, stackTrace) {
            DebugLogger.error(
              'auth-change-placeholder-settlement-failed',
              scope: 'direct-connections/chat',
              error: settlementError,
              stackTrace: stackTrace,
              data: {'conversationId': authChangedOwner.conversationId},
            );
          }
        }
        return;
      }
      if (error is _DirectRunStoppedDuringPreflight) {
        if (!registry.isLatest(reservation)) return;
        final notifier =
            ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier;
        final stoppedOwner = owner;
        final ownerIsActive = stoppedOwner != null
            ? _isDirectConversationOwnerActive(ref, stoppedOwner)
            : _isDirectSendConversationOwnerActive(
                ref,
                directSendConversationId,
              );
        final stopped =
            (ownerIsActive
                ? (ref.read(chatMessagesProvider) as List<ChatMessage>)
                      .where((entry) => entry.id == assistantMessageId)
                      .firstOrNull
                : null) ??
            assistantPlaceholder;
        final stoppedSnapshot = stopped.copyWith(isStreaming: false);
        if (ownerIsActive) {
          notifier.updateMessageById(
            assistantMessageId,
            (_) => stoppedSnapshot,
          );
        }
        if (stoppedOwner != null) {
          await _persistCompletedDirectAssistant(
            ref,
            owner: stoppedOwner,
            assistant: stoppedSnapshot,
            isCurrentGeneration: () => registry.isLatest(reservation),
          );
          if (registry.isLatest(reservation) &&
              _isDirectConversationOwnerActive(ref, stoppedOwner)) {
            notifier.updateMessageById(
              assistantMessageId,
              (_) => stoppedSnapshot,
            );
          }
        }
        return;
      }
      DebugLogger.error(
        'send-failed',
        scope: 'direct-connections/chat',
        data: {'errorType': error.runtimeType.toString()},
      );
      if (registry.isOutputFinalized(reservation)) rethrow;
      if (!registry.isLatest(reservation)) return;
      final notifier =
          ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier;
      final unavailableOwner = error is _DirectConversationOwnerUnavailable
          ? error
          : null;
      final turnStartDatabaseUnavailable =
          error is _DirectTurnStartDatabaseUnavailable;
      final failedOwner = owner;
      final ownerIsActive = failedOwner != null
          ? _isDirectConversationOwnerActive(ref, failedOwner)
          : _isDirectSendConversationOwnerActive(ref, directSendConversationId);
      final failed =
          (ownerIsActive
              ? (ref.read(chatMessagesProvider) as List<ChatMessage>)
                    .where((entry) => entry.id == assistantMessageId)
                    .firstOrNull
              : null) ??
          assistantPlaceholder;
      final failedSnapshot = failed.copyWith(
        isStreaming: false,
        error: ChatMessageError(content: chatErrorContentForException(error)),
      );
      if (ownerIsActive) {
        if (unavailableOwner?.placeholderWasDurablyDeleted == true) {
          notifier.removeMessageById(assistantMessageId);
        } else if (turnStartDatabaseUnavailable) {
          // No direct rows committed, and the managed executor is already
          // closing. Settle only the optimistic UI; the database watch will
          // restore the last durable turn without issuing a generic echo write.
          notifier.completeStoppedDirectStreamingUi(assistantMessageId);
          notifier.updateMessageById(assistantMessageId, (_) => failedSnapshot);
        } else {
          notifier.failLastStreamingAssistant(
            error,
            assistantMessageId: assistantMessageId,
          );
          // Persist the same deterministic snapshot that is projected to the
          // UI. Completing streaming can wake the placeholder database watch,
          // so a post-cleanup reread is not an authoritative failure value.
          notifier.updateMessageById(assistantMessageId, (_) => failedSnapshot);
        }
      }
      if (failedOwner != null && unavailableOwner == null) {
        await _persistCompletedDirectAssistant(
          ref,
          owner: failedOwner,
          assistant: failedSnapshot,
          isCurrentGeneration: () => registry.isLatest(reservation),
        );
        if (registry.isLatest(reservation) &&
            _isDirectConversationOwnerActive(ref, failedOwner)) {
          notifier.updateMessageById(assistantMessageId, (_) => failedSnapshot);
        }
      }
      rethrow;
    } finally {
      await owner?.releaseDatabaseLease();
      directStopIndex!.untrack(directIndexedRunKey!);
      registry.releaseReservation(reservation);
    }
  }

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

      sendHandle._bindConversation(localConversation);
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
      sendHandle._bindConversation(localConversation);
      ref.read(activeConversationProvider.notifier).set(localConversation);
      activeConversation = localConversation;

      if (!reviewerMode) {
        // Try to create on server - use lightweight message without large
        // base64 image data to avoid timeout (images sent in chat request)
        try {
          final lightweightMessage = userMessage.copyWith(
            attachmentIds: null,
            files: null,
            model: serverModelId,
            metadata: <String, dynamic>{
              ...?userMessage.metadata,
              'models': <String>[serverModelId],
            },
          );
          final serverConversation = await api.createConversation(
            title: 'New Chat',
            messages: [lightweightMessage],
            model: serverModelId,
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
          sendHandle._bindConversation(updatedConversation);
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
      final cleaned = outboundProviderReplayText(msg);

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

  // Get selected toggle filter IDs
  final selectedFilterIds = selectedFilterIdsForModel(ref, selectedModel);
  final List<String>? filterIdsForApi = selectedFilterIds.isNotEmpty
      ? selectedFilterIds
      : null;

  String? chatIdForBuffer;
  String? sessionIdForBuffer;
  String? messageIdForBuffer;
  OpenWebUiCompletionOwner? submittedOpenWebUiOwner;
  try {
    final modelItem = _buildLocalModelItem(
      selectedModel,
      trustedDirectBinding: openWebUiDirectRoute?.binding,
      wireModelId: serverModelId,
    );
    final submittedConversation = activeConversation;
    final submittedOwner = submittedConversation == null
        ? null
        : captureOpenWebUiCompletionOwner(
            ref,
            chatId: submittedConversation.id,
            api: api,
          );
    submittedOpenWebUiOwner = submittedOwner;

    bool ownsOpenWebUiPreflight() => submittedOwner == null
        ? chatMutationTokenStillActive(ref, sendMutationOwner)
        : activeOpenWebUiChatIdForMutation(ref, submittedOwner) != null;

    void requireOpenWebUiPreflightOwner() {
      if (!ownsOpenWebUiPreflight()) {
        throw StateError(
          'The conversation changed while preparing the message.',
        );
      }
    }

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
    requireOpenWebUiPreflightOwner();

    List<Map<String, dynamic>>? toolServers;
    try {
      toolServers = await _resolveToolServersForRequest(
        api: api,
        userSettings: userSettingsData,
        selectedToolIds: selectedToolIds,
      );
    } catch (_) {}
    requireOpenWebUiPreflightOwner();
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
    requireOpenWebUiPreflightOwner();

    try {
      userMessageMap = _buildOpenWebUiUserMessage(
        messages: messages,
        userMessageId: lastUserMessageId,
        modelId: serverModelId,
        assistantChildMessageId: assistantMessageId,
        useModelIdForModels: openWebUiDirectRoute != null,
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
      requireOpenWebUiPreflightOwner();
      final session = await api.sendMessageSession(
        messages: requestMessages,
        model: serverModelId,
        conversationId: submittedOwner?.chatId,
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
        reasoningEffort: reasoningEffortForModel(ref.read, selectedModel),
        parentId: userMessageMap?['parentId']?.toString(),
        userMessage: userMessageMap,
        variables: promptVariables,
        files: _extractTopLevelRequestFiles(userMessageMap),
      );

      if (submittedOwner != null) {
        submittedOwner.chatId = await resolveOpenWebUiCompletionChatId(
          ref,
          owner: submittedOwner,
          assistantMessageId: assistantMessageId,
        );
      }
      final activeOwnerChatId = submittedOwner == null
          ? null
          : activeOpenWebUiChatIdForMutation(ref, submittedOwner);
      final ownerStillActive = activeOwnerChatId != null;
      if (activeOwnerChatId != null) {
        submittedOwner!.chatId = activeOwnerChatId;
        final active = ref.read(activeConversationProvider) as Conversation?;
        if (active != null) sendHandle._bindConversation(active);
      }
      if (!ownerStillActive) {
        DebugLogger.log(
          'send-owner-changed-after-submit',
          scope: 'chat/completion',
          data: {
            'chatId': submittedOwner?.chatId,
            'assistantMessageId': assistantMessageId,
          },
        );
        if (submittedOwner == null || isTemporary) {
          // Temporary chats have no durable server resource to recover into.
          await _abortQuietly(session);
        } else {
          await _finishSubmittedOpenWebUiCompletionHeadlessly(
            ref,
            session: session,
            owner: submittedOwner,
            assistantMessageId: assistantMessageId,
            // Inline sends have no requestCompletion outbox op that could
            // replay this POST when a legacy placeholder row is absent.
            requireDurableSubmittedMarker: false,
          );
        }
      } else {
        final modelUsesReasoning2 = _modelUsesReasoning(selectedModel.id);

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
          activeConversationId: submittedOwner?.chatId,
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
          ownsActiveConversation: () =>
              activeOpenWebUiChatIdForMutation(ref, submittedOwner!) != null,
        );
        if (!attached) {
          if (isTemporary) {
            await _abortQuietly(session);
          } else {
            await _finishSubmittedOpenWebUiCompletionHeadlessly(
              ref,
              session: session,
              owner: submittedOwner!,
              assistantMessageId: assistantMessageId,
              requireDurableSubmittedMarker: false,
            );
          }
        }
      }
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
      final ownerStillActive =
          submittedOwner != null &&
          activeOpenWebUiChatIdForMutation(ref, submittedOwner) != null;
      if (ownerStillActive &&
          identical(ref.read(contextAttachmentsProvider), contextAttachments)) {
        ref.read(contextAttachmentsProvider.notifier).clear();
      }
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
    final ownerStillActive = submittedOpenWebUiOwner != null
        ? activeOpenWebUiChatIdForMutation(ref, submittedOpenWebUiOwner) != null
        : chatMutationTokenStillActive(ref, sendMutationOwner);
    if (ownerStillActive &&
        sendHandle._owns(
          ref,
          ref.read(activeConversationProvider) as Conversation?,
        )) {
      notifier.failLastStreamingAssistant(
        e,
        assistantMessageId: assistantMessageId,
      );
    }
    if (e.toString().contains('401') || e.toString().contains('403')) {
      // Authentication errors - clear auth state and redirect to login.
      ref.invalidate(authStateManagerProvider);
    }
  }
}

/// Returns a user-friendly error description based on the exception.
String chatErrorContentForException(Object e) {
  if (e is _DirectConversationOwnerUnavailable) {
    return 'This conversation is no longer available.';
  }
  if (e is HermesAttachmentsUnsupportedException) return e.message;
  if (e is HermesChatInputException) return e.message;
  if (e is HermesLocalDocumentException) return e.message;
  if (e is DirectChatInputException) return e.message;
  if (e is DirectProviderException) return e.message;

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
  var ownerDisposed = false;
  if (ref is Ref) {
    ref.onDispose(() => ownerDisposed = true);
  }
  final ownerContext = ref is WidgetRef ? ref.context : null;

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

    final copiedConversation = conversation.copyWith(
      messages: messages,
      updatedAt: DateTime.now(),
    );
    final updatedConversation = activeConversation == null
        ? copiedConversation
        : inheritNativeHermesConversationProvenance(
            activeConversation,
            copiedConversation,
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

    // This helper can outlive a voice-mode/service notifier while awaiting the
    // database lock. Once that owner is gone, its completion must not mutate
    // app state or schedule another pull through the disposed Ref.
    if (ownerDisposed || (ownerContext != null && !ownerContext.mounted)) {
      return;
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
