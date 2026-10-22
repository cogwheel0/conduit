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
/// The voice's own reply to the user's words in a realtime call.
final class ChatVoiceReply {
  const ChatVoiceReply({
    required this.text,
    required this.model,
    required this.voice,
  });

  final String text;

  /// The voice model, which the reply is stored under: Open WebUI tells a
  /// voice's own reply from a chat answer by it.
  final String model;

  /// The reply's `meta.voice`.
  final Map<String, Object?> voice;
}

/// What a realtime call adds to a turn it sends.
final class ChatSendVoiceContext {
  /// The user's words, for the chat's model to answer. [spokenContext] is
  /// the recent spoken conversation, for a backend that reads it with the
  /// turn (Hermes).
  const ChatSendVoiceContext.delegated({
    required this.userVoice,
    this.spokenContext,
  }) : reply = null;

  /// The user's words and the voice's own [reply] to them. The turn is stored
  /// like any other, and no model runs.
  const ChatSendVoiceContext.answered({
    required this.userVoice,
    required ChatVoiceReply this.reply,
  }) : spokenContext = null;

  /// The user message's `meta.voice`.
  final Map<String, Object?> userVoice;
  final ChatVoiceReply? reply;
  final String? spokenContext;
}

/// The user message of a voice turn, marked with where it was said.
ChatMessage _withUserVoice(ChatMessage user, ChatSendVoiceContext? voice) =>
    voice == null
    ? user
    : user.copyWith(
        metadata: <String, dynamic>{
          ...?user.metadata,
          kMessageVoiceMetadataKey: voice.userVoice,
        },
      );

/// The voice's reply as a finished answer, in place of a placeholder.
ChatMessage _voiceReplyMessage(ChatMessage placeholder, ChatVoiceReply reply) =>
    placeholder.copyWith(
      content: reply.text,
      model: reply.model,
      isStreaming: false,
      metadata: <String, dynamic>{
        ...?placeholder.metadata,
        'modelName': reply.model,
        kMessageVoiceMetadataKey: reply.voice,
      },
    );

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

  /// Whether the chat this send went into is the one on screen now, in the
  /// account that sent it. A new chat's local id may have been remapped in
  /// place to its server id since, which still counts; a different chat that
  /// merely shows the same text does not.
  bool ownsActiveChat(dynamic ref) {
    final active = ref.read(activeConversationProvider) as Conversation?;
    _followOpenWebUiRemap(
      ref.read(activeConversationInPlaceRemapProvider),
      active,
    );
    return _owns(ref, active);
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
  if (handle == null || !handle.ownsActiveChat(ref)) return;
  final notifier =
      ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier;
  notifier.failLastStreamingAssistant(
    error,
    assistantMessageId: handle.assistantMessageId,
  );
}

