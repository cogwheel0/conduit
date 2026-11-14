part of 'chat_providers.dart';

/// What one chat offers in its menus and on its messages, as the phone's
/// chat page and chat menus decide each one. For a host that shows a chat
/// without making it the active one (the desktop daemon answers for any
/// chat a window opens): every rule here reads the [Conversation] it is
/// given, never [activeConversationProvider].
@immutable
final class ChatActionAvailability {
  const ChatActionAvailability({
    this.fork = false,
    this.export = false,
    this.merge = false,
    this.branch = false,
    this.deleteMessages = false,
    this.markUnread = false,
    this.generateTitle = false,
    this.share = false,
    this.saveTemporary = false,
    this.compare = false,
  });

  /// Fork Chat ([chatForkAvailabilityProvider] not hidden).
  final bool fork;

  /// Export ([chatExportAvailableProvider]).
  final bool export;

  /// Merge Responses may start ([comparisonMergeCommandAvailableProvider]).
  final bool merge;

  /// Branch controls ([chatBranchControlsProvider]).
  final bool branch;

  /// Deleting messages (the chat page's `_messagesDeletable`, never in
  /// another user's chat).
  final bool deleteMessages;

  /// Mark as Unread (the chat menu's `showMarkUnread`).
  final bool markUnread;

  /// Generate Title (the chat menu's `canGenerateTitle`).
  final bool generateTitle;

  /// Share (the chat menu's `canShare`).
  final bool share;

  /// Save Chat for a temporary chat with messages.
  final bool saveTemporary;

  /// Compare Models ([comparisonCommandAvailableProvider], the model left
  /// to the composer).
  final bool compare;
}

/// What a chat's menus offer for it -- a host's chat list menu and its
/// menu bar's Chat menu -- as the phone's conversation menu decides each one
/// (`buildConversationActionsWithFolders`), plus Export as the chat page
/// offers it. Read synchronously ([chatMenuAvailability]) so a host can list
/// it beside every chat; [chatActionAvailability] answers the same rule for
/// one open chat.
@immutable
final class ChatMenuAvailability {
  const ChatMenuAvailability({
    this.share = false,
    this.duplicate = false,
    this.move = false,
    this.markUnread = false,
    this.generateTitle = false,
    this.export = false,
  });

  /// Share Chat: not for an on-device or temporary chat, nor another
  /// user's; a LibreChat chat only where its server allows links (or it has
  /// one already).
  final bool share;

  /// Duplicate Chat: a LibreChat chat's copy on its server, while online.
  final bool duplicate;

  /// Move To a folder: an Open WebUI chat while folders are on.
  final bool move;

  /// Mark as Unread (or Read): an Open WebUI chat on a server that keeps
  /// the mark.
  final bool markUnread;

  /// Generate Title: a chat the server holds (not LibreChat's, not a native
  /// Hermes session's).
  final bool generateTitle;

  /// Export: an Open WebUI chat the account may export.
  final bool export;
}

/// The one rule behind [ChatMenuAvailability], from what the caller read.
ChatMenuAvailability _chatMenuRule(
  Conversation conversation, {
  required bool readOnly,
  required bool temporary,
  required bool apiPresent,
  required bool libreChatSharedLinks,
  required bool markUnreadSupported,
  required bool exportAllowed,
  required bool online,
  required bool foldersAvailable,
}) {
  final onDevice = isDirectLocalConversation(conversation);
  final libreChat = isLibreChatConversation(conversation);
  // The chat menu's own actions: none on a temporary chat or another user's.
  final menu = !temporary && !readOnly && !onDevice;
  final shareId = conversation.shareId;
  final bool share;
  if (!menu) {
    share = false;
  } else if (!libreChat) {
    share = true;
  } else {
    share = (shareId != null && shareId.isNotEmpty) || libreChatSharedLinks;
  }
  return ChatMenuAvailability(
    share: share,
    duplicate: libreChat && !readOnly && online,
    move: menu && !libreChat && foldersAvailable,
    markUnread: menu && !libreChat && markUnreadSupported,
    generateTitle:
        menu &&
        !libreChat &&
        !isNativeHermesConversation(conversation) &&
        apiPresent,
    export:
        apiPresent &&
        !temporary &&
        chatMutationOwnerScopeForConversation(conversation) ==
            openWebUiChatMutationOwnerScope(conversation.id) &&
        exportAllowed,
  );
}

