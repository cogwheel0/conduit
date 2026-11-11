import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart';

import '../../../shared/services/navigation_service.dart';

/// Whether Android back on the chat page opens the chat list (#852).
///
/// A chat the user switched to, from the list, a folder, the calendar, a
/// scheduled task, a Hermes session or a notification, sits under the list.
/// The chat the app opened into is the top screen, and a new chat becomes it
/// again, so back there asks to close the app.
final chatBackOpensListProvider = NotifierProvider<ChatBackOpensList, bool>(
  ChatBackOpensList.new,
);

class ChatBackOpensList extends Notifier<bool> {
  @override
  bool build() {
    ref.listen<Conversation?>(activeConversationProvider, (_, next) {
      if (next == null) state = false;
    });
    return false;
  }

  /// Records that [next] is about to replace what is on screen. Opening the
  /// chat already on screen again is not a switch; [chatOnScreen] says
  /// whether it is, as a chat left for a channel or folder stays active.
  void switchTo(Conversation next, {required bool chatOnScreen}) {
    final current = ref.read(activeConversationProvider);
    if (chatOnScreen && isSameStoredConversation(current, next)) return;
    state = true;
  }
}

/// Whether the chat page is the page on screen.
bool chatPageOnScreen() =>
    Uri.tryParse(NavigationService.currentRoute ?? '')?.path == Routes.chat;
