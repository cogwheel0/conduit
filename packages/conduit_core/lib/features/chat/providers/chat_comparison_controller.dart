part of 'chat_providers.dart';

/// Multi-model comparison: one user message, several answers, ONE request.
///
/// A comparison is admitted as a single durable turn (one user row, one
/// placeholder per model, one `requestCompletion` op carrying the
/// [ComparisonGroupSnapshot]) and replayed as a single completion request whose
/// `message_ids` list names every answer. The server creates one task per entry
/// and streams each answer over the socket under its own message id; this file
/// binds each task to its assistant message and never lets one answer's events
/// or completion reach another's.

/// How many models a comparison starts with. A chat that already stores more
/// slots still loads every one of them.
const int kComparisonSlotCount = 2;

enum ComparisonAdmissionFailure {
  /// The turn cannot be a durable Open WebUI comparison: no database, reviewer
  /// or temporary chat, or a Direct/Apple/Hermes model or chat.
  unavailable,

  /// The wrong number of models was chosen.
  wrongModelCount,

  /// A chosen model is not on the server's list.
  modelUnavailable,

  /// An image is attached and a chosen model cannot read images.
  visionUnsupported,

  /// A terminal is selected and the chosen models disagree about using it.
  terminalConflict,

  /// The code interpreter is selected and a chosen model cannot run it.
  interpreterUnsupported,

  /// A generation parameter would not read the same for every chosen model.
  settingsConflict,
}

/// Why a comparison was not admitted. Nothing was written when this is thrown.
final class ComparisonAdmissionException implements Exception {
  const ComparisonAdmissionException(
    this.reason, {
    this.modelIds = const <String>[],
    this.conflict,
  });

  final ComparisonAdmissionFailure reason;

  /// The models the reason is about.
  final List<String> modelIds;

  /// Set for [ComparisonAdmissionFailure.settingsConflict].
  final ComparisonSettingsConflict? conflict;

  @override
  String toString() =>
      'ComparisonAdmissionException(${reason.name}, models: $modelIds)';
}

/// Whether this account, chat and model can run a comparison at all: a
/// comparison is always a durable Open WebUI turn, so it needs what one needs.
/// A project draft that starts with saved models to compare asks this, since
/// applying a saved default is not the Advanced command.
final comparisonRuntimeAvailableProvider = Provider<bool>((ref) {
  final model = ref.watch(selectedModelProvider);
  final active = ref.watch(activeConversationProvider);
  return ref.watch(apiServiceProvider) != null &&
      ref.watch(appDatabaseProvider) != null &&
      ref.watch(isAuthenticatedProvider2) &&
      !ref.watch(reviewerModeProvider) &&
      !ref.watch(temporaryChatEnabledProvider) &&
      !isTemporaryChat(active?.id) &&
      (active == null || conversationUsesOpenWebUiStorage(active)) &&
      model != null &&
      !isHermesModel(model) &&
      !hasReservedDirectIdentity(model) &&
      ref.watch(directModelRegistryProvider).resolve(model) == null;
});

/// Whether the composer offers "Compare models". Advanced gates only this new
/// command: it never decides what a saved comparison shows, and a comparison
/// that is already running keeps its stop controls whatever the setting is.
final comparisonCommandAvailableProvider = Provider<bool>((ref) {
  if (!ref.watch(
    appSettingsProvider.select((settings) => settings.advancedFeaturesEnabled),
  )) {
    return false;
  }
  return ref.watch(comparisonRuntimeAvailableProvider);
});

/// What a comparison turn needs from the composer, captured once.
CodeInterpreterBlock? _codeInterpreterBlockForModel(dynamic ref, Model model) {
  final api = ref.read(apiServiceProvider);
  if (api == null ||
      !ref.read(isAuthenticatedProvider2) ||
      isHermesModel(model) ||
      hasReservedDirectIdentity(model)) {
    return CodeInterpreterBlock.notOpenWebUi;
  }
  return _evaluateCodeInterpreterSupport(
    config: ref.read(backendConfigProvider).asData?.value,
    serverId: api.serverConfig.id,
    user: ref.read(currentUserProvider2),
    permissions: ref.read(userPermissionsProvider).asData?.value,
    model: model,
    terminalId: ref.read(selectedTerminalIdProvider),
  );
}

ComparisonModelProfile _comparisonProfileFor(dynamic ref, Model model) {
  final policy = reasoningEffortPolicyForModel(ref.read, model);
  final picker = reasoningEffortForModel(ref.read, model);
  return ComparisonModelProfile(
    modelId: model.id,
    supportsReasoningEffort: model.supportsReasoningEffort,
    pickerReasoningEffort: picker == kAutomaticReasoningEffort ? null : picker,
    acceptsReasoningEffort: (effort) =>
        policy.effectiveConfiguredEffort(effort) == effort,
  );
}

