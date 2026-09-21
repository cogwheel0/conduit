part of 'chat_providers.dart';

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
  bool isVoiceMode = false,
  String? sessionIdOverride,
  OpenWebUiCompletionOwner? completionOwner,
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

  final owner =
      completionOwner ??
      captureOpenWebUiCompletionOwner(ref, chatId: chatId, api: api);
  void requireActiveOwner() {
    final activeChatId = activeOpenWebUiChatIdForMutation(ref, owner);
    if (activeChatId == null) {
      throw _QueuedCompletionDeferred(
        'runQueuedCompletion: chat $chatId is not active',
      );
    }
    owner.chatId = activeChatId;
  }

  // The caller (runner) activates the chat before driving; a mismatch means
  // the active chat changed under us — let the op retry on a later drain.
  requireActiveOwner();
  final activeConversation = ref.read(activeConversationProvider);

  Map<String, dynamic>? userSettingsData;
  String? userSystemPrompt;
  try {
    userSettingsData = await api.getUserSettings();
    userSystemPrompt = _extractSystemPromptFromSettings(userSettingsData);
  } catch (_) {}
  requireActiveOwner();

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
  requireActiveOwner();

  // Ensure the (already-existing) assistant placeholder is loaded + streaming.
  await _preseedAssistantAndPersist(
    ref,
    existingAssistantId: assistantMessageId,
    modelId: effectiveModelId,
    modelName: effectiveModelName,
  );
  requireActiveOwner();

  final Map<String, dynamic> modelItem =
      (selectedModel != null && selectedModel.id == effectiveModelId)
      ? _buildLocalModelItem(selectedModel)
      : <String, dynamic>{'id': effectiveModelId, 'name': effectiveModelId};

  final socketService = _readOpenWebUiSocketForApi(ref, api);
  final socketSessionId =
      sessionIdOverride ?? await _ensureConnectedSocketSessionId(socketService);
  requireActiveOwner();

  List<Map<String, dynamic>>? toolServers;
  try {
    toolServers = await _resolveToolServersForRequest(
      api: api,
      userSettings: userSettingsData,
      selectedToolIds: toolIds,
    );
  } catch (_) {}
  requireActiveOwner();

  final bgTasks = _buildOpenWebUiBackgroundTasks(
    userSettings: userSettingsData,
    shouldGenerateTitle: _shouldGenerateQueuedTitle(
      messages,
      assistantMessageId: assistantMessageId,
      isTemporary: isTemporary,
    ),
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
  requireActiveOwner();

  final bufferedChatId = owner.chatId;
  socketService?.startBuffering(
    bufferedChatId,
    sessionId: socketSessionId,
    messageId: assistantMessageId,
  );

  try {
    final session = await api.sendMessageSession(
      messages: requestMessages,
      model: effectiveModelId,
      conversationId: owner.chatId,
      terminalId: terminalId,
      toolIds: toolIdsForApi.isNotEmpty ? toolIdsForApi : null,
      filterIds: selectedFilterIds.isNotEmpty ? selectedFilterIds : null,
      enableWebSearch: enableWebSearch,
      enableImageGeneration: enableImageGeneration,
      isVoiceMode: isVoiceMode,
      modelItem: modelItem,
      sessionIdOverride: socketSessionId,
      toolServers: toolServers,
      backgroundTasks: bgTasks,
      responseMessageId: assistantMessageId,
      userSettings: userSettingsData,
      reasoningEffort:
          selectedModel != null && selectedModel.id == effectiveModelId
          ? reasoningEffortForModel(ref.read, selectedModel)
          : null,
      parentId: parentMsgMap?['parentId']?.toString(),
      userMessage: parentMsgMap,
      variables: promptVars2,
      files: _extractTopLevelRequestFiles(parentMsgMap),
    );
    await _markAcceptedOpenWebUiCompletionOrAbort(
      ref,
      session: session,
      owner: owner,
      assistantMessageId: assistantMessageId,
    );

    owner.chatId = await resolveOpenWebUiCompletionChatId(
      ref,
      owner: owner,
      assistantMessageId: assistantMessageId,
    );
    final activeOwnerChatId = activeOpenWebUiChatIdForMutation(ref, owner);
    if (activeOwnerChatId == null) {
      DebugLogger.log(
        'queued-completion-owner-changed-after-submit',
        scope: 'chat/completion',
        data: {
          'chatId': owner.chatId,
          'assistantMessageId': assistantMessageId,
        },
      );
      await _finishSubmittedOpenWebUiCompletionHeadlessly(
        ref,
        session: session,
        owner: owner,
        assistantMessageId: assistantMessageId,
        submissionAlreadyMarked: true,
      );
      return;
    }
    owner.chatId = activeOwnerChatId;

    final modelUsesReasoning = _modelUsesReasoning(effectiveModelId);

    final bool isBackgroundFlow =
        isBackgroundToolsFlowPre ||
        enableWebSearch ||
        enableImageGeneration ||
        bgTasks.isNotEmpty;

    final attached = await dispatchChatTransport(
      ref: ref,
      session: session,
      assistantMessageId: assistantMessageId,
      modelId: effectiveModelId,
      modelItem: modelItem,
      activeConversationId: owner.chatId,
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
      ownsActiveConversation: () =>
          activeOpenWebUiChatIdForMutation(ref, owner) != null,
    );
    if (!attached) {
      await _finishSubmittedOpenWebUiCompletionHeadlessly(
        ref,
        session: session,
        owner: owner,
        assistantMessageId: assistantMessageId,
        submissionAlreadyMarked: true,
      );
    }
  } finally {
    socketService?.stopBuffering(
      bufferedChatId,
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
  bool isVoiceMode = false,
  String? sessionIdOverride,
  OpenWebUiCompletionOwner? completionOwner,
}) async {
  final api = ref.read(apiServiceProvider);
  if (api == null) {
    throw StateError('runHeadlessCompletion requires an API service');
  }
  final owner =
      completionOwner ??
      captureOpenWebUiCompletionOwner(ref, chatId: chatId, api: api);
  void requireCurrentOwner() {
    if (!openWebUiCompletionContextIsCurrent(ref, owner)) {
      throw _QueuedCompletionDeferred(
        'runHeadlessCompletion: backend changed for $chatId',
      );
    }
  }

  requireCurrentOwner();
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
  requireCurrentOwner();

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
  requireCurrentOwner();

  final modelItem =
      (selectedModel != null && selectedModel.id == effectiveModelId)
      ? _buildLocalModelItem(selectedModel)
      : <String, dynamic>{'id': effectiveModelId, 'name': effectiveModelId};

  final socketService = _readOpenWebUiSocketForApi(ref, api);
  final socketSessionId =
      sessionIdOverride ?? await _ensureConnectedSocketSessionId(socketService);
  requireCurrentOwner();

  List<Map<String, dynamic>>? toolServers;
  try {
    toolServers = await _resolveToolServersForRequest(
      api: api,
      userSettings: userSettingsData,
      selectedToolIds: toolIds,
    );
  } catch (_) {}
  requireCurrentOwner();

  final bgTasks = _buildOpenWebUiBackgroundTasks(
    userSettings: userSettingsData,
    shouldGenerateTitle: _shouldGenerateQueuedTitle(
      messages,
      assistantMessageId: assistantMessageId,
      isTemporary: false,
    ),
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
  requireCurrentOwner();
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
    conversationId: owner.chatId,
    terminalId: terminalId,
    toolIds: toolIdsForApi.isNotEmpty ? toolIdsForApi : null,
    filterIds: filterIds.isNotEmpty ? filterIds : null,
    enableWebSearch: enableWebSearch,
    enableImageGeneration: enableImageGeneration,
    isVoiceMode: isVoiceMode,
    modelItem: modelItem,
    sessionIdOverride: socketSessionId,
    toolServers: toolServers,
    backgroundTasks: bgTasks,
    responseMessageId: assistantMessageId,
    userSettings: userSettingsData,
    reasoningEffort:
        selectedModel != null && selectedModel.id == effectiveModelId
        ? reasoningEffortForModel(ref.read, selectedModel)
        : null,
    parentId: parentMsgMap?['parentId']?.toString(),
    userMessage: parentMsgMap,
    variables: promptVars,
    files: _extractTopLevelRequestFiles(parentMsgMap),
  );
  await _markAcceptedOpenWebUiCompletionOrAbort(
    ref,
    session: session,
    owner: owner,
    assistantMessageId: assistantMessageId,
  );

  await _finishSubmittedOpenWebUiCompletionHeadlessly(
    ref,
    session: session,
    owner: owner,
    assistantMessageId: assistantMessageId,
    submissionAlreadyMarked: true,
  );
}

/// Takes ownership of a completion POST that has already been accepted after
/// its foreground conversation stopped owning the global chat providers.
///
/// The distinct submitted marker is written after `sendMessageSession`
/// returns an accepted session and before draining. If the stream then fails,
/// an outbox retry takes the pull-only recovery path instead of issuing a
/// duplicate POST. Recovery exhaustion persists an explicit error; it never
/// turns an empty placeholder into a silent successful response.
Future<void> _finishSubmittedOpenWebUiCompletionHeadlessly(
  dynamic ref, {
  required ChatCompletionSession session,
  required OpenWebUiCompletionOwner owner,
  required String assistantMessageId,
  int recoveryAttempts = 6,
  Duration recoveryDelay = const Duration(seconds: 2),
  bool requireDurableSubmittedMarker = true,
  bool submissionAlreadyMarked = false,
}) async {
  final chatId = owner.chatId;
  final markerPersisted =
      submissionAlreadyMarked ||
      await _markHeadlessCompletionSubmitted(
        ref,
        owner: owner,
        assistantMessageId: assistantMessageId,
      );
  if (!markerPersisted && requireDurableSubmittedMarker) {
    // The request crossed the server boundary, but without a durable marker an
    // outbox retry could POST it again. Abort the owned stream and park this op
    // as terminal rather than accepting duplicate generation.
    await _abortQuietly(session);
    throw const SyncTerminalException(
      statusCode: 500,
      message:
          'Completion was submitted, but its recovery marker could not be '
          'persisted. The request was stopped to prevent a duplicate retry.',
    );
  }

  // Drain the HTTP byte stream to EOF (discarding chunks) so the server runs to
  // completion + persists. The socket/task flow has no byteStream — the server
  // generates it as a background task; the subsequent pull(s) collect it.
  final byteStream = session.byteStream;
  Object? drainFailure;
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
      drainFailure = error;
    } catch (error) {
      DebugLogger.error(
        'headless-stream-drain-failed',
        scope: 'chat/completion',
        error: error,
        data: {'chatId': chatId},
      );
      await _abortQuietly(session);
      drainFailure = error;
    }
  }

  final landed = await _pullSubmittedOpenWebUiCompletion(
    ref,
    owner: owner,
    assistantMessageId: assistantMessageId,
    attempts: recoveryAttempts,
    delay: recoveryDelay,
  );
  if (landed == true) return;
  if (landed == null && drainFailure == null) return;

  await _markHeadlessCompletionRecoveryFailed(
    ref,
    owner: owner,
    assistantMessageId: assistantMessageId,
  );
  DebugLogger.error(
    'headless-completion-recovery-failed',
    scope: 'chat/completion',
    error: drainFailure,
    data: {'chatId': chatId, 'assistantMessageId': assistantMessageId},
  );
}

