part of 'chat_providers.dart';

/// Whether Settings offers the Chat data controls page: the Advanced
/// disclosure is on and an Open WebUI account is signed in. Flutter Settings and
/// the native iOS sheet both read this, so they cannot disagree about when the
/// entry exists. Turning Advanced off hides the entry only; a chat's own Export
/// and everything stored stay available.
final chatDataControlsEntryVisibleProvider = Provider<bool>((ref) {
  if (!ref.watch(
    appSettingsProvider.select((s) => s.advancedFeaturesEnabled),
  )) {
    return false;
  }
  return ref.watch(apiServiceProvider) != null &&
      ref.watch(currentUserProvider2) != null;
});

/// Whether the signed-in account may use [action] (`import`, `export` or
/// `delete`) on its chats, following Open WebUI's `canManageChats`: an admin
/// always may, and anyone else may unless `chat.<action>` is explicitly off.
/// Fails closed for an unreadable permission set, and an answer for an earlier
/// account or session is denied. The shared [userPermissionsProvider] owns the
/// transport; this adds no request.
final openWebUiChatActionAllowedProvider = FutureProvider.family<bool, String>((
  ref,
  action,
) async {
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
    final allowed = chat is Map ? chat[action] : null;
    return allowed is bool ? allowed : true;
  } catch (_) {
    return false;
  }
});

/// Whether the open chat offers Export: a durable chat of the signed-in Open
/// WebUI account (not Direct, Hermes, on-device or temporary), and an account
/// that may export. Independent of Advanced: exporting the chat you are reading
/// is an everyday action.
final chatExportAvailableProvider = Provider<bool>((ref) {
  if (ref.watch(apiServiceProvider) == null) return false;
  final conversation = ref.watch(activeConversationProvider);
  if (conversation == null ||
      isTemporaryChat(conversation.id) ||
      chatMutationOwnerScopeForConversation(conversation) !=
          openWebUiChatMutationOwnerScope(conversation.id)) {
    return false;
  }
  return ref
          .watch(openWebUiChatActionAllowedProvider('export'))
          .asData
          ?.value ??
      false;
});

/// The account a data-controls surface was opened for.
///
/// The notifiers outlive account switches and the [ApiService] can stay the
/// same across them, so nothing held by a surface says whose chats a later
/// Export, Restore or Delete would touch. Capture this synchronously when the
/// surface opens, before any await, and run every operation against it.
@immutable
final class ChatDataControlsOwner {
  const ChatDataControlsOwner._({
    required this.api,
    required this.auth,
    required this.database,
    required this.accountId,
    required this.serverName,
    required this.accountName,
    required this.authSessionEpoch,
  });

  final ApiService api;
  final ApiAuthSnapshot auth;
  final AppDatabase database;

  /// The signed-in account's server user id.
  final String? accountId;

  /// What the user sees as the target: the server and the account on it.
  final String serverName;
  final String accountName;
  final Object? authSessionEpoch;
}

/// The signed-in Open WebUI account, or null when there is none to own chats.
ChatDataControlsOwner? captureChatDataControlsOwner(dynamic ref) {
  final api = _readApiServiceOrNull(ref);
  final database = _readAppDatabaseOrNull(ref);
  final user = ref.read(currentUserProvider2) as User?;
  if (api is! ApiService || database == null || user == null) return null;
  final server = api.serverConfig;
  final name = user.name?.trim() ?? '';
  final account = name.isNotEmpty
      ? name
      : (user.email.trim().isNotEmpty ? user.email.trim() : user.username);
  return ChatDataControlsOwner._(
    api: api,
    auth: api.captureAuthSnapshot(),
    database: database,
    accountId: user.id.trim().isEmpty ? null : user.id.trim(),
    serverName: server.name.trim().isNotEmpty ? server.name : server.url,
    accountName: account,
    authSessionEpoch: _readOpenWebUiAuthSessionEpoch(ref),
  );
}

bool chatDataControlsOwnerIsCurrent(dynamic ref, ChatDataControlsOwner owner) {
  final user = ref.read(currentUserProvider2) as User?;
  return identical(_readAppDatabaseOrNull(ref), owner.database) &&
      identical(_readApiServiceOrNull(ref), owner.api) &&
      identical(_readOpenWebUiAuthSessionEpoch(ref), owner.authSessionEpoch) &&
      user != null &&
      user.id.trim() == (owner.accountId ?? '');
}

