part of 'chat_providers.dart';

/// Collision-free runtime ownership for asynchronous chat mutations.
///
/// Stored conversations include their database provenance. Unstored direct
/// and Hermes conversations use backend-specific namespaces so an id collision
/// cannot let late work from one backend mutate another backend's active chat.
String chatMutationOwnerScopeForConversation(Conversation conversation) {
  final storage = chatStorageKindOf(conversation);
  if (storage != null) {
    return ChatStorageIdentity(
      rawId: conversation.id,
      storage: storage,
    ).scopedId;
  }
  if (conversation.metadata['backend'] == kDirectTransport) {
    return 'conduit-direct-runtime://${Uri.encodeComponent(conversation.id)}';
  }
  if (isNativeHermesConversation(conversation)) {
    return 'conduit-hermes-runtime://${Uri.encodeComponent(conversation.id)}';
  }
  // Unannotated conversations retain their historical OpenWebUI ownership.
  return ChatStorageIdentity(
    rawId: conversation.id,
    storage: ChatStorageKind.openWebUi,
  ).scopedId;
}

/// Storage-scoped owner for a server-backed OpenWebUI chat.
///
/// Raw ids are not sufficient here because a direct-local chat may legally
/// use the same id. Completion runners use this value to decide whether their
/// target still owns the globally-visible chat state after an async boundary.
String openWebUiChatMutationOwnerScope(String chatId) => ChatStorageIdentity(
  rawId: chatId,
  storage: ChatStorageKind.openWebUi,
).scopedId;

/// Immutable ownership captured before an asynchronous chat mutation starts.
/// OpenWebUI ownership includes the exact API and database instances so equal
/// raw ids on two configured servers remain distinct. Direct/Hermes ownership
/// continues to use its backend-scoped conversation identity.
final class ChatMutationOwnerToken {
  const ChatMutationOwnerToken._({
    required this.conversation,
    required this.ownerConversationId,
    required this.usesOpenWebUiContext,
    required this.openWebUiDatabase,
    required this.openWebUiApi,
    required this.openWebUiAuthSnapshot,
    required this.openWebUiAuthSessionEpoch,
  });

  final Conversation? conversation;
  final String? ownerConversationId;
  final bool usesOpenWebUiContext;
  final AppDatabase? openWebUiDatabase;
  final Object? openWebUiApi;
  final ApiAuthSnapshot? openWebUiAuthSnapshot;
  final Object? openWebUiAuthSessionEpoch;
}

ChatMutationOwnerToken captureChatMutationOwner(
  dynamic ref,
  Conversation? conversation,
) {
  final ownerConversationId = conversation == null
      ? null
      : chatMutationOwnerScopeForConversation(conversation);
  final isOpenWebUi =
      conversation == null ||
      ownerConversationId == openWebUiChatMutationOwnerScope(conversation.id);
  final openWebUiApi = isOpenWebUi ? _readApiServiceOrNull(ref) : null;
  return ChatMutationOwnerToken._(
    conversation: conversation,
    ownerConversationId: ownerConversationId,
    usesOpenWebUiContext: isOpenWebUi,
    openWebUiDatabase: isOpenWebUi ? _readAppDatabaseOrNull(ref) : null,
    openWebUiApi: openWebUiApi,
    openWebUiAuthSnapshot: openWebUiApi is ApiService
        ? openWebUiApi.captureAuthSnapshot()
        : null,
    openWebUiAuthSessionEpoch: isOpenWebUi
        ? _readOpenWebUiAuthSessionEpoch(ref)
        : null,
  );
}

void _requireChatMutationOpenWebUiAuthSession(
  dynamic ref,
  ChatMutationOwnerToken token,
) {
  if (!token.usesOpenWebUiContext || token.openWebUiApi == null) return;
  final capturedEpoch = token.openWebUiAuthSessionEpoch;
  if (capturedEpoch == null ||
      !identical(capturedEpoch, _readOpenWebUiAuthSessionEpoch(ref))) {
    throw StateError(
      'The OpenWebUI authentication session changed while preparing files.',
    );
  }
}

bool chatMutationTokenStillActive(dynamic ref, ChatMutationOwnerToken token) {
  if (token.usesOpenWebUiContext &&
      (!identical(_readAppDatabaseOrNull(ref), token.openWebUiDatabase) ||
          !identical(_readApiServiceOrNull(ref), token.openWebUiApi) ||
          !identical(
            _readOpenWebUiAuthSessionEpoch(ref),
            token.openWebUiAuthSessionEpoch,
          ))) {
    return false;
  }
  final current = ref.read(activeConversationProvider) as Conversation?;
  final origin = token.conversation;
  if (origin == null || current == null) {
    return origin == null && current == null;
  }
  if (token.ownerConversationId ==
      chatMutationOwnerScopeForConversation(current)) {
    return true;
  }
  if (!token.usesOpenWebUiContext) {
    return false;
  }
  final remap = ref.read(activeConversationInPlaceRemapProvider);
  return _openWebUiRemapMatchesOwner(
        remap,
        fromId: origin.id,
        toId: current.id,
        database: token.openWebUiDatabase,
        api: token.openWebUiApi,
        authSessionEpoch: token.openWebUiAuthSessionEpoch,
      ) &&
      chatMutationOwnerScopeForConversation(current) ==
          openWebUiChatMutationOwnerScope(current.id);
}

