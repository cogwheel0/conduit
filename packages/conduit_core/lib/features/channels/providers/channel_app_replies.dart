import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:conduit_core/models/channel_app.dart';
import 'package:conduit_core/providers/app_providers.dart';

part 'channel_app_replies.g.dart';

/// App replies that only the signed-in user sees, keyed by
/// [AppChannelReplyEvent.key], for the channel [channelId] itself
/// ([parentId] null) or for its thread [parentId].
///
/// Mirrors Open WebUI's Messages.svelte: replies arrive over `events:app` or
/// as the answer to a button press, are never stored, and are dropped when the
/// view that shows them goes away, so this provider is not kept alive.
@riverpod
class ChannelAppReplies extends _$ChannelAppReplies {
  @override
  Map<String, AppChannelReplyEvent> build(String channelId, String? parentId) {
    // A new account or server starts with no replies.
    ref.watch(openWebUiAuthSessionEpochProvider);
    final socket = ref.watch(socketServiceProvider);
    if (socket != null) {
      final subscription = socket.addAppEventHandler(
        (event) => add(AppChannelReplyEvent.fromJson(event)),
      );
      ref.onDispose(subscription.dispose);
    }
    return const {};
  }

  /// Shows [event] under its message when it belongs to this channel or
  /// thread. An acknowledgement has nothing to show.
  void add(AppChannelReplyEvent? event) {
    if (event == null ||
        event.reply.isAck ||
        event.channelId != channelId ||
        event.parentId != parentId) {
      return;
    }
    state = {...state, event.key: event};
  }

  /// Removes the reply [key] at the user's request.
  void dismiss(String key) {
    if (!state.containsKey(key)) return;
    state = {...state}..remove(key);
  }
}
