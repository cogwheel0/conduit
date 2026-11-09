import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/providers/app_providers.dart';

/// Marks the start of what the user's own picks in a chat belong to: one
/// conversation of one signed-in account.
///
/// The tools, filters, terminal and features the user turns on or off are
/// kept through a switch of model, as on Open WebUI 0.12.5, and start again
/// from the model's defaults in another chat, as its web client starts them
/// on every navigation. Every new value of this provider starts them again:
/// a conversation boundary sets one, and so does another account or server.
/// A connection issue that keeps the account signed in leaves them as they
/// are. The value is only an identity to compare.
final chatPicksSessionProvider = NotifierProvider<ChatPicksSession, Object>(
  ChatPicksSession.new,
);

class ChatPicksSession extends Notifier<Object> {
  @override
  Object build() {
    ref
      ..watch(currentUserProvider2.select((user) => user?.id))
      ..watch(activeServerProvider.select((server) => server.asData?.value?.id))
      // LibreChat's tool picks name its servers, which another account may
      // name too.
      ..watch(activeLibreChatAccountProvider.select((account) => account?.id));
    return Object();
  }

  /// Another conversation is opened or started.
  void newConversation() => state = Object();
}
