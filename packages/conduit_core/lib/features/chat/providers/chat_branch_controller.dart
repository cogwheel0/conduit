part of 'chat_providers.dart';

/// Whether the Advanced branch controls (continue from an alternative, step
/// through edited messages, fork at a message) are offered for the active chat.
///
/// Saved branches and the everyday response pager work whether or not this is
/// true; it only decides what the user is offered to change. Hidden for Hermes,
/// Direct and on-device chats and models, for a chat that exists only in
/// memory, and for another user's chat.
final chatBranchControlsProvider = Provider<bool>((ref) {
  if (ref.watch(reviewerModeProvider)) return false;
  if (!ref.watch(
    appSettingsProvider.select((s) => s.advancedFeaturesEnabled),
  )) {
    return false;
  }
  if (ref.watch(apiServiceProvider) == null) return false;
  final conversation = ref.watch(activeConversationProvider);
  if (conversation == null) return false;
  return _conversationIsBranchableByUser(
    conversation,
    ref.watch(currentUserProvider2.select((user) => user?.id)),
  );
});

bool _conversationIsBranchableByUser(
  Conversation conversation,
  String? currentUserId,
) =>
    !isTemporaryChat(conversation.id) &&
    chatMutationOwnerScopeForConversation(conversation) ==
        openWebUiChatMutationOwnerScope(conversation.id) &&
    !isReadOnlySharedConversation(conversation, currentUserId);

/// Whether the signed-in account may import chats, which is what the server
/// requires to fork one. Fails closed: an unreadable permission set grants
/// nothing, while a permission the server does not report follows its default
/// (allowed). The shared [userPermissionsProvider] owns the transport; this
/// adds no request, and an answer for an earlier account or session is denied.
final openWebUiChatImportAllowedProvider = FutureProvider<bool>((ref) async {
  if (ref.watch(reviewerModeProvider)) return false;
  final api = ref.watch(apiServiceProvider);
  final user = ref.watch(currentUserProvider2);
  final epoch = ref.watch(openWebUiAuthSessionEpochProvider);
  if (api == null || user == null) return false;
  if (user.role == 'admin') return true;
  try {
    final permissions = await ref.watch(userPermissionsProvider.future);
    if (!ref.mounted ||
        !identical(api, ref.read(apiServiceProvider)) ||
        !identical(epoch, ref.read(openWebUiAuthSessionEpochProvider)) ||
        user.id != ref.read(currentUserProvider2)?.id) {
      return false;
    }
    final chat = permissions['chat'];
    final allowed = chat is Map ? chat['import'] : null;
    return allowed is bool ? allowed : true;
  } catch (_) {
    return false;
  }
});

/// What the fork action can do for the active chat right now.
enum ChatForkAvailability {
  /// Not offered: Advanced is off, the chat is not the user's own durable Open
  /// WebUI chat, or the account may not import chats.
  hidden,

  /// Offered, but the device is offline.
  offline,

  /// Offered, but a response is still running on this chat.
  responseRunning,

  /// Ready.
  available,
}

final chatForkAvailabilityProvider = Provider<ChatForkAvailability>((ref) {
  if (!ref.watch(chatBranchControlsProvider)) {
    return ChatForkAvailability.hidden;
  }
  final allowed =
      ref.watch(openWebUiChatImportAllowedProvider).asData?.value ?? false;
  if (!allowed) return ChatForkAvailability.hidden;
  if (!ref.watch(isOnlineProvider)) return ChatForkAvailability.offline;
  if (ref.watch(isChatStreamingProvider)) {
    return ChatForkAvailability.responseRunning;
  }
  return ChatForkAvailability.available;
});

/// Identifies one message whose alternatives are wanted: the chat and the
/// displayed message's real id.
typedef ChatBranchSiblingsKey = ({String chatId, String messageId});

/// The alternatives to one displayed message of the active chat, read from the
/// complete stored graph, or null when there are none to choose from (or the
/// controls are not offered).
///
/// The only way a displayed version earns a "continue" action: its id must be a
/// real same-role sibling in the stored graph, so a version without a reliable
/// id stays preview-only. Reads the device's copy only and never the network.
/// Re-reads when the visible branch changes, and is dropped with the account.
final chatBranchSiblingsProvider = FutureProvider.autoDispose
    .family<ChatBranchSiblings?, ChatBranchSiblingsKey>((ref, key) async {
      if (!ref.watch(chatBranchControlsProvider)) return null;
      ref.watch(appDatabaseProvider);
      ref.watch(apiServiceProvider);
      ref.watch(openWebUiAuthSessionEpochProvider);
      // A new leaf, or a branch switch that keeps the same length, both move
      // the tip; streaming token updates do not.
      ref.watch(
        chatMessagesProvider.select(
          (messages) => (messages.length, messages.lastOrNull?.id),
        ),
      );
      final conversation = ref.read(activeConversationProvider);
      if (conversation == null || conversation.id != key.chatId) return null;
      final token = captureChatMutationOwner(ref, conversation);
      final database = token.openWebUiDatabase;
      if (!token.usesOpenWebUiContext || database == null) return null;
      try {
        final graph = await _chatBranchServiceFor(
          ref,
          token,
          database,
        ).readGraph(key.chatId);
        final siblings = graph?.siblingsOf(key.messageId);
        return siblings == null || siblings.ids.length < 2 ? null : siblings;
      } on ChatBranchException {
        return null;
      }
    });