/// Pull-only recovery for an accepted completion found by an outbox retry.
/// This is intentionally public so [ChatRequestCompletionRunner] can honor the
/// durable submitted marker without issuing a second completion request.
Future<void> recoverSubmittedOpenWebUiCompletion(
  dynamic ref, {
  required OpenWebUiCompletionOwner owner,
  required String assistantMessageId,
  int recoveryAttempts = 6,
  Duration recoveryDelay = const Duration(seconds: 2),
}) async {
  final landed = await _pullSubmittedOpenWebUiCompletion(
    ref,
    owner: owner,
    assistantMessageId: assistantMessageId,
    attempts: recoveryAttempts,
    delay: recoveryDelay,
  );
  if (landed == true) return;
  if (landed == null) return;
  await _markHeadlessCompletionRecoveryFailed(
    ref,
    owner: owner,
    assistantMessageId: assistantMessageId,
  );
}

Future<bool?> _pullSubmittedOpenWebUiCompletion(
  dynamic ref, {
  required OpenWebUiCompletionOwner owner,
  required String assistantMessageId,
  int attempts = 6,
  Duration delay = const Duration(seconds: 2),
}) async {
  final chatId = owner.chatId;
  if (!openWebUiCompletionContextIsCurrent(ref, owner)) {
    DebugLogger.log(
      'headless-completion-pull-deferred-backend-changed',
      scope: 'chat/completion',
      data: {'chatId': chatId, 'assistantMessageId': assistantMessageId},
    );
    return null;
  }
  // Pull the chat (bounded) until the server-persisted assistant reply lands
  // locally. The Phase 3 merge applies it under the chat lock. Both transport
  // flows persist the assistant message ASYNCHRONOUSLY (the server defaults
  // ENABLE_REALTIME_CHAT_SAVE=False, so even after the HTTP byte stream drains
  // to EOF the final upsert can trail the stream close), so BOTH paths poll
  // with a short backoff rather than trusting a single immediate pull. If it
  // still hasn't landed within the window the content is safe on the server and
  // the next sync cycle collects it — this only tightens the latency.
  final engine = ref.read(syncEngineProvider.notifier);
  for (var attempt = 0; attempt < attempts; attempt++) {
    if (!openWebUiCompletionContextIsCurrent(ref, owner)) return null;
    if (attempt > 0) {
      if (!openWebUiCompletionContextIsCurrent(ref, owner)) return null;
      await Future<void>.delayed(delay);
      if (!openWebUiCompletionContextIsCurrent(ref, owner)) return null;
    }
    if (!openWebUiCompletionContextIsCurrent(ref, owner)) return null;
    Conversation? convo;
    try {
      convo = await engine.pullChatNow(chatId);
      if (!openWebUiCompletionContextIsCurrent(ref, owner)) return null;
    } catch (error, stackTrace) {
      DebugLogger.error(
        'headless-completion-pull-failed',
        scope: 'chat/completion',
        error: error,
        stackTrace: stackTrace,
        data: {'chatId': chatId, 'attempt': attempt},
      );
      continue;
    }
    final asst = convo?.messages
        .where((m) => m.id == assistantMessageId)
        .firstOrNull;
    if (asst != null && _headlessAssistantLanded(asst)) {
      DebugLogger.log(
        'headless-completion-landed',
        scope: 'chat/completion',
        data: {'chatId': chatId, 'attempt': attempt},
      );
      return true;
    }
  }
  DebugLogger.log(
    'headless-completion-not-yet-landed',
    scope: 'chat/completion',
    data: {'chatId': chatId},
  );
  return false;
}