bool _openWebUiRemapMatchesOwner(
  ActiveConversationInPlaceRemap? remap, {
  required String fromId,
  required String toId,
  required Object? database,
  required Object? api,
  required Object? authSessionEpoch,
}) =>
    remap?.matches(
          fromId,
          toId,
          namespace: ActiveConversationRemapNamespace.openWebUi,
        ) ==
        true &&
    remap!.matchesOpenWebUiContext(
      database: database,
      api: api,
      authSessionEpoch: authSessionEpoch,
    );

final class OpenWebUiCompletionOwner {
  OpenWebUiCompletionOwner({
    required this.chatId,
    required this.database,
    required this.api,
    required this.contextWasCoherent,
    required this.authSessionEpoch,
  });

  String chatId;
  final AppDatabase? database;
  final Object? api;
  final bool contextWasCoherent;
  final Object? authSessionEpoch;
}

OpenWebUiCompletionOwner captureOpenWebUiCompletionOwner(
  dynamic ref, {
  required String chatId,
  AppDatabase? database,
  Object? api,
}) {
  final capturedDatabase = database ?? _readAppDatabaseOrNull(ref);
  final capturedApi = api ?? _readApiServiceOrNull(ref);
  final capturedSocket = _readOpenWebUiSocketForApi(ref, capturedApi);
  return OpenWebUiCompletionOwner(
    chatId: chatId,
    database: capturedDatabase,
    api: capturedApi,
    authSessionEpoch: _readOpenWebUiAuthSessionEpoch(ref),
    contextWasCoherent: _openWebUiContextTupleIsCoherent(
      ref,
      database: capturedDatabase,
      api: capturedApi,
      socket: capturedSocket,
    ),
  );
}

/// Whether [ownerConversationId] still owns the active global chat state.
bool chatMutationOwnerScopeIsActive(dynamic ref, String ownerConversationId) {
  final active = ref.read(activeConversationProvider) as Conversation?;
  return active != null &&
      chatMutationOwnerScopeForConversation(active) == ownerConversationId;
}

/// Returns the active OpenWebUI id when it still represents [chatId], including
/// the one explicit in-place remap recorded by the active-conversation owner.
String? activeOpenWebUiChatIdForMutation(
  dynamic ref,
  OpenWebUiCompletionOwner owner,
) {
  if (!openWebUiCompletionContextIsCurrent(ref, owner)) return null;
  final active = ref.read(activeConversationProvider) as Conversation?;
  if (active == null ||
      chatMutationOwnerScopeForConversation(active) !=
          openWebUiChatMutationOwnerScope(active.id)) {
    return null;
  }
  if (active.id == owner.chatId) return owner.chatId;
  final remap = ref.read(activeConversationInPlaceRemapProvider);
  return _openWebUiRemapMatchesOwner(
        remap,
        fromId: owner.chatId,
        toId: active.id,
        database: owner.database,
        api: owner.api,
        authSessionEpoch: owner.authSessionEpoch,
      )
      ? active.id
      : null;
}

bool openWebUiCompletionContextIsCurrent(
  dynamic ref,
  OpenWebUiCompletionOwner owner,
) {
  if (!owner.contextWasCoherent) return false;
  final database = _readAppDatabaseOrNull(ref);
  final api = _readApiServiceOrNull(ref);
  return identical(database, owner.database) &&
      identical(api, owner.api) &&
      identical(_readOpenWebUiAuthSessionEpoch(ref), owner.authSessionEpoch) &&
      _openWebUiContextTupleIsCoherent(
        ref,
        database: database,
        api: api,
        socket: _readOpenWebUiSocketForApi(ref, api),
      );
}

bool _sameOpenWebUiOwnerContext(
  OpenWebUiCompletionOwner? left,
  OpenWebUiCompletionOwner right,
) =>
    left != null &&
    left.contextWasCoherent &&
    right.contextWasCoherent &&
    identical(left.database, right.database) &&
    identical(left.api, right.api) &&
    identical(left.authSessionEpoch, right.authSessionEpoch);

/// Resolves an OpenWebUI completion placeholder's current durable chat id after
/// a possible local-to-server remap. The lookup is confined to the OpenWebUI
/// database, so a colliding direct-local row or an unrelated Hermes remap can
/// never redirect recovery.
Future<String> resolveOpenWebUiCompletionChatId(
  dynamic ref, {
  required OpenWebUiCompletionOwner owner,
  required String assistantMessageId,
}) async {
  final recordedChatId = owner.chatId;
  try {
    final database = owner.database;
    if (database != null) {
      final resolved = await resolveDurableChatMessageOwner(
        database,
        recordedChatId: recordedChatId,
        messageId: assistantMessageId,
        expectedRole: 'assistant',
      );
      if (resolved != null) return resolved;
    }
  } catch (_) {}

  // A truly inline request may have no durable row. It may follow a remap only
  // when the active OpenWebUI context carries that exact in-place remap and the
  // current UI still owns this assistant placeholder. Headless work never
  // follows sync metadata alone.
  final activeId = activeOpenWebUiChatIdForMutation(ref, owner);
  if (activeId != null && activeId != recordedChatId) {
    final currentMessages = ref.read(chatMessagesProvider) as List<ChatMessage>;
    final ownsPlaceholder = currentMessages.any(
      (message) =>
          message.id == assistantMessageId && message.role == 'assistant',
    );
    if (ownsPlaceholder) return activeId;
  }
  return recordedChatId;
}