bool _branchMutationContextIsCurrent(
  dynamic ref,
  ChatMutationOwnerToken token,
) =>
    identical(_readAppDatabaseOrNull(ref), token.openWebUiDatabase) &&
    identical(_readApiServiceOrNull(ref), token.openWebUiApi) &&
    identical(
      _readOpenWebUiAuthSessionEpoch(ref),
      token.openWebUiAuthSessionEpoch,
    );

/// A service bound to [token]'s database and credentials. [loadBody] lets it
/// fetch a chat whose body is not stored yet; a UI that only asks what exists
/// leaves it off.
ChatBranchService _chatBranchServiceFor(
  dynamic ref,
  ChatMutationOwnerToken token,
  AppDatabase database, {
  bool loadBody = false,
}) {
  final api = token.openWebUiApi;
  final workerManager = ref.read(workerManagerProvider) as WorkerManager;
  return ChatBranchService(
    database: database,
    locks: ref.read(chatLocksProvider) as ChatLocks,
    ownerIsCurrent: () => _branchMutationContextIsCurrent(ref, token),
    nowEpochSeconds: () => ref.read(syncClockProvider).nowEpochSeconds() as int,
    graphOffload: (envelope) => workerManager.schedule(
      parseChatBranchGraphWorker,
      envelope,
      debugLabel: 'chat.branchGraph',
    ),
    rowsParseOffload: (response) => workerManager.schedule(
      parseChatRowsWorker,
      response,
      debugLabel: 'chat.branchEnvelopeRows',
    ),
    authoritativeLoader: loadBody && api is ApiService
        ? (chatId) =>
              api.getChatRaw(chatId, authSnapshot: token.openWebUiAuthSnapshot)
        : null,
    responseIsRunning: (chatId) {
      final active = ref.read(activeConversationProvider) as Conversation?;
      // Only the chat on screen has an in-memory stream to wait for.
      return active?.id == chatId &&
          _messagesAreStreaming(ref.read(chatMessagesProvider));
    },
  );
}

/// The database a branch operation on [conversation] runs against, or a
/// [ChatBranchException] when it is not a durable chat of the signed-in user on
/// the server captured in [token].
AppDatabase _requireBranchableChat(
  dynamic ref,
  ChatMutationOwnerToken token,
  Conversation conversation,
) {
  final database = token.openWebUiDatabase;
  if (!token.usesOpenWebUiContext ||
      database == null ||
      token.openWebUiApi is! ApiService ||
      ref.read(reviewerModeProvider) == true ||
      !_conversationIsBranchableByUser(
        conversation,
        (ref.read(currentUserProvider2) as User?)?.id,
      )) {
    throw const ChatBranchException(ChatBranchFailure.unavailable);
  }
  if (!_branchMutationContextIsCurrent(ref, token)) {
    throw const ChatBranchException(ChatBranchFailure.ownerChanged);
  }
  return database;
}

/// Makes [messageId] (and the leaf below it) the active branch of
/// [conversation], and shows it.
///
/// [alternativeTo] is the message the user was looking at; when given, the
/// chosen id must be a real same-role alternative of it. The choice is stored
/// and queued for sync as one unit under the chat's lock, against the database
/// and credentials captured with [owner] (or captured now); a server, account or
/// session change at any point aborts without writing. A response running on
/// the chat blocks it with [ChatBranchFailure.responseRunning] and is never
/// stopped. The visible transcript follows only while the user is still on that
/// chat; it is rebuilt from the stored branch, never the other way round.
Future<ChatBranchSelection> selectChatBranch(
  dynamic ref, {
  required Conversation conversation,
  required String messageId,
  String? alternativeTo,
  ChatMutationOwnerToken? owner,
}) async {
  final token = owner ?? captureChatMutationOwner(ref, conversation);
  final database = _requireBranchableChat(ref, token, conversation);
  final selection =
      await _chatBranchServiceFor(
        ref,
        token,
        database,
        loadBody: true,
      ).selectBranch(
        chatId: conversation.id,
        messageId: messageId,
        alternativeTo: alternativeTo,
      );
  if (selection.changed && _branchMutationContextIsCurrent(ref, token)) {
    try {
      unawaited(
        (ref.read(syncEngineProvider.notifier) as SyncEngine)
            .drainNowForDatabase(database)
            .catchError((Object _) {}),
      );
    } catch (_) {
      // The op is durable; the next drain trigger sends it.
    }
  }
  await _showStoredBranch(ref, token, conversation.id);
  return selection;
}