ChatDataControlsService _chatDataControlsServiceFor(
  dynamic ref, {
  required AppDatabase database,
  required ApiService api,
  required ApiAuthSnapshot auth,
  required String? accountId,
  required bool Function() ownerIsCurrent,
}) {
  final workerManager = ref.read(workerManagerProvider) as WorkerManager;
  return ChatDataControlsService(
    database: database,
    locks: ref.read(chatLocksProvider) as ConversationLocks,
    api: ApiChatDataControls(api, auth),
    accountId: accountId,
    ownerIsCurrent: ownerIsCurrent,
    activeChatIds: () => ref.read(activeChatIdsProvider) as Set<String>,
    nowEpochSeconds: () => ref.read(syncClockProvider).nowEpochSeconds() as int,
    decodeOffload: (json) => workerManager.schedule<String, Object?>(
      decodeChatBackupJsonWorker,
      json,
      debugLabel: 'chat.backupDecode',
    ),
    rowsParseOffload: (response) => workerManager.schedule(
      parseChatRowsWorker,
      response,
      debugLabel: 'chat.dataControlsRows',
    ),
    graphOffload: (envelope) => workerManager.schedule(
      parseChatBranchGraphWorker,
      envelope,
      debugLabel: 'chat.dataControlsGraph',
    ),
    conversationOffload: (envelope) => workerManager.schedule(
      parseFullConversationModelWorker,
      envelope,
      debugLabel: 'chat.dataControlsTranscript',
    ),
  );
}

/// The service for [owner]'s library operations.
ChatDataControlsService chatDataControlsServiceForOwner(
  dynamic ref,
  ChatDataControlsOwner owner,
) => _chatDataControlsServiceFor(
  ref,
  database: owner.database,
  api: owner.api,
  auth: owner.auth,
  accountId: owner.accountId,
  ownerIsCurrent: () => chatDataControlsOwnerIsCurrent(ref, owner),
);

/// Top-level so a worker isolate can run it.
Object? decodeChatBackupJsonWorker(String json) => jsonDecode(json);

/// Validates [bytes] as a chat export off the UI isolate when it is large.
Future<ChatImportPreview> prepareChatImportFile(dynamic ref, Uint8List bytes) {
  if (bytes.lengthInBytes < 256 * 1024) {
    return Future<ChatImportPreview>.sync(() => prepareChatImport(bytes));
  }
  return (ref.read(workerManagerProvider) as WorkerManager)
      .schedule<Uint8List, ChatImportPreview>(
        prepareChatImport,
        bytes,
        debugLabel: 'chat.importPrepare',
      );
}

/// Sends what the device still holds for [owner] and reads what the server
/// has, so a backup taken right after counts as much as it can.
Future<void> syncChatDataControlsOwner(
  dynamic ref,
  ChatDataControlsOwner owner,
) async {
  bool current() => chatDataControlsOwnerIsCurrent(ref, owner);
  if (!current()) {
    throw const ChatDataControlsException(ChatDataControlsFailure.ownerChanged);
  }
  final engine = ref.read(syncEngineProvider.notifier) as SyncEngine;
  await engine.drainNowForDatabase(owner.database);
  if (!current()) {
    throw const ChatDataControlsException(ChatDataControlsFailure.ownerChanged);
  }
  await engine.requestPull(reason: 'data-controls');
}

/// Exports one Open WebUI chat: its complete stored graph as the upstream JSON.
///
/// Bound to the database and credentials captured with [owner] (or captured
/// now); a server, account or session change at any point throws
/// [ChatBranchException] without delivering anything.
Future<ChatExport> exportOpenWebUiChat(
  dynamic ref, {
  required Conversation conversation,
  ChatMutationOwnerToken? owner,
}) => _exportOpenWebUiChat(ref, conversation, owner, (service, id) {
  return service.exportChat(id);
});

