import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/providers/app_providers.dart';
import '../../channels/providers/channel_providers.dart';

part 'active_view_tracker.g.dart';

/// The chat / channel the user is currently looking at.
///
/// Derived from the existing [activeConversationProvider] and
/// [activeChannelProvider], which are set synchronously when their pages load.
/// This is the source of truth for notification foreground-suppression — a
/// `NavigatorObserver` cannot recover these ids (the chat route carries no path
/// parameter), whereas these providers already track them reactively.
class ActiveView {
  const ActiveView({this.chatId, this.channelId});

  final String? chatId;
  final String? channelId;

  bool isViewingChat(String id) => chatId != null && chatId == id;

  bool isViewingChannel(String id) => channelId != null && channelId == id;
}

@Riverpod(keepAlive: true)
ActiveView activeView(Ref ref) {
  final conversation = ref.watch(activeConversationProvider);
  final channel = ref.watch(activeChannelProvider);
  return ActiveView(chatId: conversation?.id, channelId: channel?.id);
}
