import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart';

import '../../channels/providers/channel_providers.dart';
import '../../hermes/providers/hermes_providers.dart';
import '../models/app_notification.dart';
import '../models/notification_scope.dart';

part 'active_view_tracker.g.dart';

/// The chat / channel the user is currently looking at, and the account and
/// Hermes connection it belongs to.
///
/// Derived from the existing [activeConversationProvider] and
/// [activeChannelProvider], which are set synchronously when their pages load.
/// This is the source of truth for notification foreground-suppression — a
/// `NavigatorObserver` cannot recover these ids (the chat route carries no path
/// parameter), whereas these providers already track them reactively.
class ActiveView {
  const ActiveView({
    this.chatId,
    this.channelId,
    this.openWebUiAccountId,
    this.hermesConnectionId,
    this.hermesSessionId,
  });

  /// The open conversation's id.
  final String? chatId;

  /// The open channel's id.
  final String? channelId;

  /// The active Open WebUI account, whose chats and channels are the ones on
  /// screen.
  final String? openWebUiAccountId;

  /// The Hermes connection in use.
  final String? hermesConnectionId;

  /// The Hermes session of the open conversation, when it is a Hermes chat.
  final String? hermesSessionId;

  bool isViewingChat(String id) => chatId != null && chatId == id;

  bool isViewingChannel(String id) => channelId != null && channelId == id;

  /// Whether [notification] points at what is on screen right now: the same
  /// chat, channel or Hermes session, in the same account or connection. A
  /// reply in another account's chat with the same id is not.
  bool isViewing(AppNotification notification) {
    final kind = notification.kind;
    final isReply =
        kind == NotificationKind.chatCompletion ||
        kind == NotificationKind.replyFailed;
    switch (NotificationScope.tryParse(notification.scope)) {
      case OpenWebUiNotificationScope(:final accountId):
        if (openWebUiAccountId != accountId) return false;
        if (isReply) return isViewingChat(notification.sourceId);
        if (kind == NotificationKind.channelMessage) {
          return isViewingChannel(notification.sourceId);
        }
        return false;
      case HermesNotificationScope(:final connectionId):
        if (hermesConnectionId != connectionId || !isReply) return false;
        return hermesSessionId != null &&
            hermesSessionId == notification.sourceId;
      case DirectNotificationScope():
        return isReply && isViewingChat(notification.sourceId);
      case null:
        return false;
    }
  }
}

@Riverpod(keepAlive: true)
ActiveView activeView(Ref ref) {
  final conversation = ref.watch(activeConversationProvider);
  final channel = ref.watch(activeChannelProvider);
  return ActiveView(
    chatId: conversation?.id,
    channelId: channel?.id,
    openWebUiAccountId: ref.watch(settledActiveAccountIdProvider),
    hermesConnectionId: ref.watch(hermesActiveConnectionIdProvider),
    hermesSessionId: _hermesSessionId(conversation),
  );
}

String? _hermesSessionId(Conversation? conversation) {
  final metadata = conversation?.metadata;
  if (metadata == null || metadata['backend'] != 'hermes') return null;
  final sessionId = metadata['hermesSessionId'];
  return sessionId is String && sessionId.isNotEmpty ? sessionId : null;
}