/// Replaces the active conversation with the stored one, so the transcript is
/// rebuilt from the durable current branch. A no-op once the user left the chat
/// or the account changed.
Future<void> _showStoredBranch(
  dynamic ref,
  ChatMutationOwnerToken token,
  String chatId,
) async {
  final stored = await _loadStoredOpenWebUiConversation(ref, token, chatId);
  if (stored == null || !chatMutationTokenStillActive(ref, token)) return;
  (ref.read(activeConversationProvider.notifier) as ActiveConversationNotifier)
      .set(stored);
}

Future<Conversation?> _loadStoredOpenWebUiConversation(
  dynamic ref,
  ChatMutationOwnerToken token,
  String chatId,
) async {
  final located =
      await (ref.read(chatDatabaseRepositoryProvider) as ChatDatabaseRepository)
          .loadConversation(
            chatId,
            preferred: ChatStorageKind.openWebUi,
            offload: (envelope) =>
                (ref.read(workerManagerProvider) as WorkerManager).schedule(
                  parseFullConversationModelWorker,
                  envelope,
                  debugLabel: 'chat.branchConversation',
                ),
            locationIsCurrent: (location) =>
                identical(location.database, token.openWebUiDatabase) &&
                _branchMutationContextIsCurrent(ref, token),
          );
  return located == null
      ? null
      : withChatStorageProvenance(
          located.conversation,
          located.location.storage,
        );
}

/// Forks [conversation] at [messageId] on the server and opens the new chat.
///
/// Uses the exact upstream fork request, sent once with the credentials
/// captured with [owner] (or captured now), and never falls back to a
/// whole-chat clone. The server's answer is stored as the authoritative chat
/// (its id, folder, title, params and full graph) and shown only while the user
/// is still on the chat they forked from; if the account changed meanwhile
/// nothing is stored or shown. Throws [ChatBranchException] for an offline
/// device, a refused account, a missing source or message, an unsupported
/// server, or a response still running on the server.
Future<({String chatId, bool opened})> forkChatAtMessage(
  dynamic ref, {
  required Conversation conversation,
  required String messageId,
  ChatMutationOwnerToken? owner,
}) async {
  final token = owner ?? captureChatMutationOwner(ref, conversation);
  final database = _requireBranchableChat(ref, token, conversation);
  final api = token.openWebUiApi as ApiService;
  if (ref.read(isOnlineProvider) == false) {
    throw const ChatBranchException(ChatBranchFailure.offline);
  }
  if (await ref.read(openWebUiChatImportAllowedProvider.future) != true) {
    throw const ChatBranchException(ChatBranchFailure.forkForbidden);
  }
  if (!_branchMutationContextIsCurrent(ref, token)) {
    throw const ChatBranchException(ChatBranchFailure.ownerChanged);
  }

  final outcome =
      await _chatBranchServiceFor(ref, token, database, loadBody: true).forkAt(
        chatId: conversation.id,
        messageId: messageId,
        request: (chatId, sourceMessageId) => api.forkChatRaw(
          chatId,
          sourceMessageId,
          authSnapshot: token.openWebUiAuthSnapshot,
        ),
      );

  final fork = await _loadStoredOpenWebUiConversation(
    ref,
    token,
    outcome.chatId,
  );
  if (fork == null || !_branchMutationContextIsCurrent(ref, token)) {
    return (chatId: outcome.chatId, opened: false);
  }
  _readProvider(ref, conversationsProvider.notifier).upsertConversation(
    fork,
    trustFolderConversation: fork.folderId != null && fork.folderId!.isNotEmpty,
  );
  refreshConversationsCache(ref);
  if (!chatMutationTokenStillActive(ref, token)) {
    return (chatId: outcome.chatId, opened: false);
  }
  clearSelectedFiltersForConversationBoundary(ref);
  _readProvider(ref, activeConversationProvider.notifier).set(fork);
  return (chatId: outcome.chatId, opened: true);
}