/// Like [exportOpenWebUiChat], as a Markdown transcript of the active branch.
Future<String> exportOpenWebUiChatTranscript(
  dynamic ref, {
  required Conversation conversation,
  ChatMutationOwnerToken? owner,
}) => _exportOpenWebUiChat(ref, conversation, owner, (service, id) {
  return service.exportChatTranscript(id);
});

Future<T> _exportOpenWebUiChat<T>(
  dynamic ref,
  Conversation conversation,
  ChatMutationOwnerToken? owner,
  Future<T> Function(ChatDataControlsService service, String chatId) run,
) async {
  final token = owner ?? captureChatMutationOwner(ref, conversation);
  final database = _requireBranchableChatForExport(ref, token, conversation);
  final api = token.openWebUiApi as ApiService;
  final service = _chatDataControlsServiceFor(
    ref,
    database: database,
    api: api,
    auth: token.openWebUiAuthSnapshot ?? api.captureAuthSnapshot(),
    accountId: (ref.read(currentUserProvider2) as User?)?.id,
    ownerIsCurrent: () => _branchMutationContextIsCurrent(ref, token),
  );
  try {
    return await run(service, conversation.id);
  } on ChatDataControlsException catch (error) {
    throw ChatBranchException(
      error.failure == ChatDataControlsFailure.ownerChanged
          ? ChatBranchFailure.ownerChanged
          : ChatBranchFailure.unavailable,
    );
  }
}

/// Throws [ChatBranchException] unless the server, account and session that
/// [owner] captured for an export are still the signed-in ones.
///
/// Which chat is open does not matter: a chat the user chose to export stays
/// theirs to export wherever they navigate. Run it right before an exported
/// file is handed over, since staging the file is asynchronous.
void requireOpenWebUiChatExportOwner(
  dynamic ref,
  ChatMutationOwnerToken owner,
) {
  if (!_branchMutationContextIsCurrent(ref, owner)) {
    throw const ChatBranchException(ChatBranchFailure.ownerChanged);
  }
}

AppDatabase _requireBranchableChatForExport(
  dynamic ref,
  ChatMutationOwnerToken token,
  Conversation conversation,
) {
  final database = token.openWebUiDatabase;
  if (!token.usesOpenWebUiContext ||
      database == null ||
      token.openWebUiApi is! ApiService ||
      ref.read(reviewerModeProvider) == true ||
      isTemporaryChat(conversation.id)) {
    throw const ChatBranchException(ChatBranchFailure.unavailable);
  }
  requireOpenWebUiChatExportOwner(ref, token);
  return database;
}

/// The account-wide change a surface just stored.
enum ChatBulkChange { archive, unarchive, unshare, delete }

/// Brings the visible state in line with a stored account-wide change, only
/// while [owner] is still signed in.
///
/// Delete all and archive all take the open chat off screen exactly as deleting
/// or archiving it by hand does, because it is gone or filed away; unarchive
/// and unshare only update its flags.
void applyChatBulkOutcome(
  dynamic ref,
  ChatDataControlsOwner owner,
  ChatBulkChange change,
  ChatBulkOutcome outcome,
) {
  if (!chatDataControlsOwnerIsCurrent(ref, owner)) return;
  final active = _readProvider(ref, activeConversationProvider);
  if (active != null &&
      !isDirectLocalConversation(active) &&
      !isTemporaryChat(active.id) &&
      !isReadOnlySharedConversation(active, owner.accountId)) {
    final leaves = switch (change) {
      ChatBulkChange.delete => outcome.removedChatIds.contains(active.id),
      ChatBulkChange.archive => true,
      ChatBulkChange.unarchive || ChatBulkChange.unshare => false,
    };
    if (leaves) {
      clearSelectedFiltersForConversationBoundary(ref);
      _readProvider(ref, activeConversationProvider.notifier).clear();
      _readProvider(ref, chatMessagesProvider.notifier).clearMessages();
    } else if (change == ChatBulkChange.unarchive) {
      _readProvider(
        ref,
        activeConversationProvider.notifier,
      ).set(active.copyWith(archived: false));
    } else if (change == ChatBulkChange.unshare) {
      _readProvider(
        ref,
        activeConversationProvider.notifier,
      ).set(active.copyWith(shareId: null));
    }
  }
  refreshConversationsCache(ref);
}