/// Admits a comparison of [models] as ONE durable turn and starts it.
///
/// Mirrors [durableSend]: the optimistic rows, the database rows and the
/// completion op share the minted ids, the write is one transaction under the
/// chat lock, and every check that can refuse the turn runs before anything is
/// written. Returns one handle per answer, in slot order.
///
/// A new draft's project is the one it had when the send began, however long
/// the admission waits afterwards. The turn lands in that project; only a draft
/// still showing the project and this turn's rows is taken over by the chat.
///
/// [onCommitted] runs once the turn is durable, before the first dispatch is
/// awaited, for a caller that moves to the chat while that dispatch runs. It
/// is skipped when the chat on screen is no longer the one this turn went into.
Future<List<ChatSendPlaceholderHandle>> durableCompareSend(
  dynamic ref,
  String message,
  List<String>? attachments, {
  required List<Model> models,
  List<String>? toolIds,
  bool isVoiceMode = false,
  void Function()? onCommitted,
}) async {
  final activeAtSendStart = ref.read(activeConversationProvider);
  final sendMutationOwner = captureChatMutationOwner(ref, activeAtSendStart);
  final draftFolderId = activeAtSendStart == null
      ? ref.read(pendingFolderIdProvider) as String?
      : null;
  final settingsOwnerKey = _openWebUiSettingsOwnerKey(
    ref,
    sendMutationOwner.openWebUiApi,
  );

  if (models.length != kComparisonSlotCount) {
    throw const ComparisonAdmissionException(
      ComparisonAdmissionFailure.wrongModelCount,
    );
  }
  final db = _readAppDatabaseOrNull(ref);
  final directRegistry = ref.read(directModelRegistryProvider);
  if (db == null ||
      ref.read(reviewerModeProvider) ||
      ref.read(temporaryChatEnabledProvider) ||
      isTemporaryChat(activeAtSendStart?.id) ||
      (activeAtSendStart != null &&
          !conversationUsesOpenWebUiStorage(activeAtSendStart)) ||
      models.any(
        (model) =>
            isHermesModel(model) ||
            hasReservedDirectIdentity(model) ||
            directRegistry.resolve(model) != null,
      )) {
    throw const ComparisonAdmissionException(
      ComparisonAdmissionFailure.unavailable,
    );
  }

  // A slot whose model the server does not list is refused up front, so a
  // stale picker entry can never become a placeholder that nothing answers.
  final listed =
      (ref.read(modelsProvider) as AsyncValue<List<Model>>).asData?.value;
  if (listed != null) {
    final missing = [
      for (final model in models)
        if (!listed.any((candidate) => candidate.id == model.id)) model.id,
    ];
    if (missing.isNotEmpty) {
      throw ComparisonAdmissionException(
        ComparisonAdmissionFailure.modelUnavailable,
        modelIds: missing,
      );
    }
  }

  // The single request carries one terminal id and one interpreter flag for
  // every answer, so the models must agree about them.
  final resolvedTerminalId = _resolveTerminalIdForRequest(
    selectedTerminalId: ref.read(selectedTerminalIdProvider),
  );
  String? terminalIdForCompletion;
  if (resolvedTerminalId != null) {
    final supporting = [
      for (final model in models)
        if (modelSupportsTerminal(model)) model.id,
    ];
    if (supporting.length == models.length) {
      terminalIdForCompletion = resolvedTerminalId;
    } else if (supporting.isNotEmpty) {
      throw ComparisonAdmissionException(
        ComparisonAdmissionFailure.terminalConflict,
        modelIds: [
          for (final model in models)
            if (!supporting.contains(model.id)) model.id,
        ],
      );
    }
  }
  final interpreterRequested = ref.read(codeInterpreterEnabledProvider) as bool;
  if (interpreterRequested) {
    final blocked = [
      for (final model in models)
        if (_codeInterpreterBlockForModel(ref, model) != null) model.id,
    ];
    if (blocked.isNotEmpty) {
      throw ComparisonAdmissionException(
        ComparisonAdmissionFailure.interpreterUnsupported,
        modelIds: blocked,
      );
    }
  }

  // Settings the chat saved, read from its own row so an edit made on another
  // screen is seen; a chat with no row yet uses what is on screen.
  final draftChatParams = activeAtSendStart == null
      ? Map<String, dynamic>.of(
          ref.read(pendingOpenWebUiChatSettingsProvider)
              as Map<String, dynamic>,
        )
      : const <String, dynamic>{};
  final profiles = [
    for (final model in models) _comparisonProfileFor(ref, model),
  ];
  void requireCompatibleSettings(Map<String, dynamic> chatParams) {
    final conflict = findComparisonSettingsConflict(
      chatParams: chatParams,
      models: profiles,
    );
    if (conflict != null) {
      throw ComparisonAdmissionException(
        ComparisonAdmissionFailure.settingsConflict,
        modelIds: conflict.modelIds,
        conflict: conflict,
      );
    }
  }

  final storedParamsBeforeWrite = activeAtSendStart == null
      ? draftChatParams
      : (await db.chatsDao.getChatParams(activeAtSendStart.id)) ??
            activeAtSendStart.chatParams;
  requireCompatibleSettings(storedParamsBeforeWrite);

  final contextAttachments = ref.read(contextAttachmentsProvider);
  final contextFiles = _contextAttachmentsToFiles(contextAttachments);
  final attachmentList = attachments ?? const <String>[];
  final carriesImage =
      attachmentList.any((id) => id.startsWith('data:image/')) ||
      contextFiles.any((file) => file['type'] == 'image');
  final durableAttachmentFiles = await _resolveDurableFilesFor(
    ref,
    attachmentList,
    sourceApi: sendMutationOwner.openWebUiApi,
    sourceAuthSnapshot: sendMutationOwner.openWebUiAuthSnapshot,
    requireSourceContext: () =>
        _requireChatMutationOpenWebUiAuthSession(ref, sendMutationOwner),
  );
  final durableFiles = <Map<String, dynamic>>[
    ...durableAttachmentFiles,
    ...contextFiles,
  ];
  final hasImage =
      carriesImage || durableFiles.any((file) => file['type'] == 'image');
  if (hasImage) {
    final blind = [
      for (final model in models)
        if (!model.isMultimodal) model.id,
    ];
    if (blind.isNotEmpty) {
      throw ComparisonAdmissionException(
        ComparisonAdmissionFailure.visionUnsupported,
        modelIds: blind,
      );
    }
  }

  // The filters are the primary model's picks that every other model offers.
  final primaryModel = models.first;
  final filterIds = [
    for (final id in selectedFilterIdsForModel(ref, primaryModel))
      if (models.every(
        (model) => model.filters?.any((filter) => filter.id == id) ?? false,
      ))
        id,
  ];
  final now = ref.read(syncClockProvider).nowEpochSeconds();
  final webSearchEnabled =
      ref.read(webSearchEnabledProvider) &&
      ref.read(webSearchAvailableProvider);
  final imageGenerationEnabled =
      ref.read(imageGenerationEnabledProvider) &&
      ref.read(imageGenerationAvailableProvider);

  final existingMessages = ref.read(chatMessagesProvider) as List<ChatMessage>;
  final parentId = _resolveOpenWebUiParentIdForNewUserMessage(existingMessages);
  final userMessageId = const Uuid().v4();
  final slots = <ComparisonSlotSnapshot>[
    for (var index = 0; index < models.length; index++)
      ComparisonSlotSnapshot(
        assistantMessageId: const Uuid().v4(),
        model: models[index].id,
        modelIdx: index,
      ),
  ];
  final assistantIds = [for (final slot in slots) slot.assistantMessageId];
  final modelIds = [for (final model in models) model.id];

  final userMessage = ChatMessage(
    id: userMessageId,
    role: 'user',
    content: message,
    timestamp: DateTime.now(),
    model: primaryModel.id,
    attachmentIds: attachments,
    files: durableFiles.isEmpty ? null : durableFiles,
    metadata: {
      'parentId': parentId,
      'childrenIds': assistantIds,
      'models': modelIds,
    },
  );
  final placeholders = [
    for (var index = 0; index < models.length; index++)
      ChatMessage(
        id: assistantIds[index],
        role: 'assistant',
        content: '',
        timestamp: DateTime.now(),
        model: models[index].id,
        isStreaming: true,
        metadata: {
          'parentId': userMessageId,
          'childrenIds': const <String>[],
          kMessageModelIdxMetadataKey: index,
          if (models[index].name.trim().isNotEmpty)
            'modelName': models[index].name.trim(),
        },
      ),
  ];
  final messagesNotifier =
      ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier;
  messagesNotifier.addMessages([userMessage, ...placeholders]);
  final durableOptimisticMessages = List<ChatMessage>.unmodifiable(
    ref.read(chatMessagesProvider) as List<ChatMessage>,
  );
  final handles = [
    for (final id in assistantIds)
      ChatSendPlaceholderHandle._(
        userMessageId: userMessageId,
        assistantMessageId: id,
        mutationOwner: sendMutationOwner,
      ),
  ];

  void withdrawOptimisticTurn() {
    if (!chatMutationTokenStillActive(ref, sendMutationOwner)) return;
    for (final id in [userMessageId, ...assistantIds]) {
      messagesNotifier.removeMessageById(id);
    }
  }

  final chatLocks = ref.read(chatLocksProvider);
  final toolIdList = toolIds ?? const <String>[];
  final databaseLease = ref.read(databaseManagerProvider).tryAcquireLease(db);
  final capturedSyncEngine = ref.read(syncEngineProvider.notifier);
  final durableContextOwner = captureOpenWebUiCompletionOwner(
    ref,
    chatId: activeAtSendStart?.id ?? '',
    database: db,
    api: sendMutationOwner.openWebUiApi,
  );
  var committed = false;
  try {
    final pickerReasoningEffort = reasoningEffortForModel(
      ref.read,
      primaryModel,
    );
    final admissionGlobals = await _captureAdmissionGlobalSettings(
      ref,
      owner: sendMutationOwner,
      ownerKey: settingsOwnerKey,
    );
    RequestCompletionPayload completionFor(
      Map<String, dynamic> chatParams, {
      required String? legacyChatSystem,
    }) => RequestCompletionPayload(
      assistantMessageId: assistantIds.first,
      model: primaryModel.id,
      toolIds: toolIdList,
      filterIds: filterIds,
      terminalId: terminalIdForCompletion,
      enableWebSearch: webSearchEnabled,
      enableImageGeneration: imageGenerationEnabled,
      enableCodeInterpreter: interpreterRequested,
      isVoiceMode: isVoiceMode,
      chatSettings: _admissionSettingsSnapshot(
        chatParams,
        pickerReasoningEffort: pickerReasoningEffort,
        globals: admissionGlobals,
        legacyChatSystem: legacyChatSystem,
      ),
      comparison: ComparisonGroupSnapshot(
        userMessageId: userMessageId,
        slots: slots,
      ),
    );

    var activeConversation = activeAtSendStart as Conversation?;
    if (activeConversation == null) {
      final pendingFolderId = draftFolderId;
      final localId = 'local:${const Uuid().v4()}';
      final title = _titleFromText(message);
      final blob = _buildDurableComparisonChatBlob(
        userMsgId: userMessageId,
        parentId: parentId,
        text: message,
        files: durableFiles,
        slots: slots,
        modelNames: [for (final model in models) model.name],
        now: now,
        chatParams: draftChatParams,
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
      final localConversation = Conversation(
        id: localId,
        title: title,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        messages: durableOptimisticMessages,
        folderId: pendingFolderId,
        chatParams: draftChatParams,
      );
      for (final handle in handles) {
        handle._bindConversation(localConversation);
      }
      // Two empty composers look alike, so the composer is still this one only
      // while it shows the project the send began in and this turn's own rows.
      final stillOwnsDraft =
          chatMutationTokenStillActive(ref, sendMutationOwner) &&
          ref.read(pendingFolderIdProvider) == draftFolderId &&
          (ref.read(chatMessagesProvider) as List<ChatMessage>).any(
            (shown) => shown.id == userMessageId,
          );
      if (stillOwnsDraft) {
        ref.read(activeConversationProvider.notifier).set(localConversation);
        ref.read(pendingFolderIdProvider.notifier).clear();
      } else {
        // The turn is still written below; its rows have no place on a draft
        // that moved on.
        for (final id in [userMessageId, ...assistantIds]) {
          messagesNotifier.removeMessageById(id);
        }
      }
      activeConversation = localConversation;
      await chatLocks.runExclusive(localId, () async {
        await db.chatsDao.insertLocalChatWithCreateOp(
          chat: rows.chat,
          messages: rows.messages,
          blobRows: rows,
          contentHash: contentHash,
          completion: completionFor(draftChatParams, legacyChatSystem: null),
        );
      });
    } else {
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
          'childrenIds': assistantIds,
          'role': 'user',
          'content': message,
          'files': durableFiles,
          'models': modelIds,
          'timestamp': now,
        },
      );
      final assistantRows = [
        for (var index = 0; index < slots.length; index++)
          MessageRowData(
            id: slots[index].assistantMessageId,
            chatId: chatId,
            parentId: userMessageId,
            role: 'assistant',
            content: '',
            model: slots[index].model,
            createdAt: now,
            orderIndex: index + 1,
            payload: _durableComparisonAssistantPayload(
              slot: slots[index],
              parentId: userMessageId,
              modelName: models[index].name,
              timestamp: now,
            ),
          ),
      ];
      await chatLocks.runExclusive(chatId, () async {
        final storedChatParams =
            await db.chatsDao.getChatParams(chatId) ??
            activeConversation!.chatParams;
        // The settings were checked before the write; one edited since is
        // caught here, under the lock an edit holds, before anything lands.
        requireCompatibleSettings(storedChatParams);
        await db.chatsDao.appendMessagesWithUpdateOp(
          chatId: chatId,
          messages: [userRow, ...assistantRows],
          // The chat opens on the first answer, as Open WebUI's own comparison
          // does; the user chooses another by continuing from it.
          currentMessageId: assistantIds.first,
          updatedAt: now,
          chatModels: modelIds,
          enqueueCompletion: true,
          completion: completionFor(
            storedChatParams,
            legacyChatSystem: activeConversation!.systemPrompt,
          ),
        );
      });
    }

    // The turn and its one completion op are durable from here on. Whatever
    // goes wrong next, the outbox owns the send.
    committed = true;
    final presentingTurn = handles.first.ownsActiveChat(ref);
    if (presentingTurn &&
        identical(ref.read(contextAttachmentsProvider), contextAttachments)) {
      ref.read(contextAttachmentsProvider.notifier).clear();
    }
    if (presentingTurn) onCommitted?.call();
    if (openWebUiCompletionContextIsCurrent(ref, durableContextOwner)) {
      try {
        await capturedSyncEngine.drainNowForDatabase(db);
      } catch (error, stackTrace) {
        // Withdrawing the turn or reporting a failed send would invite a second
        // one beside the op that is still queued; a later drain sends it.
        DebugLogger.error(
          'comparison-drain-failed',
          scope: 'chat/comparison',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    return handles;
  } catch (_) {
    if (!committed) withdrawOptimisticTurn();
    rethrow;
  } finally {
    await databaseLease?.release();
  }
}

Map<String, dynamic> _durableComparisonAssistantPayload({
  required ComparisonSlotSnapshot slot,
  required String parentId,
  required String modelName,
  required int timestamp,
}) => <String, dynamic>{
  ..._durableAssistantPayload(
    id: slot.assistantMessageId,
    parentId: parentId,
    modelId: slot.model,
    modelName: modelName,
    timestamp: timestamp,
  ),
  // The column is what keeps two runs of one model apart, here and upstream.
  kMessageModelIdxMetadataKey: slot.modelIdx,
};

Map<String, dynamic> _buildDurableComparisonChatBlob({
  required String userMsgId,
  required String? parentId,
  required String text,
  required List<Map<String, dynamic>> files,
  required List<ComparisonSlotSnapshot> slots,
  required List<String> modelNames,
  required int now,
  Map<String, dynamic> chatParams = const <String, dynamic>{},
}) {
  final assistantIds = [for (final slot in slots) slot.assistantMessageId];
  final modelIds = [for (final slot in slots) slot.model];
  return <String, dynamic>{
    'title': _titleFromText(text),
    'models': modelIds,
    if (chatParams.isNotEmpty) 'params': chatParams,
    'history': <String, dynamic>{
      'currentId': assistantIds.first,
      'messages': <String, dynamic>{
        userMsgId: <String, dynamic>{
          'id': userMsgId,
          'parentId': parentId,
          'childrenIds': assistantIds,
          'role': 'user',
          'content': text,
          'files': files,
          'models': modelIds,
          'timestamp': now,
        },
        for (var index = 0; index < slots.length; index++)
          slots[index].assistantMessageId: _durableComparisonAssistantPayload(
            slot: slots[index],
            parentId: userMsgId,
            modelName: modelNames[index],
            timestamp: now,
          ),
      },
    },
  };
}

// ---------------------------------------------------------------------------
// Replay
// ---------------------------------------------------------------------------

const String _comparisonUnsupportedServerError =
    'This server answered with a single response, so it cannot compare '
    'models. Only the first model replied.';

const String _comparisonNoTaskError =
    'The server did not start this model. Try the comparison again.';

/// Runs an admitted comparison as ONE completion request and binds each answer.
///
/// [live] drives the transcript the user is looking at, streaming every answer
/// into its own message. Otherwise the server runs the answers to completion and
/// they are pulled into the local database, as for a single answer the user
/// has navigated away from. Either way the request is sent once: the first
/// accepted response marks every slot submitted, and any later run of the same
/// op recovers by pull alone.
Future<void> runComparisonCompletion(
  dynamic ref, {
  required String chatId,
  required ComparisonGroupSnapshot group,
  required List<ChatMessage> messages,
  required Conversation? conversation,
  required bool live,
  List<String> toolIds = const <String>[],
  List<String> filterIds = const <String>[],
  String? terminalId,
  bool enableWebSearch = false,
  bool enableImageGeneration = false,
  bool enableCodeInterpreter = false,
  bool isVoiceMode = false,
  String? sessionIdOverride,
  OpenWebUiCompletionOwner? completionOwner,
  OpenWebUiChatSettingsSnapshot? chatSettings,
  int recoveryAttempts = 6,
  Duration recoveryDelay = const Duration(seconds: 2),
}) async {
  final api = ref.read(apiServiceProvider);
  if (api == null) {
    throw StateError('runComparisonCompletion requires an API service');
  }
  final slots = group.slots;
  final primary = slots.first;
  final slotIds = [for (final slot in slots) slot.assistantMessageId];
  final owner =
      completionOwner ??
      captureOpenWebUiCompletionOwner(ref, chatId: chatId, api: api);
  void requireOwner() {
    if (live) {
      final activeChatId = activeOpenWebUiChatIdForMutation(ref, owner);
      if (activeChatId == null) {
        throw _QueuedCompletionDeferred(
          'runComparisonCompletion: chat $chatId is not active',
        );
      }
      owner.chatId = activeChatId;
      return;
    }
    if (!openWebUiCompletionContextIsCurrent(ref, owner)) {
      throw _QueuedCompletionDeferred(
        'runComparisonCompletion: backend changed for $chatId',
      );
    }
  }

  requireOwner();
  if (isTemporaryChat(chatId)) return;

  Map<String, dynamic>? userSettingsData;
  String? userSystemPrompt;
  try {
    userSettingsData = await api.getUserSettings();
    userSystemPrompt = _extractSystemPromptFromSettings(userSettingsData);
  } catch (_) {}
  requireOwner();
  _rememberOpenWebUiUserSettings(
    ref,
    _openWebUiSettingsOwnerKey(ref, api),
    userSettingsData,
  );

  // A group admitted with the interpreter is sent only while the server still
  // runs it for every one of its models; one that cannot refuses the whole turn.
  if (enableCodeInterpreter) {
    for (final modelId in {for (final slot in slots) slot.model}) {
      final unsupported = await _recheckCodeInterpreterForCompletion(
        ref,
        api: api,
        requireCurrentOwner: requireOwner,
        modelId: modelId,
        terminalId: terminalId,
      );
      if (unsupported != null) {
        await _rejectUnsupportedComparisonInterpreter(
          ref,
          owner: owner,
          slotIds: slotIds,
          reason: unsupported,
          live: live,
        );
      }
    }
  }

  final turnSettings = await _resolveOpenWebUiTurnSettings(
    owner,
    conversation: conversation,
    snapshot: chatSettings,
    pickerReasoningEffort: null,
  );
  requireOwner();

  final toolIdsForApi = _extractToolIdsForApi(toolIds);
  // The history the server sees ends at the user message: the answers being
  // requested are not part of it.
  final history = [
    for (final message in messages)
      if (!slotIds.contains(message.id)) message,
  ];
  final requestMessages = await _buildCompletionRequestMessages(
    api: api,
    messages: history,
    chatParams: turnSettings.chatParams,
    baseline: turnSettings.baseline,
    conversationSystemPrompt: conversation?.systemPrompt,
    userSystemPrompt: userSystemPrompt,
    isTemporary: false,
  );
  requireOwner();

  if (live) {
    final notifier =
        ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier;
    for (final slot in slots) {
      notifier.updateMessageById(slot.assistantMessageId, (message) {
        if (message.isStreaming) return message;
        return message.copyWith(
          isStreaming: true,
          metadata: notifier._metadataWithoutResponseDone(message.metadata),
        );
      });
    }
  }

  final visibleModels =
      (ref.read(modelsProvider) as AsyncValue<List<Model>>).asData?.value ??
      const <Model>[];
  Model? modelFor(String id) =>
      visibleModels.where((model) => model.id == id).firstOrNull;
  Map<String, dynamic> modelItemFor(String id) {
    final model = modelFor(id);
    return model != null
        ? _buildLocalModelItem(model)
        : <String, dynamic>{'id': id, 'name': id};
  }

  final socketService = _readOpenWebUiSocketForApi(ref, api);
  final socketSessionId =
      sessionIdOverride ?? await _ensureConnectedSocketSessionId(socketService);
  requireOwner();
  if (socketSessionId == null || socketSessionId.isEmpty) {
    // Several answers arrive only as socket tasks. Without a connection the
    // server would answer one model synchronously, which is not a comparison;
    // nothing has been sent, so a later drain may try again.
    await _refuseComparison(
      ref,
      owner: owner,
      slotIds: slotIds,
      error: 'Comparing models needs a live connection to the server.',
      live: live,
    );
    throw const _QueuedCompletionDeferred(
      'comparison needs a connected socket session',
    );
  }

  List<Map<String, dynamic>>? toolServers;
  final admittedToolServers = <PersonalToolAdmission>[];
  try {
    toolServers = await _resolveToolServersForRequest(
      api: api,
      userSettings: userSettingsData,
      selectedToolIds: toolIds,
      admitted: admittedToolServers,
    );
  } catch (_) {}
  requireOwner();

  final bgTasks = _buildOpenWebUiBackgroundTasks(
    userSettings: userSettingsData,
    shouldGenerateTitle: _shouldGenerateQueuedTitle(
      messages,
      assistantMessageId: primary.assistantMessageId,
      isTemporary: false,
    ),
    webSearchEnabled: enableWebSearch,
    imageGenerationEnabled: enableImageGeneration,
  );
  final isBackgroundFlow =
      toolIdsForApi.isNotEmpty ||
      terminalId != null ||
      (toolServers != null && toolServers.isNotEmpty) ||
      enableWebSearch ||
      enableImageGeneration ||
      enableCodeInterpreter ||
      bgTasks.isNotEmpty;

  Map<String, dynamic>? promptVars;
  Map<String, dynamic>? userMessageMap;
  try {
    promptVars = await _buildOpenWebUiPromptVariablesForRequest(
      ref,
      now: DateTime.now(),
      userSettings: userSettingsData,
    );
  } catch (_) {}
  try {
    userMessageMap = _buildOpenWebUiUserMessage(
      messages: messages,
      userMessageId: group.userMessageId,
      modelId: primary.model,
      assistantChildMessageId: primary.assistantMessageId,
    );
  } catch (_) {}
  requireOwner();
  if (userMessageMap != null) {
    // The server stores this message as the parent of every answer, so it must
    // name all of them and every model that was asked.
    userMessageMap['childrenIds'] = slotIds;
    userMessageMap['models'] = [for (final slot in slots) slot.model];
  }

  final bufferedChatId = owner.chatId;
  for (final id in slotIds) {
    socketService?.startBuffering(
      bufferedChatId,
      sessionId: socketSessionId,
      messageId: id,
    );
  }

  try {
    for (final id in slotIds) {
      _admitPersonalToolServers(
        socketService,
        sessionId: socketSessionId,
        chatId: owner.chatId,
        messageId: id,
        admitted: admittedToolServers,
      );
    }
    final session = await api.sendMessageSession(
      messages: requestMessages,
      model: primary.model,
      conversationId: owner.chatId,
      terminalId: terminalId,
      toolIds: toolIdsForApi.isNotEmpty ? toolIdsForApi : null,
      filterIds: filterIds.isNotEmpty ? filterIds : null,
      enableWebSearch: enableWebSearch,
      enableImageGeneration: enableImageGeneration,
      enableCodeInterpreter: enableCodeInterpreter,
      isVoiceMode: isVoiceMode,
      modelItem: modelItemFor(primary.model),
      sessionIdOverride: socketSessionId,
      toolServers: toolServers,
      backgroundTasks: bgTasks,
      responseMessageId: primary.assistantMessageId,
      userSettings: userSettingsData,
      globalParams: turnSettings.baseline?.globalParams,
      chatParams: turnSettings.chatParams,
      reasoningEffort: turnSettings.reasoningEffort,
      parentId: userMessageMap?['parentId']?.toString(),
      userMessage: userMessageMap,
      variables: promptVars,
      files: _extractTopLevelRequestFiles(userMessageMap),
      messageIds: comparisonTargets(group),
    );
    final completed = await _markComparisonAcceptedOrAbort(
      ref,
      session: session,
      api: api,
      owner: owner,
      slotIds: slotIds,
    );
    owner.chatId = await resolveOpenWebUiCompletionChatId(
      ref,
      owner: owner,
      assistantMessageId: primary.assistantMessageId,
    );

    // The server's task list names each answer by position; nothing else in
    // the response does. A server that answered synchronously, or listed fewer
    // tasks than answers, leaves the unbound answers explained, not retried.
    // An answer the server finished before this receipt arrived has nothing
    // left to bind or explain, whatever its task.
    final isTaskSession =
        session.transport == ChatCompletionTransport.taskSocket;
    final taskBySlot = isTaskSession
        ? comparisonTaskIdsBySlot(group, session.taskIds)
        : const <String, String>{};
    final unbound = <String, String>{
      for (final slot in slots)
        if (!completed.contains(slot.assistantMessageId) &&
            (isTaskSession
                ? !taskBySlot.containsKey(slot.assistantMessageId)
                : slot != primary))
          slot.assistantMessageId: isTaskSession
              ? _comparisonNoTaskError
              : _comparisonUnsupportedServerError,
    };
    if (unbound.isNotEmpty) {
      await _settleUnboundComparisonSlots(
        ref,
        owner: owner,
        unbound: unbound,
        live: live,
      );
    }
    final bound = [
      for (final slot in slots)
        if (!unbound.containsKey(slot.assistantMessageId) &&
            !completed.contains(slot.assistantMessageId))
          slot,
    ];

    if (!isTaskSession) {
      // One accepted synchronous response belongs to the primary answer; keep
      // it through the ordinary single-answer path rather than discarding it.
      await _finishComparisonSlotsHeadlessly(
        ref,
        session: session,
        owner: owner,
        slotIds: [primary.assistantMessageId],
        recoveryAttempts: recoveryAttempts,
        recoveryDelay: recoveryDelay,
      );
      return;
    }

    final activeOwnerChatId = live
        ? activeOpenWebUiChatIdForMutation(ref, owner)
        : null;
    if (!live || activeOwnerChatId == null) {
      await _finishComparisonSlotsHeadlessly(
        ref,
        session: session,
        owner: owner,
        slotIds: [for (final slot in bound) slot.assistantMessageId],
        recoveryAttempts: recoveryAttempts,
        recoveryDelay: recoveryDelay,
      );
      return;
    }
    owner.chatId = activeOwnerChatId;

    final detached = <String>[];
    for (final slot in bound) {
      final slotSession = ChatCompletionSession.taskSocket(
        messageId: slot.assistantMessageId,
        sessionId: session.sessionId,
        conversationId: session.conversationId,
        taskId: taskBySlot[slot.assistantMessageId]!,
      );
      final attached = await dispatchChatTransport(
        ref: ref,
        session: slotSession,
        assistantMessageId: slot.assistantMessageId,
        modelId: slot.model,
        modelItem: modelItemFor(slot.model),
        activeConversationId: owner.chatId,
        api: api,
        socketService: socketService,
        workerManager: ref.read(workerManagerProvider),
        webSearchEnabled: enableWebSearch,
        imageGenerationEnabled: enableImageGeneration,
        isBackgroundFlow: isBackgroundFlow,
        modelUsesReasoning: _modelUsesReasoning(slot.model),
        toolsEnabled:
            toolIdsForApi.isNotEmpty ||
            terminalId != null ||
            (toolServers != null && toolServers.isNotEmpty) ||
            enableImageGeneration ||
            enableCodeInterpreter,
        isTemporary: false,
        filterIds: filterIds.isNotEmpty ? filterIds : null,
        ownsActiveConversation: () =>
            activeOpenWebUiChatIdForMutation(ref, owner) != null,
        slotMessageId: slot.assistantMessageId,
        slotSiblingIds: [
          for (final id in slotIds)
            if (id != slot.assistantMessageId) id,
        ],
      );
      if (!attached) detached.add(slot.assistantMessageId);
    }
    if (detached.isNotEmpty) {
      await _finishComparisonSlotsHeadlessly(
        ref,
        session: session,
        owner: owner,
        slotIds: detached,
        recoveryAttempts: recoveryAttempts,
        recoveryDelay: recoveryDelay,
      );
    }
  } finally {
    for (final id in slotIds) {
      socketService?.stopBuffering(
        bufferedChatId,
        sessionId: socketSessionId,
        messageId: id,
      );
    }
  }
}

/// Marks every answer of an accepted group as submitted, before anything is
/// drained, so a later run of the same op recovers by pull and never re-sends.
/// If a marker cannot be written the accepted tasks are stopped instead: an
/// unmarked group could be sent a second time.
///
/// Returns the answers the server had already finished, by its own `done: true`,
/// when the receipt arrived. The marker would rewrite such a row as streaming,
/// so they are left as they are: a finished row already tells a replay that the
/// request was accepted. Nothing is left to bind or stop for them.
Future<Set<String>> _markComparisonAcceptedOrAbort(
  dynamic ref, {
  required ChatCompletionSession session,
  required ApiService api,
  required OpenWebUiCompletionOwner owner,
  required List<String> slotIds,
}) async {
  final completed = <String>{};
  try {
    for (final id in slotIds) {
      if (await _comparisonAnswerCompletedByServer(owner, id)) {
        completed.add(id);
        continue;
      }
      await beginOpenWebUiCompletionSubmission(
        ref,
        owner: owner,
        assistantMessageId: id,
      );
    }
  } catch (_) {
    await _abortQuietly(session);
    for (final taskId in session.taskIds) {
      try {
        await api.stopTask(taskId);
      } catch (_) {}
    }
    rethrow;
  }
  return completed;
}

/// Whether the stored copy of the answer carries the server's own `done: true`.
/// Text alone is not completion, and a row refused before it was sent settles
/// with `done` too, though nothing was ever accepted for it. A row that cannot
/// be read is not taken to be finished.
Future<bool> _comparisonAnswerCompletedByServer(
  OpenWebUiCompletionOwner owner,
  String assistantMessageId,
) async {
  try {
    final row = await owner.database?.messagesDao.getMessage(
      owner.chatId,
      assistantMessageId,
    );
    if (row == null) return false;
    final payload = jsonDecode(row.payload);
    if (payload is! Map || payload['done'] != true) return false;
    final metadata = payload['metadata'];
    return !(metadata is Map &&
        metadata['completionRefused'] == true &&
        metadata['responseDone'] != true);
  } catch (_) {
    return false;
  }
}

/// Settles answers the server did not start, with the reason, without sending
/// anything again.
Future<void> _settleUnboundComparisonSlots(
  dynamic ref, {
  required OpenWebUiCompletionOwner owner,
  required Map<String, String> unbound,
  required bool live,
}) async {
  final notifier =
      ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier;
  final locks = ref.read(chatLocksProvider) as ChatLocks;
  for (final entry in unbound.entries) {
    if (live) {
      notifier.updateMessageById(
        entry.key,
        (message) => message.copyWith(
          isStreaming: false,
          error: ChatMessageError(content: entry.value),
        ),
      );
    }
    try {
      await locks.runExclusive(owner.chatId, () async {
        await owner.database?.messagesDao.markAssistantCompletionRecoveryFailed(
          chatId: owner.chatId,
          messageId: entry.key,
          error: entry.value,
        );
      });
    } catch (error, stackTrace) {
      DebugLogger.error(
        'comparison-unbound-marker-failed',
        scope: 'chat/completion',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}

Future<void> _refuseComparison(
  dynamic ref, {
  required OpenWebUiCompletionOwner owner,
  required List<String> slotIds,
  required String error,
  required bool live,
}) async {
  final notifier =
      ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier;
  final locks = ref.read(chatLocksProvider) as ChatLocks;
  for (final id in slotIds) {
    if (live) {
      notifier.updateMessageById(
        id,
        (message) => message.copyWith(
          isStreaming: false,
          error: ChatMessageError(content: error),
        ),
      );
    }
    try {
      await locks.runExclusive(owner.chatId, () async {
        await owner.database?.messagesDao.markAssistantCompletionRefused(
          chatId: owner.chatId,
          messageId: id,
          error: error,
        );
      });
    } catch (cause, stackTrace) {
      DebugLogger.error(
        'comparison-refusal-marker-failed',
        scope: 'chat/completion',
        error: cause,
        stackTrace: stackTrace,
      );
    }
  }
}

Future<Never> _rejectUnsupportedComparisonInterpreter(
  dynamic ref, {
  required OpenWebUiCompletionOwner owner,
  required List<String> slotIds,
  required CodeInterpreterBlock reason,
  required bool live,
}) async {
  final error = CodeInterpreterUnavailableException(reason);
  await _refuseComparison(
    ref,
    owner: owner,
    slotIds: slotIds,
    error: chatErrorContentForException(error),
    live: live,
  );
  throw SyncTerminalException(message: error.toString());
}

/// Drains an accepted session and pulls the chat until every one of [slotIds]
/// has landed; an answer that never does is settled with an explicit error
/// rather than left as a silent empty bubble.
Future<void> _finishComparisonSlotsHeadlessly(
  dynamic ref, {
  required ChatCompletionSession session,
  required OpenWebUiCompletionOwner owner,
  required List<String> slotIds,
  int recoveryAttempts = 6,
  Duration recoveryDelay = const Duration(seconds: 2),
}) async {
  final byteStream = session.byteStream;
  if (byteStream != null) {
    try {
      await byteStream.drain<void>().timeout(_headlessStreamDrainTimeout);
    } catch (_) {
      // A stream that fails or stalls ends here; the pull below settles every
      // answer that did not land.
      await _abortQuietly(session);
    }
  }
  await recoverSubmittedOpenWebUiComparison(
    ref,
    owner: owner,
    assistantMessageIds: slotIds,
    recoveryAttempts: recoveryAttempts,
    recoveryDelay: recoveryDelay,
  );
}

/// Pull-only recovery for an accepted comparison, found by an outbox retry or
/// left over when the foreground lost the chat. Waits for EVERY expected answer,
/// not just the first to land, and settles each one that never arrives.
Future<void> recoverSubmittedOpenWebUiComparison(
  dynamic ref, {
  required OpenWebUiCompletionOwner owner,
  required List<String> assistantMessageIds,
  int recoveryAttempts = 6,
  Duration recoveryDelay = const Duration(seconds: 2),
}) async {
  final missing = await _pullSubmittedOpenWebUiComparison(
    ref,
    owner: owner,
    assistantMessageIds: assistantMessageIds,
    attempts: recoveryAttempts,
    delay: recoveryDelay,
  );
  // The backend changed under us: the next drain owns recovery.
  if (missing == null || missing.isEmpty) return;
  // An answer the bounded wait did not find may simply still be running: a
  // short polling window is not the server saying it failed. While the server
  // lists tasks for the chat the answers stay as they are, keeping their
  // accepted markers, for a later pull to collect.
  if (await _serverStillRunsTasks(owner)) return;
  // The list was read for the session that asked; if another account has
  // signed in since, its answer says nothing about this work.
  for (final id in missing) {
    if (!openWebUiCompletionContextIsCurrent(ref, owner)) return;
    await _markHeadlessCompletionRecoveryFailed(
      ref,
      owner: owner,
      assistantMessageId: id,
    );
  }
}

/// Whether the server still reports a running task for the owner's chat. A
/// server that cannot say is taken to have none, as recovery always has.
Future<bool> _serverStillRunsTasks(OpenWebUiCompletionOwner owner) async {
  final api = owner.api;
  if (api is! ApiService) return false;
  try {
    return (await api.getTaskIdsByChat(owner.chatId)).isNotEmpty;
  } catch (_) {
    return false;
  }
}

/// Whether the stored alternative holds an answer, or the reason it has none.
bool _comparisonVersionLanded(ChatMessageVersion version) =>
    version.content.trim().isNotEmpty ||
    version.output?.isNotEmpty == true ||
    version.error != null ||
    version.files?.isNotEmpty == true;

/// The ids of [assistantMessageIds] that had not landed after the bounded
/// wait; empty when all did; null when the backend changed.
Future<List<String>?> _pullSubmittedOpenWebUiComparison(
  dynamic ref, {
  required OpenWebUiCompletionOwner owner,
  required List<String> assistantMessageIds,
  required int attempts,
  required Duration delay,
}) async {
  final chatId = owner.chatId;
  if (!openWebUiCompletionContextIsCurrent(ref, owner)) return null;
  final engine = ref.read(syncEngineProvider.notifier);
  var waiting = List<String>.of(assistantMessageIds);
  for (var attempt = 0; attempt < attempts && waiting.isNotEmpty; attempt++) {
    if (attempt > 0) {
      await Future<void>.delayed(delay);
    }
    if (!openWebUiCompletionContextIsCurrent(ref, owner)) return null;
    Conversation? conversation;
    try {
      conversation = await engine.pullChatNow(chatId);
      if (!openWebUiCompletionContextIsCurrent(ref, owner)) return null;
    } catch (error, stackTrace) {
      DebugLogger.error(
        'comparison-pull-failed',
        scope: 'chat/completion',
        error: error,
        stackTrace: stackTrace,
        data: {'chatId': chatId, 'attempt': attempt},
      );
      continue;
    }
    if (conversation == null) continue;
    // Every answer of the turn, whichever one is the chat's current branch:
    // the pulled messages hold the current one, its siblings sit in versions.
    final landed = <String>{};
    for (final message in conversation.messages) {
      if (_headlessAssistantLanded(message)) landed.add(message.id);
      for (final version in message.versions) {
        if (_comparisonVersionLanded(version)) landed.add(version.id);
      }
    }
    waiting = [
      for (final id in waiting)
        if (!landed.contains(id)) id,
    ];
  }
  return waiting;
}

// ---------------------------------------------------------------------------
// Per-answer control
// ---------------------------------------------------------------------------

/// What [stopComparisonAnswer] did.
enum ComparisonAnswerStop {
  /// The server stopped the answer's task and the answer settled.
  stopped,

  /// The server refused or could not stop the task. The answer is unchanged.
  refused,

  /// Nothing was asked of the server or changed: the account may not stop one
  /// task, the answer is not running, or the account or answer it belonged to
  /// changed while the server was answering.
  ignored,
}

/// Whether this account may stop ONE task. Open WebUI 0.11.4 routes
/// `/api/tasks/stop/{task_id}` through its admin check (answering a regular user
/// 401); only the whole-chat stop is open to every account. No signed-in user
/// is no admin.
final comparisonAnswerStopPermittedProvider = Provider<bool>((ref) {
  return ref.watch(currentUserProvider2)?.role == 'admin';
});

/// Stops ONE answer of a comparison and leaves its siblings running.
///
/// The server's task for the answer is stopped by its own id (kept in the
/// answer's metadata when the request was accepted); the whole-chat stop is a
/// different control and covers every task. The answer settles only once the
/// server has acknowledged the stop, and whatever it had streamed so far stays
/// on screen. A stop the server refuses leaves the answer running.
Future<ComparisonAnswerStop> stopComparisonAnswer(
  dynamic ref,
  String assistantMessageId,
) async {
  if (ref.read(comparisonAnswerStopPermittedProvider) != true) {
    return ComparisonAnswerStop.ignored;
  }
  final notifier =
      ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier;
  ChatMessage? running() =>
      (ref.read(chatMessagesProvider) as List<ChatMessage>)
          .where((candidate) => candidate.id == assistantMessageId)
          .firstOrNull;
  final message = running();
  if (message == null || !message.isStreaming) {
    return ComparisonAnswerStop.ignored;
  }
  final taskId = message.metadata?['taskId']?.toString();
  final api = ref.read(apiServiceProvider);
  if (api == null || taskId == null || taskId.isEmpty) {
    return ComparisonAnswerStop.ignored;
  }
  final userId = (ref.read(currentUserProvider2) as User?)?.id;
  final authEpoch = ref.read(openWebUiAuthSessionEpochProvider);
  var acknowledged = true;
  try {
    await api.stopTask(taskId);
  } catch (_) {
    acknowledged = false;
  }
  // The answer is still this one only for the sign-in and server that asked
  // (the same account signing back in is another sign-in), and while it still
  // runs under the task that was stopped.
  final current = running();
  if (!identical(ref.read(apiServiceProvider), api) ||
      !identical(authEpoch, ref.read(openWebUiAuthSessionEpochProvider)) ||
      (ref.read(currentUserProvider2) as User?)?.id != userId ||
      current == null ||
      !current.isStreaming ||
      current.metadata?['taskId']?.toString() != taskId) {
    return ComparisonAnswerStop.ignored;
  }
  if (!acknowledged) return ComparisonAnswerStop.refused;
  // The server keeps the stopped answer as its last running checkpoint, so it
  // is stored as finished before the caller goes on to a sibling or next turn.
  // What this reports is the server's acknowledgement; a failed local write is
  // logged.
  await notifier.settleStoppedSlotMessages([assistantMessageId]);
  return ComparisonAnswerStop.stopped;
}

final stopComparisonAnswerProvider =
    Provider<Future<ComparisonAnswerStop> Function(String)>((ref) {
      return (assistantMessageId) =>
          stopComparisonAnswer(ref, assistantMessageId);
    });

// ---------------------------------------------------------------------------
// Merge
// ---------------------------------------------------------------------------

enum ComparisonMergeFailure {
  /// The answers cannot be merged here: not a durable Open WebUI chat, fewer
  /// than two answers, or an answer that has no text yet.
  notMergeable,

  /// A merge is already running.
  busy,

  /// The server has no merge endpoint. Nothing was generated.
  unavailable,

  /// The account, server or chat changed while merging. Nothing was written.
  ownerChanged,

  /// The server failed or refused the merge. The answers are unchanged.
  failed,
}

/// Why a merge did not complete. The answers it was made from are never touched
/// by it, whatever the reason: no source answer becomes failed.
final class ComparisonMergeException implements Exception {
  const ComparisonMergeException(this.reason, {this.message});

  final ComparisonMergeFailure reason;
  final String? message;

  @override
  String toString() => 'ComparisonMergeException(${reason.name}, $message)';
}

/// Whether the composer's chat offers "Merge responses" right now. Advanced
/// gates only this new command: a merge already saved on an answer is shown
/// whatever the setting is, and a merge in progress keeps its stop control.
final comparisonMergeCommandAvailableProvider = Provider<bool>((ref) {
  if (!ref.watch(
    appSettingsProvider.select((settings) => settings.advancedFeaturesEnabled),
  )) {
    return false;
  }
  final active = ref.watch(activeConversationProvider);
  return ref.watch(apiServiceProvider) != null &&
      ref.watch(appDatabaseProvider) != null &&
      ref.watch(isAuthenticatedProvider2) &&
      !ref.watch(reviewerModeProvider) &&
      active != null &&
      !isTemporaryChat(active.id) &&
      conversationUsesOpenWebUiStorage(active) &&
      ref.watch(comparisonMergeProvider) == null;
});

/// The answer a merge is currently writing into, or null when none is running.
final comparisonMergeProvider =
    NotifierProvider<ComparisonMergeController, String?>(
      ComparisonMergeController.new,
    );

/// Merges the answers of one comparison turn into a single response, saved on
/// the answer the user chose, in Open WebUI's own `merged` field.
class ComparisonMergeController extends Notifier<String?> {
  Future<void> Function()? _cancelRequest;
  bool _cancelled = false;

  @override
  String? build() => null;

  /// Stops the running merge. Text that already arrived is kept.
  Future<void> cancel() async {
    _cancelled = true;
    await _cancelRequest?.call();
  }

  /// Merges [responses] (the turn's answers in slot order) and saves the result
  /// on [targetMessageId]. [displayedMessageId] is the transcript message that
  /// holds the target answer, either as itself or as a stored alternative.
  Future<void> merge({
    required String targetMessageId,
    required String displayedMessageId,
    required String parentMessageId,
    required String model,
    required List<String> responses,
  }) async {
    if (state != null) {
      throw const ComparisonMergeException(ComparisonMergeFailure.busy);
    }
    final texts = [for (final text in responses) text.trim()];
    final active = ref.read(activeConversationProvider);
    final database = _readAppDatabaseOrNull(ref);
    final api = ref.read(apiServiceProvider);
    if (texts.length < 2 ||
        texts.any((text) => text.isEmpty) ||
        model.trim().isEmpty ||
        active == null ||
        isTemporaryChat(active.id) ||
        !conversationUsesOpenWebUiStorage(active) ||
        database == null ||
        api is! ApiService) {
      throw const ComparisonMergeException(ComparisonMergeFailure.notMergeable);
    }
    // The server, account and chat this merge belongs to, fixed now.
    final owner = captureOpenWebUiCompletionOwner(
      ref,
      chatId: active.id,
      database: database,
      api: api,
    );
    final authSnapshot = api.captureAuthSnapshot();
    bool ownsContext() => openWebUiCompletionContextIsCurrent(ref, owner);

    // Another account's chat is read-only whichever surface asked. The stored
    // row names its owner, which a cached copy on screen may not carry.
    final currentUserId = ref.read(currentUserProvider2)?.id;
    final storedOwner = (await database.chatsDao.getChat(active.id))?.userId;
    if (isReadOnlySharedConversation(active, currentUserId) ||
        (storedOwner != null && storedOwner != currentUserId)) {
      throw const ComparisonMergeException(ComparisonMergeFailure.notMergeable);
    }

    final prompt = await _mergePrompt(owner, parentMessageId);
    if (!ownsContext()) {
      throw const ComparisonMergeException(ComparisonMergeFailure.ownerChanged);
    }

    // The merge the target shows, wherever the transcript keeps it: on the
    // displayed message itself or on one of its stored alternatives.
    Map<String, dynamic>? mergedOf(ChatMessage message) {
      Object? raw;
      if (message.id == targetMessageId) {
        raw = message.metadata?[kMessageMergedMetadataKey];
      } else {
        for (final version in message.versions) {
          if (version.id == targetMessageId) raw = version.merged;
        }
      }
      return raw is Map
          ? <String, dynamic>{
              for (final entry in raw.entries) entry.key.toString(): entry.value,
            }
          : null;
    }

    // What the target showed before this merge, so a merge that produces no
    // text puts it back rather than erasing it.
    final shownBefore = ref
        .read(chatMessagesProvider)
        .where((message) => message.id == displayedMessageId)
        .firstOrNull;
    final previousMerged = shownBefore == null ? null : mergedOf(shownBefore);

    state = targetMessageId;
    _cancelled = false;
    var content = '';
    ComparisonMergeException? failure;

    // [restoring] replaces only the empty placeholder this merge put on screen:
    // a result that landed in its place meanwhile is newer and stays.
    void show(Map<String, dynamic>? merged, {bool restoring = false}) {
      // The transcript only changes while it is still this chat's.
      if (activeOpenWebUiChatIdForMutation(ref, owner) == null) return;
      final notifier = ref.read(chatMessagesProvider.notifier);
      notifier.updateMessageById(displayedMessageId, (message) {
        if (restoring) {
          final current = mergedOf(message);
          if (current == null ||
              current['status'] != true ||
              current['content'] != '') {
            return message;
          }
        }
        if (message.id == targetMessageId) {
          final metadata = Map<String, dynamic>.of(
            message.metadata ?? const <String, dynamic>{},
          );
          if (merged == null) {
            metadata.remove(kMessageMergedMetadataKey);
          } else {
            metadata[kMessageMergedMetadataKey] = merged;
          }
          return message.copyWith(metadata: metadata);
        }
        return message.copyWith(
          versions: [
            for (final version in message.versions)
              version.id == targetMessageId
                  ? version.copyWith(merged: merged)
                  : version,
          ],
        );
      });
    }

    Map<String, dynamic> mergedText(String text) => <String, dynamic>{
      'status': true,
      'content': text,
    };

    try {
      show(mergedText(''));
      final MoaCompletion completion;
      try {
        completion = await api.generateMoaCompletion(
          model: model,
          prompt: prompt,
          responses: texts,
          authSnapshot: authSnapshot,
        );
      } on MoaCompletionUnavailable {
        failure = const ComparisonMergeException(
          ComparisonMergeFailure.unavailable,
        );
        throw failure;
      } on MoaCompletionFailed catch (error) {
        failure = ComparisonMergeException(
          ComparisonMergeFailure.failed,
          message: error.message,
        );
        throw failure;
      }
      _cancelRequest = completion.cancel;
      // The account or chat may have changed, or the user pressed Stop, while
      // the server was still answering with its headers: that response is
      // stopped before any text of it is read.
      if (!ownsContext()) {
        await completion.cancel();
        failure = const ComparisonMergeException(
          ComparisonMergeFailure.ownerChanged,
        );
        throw failure;
      }
      if (_cancelled) {
        await completion.cancel();
        return;
      }
      try {
        await for (final update in completion.updates) {
          if (!ownsContext()) {
            await completion.cancel();
            failure = const ComparisonMergeException(
              ComparisonMergeFailure.ownerChanged,
            );
            throw failure;
          }
          switch (update) {
            case OpenWebUIContentDelta(content: final delta):
              // Open WebUI drops a leading newline before the first text.
              if (content.isEmpty && delta == '\n') continue;
              content += delta;
              show(mergedText(content));
            case OpenWebUIContentSnapshot(content: final snapshot):
              content = snapshot;
              show(mergedText(content));
            case OpenWebUIErrorUpdate(:final error):
              failure = ComparisonMergeException(
                ComparisonMergeFailure.failed,
                message: error['message']?.toString(),
              );
              break;
            case OpenWebUIStreamDone():
              break;
            default:
              continue;
          }
          if (failure != null) break;
          if (update is OpenWebUIStreamDone) break;
        }
      } on ComparisonMergeException {
        rethrow;
      } catch (error) {
        // A stopped request ends its stream with a cancellation; anything else
        // is the merge failing. Either way what arrived is kept.
        if (!_cancelled) {
          failure = ComparisonMergeException(
            ComparisonMergeFailure.failed,
            message: error.toString(),
          );
        }
      }
    } finally {
      _cancelRequest = null;
      state = null;
      // The merge is saved as far as it got, like Open WebUI saves what it has
      // when its stream ends or is stopped. Failing before any text leaves what
      // the answer showed before, not an empty merge and not nothing.
      if (failure?.reason != ComparisonMergeFailure.ownerChanged &&
          ownsContext()) {
        if (content.isNotEmpty) {
          await _saveMerged(owner, database, targetMessageId, content);
        } else {
          show(previousMerged, restoring: true);
        }
      }
    }
    if (failure != null) throw failure;
  }

  Future<String> _mergePrompt(
    OpenWebUiCompletionOwner owner,
    String parentMessageId,
  ) async {
    final loaded = ref
        .read(chatMessagesProvider)
        .where((message) => message.id == parentMessageId)
        .firstOrNull;
    if (loaded != null) return loaded.content;
    final row = await owner.database?.messagesDao.getMessage(
      owner.chatId,
      parentMessageId,
    );
    return row?.content ?? '';
  }

  Future<void> _saveMerged(
    OpenWebUiCompletionOwner owner,
    AppDatabase database,
    String targetMessageId,
    String content,
  ) async {
    // A local chat may have been given its server id while the merge ran.
    final current = activeOpenWebUiChatIdForMutation(ref, owner);
    if (current != null) owner.chatId = current;
    final locks = ref.read(chatLocksProvider);
    final now = ref.read(syncClockProvider).nowEpochSeconds();
    var written = false;
    await locks.runExclusive(owner.chatId, () async {
      // Under the lock, and never for an account that is no longer current.
      if (!openWebUiCompletionContextIsCurrent(ref, owner)) return;
      written = await database.chatsDao.patchMessageMergedWithOutbox(
        owner.chatId,
        targetMessageId,
        merged: <String, dynamic>{'status': true, 'content': content},
        updatedAt: now,
      );
    });
    if (written && openWebUiCompletionContextIsCurrent(ref, owner)) {
      try {
        await ref
            .read(syncEngineProvider.notifier)
            .drainNowForDatabase(database);
      } catch (_) {
        // The saved merge is queued; a later drain pushes it.
      }
    }
  }
}
