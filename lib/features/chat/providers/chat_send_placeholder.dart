part of 'chat_providers.dart';

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
final class ChatSendPlaceholderHandle {
  ChatSendPlaceholderHandle._({
    this.userMessageId,
    required this.assistantMessageId,
    required ChatMutationOwnerToken mutationOwner,
    String? regenerationAttemptId,
  }) : _ownerConversationId = mutationOwner.ownerConversationId,
       _usesOpenWebUiContext = mutationOwner.usesOpenWebUiContext,
       _openWebUiDatabase = mutationOwner.openWebUiDatabase,
       _openWebUiApi = mutationOwner.openWebUiApi,
       _openWebUiAuthSessionEpoch = mutationOwner.openWebUiAuthSessionEpoch,
       _regenerationAttemptId = regenerationAttemptId;

  /// The optimistic user row that owns this send.
  ///
  /// Regeneration creates only an assistant placeholder, so this is null for
  /// regeneration handles. Normal sends always expose it so the presentation
  /// layer can establish its turn anchor from the exact minted identity rather
  /// than rediscovering it later from streaming metadata.
  final String? userMessageId;
  final String assistantMessageId;
  String? _ownerConversationId;
  final bool _usesOpenWebUiContext;
  final AppDatabase? _openWebUiDatabase;
  final Object? _openWebUiApi;
  final Object? _openWebUiAuthSessionEpoch;
  final String? _regenerationAttemptId;

  void _bindConversation(Conversation conversation) {
    _ownerConversationId = chatMutationOwnerScopeForConversation(conversation);
  }

  void _bindOwnerScope(String ownerConversationId) {
    _ownerConversationId = ownerConversationId;
  }

  void _followOpenWebUiRemap(
    ActiveConversationInPlaceRemap? remap,
    Conversation? active,
  ) {
    if (remap == null ||
        remap.namespace != ActiveConversationRemapNamespace.openWebUi ||
        !remap.matchesOpenWebUiContext(
          database: _openWebUiDatabase,
          api: _openWebUiApi,
          authSessionEpoch: _openWebUiAuthSessionEpoch,
        ) ||
        active == null ||
        active.id != remap.toId) {
      return;
    }
    final owner = _ownerConversationId;
    if (owner == null) return;
    final identity = ChatStorageIdentity.parse(owner);
    if (identity.storage != ChatStorageKind.openWebUi ||
        identity.rawId != remap.fromId) {
      return;
    }
    final rebound = ChatStorageIdentity(
      rawId: remap.toId,
      storage: ChatStorageKind.openWebUi,
    ).scopedId;
    if (chatMutationOwnerScopeForConversation(active) == rebound) {
      _ownerConversationId = rebound;
    }
  }

  bool _owns(dynamic ref, Conversation? conversation) {
    if (_usesOpenWebUiContext &&
        (!identical(_readAppDatabaseOrNull(ref), _openWebUiDatabase) ||
            !identical(_readApiServiceOrNull(ref), _openWebUiApi) ||
            !identical(
              _readOpenWebUiAuthSessionEpoch(ref),
              _openWebUiAuthSessionEpoch,
            ))) {
      return false;
    }
    final owner = _ownerConversationId;
    if (owner == null) return conversation == null;
    return conversation != null &&
        chatMutationOwnerScopeForConversation(conversation) == owner;
  }
}

/// Recovers only the optimistic assistant created by one send. Conversation
/// scope is part of the handle so a late failure cannot target a colliding
/// message id in another backend or database.
void recoverFailedChatSend(
  dynamic ref,
  Object error,
  ChatSendPlaceholderHandle? handle,
) {
  if (handle == null) return;
  final active = ref.read(activeConversationProvider) as Conversation?;
  handle._followOpenWebUiRemap(
    ref.read(activeConversationInPlaceRemapProvider),
    active,
  );
  if (!handle._owns(ref, active)) return;
  final notifier =
      ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier;
  notifier.failLastStreamingAssistant(
    error,
    assistantMessageId: handle.assistantMessageId,
  );
}

