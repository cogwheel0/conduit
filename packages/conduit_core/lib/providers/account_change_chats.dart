import 'package:conduit_core/database/account_storage_isolation.dart'
    show conversationUsesOpenWebUiStorage;
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart'
    show isHermesSessionConversation, kHermesSessionConversationIdPrefix;
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart'
    show chatStorageKindOf;

/// Who a chat belongs to, which decides what an account change ends.
enum ChatOwner {
  /// Kept on this device and owned by no account: a Direct chat whose
  /// history stays here, an Apple model's, a Hermes session's.
  device,

  /// Stored in the Open WebUI account's database: its own chats, and a Direct
  /// chat whose history the account keeps.
  openWebUi,

  /// Stored in the LibreChat account's database.
  libreChat,
}

/// The owner of [conversation], or of the chat [chatId] names while its
/// conversation is not known. A chat known by neither is taken as Open
/// WebUI's, as a chat with no annotation always has been.
ChatOwner chatOwnerOf(Conversation? conversation, {String? chatId}) {
  final id = conversation?.id ?? chatId;
  final storage =
      chatStorageKindOf(conversation) ??
      (id == null ? null : ChatStorageIdentity.parse(id).storage);
  if (storage == ChatStorageKind.libreChat) return ChatOwner.libreChat;
  if (storage == ChatStorageKind.openWebUi) return ChatOwner.openWebUi;
  if (storage == ChatStorageKind.directLocal ||
      isHermesSessionConversation(conversation) ||
      (id != null &&
          (id.startsWith(kHermesSessionConversationIdPrefix) ||
              ChatStorageIdentity.parse(id).rawId.startsWith(
                'direct-local:',
              )))) {
    return ChatOwner.device;
  }
  if (conversation == null) return ChatOwner.openWebUi;
  return conversationUsesOpenWebUiStorage(conversation)
      ? ChatOwner.openWebUi
      : ChatOwner.device;
}

/// What changed about the accounts.
enum AccountChange {
  /// The Open WebUI session: a sign-in (the first, or again), a switch to
  /// another account, a sign-out.
  openWebUiSession,

  /// The Open WebUI client for the same session: its address changed, or it
  /// was built again.
  openWebUiClient,

  /// The account in charge of the chats: Open WebUI and LibreChat taking over
  /// from each other, or one LibreChat account from another.
  chatsAccount,
}

/// Whether [change] ends a chat [owner] owns: a chat belongs to the account
/// it is stored in, and a chat stored in none outlives every account change.
/// A new client for the same session ends only what reaches the server
/// through it, so not a chat whose running reply comes from elsewhere
/// ([replyBypassesOpenWebUi]: a Direct, Apple or Hermes reply).
bool accountChangeEndsChat(
  AccountChange change,
  ChatOwner owner, {
  bool replyBypassesOpenWebUi = false,
}) => switch (change) {
  AccountChange.openWebUiSession => owner == ChatOwner.openWebUi,
  AccountChange.openWebUiClient =>
    owner == ChatOwner.openWebUi && !replyBypassesOpenWebUi,
  AccountChange.chatsAccount => owner != ChatOwner.device,
};