/// [ChatMenuAvailability] for [conversation] from what is loaded now: an
/// account permission or LibreChat's capabilities still loading read as
/// not allowed (a host lists again once they load). [temporary] marks a
/// chat the server never stores (besides a `local:` id).
ChatMenuAvailability chatMenuAvailability(
  dynamic ref,
  Conversation conversation, {
  bool temporary = false,
}) {
  bool read(Object? Function() value) {
    try {
      return value() == true;
    } catch (_) {
      return false;
    }
  }

  final userId = (ref.read(currentUserProvider2) as User?)?.id;
  return _chatMenuRule(
    conversation,
    readOnly: isReadOnlySharedConversation(conversation, userId),
    temporary: temporary || isTemporaryChat(conversation.id),
    apiPresent: ref.read(apiServiceProvider) != null,
    libreChatSharedLinks: read(() {
      // Typed, not dynamic: `asData` is an extension getter.
      final loaded =
          ref.read(libreChatCapabilitiesProvider) as AsyncValue<Object?>;
      final dynamic capabilities = loaded.asData?.value;
      return capabilities?.sharedLinks;
    }),
    markUnreadSupported: read(() => ref.read(chatMarkUnreadSupportedProvider)),
    exportAllowed: read(
      () => (ref.read(
        openWebUiChatActionAllowedProvider('export'),
      ) as AsyncValue<bool>).asData?.value,
    ),
    online: read(() => ref.read(isOnlineProvider)),
    foldersAvailable: read(() => ref.read(foldersAvailableProvider)),
  );
}

/// Whether the branch controls apply to [conversation]: the signed-in
/// user's own durable Open WebUI chat, outside reviewer mode, as
/// [chatBranchControlsProvider] decides for the active chat.
bool chatBranchControlsFor(dynamic ref, Conversation conversation) {
  if (ref.read(reviewerModeProvider) == true) return false;
  if (ref.read(apiServiceProvider) == null) return false;
  return _conversationIsBranchableByUser(
    conversation,
    (ref.read(currentUserProvider2) as User?)?.id,
  );
}

/// [ChatActionAvailability] for [conversation]. [temporary] marks a chat the
/// server never stores (besides a `local:` id); [mergeRunning] says a merge
/// is already writing in it.
Future<ChatActionAvailability> chatActionAvailability(
  dynamic ref,
  Conversation conversation, {
  bool temporary = false,
  bool mergeRunning = false,
}) async {
  final userId = (ref.read(currentUserProvider2) as User?)?.id;
  final readOnly = isReadOnlySharedConversation(conversation, userId);
  final isTemporary = temporary || isTemporaryChat(conversation.id);
  final api = ref.read(apiServiceProvider);
  final reviewer = ref.read(reviewerModeProvider) == true;
  final libreChat = isLibreChatConversation(conversation);
  final branch = !isTemporary && chatBranchControlsFor(ref, conversation);

  Future<bool> allowed(FutureOr<bool> Function() read) async {
    try {
      return await read();
    } catch (_) {
      return false;
    }
  }

  final bool fork;
  if (libreChat) {
    fork = !readOnly && ref.read(libreChatSyncEngineProvider) != null;
  } else {
    fork =
        branch &&
        await allowed(
          () =>
              ref.read(openWebUiChatImportAllowedProvider.future)
                  as Future<bool>,
        );
  }
  final advanced =
      (ref.read(appSettingsProvider) as AppSettings).advancedFeaturesEnabled;
  final durableOpenWebUi =
      api != null &&
      _readAppDatabaseOrNull(ref) != null &&
      ref.read(isAuthenticatedProvider2) == true &&
      !reviewer &&
      !isTemporary &&
      conversationUsesOpenWebUiStorage(conversation);
  // Share, Mark as Unread, Generate Title and Export: the menus' rule
  // ([chatMenuAvailability]), with the permissions it reads awaited.
  final menu = _chatMenuRule(
    conversation,
    readOnly: readOnly,
    temporary: isTemporary,
    apiPresent: api != null,
    libreChatSharedLinks:
        libreChat &&
        await allowed(() async {
          final dynamic capabilities = await ref.read(
            libreChatCapabilitiesProvider.future,
          );
          return capabilities.sharedLinks == true;
        }),
    markUnreadSupported: ref.read(chatMarkUnreadSupportedProvider) == true,
    exportAllowed:
        api != null &&
        !isTemporary &&
        await allowed(
          () =>
              ref.read(openWebUiChatActionAllowedProvider('export').future)
                  as Future<bool>,
        ),
    online: true,
    foldersAvailable: true,
  );
  return ChatActionAvailability(
    fork: fork,
    export: menu.export,
    merge: advanced && durableOpenWebUi && !readOnly && !mergeRunning,
    branch: branch,
    deleteMessages: !readOnly && !libreChat,
    markUnread: menu.markUnread,
    generateTitle: menu.generateTitle,
    share: menu.share,
    saveTemporary:
        isTemporary &&
        conversation.messages.isNotEmpty &&
        api != null &&
        !isNativeHermesConversation(conversation),
    compare: advanced && durableOpenWebUi && !readOnly,
  );
}