@visibleForTesting
ChatSendPlaceholderHandle chatSendPlaceholderHandleForTest({
  required dynamic ref,
  required String assistantMessageId,
  String? userMessageId,
  required Conversation? owner,
}) => ChatSendPlaceholderHandle._(
  userMessageId: userMessageId,
  assistantMessageId: assistantMessageId,
  mutationOwner: captureChatMutationOwner(ref, owner),
);

Future<void> durableSend(
  dynamic ref,
  String message,
  List<String>? attachments, {
  List<String>? toolIds,
  String? pendingFolderIdOverride,
  bool isVoiceMode = false,
  void Function(ChatSendPlaceholderHandle handle)?
  onAssistantPlaceholderCreated,
}) async {
  final activeAtSendStart = ref.read(activeConversationProvider);
  final sendMutationOwner = captureChatMutationOwner(ref, activeAtSendStart);
  if (isTemporaryChat(activeAtSendStart?.id)) {
    await _sendMessageInternal(
      ref,
      message,
      attachments,
      toolIds,
      isVoiceMode,
      pendingFolderIdOverride,
      onAssistantPlaceholderCreated,
    );
    return;
  }

  final db = _readAppDatabaseOrNull(ref);
  final reviewerMode = ref.read(reviewerModeProvider);
  final selectedModel = ref.read(selectedModelProvider);
  final temporary = ref.read(temporaryChatEnabledProvider);
  final trustedDirectBinding = selectedModel == null
      ? null
      : ref.read(directModelRegistryProvider).resolve(selectedModel);
  final hasTrustedDirectBinding = trustedDirectBinding != null;
  final hasDeviceDirectBinding =
      trustedDirectBinding?.source == DirectModelSource.device;

  if (!isModelCompatibleWithConversation(
    conversation: activeAtSendStart,
    hasTrustedDirectBinding: hasDeviceDirectBinding,
  )) {
    throw StateError(
      'On-device direct chats can only continue with a direct connection model.',
    );
  }

  // Hermes agent chats never touch the OpenWebUI outbox/sync engine — route
  // them through the inline path, which dispatches to the Hermes runs transport.
  if (selectedModel != null && isHermesModel(selectedModel)) {
    await _sendMessageInternal(
      ref,
      message,
      attachments,
      toolIds,
      isVoiceMode,
      pendingFolderIdOverride,
      onAssistantPlaceholderCreated,
    );
    return;
  }

  if (hasTrustedDirectBinding) {
    await _sendMessageInternal(
      ref,
      message,
      attachments,
      toolIds,
      isVoiceMode,
      pendingFolderIdOverride,
      onAssistantPlaceholderCreated,
    );
    return;
  }
  if (selectedModel != null && hasReservedDirectIdentity(selectedModel)) {
    throw StateError('The selected direct connection is no longer available.');
  }

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
      onAssistantPlaceholderCreated,
    );
    return;
  }

  final filterIds = selectedFilterIdsForModel(ref, selectedModel);
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
  final durableOptimisticMessages = List<ChatMessage>.unmodifiable(
    ref.read(chatMessagesProvider) as List<ChatMessage>,
  );
  final sendHandle = ChatSendPlaceholderHandle._(
    userMessageId: userMessageId,
    assistantMessageId: assistantMessageId,
    mutationOwner: sendMutationOwner,
  );
  onAssistantPlaceholderCreated?.call(sendHandle);

  final chatLocks = ref.read(chatLocksProvider);
  final attachmentList = attachments ?? const <String>[];
  final toolIdList = toolIds ?? const <String>[];
  final databaseLease = ref.read(databaseManagerProvider).tryAcquireLease(db);
  final capturedSyncEngine = ref.read(syncEngineProvider.notifier);
  final durableContextOwner = captureOpenWebUiCompletionOwner(
    ref,
    chatId: activeAtSendStart?.id ?? '',
    database: db,
    api: sendMutationOwner.openWebUiApi,
  );
  try {
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
    // The completion runner builds the top-level request `files` from the
    // in-memory user message, so the resolved attachments must land there too,
    // not only on the durable rows (issue #729).
    if (durableAttachmentFiles.isNotEmpty) {
      ref
          .read(chatMessagesProvider.notifier)
          .updateMessageById(
            userMessageId,
            (ChatMessage m) => m.copyWith(files: durableFiles),
          );
    }

    final completion = RequestCompletionPayload(
      assistantMessageId: assistantMessageId,
      model: selectedModel.id,
      toolIds: toolIdList,
      filterIds: filterIds,
      terminalId: terminalIdForCompletion,
      enableWebSearch: webSearchEnabled,
      enableImageGeneration: imageGenerationEnabled,
      isVoiceMode: isVoiceMode,
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
        messages: durableOptimisticMessages,
        folderId: pendingFolderId,
      );
      sendHandle._bindConversation(localConversation);
      final stillOwnsEmptyComposer = chatMutationTokenStillActive(
        ref,
        sendMutationOwner,
      );
      if (stillOwnsEmptyComposer) {
        ref.read(activeConversationProvider.notifier).set(localConversation);
        ref.read(pendingFolderIdProvider.notifier).clear();
      }
      activeConversation = localConversation;

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
    if (sendHandle._owns(ref, activeConversation) &&
        identical(ref.read(contextAttachmentsProvider), contextAttachments)) {
      ref.read(contextAttachmentsProvider.notifier).clear();
    }

    // Drive only the database that owns this write. If the user switched
    // server or auth session while attachments/rows were being persisted, its
    // pending outbox remains durable and will drain when that context returns.
    if (openWebUiCompletionContextIsCurrent(ref, durableContextOwner)) {
      await capturedSyncEngine.drainNowForDatabase(db);
    }
  } finally {
    await databaseLease?.release();
  }
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
  List<String> attachments, {
  required Object? sourceApi,
  ApiAuthSnapshot? sourceAuthSnapshot,
  CancelToken? cancelToken,
  _AttachmentTypeMap? capturedContentTypes,
  void Function()? requireSourceContext,
}) async {
  if (attachments.isEmpty) return const [];

  final contentTypes = capturedContentTypes == null
      ? _durableAttachmentContentTypesFromState(ref, attachments)
      : Map<String, String>.from(capturedContentTypes);
  final missingIds = attachments
      .where((id) => !id.startsWith('data:image/'))
      .where((id) => (contentTypes[id] ?? '').isEmpty)
      .toSet();

  final dynamic api = sourceApi;
  if (api != null && missingIds.isNotEmpty) {
    requireSourceContext?.call();
    final fetchedTypes = await Future.wait(
      missingIds.map((id) async {
        try {
          requireSourceContext?.call();
          final raw = api is ApiService
              ? await api.getFileInfo(
                  id,
                  authSnapshot: sourceAuthSnapshot,
                  cancelToken: cancelToken,
                )
              : await api.getFileInfo(id);
          requireSourceContext?.call();
          if (raw is! Map) return null;
          final contentType = _contentTypeFromFileInfo(raw);
          if (contentType.isEmpty) return null;
          return MapEntry(id, contentType);
        } on _DirectOpenWebUiAuthSessionChanged {
          rethrow;
        } catch (_) {
          return null;
        }
      }),
    );
    requireSourceContext?.call();
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
/// Bridges the chat send pipeline to the direct Hermes runs transport, wiring
/// the chat notifier callbacks and resolving multi-turn / memory continuity.
/// Derives a short session title from the first user message.
String _deriveHermesSessionTitle(String input) {
  final trimmed = input.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (trimmed.isEmpty) return 'New Hermes chat';
  return trimmed.length <= 60 ? trimmed : '${trimmed.substring(0, 60)}…';
}