@visibleForTesting
Future<void> finishSubmittedOpenWebUiCompletionHeadlesslyForTest(
  dynamic ref, {
  required ChatCompletionSession session,
  required String chatId,
  required String assistantMessageId,
  int recoveryAttempts = 1,
  Duration recoveryDelay = Duration.zero,
  bool requireDurableSubmittedMarker = true,
  bool submissionAlreadyMarked = false,
}) {
  final owner = captureOpenWebUiCompletionOwner(ref, chatId: chatId);
  return _finishSubmittedOpenWebUiCompletionHeadlessly(
    ref,
    session: session,
    owner: owner,
    assistantMessageId: assistantMessageId,
    recoveryAttempts: recoveryAttempts,
    recoveryDelay: recoveryDelay,
    requireDurableSubmittedMarker: requireDurableSubmittedMarker,
    submissionAlreadyMarked: submissionAlreadyMarked,
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

Future<void> _markAcceptedOpenWebUiCompletionOrAbort(
  dynamic ref, {
  required ChatCompletionSession session,
  required OpenWebUiCompletionOwner owner,
  required String assistantMessageId,
}) async {
  try {
    await beginOpenWebUiCompletionSubmission(
      ref,
      owner: owner,
      assistantMessageId: assistantMessageId,
    );
  } catch (_) {
    // The server accepted the request, but without a durable marker a later
    // outbox retry could submit it again. Stop the exact accepted session and
    // preserve the marker failure as the terminal result.
    await _abortQuietly(session);
    rethrow;
  }
}

Future<bool> _markHeadlessCompletionSubmitted(
  dynamic ref, {
  required OpenWebUiCompletionOwner owner,
  required String assistantMessageId,
}) async {
  final chatId = owner.chatId;
  final db = owner.database;
  if (db == null) return false;
  try {
    return await db.messagesDao.markAssistantCompletionSubmitted(
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
    return false;
  }
}

/// Durable accepted-submission marker for replayable OpenWebUI completions.
///
/// Call only after `sendMessageSession` returns. A recreated outbox runner may
/// treat this marker as proof that the POST crossed the server boundary and use
/// pull-only recovery. Failure to persist it is terminal; callers must abort
/// the accepted session to reduce the chance of duplicate generation.
Future<void> beginOpenWebUiCompletionSubmission(
  dynamic ref, {
  required OpenWebUiCompletionOwner owner,
  required String assistantMessageId,
}) async {
  final persisted = await _markHeadlessCompletionSubmitted(
    ref,
    owner: owner,
    assistantMessageId: assistantMessageId,
  );
  if (persisted) return;
  throw const SyncTerminalException(
    statusCode: 500,
    message:
        'Completion was accepted, but its recovery marker could not be '
        'persisted.',
  );
}

const String _headlessCompletionRecoveryError =
    'Conduit could not confirm or recover this response from Open WebUI. '
    'Refresh this chat to try again.';

Future<void> _markHeadlessCompletionRecoveryFailed(
  dynamic ref, {
  required OpenWebUiCompletionOwner owner,
  required String assistantMessageId,
}) async {
  final chatId = owner.chatId;
  final db = owner.database;
  if (db == null) return;
  try {
    await db.messagesDao.markAssistantCompletionRecoveryFailed(
      chatId: chatId,
      messageId: assistantMessageId,
      error: _headlessCompletionRecoveryError,
    );
  } catch (error, stackTrace) {
    DebugLogger.error(
      'headless-completion-recovery-marker-failed',
      scope: 'chat/completion',
      error: error,
      stackTrace: stackTrace,
      data: {'chatId': chatId, 'assistantMessageId': assistantMessageId},
    );
  }
}
