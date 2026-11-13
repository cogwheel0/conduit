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
  final onDevice = isDirectLocalConversation(conversation);
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
          () => ref.read(openWebUiChatImportAllowedProvider.future)
              as Future<bool>,
        );
  }
  final export =
      api != null &&
      !isTemporary &&
      chatMutationOwnerScopeForConversation(conversation) ==
          openWebUiChatMutationOwnerScope(conversation.id) &&
      await allowed(
        () => ref.read(openWebUiChatActionAllowedProvider('export').future)
            as Future<bool>,
      );
  final advanced =
      (ref.read(appSettingsProvider) as AppSettings).advancedFeaturesEnabled;
  final durableOpenWebUi =
      api != null &&
      _readAppDatabaseOrNull(ref) != null &&
      ref.read(isAuthenticatedProvider2) == true &&
      !reviewer &&
      !isTemporary &&
      conversationUsesOpenWebUiStorage(conversation);
  // The chat menu's own actions: none on a temporary chat or another user's.
  final menu = !isTemporary && !readOnly && !onDevice;
  final shareId = conversation.shareId;
  final bool share;
  if (!menu) {
    share = false;
  } else if (!libreChat) {
    share = true;
  } else if (shareId != null && shareId.isNotEmpty) {
    share = true;
  } else {
    share = await allowed(() async {
      final dynamic capabilities = await ref.read(
        libreChatCapabilitiesProvider.future,
      );
      return capabilities.sharedLinks == true;
    });
  }
  return ChatActionAvailability(
    fork: fork,
    export: export,
    merge: advanced && durableOpenWebUi && !readOnly && !mergeRunning,
    branch: branch,
    deleteMessages: !readOnly && !libreChat,
    markUnread:
        menu && !libreChat && ref.read(chatMarkUnreadSupportedProvider) == true,
    generateTitle:
        menu &&
        !libreChat &&
        !isNativeHermesConversation(conversation) &&
        api != null,
    share: share,
    saveTemporary:
        isTemporary &&
        conversation.messages.isNotEmpty &&
        api != null &&
        !isNativeHermesConversation(conversation),
    compare: advanced && durableOpenWebUi && !readOnly,
  );
}
