part of 'chat_providers.dart';

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
    // The earlier answer keeps its column and merge, so stepping back to it
    // after a regeneration still lands in the right slot.
    modelIdx: message.metadata?[kMessageModelIdxMetadataKey] is int
        ? message.metadata![kMessageModelIdxMetadataKey] as int
        : null,
    merged: message.metadata?[kMessageMergedMetadataKey] is Map
        ? Map<String, dynamic>.from(
            message.metadata![kMessageMergedMetadataKey] as Map,
          )
        : null,
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

ChatMessage _directRegenerationCompletedBase(ChatMessage message) {
  final isEmptyPlaceholder =
      message.content.isEmpty &&
      message.files?.isNotEmpty != true &&
      message.output?.isNotEmpty != true &&
      message.embeds?.isNotEmpty != true &&
      message.sources.isEmpty &&
      message.statusHistory.isEmpty &&
      message.followUps.isEmpty &&
      message.codeExecutions.isEmpty &&
      message.usage?.isNotEmpty != true &&
      message.error == null;
  if (!message.isStreaming || message.versions.isEmpty || !isEmptyPlaceholder) {
    return message.copyWith(isStreaming: false);
  }
  final completed = message.versions.last;
  final metadata = <String, dynamic>{...?message.metadata};
  final modelName = completed.modelName?.trim();
  if (modelName != null && modelName.isNotEmpty) {
    metadata['modelName'] = modelName;
  }
  return message.copyWith(
    content: completed.content,
    timestamp: completed.timestamp,
    model: completed.model,
    files: completed.files,
    output: completed.output,
    embeds: completed.embeds,
    sources: completed.sources,
    followUps: completed.followUps,
    codeExecutions: completed.codeExecutions,
    usage: completed.usage,
    versions: message.versions.sublist(0, message.versions.length - 1),
    error: completed.error,
    metadata: metadata.isEmpty ? null : metadata,
    isStreaming: false,
  );
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
  Map<String, dynamic>? placeholderMetadata,
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
    ...?placeholderMetadata,
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

String? _extractSystemPromptFromSettings(Map<String, dynamic>? settings) =>
    systemPromptFromSettings(settings);

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

bool _shouldGenerateQueuedTitle(
  List<ChatMessage> messages, {
  required String assistantMessageId,
  required bool isTemporary,
}) {
  if (isTemporary) return false;
  final assistantIndex = messages.indexWhere(
    (message) => message.id == assistantMessageId,
  );
  if (assistantIndex < 0) return false;
  return messages
          .take(assistantIndex)
          .where((message) => message.role == 'user')
          .length ==
      1;
}

/// Exposes [_shouldGenerateQueuedTitle] for focused regression tests.
@visibleForTesting
bool shouldGenerateQueuedTitleForTest(
  List<ChatMessage> messages, {
  required String assistantMessageId,
  required bool isTemporary,
}) {
  return _shouldGenerateQueuedTitle(
    messages,
    assistantMessageId: assistantMessageId,
    isTemporary: isTemporary,
  );
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
    final String? languageTag = ref.read(appLanguageTagProvider);
    if (languageTag != null) {
      userLanguage = languageTag;
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

  return buildOpenWebUiPromptVariables(
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
  bool useModelIdForModels = false,
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
      'models': useModelIdForModels || models.isEmpty
          ? <String>[modelId]
          : models,
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
  return id.startsWith('direct_server:') ||
      id.startsWith(kDirectMcpToolIdPrefix);
}

List<String> _extractToolIdsForApi(Iterable<String> selectedToolIds) {
  return selectedToolIds
      .where((id) => !_isDirectServerToolSelection(id))
      .toList(growable: false);
}

List _extractConfiguredToolServers(Map<String, dynamic>? settings) {
  return effectivePersonalServerList(
    settings,
    PersonalConnectionKind.toolServer.settingsKey,
  );
}

List _extractConfiguredTerminalServers(Map<String, dynamic>? settings) {
  return effectivePersonalServerList(
    settings,
    PersonalConnectionKind.terminal.settingsKey,
  );
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
  // Selections name an entry by key or by position plus fingerprint. Resolve
  // them against the list being sent, so a selection made before the list was
  // reordered or pruned never lands on a different server.
  final selection = resolvePersonalToolSelections(rawServers, selectedToolIds);
  final filtered = <dynamic>[];
  for (final index in selection.matchedIndices) {
    final server = rawServers[index];
    if (server is Map && _isConfiguredServerEnabled(server)) {
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

/// Drops `direct_server:` selections that name no current connection and tells
/// the personal connections screen which ones went, instead of letting a
/// stale position pick up whichever server now sits there.
void _clearUnresolvedPersonalToolSelections(
  dynamic ref,
  List<String> unresolvedIds,
) {
  final current = List<String>.from(ref.read(selectedToolIdsProvider) as List);
  final remaining = current
      .where((id) => !unresolvedIds.contains(id))
      .toList(growable: false);
  if (remaining.length == current.length) return;
  ref.read(selectedToolIdsProvider.notifier).set(remaining);
  ref
      .read(personalSelectionNoticeProvider.notifier)
      .add(unresolvedIds.map(personalToolSelectionLabel));
}

Future<List<Map<String, dynamic>>?> _resolveToolServersForRequest({
  required dynamic api,
  required Map<String, dynamic>? userSettings,
  required List<String> selectedToolIds,
  void Function(List<String> unresolvedIds)? onUnresolvedSelections,
  List<PersonalToolAdmission>? admitted,
}) async {
  final configuredToolServers = _extractConfiguredToolServers(userSettings);
  final unresolved = resolvePersonalToolSelections(
    configuredToolServers,
    selectedToolIds,
  ).unresolvedIds;
  if (unresolved.isNotEmpty) {
    onUnresolvedSelections?.call(unresolved);
  }
  final selectedRawToolServers = _filterSelectedConfiguredToolServers(
    configuredToolServers,
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
    resolved.addAll(
      await _resolveToolServers(
        selectedRawToolServers,
        api,
        admitted: admitted,
      ),
    );
  }
  if (directTerminalServers.isNotEmpty) {
    resolved.addAll(
      await _resolveToolServers(
        directTerminalServers,
        api,
        terminal: true,
        admitted: admitted,
      ),
    );
  }

  return resolved.isEmpty ? null : resolved;
}

/// Builds the chat-completion request `messages` for both the foreground
/// ([runQueuedCompletion]) and headless ([runHeadlessCompletion]) paths:
/// rebuild the live conversation history (skip archived/non-history rows,
/// sanitize content, merge attachment/file/output payloads), prepend the
/// effective system message (chat `params.system`, then the legacy
/// conversation prompt, then the user prompt) when one is absent, then apply
/// [_buildChatCompletionMessages].
Future<List<Map<String, dynamic>>> _buildCompletionRequestMessages({
  required dynamic api,
  required List<ChatMessage> messages,
  required Map<String, dynamic> chatParams,
  required String? conversationSystemPrompt,
  required String? userSystemPrompt,
  required bool isTemporary,
  OpenWebUiAdmittedBaseline? baseline,
}) async {
  final conversationMessages = <Map<String, dynamic>>[];
  for (final msg in messages) {
    if (_isArchivedAssistantVariant(msg)) continue;
    if (!_shouldIncludeConversationHistoryMessage(msg)) continue;
    final cleaned = outboundProviderReplayText(msg);
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

  _insertOpenWebUiSystemMessage(
    conversationMessages,
    chatParams: chatParams,
    legacyChatSystem: conversationSystemPrompt,
    globalSystem: userSystemPrompt,
    baseline: baseline,
  );

  return _buildChatCompletionMessages(
    conversationMessages: conversationMessages,
    isTemporary: isTemporary,
  );
}

@visibleForTesting
Future<List<Map<String, dynamic>>>
buildOpenWebUiCompletionRequestMessagesForTest({
  required List<ChatMessage> messages,
}) => _buildCompletionRequestMessages(
  api: null,
  messages: messages,
  chatParams: const <String, dynamic>{},
  conversationSystemPrompt: null,
  userSystemPrompt: null,
  isTemporary: true,
);

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

/// Stops the Hermes run owned by the visible assistant and clears its session
/// binding before a navigation/reset replaces the message list.
void _observeDetachedCancellation(
  Future<void>? cancellation, {
  required String scope,
}) {
  if (cancellation == null) return;
  unawaited(
    cancellation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {
        // Cancellation is best-effort after registry ownership was revoked.
        // Observe hostile transport cleanup futures so they cannot surface as
        // uncaught zone errors from synchronous UI actions.
        try {
          DebugLogger.error('detached-cancellation-failed', scope: scope);
        } catch (_) {}
      },
    ),
  );
}
