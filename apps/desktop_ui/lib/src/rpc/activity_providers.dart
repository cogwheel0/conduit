import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import 'chat_providers.dart';
import 'rpc_providers.dart';

/// What a sidebar row's status dot says about its conversation.
enum ChatActivity {
  /// An answer is being written.
  running,

  /// An answer finished while the conversation was not the one on screen.
  unread,

  /// An answer failed while the conversation was not the one on screen.
  failed,
}

/// The next activity map after [event] for [chatId], with [selected] the
/// conversation on screen. Returns [current] itself when nothing changes,
/// so a stream of deltas does not rebuild the sidebar sixty times a second.
Map<String, ChatActivity> nextActivity(
  Map<String, ChatActivity> current, {
  required String event,
  required String chatId,
  required String? selected,
}) {
  final ChatActivity? next = switch (event) {
    ConduitEvents.turnStarted ||
    ConduitEvents.turnDelta => ChatActivity.running,
    ConduitEvents.turnCompleted =>
      chatId == selected ? null : ChatActivity.unread,
    ConduitEvents.turnFailed => chatId == selected ? null : ChatActivity.failed,
    _ => current[chatId],
  };
  if (current[chatId] == next) return current;
  return <String, ChatActivity>{
    for (final entry in current.entries)
      if (entry.key != chatId) entry.key: entry.value,
    chatId: ?next,
  };
}

/// Every conversation with something to show on its status dot.
///
/// Opening a conversation clears its unread or failed dot; not a running
/// one, since that answer is still being written.
final chatActivityProvider =
    NotifierProvider<ChatActivityNotifier, Map<String, ChatActivity>>(
      ChatActivityNotifier.new,
    );

class ChatActivityNotifier extends Notifier<Map<String, ChatActivity>> {
  @override
  Map<String, ChatActivity> build() {
    ref.watch(eventSubscriptionProvider);
    final subscription = ref.watch(rpcClientProvider).events.listen((envelope) {
      final chatId = switch (envelope.payload['chatId']) {
        final String id => id,
        _ => null,
      };
      if (chatId == null) return;
      state = nextActivity(
        state,
        event: envelope.event,
        chatId: chatId,
        selected: ref.read(selectedChatIdProvider),
      );
    });
    ref.onDispose(() => unawaited(subscription.cancel()));
    ref.listen<String?>(selectedChatIdProvider, (_, selected) {
      if (selected == null) return;
      if (state[selected] case ChatActivity.unread || ChatActivity.failed) {
        state = <String, ChatActivity>{
          for (final entry in state.entries)
            if (entry.key != selected) entry.key: entry.value,
        };
      }
    });
    return const <String, ChatActivity>{};
  }
}