/// Removes the optimistic rows of a send that never committed, for a caller
/// that keeps the content to send again. Marking the assistant failed instead
/// would leave a turn on screen that the retry then sends a second time.
void discardUncommittedChatSend(dynamic ref, ChatSendPlaceholderHandle? handle) {
  if (handle == null) return;
  final active = ref.read(activeConversationProvider) as Conversation?;
  handle._followOpenWebUiRemap(
    ref.read(activeConversationInPlaceRemapProvider),
    active,
  );
  if (!handle._owns(ref, active)) return;
  final notifier =
      ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier;
  notifier.removeMessageById(handle.assistantMessageId);
  final userMessageId = handle.userMessageId;
  if (userMessageId != null) notifier.removeMessageById(userMessageId);
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

/// Proof that one durable send is committed: its user and assistant rows and
/// its requestCompletion outbox operation were written in one transaction.
///
/// Unlike the optimistic placeholder, this certifies admission. A later drain
/// failure belongs to the admitted operation, which the outbox replays; it
/// does not undo the send. The operation is identified by the chat and the
/// assistant message id its payload carries, both minted once for this send.
final class ChatSendAdmissionReceipt {
  const ChatSendAdmissionReceipt._({
    required this.owner,
    required this.chatId,
    required this.userMessageId,
    required this.assistantMessageId,
  });

  /// The owner captured before the first asynchronous step of the send.
  final ChatMutationOwnerToken owner;

  /// The chat the rows were committed under: a local id for a new chat.
  final String chatId;
  final String userMessageId;
  final String assistantMessageId;
}

/// Raised before anything is written when a send that needs a committed
/// receipt would have gone through a path that has none (a temporary chat,
/// Direct, Hermes, or no durable database).
class ChatAdmissionNotDurableException implements Exception {
  const ChatAdmissionNotDurableException();

  @override
  String toString() =>
      'ChatAdmissionNotDurableException: this send would not be committed '
      'to the outbox';
}

/// [onAdmissionCommitted] runs once, after the rows and outbox operation are
/// committed and before the outbox is drained. A caller that passes it needs
/// that certification, so a send that would take an inline path throws
/// [ChatAdmissionNotDurableException] instead of running without one.
///
/// [contextAttachments] replaces the composer's context attachments for this
/// send and leaves the composer's own untouched.
Future<void> durableSend(
  dynamic ref,
  String message,
  List<String>? attachments, {
  List<String>? toolIds,
  List<ChatContextAttachment>? contextAttachments,
  String? pendingFolderIdOverride,
  bool isVoiceMode = false,
  ChatSendVoiceContext? voice,
  void Function(ChatSendPlaceholderHandle handle)?
  onAssistantPlaceholderCreated,
  void Function(ChatSendAdmissionReceipt receipt)? onAdmissionCommitted,
}) async {
  Future<void> inlineSend() {
    if (onAdmissionCommitted != null) {
      throw const ChatAdmissionNotDurableException();
    }
    return _sendMessageInternal(
      ref,
      message,
      attachments,
      toolIds,
      isVoiceMode,
      pendingFolderIdOverride,
      onAssistantPlaceholderCreated,
      voice,
    );
  }
  final voiceReply = voice?.reply;

  final activeAtSendStart = ref.read(activeConversationProvider);
  final sendMutationOwner = captureChatMutationOwner(ref, activeAtSendStart);
  // Named with the owner, before the first await: the account whose defaults
  // this turn may recall is the one that sent it, not whoever is signed in once
  // attachment preparation returns.
  final settingsOwnerKey = _openWebUiSettingsOwnerKey(
    ref,
    sendMutationOwner.openWebUiApi,
  );
  // Settings chosen before this chat existed become its first stored params.
  final draftChatParams = activeAtSendStart == null
      ? Map<String, dynamic>.of(
          ref.read(pendingOpenWebUiChatSettingsProvider)
              as Map<String, dynamic>,
        )
      : const <String, dynamic>{};
  // A new chat is stored in the project the send began in, however long its
  // admission waits. The project the composer showed is kept apart, since an
  // explicit override can differ from it: it decides only whether the draft
  // still on screen is this one.
  final draftFolderId = activeAtSendStart == null
      ? ref.read(pendingFolderIdProvider) as String?
      : null;
  final storageFolderId = pendingFolderIdOverride ?? draftFolderId;
  if (isTemporaryChat(activeAtSendStart?.id)) {
    await inlineSend();
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
    await inlineSend();
    return;
  }

  if (hasTrustedDirectBinding) {
    await inlineSend();
    return;
  }
  if (selectedModel != null && hasReservedDirectIdentity(selectedModel)) {
    throw StateError('The selected direct connection is no longer available.');
  }

  // No durable backend (reviewer mode, no active server) OR a temporary chat
  // (never persisted): fall back to the legacy inline send path unchanged.
  if (db == null || reviewerMode || selectedModel == null || temporary) {
    await inlineSend();
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
  final codeInterpreterEnabled = _admitCodeInterpreter(ref);

  final existingMessages = ref.read(chatMessagesProvider);
  final parentId = _resolveOpenWebUiParentIdForNewUserMessage(existingMessages);

  // Mint both ids ONCE (R8): the placeholder, the DB row, and the completion
  // payload all share `assistantMessageId`.
  final userMessageId = const Uuid().v4();
  final assistantMessageId = const Uuid().v4();

  // ---- optimistic UI (instant; NON-NEGOTIABLE 4) ----
  final sentContextAttachments =
      contextAttachments ??
      ref.read(contextAttachmentsProvider) as List<ChatContextAttachment>;
  final contextFiles = _contextAttachmentsToFiles(sentContextAttachments);
  final attachmentIds = attachments;
  final userMessage = _withUserVoice(
    ChatMessage(
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
    ),
    voice,
  );
  final placeholder = ChatMessage(
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
  final assistantPlaceholder = voiceReply == null
      ? placeholder
      : _voiceReplyMessage(placeholder, voiceReply);
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

    // The settings are fixed here, at admission: a later edit to the chat, to
    // the picker, or to the account's global defaults cannot change this turn
    // when it is replayed. The account's defaults are read (or recalled when
    // offline) before the chat lock is taken, so a slow server never holds it.
    // They are read with the credentials captured for this send, so a session
    // change meanwhile cannot hand this turn another account's defaults; the
    // commit below stays with the database captured at send time, as before.
    final pickerReasoningEffort = reasoningEffortForModel(
      ref.read,
      selectedModel,
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
      assistantMessageId: assistantMessageId,
      model: selectedModel.id,
      toolIds: toolIdList,
      filterIds: filterIds,
      terminalId: terminalIdForCompletion,
      enableWebSearch: webSearchEnabled,
      enableImageGeneration: imageGenerationEnabled,
      enableCodeInterpreter: codeInterpreterEnabled,
      isVoiceMode: isVoiceMode,
      chatSettings: _admissionSettingsSnapshot(
        chatParams,
        pickerReasoningEffort: pickerReasoningEffort,
        globals: admissionGlobals,
        legacyChatSystem: legacyChatSystem,
      ),
    );

    var activeConversation = activeAtSendStart;
    var presentingDraft = false;

    if (activeConversation == null) {
      // ---- NEW local chat ----
      final pendingFolderId = storageFolderId;
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
        chatParams: draftChatParams,
        voice: voice,
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
        chatParams: draftChatParams,
      );
      sendHandle._bindConversation(localConversation);
      // Two empty composers look alike, so the composer is still this one only
      // while it shows the project the send began in and this turn's own rows.
      presentingDraft =
          chatMutationTokenStillActive(ref, sendMutationOwner) &&
          ref.read(pendingFolderIdProvider) == draftFolderId &&
          (ref.read(chatMessagesProvider) as List<ChatMessage>).any(
            (shown) => shown.id == userMessageId,
          );
      if (presentingDraft) {
        ref.read(activeConversationProvider.notifier).set(localConversation);
        ref.read(pendingFolderIdProvider.notifier).clear();
      } else {
        // The turn is still written below; its rows have no place on a draft
        // that moved on.
        final messagesNotifier = ref.read(chatMessagesProvider.notifier);
        messagesNotifier.removeMessageById(assistantMessageId);
        messagesNotifier.removeMessageById(userMessageId);
      }
      activeConversation = localConversation;

      await chatLocks.runExclusive(localId, () async {
        await db.chatsDao.insertLocalChatWithCreateOp(
          chat: rows.chat,
          messages: rows.messages,
          blobRows: rows,
          contentHash: contentHash,
          completion: voiceReply != null
              ? null
              : completionFor(draftChatParams, legacyChatSystem: null),
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
          if (voice != null) 'meta': {'voice': voice.userVoice},
        },
      );
      final asstRow = MessageRowData(
        id: assistantMessageId,
        chatId: chatId,
        parentId: userMessageId,
        role: 'assistant',
        content: voiceReply?.text ?? '',
        model: voiceReply?.model ?? selectedModel.id,
        createdAt: now,
        orderIndex: 1,
        payload: _durableAssistantPayload(
          id: assistantMessageId,
          parentId: userMessageId,
          modelId: selectedModel.id,
          modelName: selectedModel.name,
          timestamp: now,
          voiceReply: voiceReply,
        ),
      );

      await chatLocks.runExclusive(chatId, () async {
        // Read under the chat lock, the same lock a settings edit holds, so an
        // edit is either wholly before or wholly after this admission.
        final storedChatParams =
            await db.chatsDao.getChatParams(chatId) ??
            activeConversation!.chatParams;
        await db.chatsDao.appendMessagesWithUpdateOp(
          chatId: chatId,
          messages: [userRow, asstRow],
          currentMessageId: assistantMessageId,
          updatedAt: now,
          enqueueCompletion: voiceReply == null,
          completion: voiceReply != null
              ? null
              : completionFor(
                  storedChatParams,
                  legacyChatSystem: activeConversation!.systemPrompt,
                ),
        );
      });
    }

    // The rows and the outbox operation are committed: the send is admitted,
    // whatever the drain below does. The placeholder above is only optimistic.
    if (onAdmissionCommitted != null) {
      onAdmissionCommitted(
        ChatSendAdmissionReceipt._(
          owner: sendMutationOwner,
          chatId: activeConversation.id,
          userMessageId: userMessageId,
          assistantMessageId: assistantMessageId,
        ),
      );
    }

    // Context attachments (web page / YouTube transcript / KB doc) have now been
    // folded into the persisted user message + durable rows, so clear them —
    // otherwise they stay attached and are silently re-sent on the next message
    // (mirrors `_sendMessageInternal`). Ones the caller supplied never lived in
    // the composer, and a draft that moved on keeps its own.
    if (contextAttachments == null &&
        (activeAtSendStart != null || presentingDraft) &&
        sendHandle._owns(ref, activeConversation) &&
        identical(
          ref.read(contextAttachmentsProvider),
          sentContextAttachments,
        )) {
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
  Map<String, dynamic> chatParams = const <String, dynamic>{},
  ChatSendVoiceContext? voice,
}) {
  return <String, dynamic>{
    'title': _titleFromText(text),
    'models': <String>[modelId],
    if (chatParams.isNotEmpty) 'params': chatParams,
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
          if (voice != null) 'meta': {'voice': voice.userVoice},
        },
        asstId: _durableAssistantPayload(
          id: asstId,
          parentId: userMsgId,
          modelId: modelId,
          modelName: modelName,
          timestamp: now,
          voiceReply: voice?.reply,
        ),
      },
    },
  };
}

/// A new answer's row: empty until its model fills it, or, for [voiceReply],
/// the voice's finished reply stored under the voice model as Open WebUI's
/// web client stores it.
Map<String, dynamic> _durableAssistantPayload({
  required String id,
  required String parentId,
  required String modelId,
  required String modelName,
  required int timestamp,
  ChatVoiceReply? voiceReply,
}) {
  final trimmedModelName = voiceReply?.model ?? modelName.trim();
  return <String, dynamic>{
    'id': id,
    'parentId': parentId,
    'childrenIds': <String>[],
    'role': 'assistant',
    'content': voiceReply?.text ?? '',
    'model': voiceReply?.model ?? modelId,
    if (trimmedModelName.isNotEmpty) 'modelName': trimmedModelName,
    'timestamp': timestamp,
    if (voiceReply != null) ...{
      'done': true,
      'modelIdx': 0,
      'meta': {'voice': voiceReply.voice},
    },
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
    // Files of drafts queued behind a response are no longer in the tray.
    for (final file in [
      ...ref.read(attachedFilesProvider) as List<FileUploadState>,
      for (final held
          in ref.read(queuedDraftAttachmentsProvider)
              as List<QueuedDraftAttachment>)
        held.upload,
    ]) {
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
  dynamic ref,
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
