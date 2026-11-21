/// Which embeds may hand the media they name on the account's server to the
/// app's players ([webEmbedCameFromOpenWebUiChat]), and which account those
/// players fetch it as ([webEmbedMediaAccountProvider]).
library;

import 'package:meta/meta.dart';
import 'package:riverpod/riverpod.dart';

import '../../models/chat_message.dart';
import '../../models/conversation.dart';
import '../../models/server_config.dart';
import '../../providers/app_providers.dart';
import '../../services/chat_completion_transport.dart';
import '../chat/providers/chat_providers.dart'
    show chatMutationOwnerScopeForConversation, openWebUiChatMutationOwnerScope;
import '../hermes/services/hermes_session_provenance.dart'
    show isHermesSessionConversation;

/// Whether the embeds in [message], a reply in [conversation], came from an
/// Open WebUI chat: one the Open WebUI account owns, saved or temporary, and
/// a reply its server ran.
///
/// Hermes, Direct, LibreChat and on-device chats are not, nor a reply another
/// backend ran in an Open WebUI chat, such as a Hermes turn or a direct
/// connection's. Their pages name addresses that mean nothing on the Open
/// WebUI server, so they stay as written.
bool webEmbedCameFromOpenWebUiChat(
  Conversation? conversation, {
  ChatMessage? message,
}) {
  if (conversation == null || isHermesSessionConversation(conversation)) {
    return false;
  }
  if (chatMutationOwnerScopeForConversation(conversation) !=
      openWebUiChatMutationOwnerScope(conversation.id)) {
    return false;
  }
  // Every other backend marks its replies; Open WebUI's carry no marker, or
  // the way its completion streamed.
  final transport = message?.metadata?['transport'];
  return transport == null ||
      ChatCompletionTransport.values.any((it) => it.name == transport);
}

/// The account a web embed's server media is fetched as.
@immutable
final class WebEmbedMediaAccount {
  const WebEmbedMediaAccount({required this.server, required this.session});

  final ServerConfig server;

  /// The account's auth session ([openWebUiAuthSessionEpochProvider]): a new
  /// one for each sign-in, account or token, so a player keyed by it never
  /// outlives the account it fetched for.
  final Object session;

  @override
  bool operator ==(Object other) =>
      other is WebEmbedMediaAccount &&
      other.server.id == server.id &&
      other.server.url == server.url &&
      identical(other.session, session);

  @override
  int get hashCode =>
      Object.hash(server.id, server.url, identityHashCode(session));
}

/// The signed-in Open WebUI account while it owns the Chats tab; null
/// otherwise, as when signed out or while LibreChat is the account backend.
final webEmbedMediaAccountProvider = Provider<WebEmbedMediaAccount?>((ref) {
  if (!ref.watch(openWebUiAccountAvailableProvider)) return null;
  final api = ref.watch(apiServiceProvider);
  if (api == null) return null;
  return WebEmbedMediaAccount(
    server: api.serverConfig,
    session: ref.watch(openWebUiAuthSessionEpochProvider),
  );
});
