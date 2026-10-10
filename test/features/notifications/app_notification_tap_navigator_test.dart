import 'package:checks/checks.dart';
import 'package:conduit/features/navigation/providers/conversation_selection_provider.dart';
import 'package:conduit/features/notifications/services/notification_tap_router.dart';
import 'package:conduit_core/database/chat_database_repository.dart'
    show ChatStorageKind, kChatStorageKindMetadataKey;
import 'package:conduit_core/models/conversation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records the chat a tap asked to open and answers with [result].
final class _RecordingSelection extends ConversationSelection {
  _RecordingSelection(this.result, this.selected);

  final ConversationSelectionResult result;
  final List<Conversation> selected;

  @override
  Future<ConversationSelectionResult> select(Conversation summary) async {
    selected.add(summary);
    return result;
  }
}

final _navigatorProvider = Provider<AppNotificationTapNavigator>(
  AppNotificationTapNavigator.new,
);

void main() {
  group('openOpenWebUiChat', () {
    late List<Conversation> selected;

    ProviderContainer containerAnswering(ConversationSelectionResult result) {
      selected = [];
      final container = ProviderContainer(
        overrides: [
          conversationSelectionProvider.overrideWith(
            () => _RecordingSelection(result, selected),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('opens the chat through the selection flow', () async {
      final container = containerAnswering(
        const ConversationSelectionResult.canceled(),
      );

      await container.read(_navigatorProvider).openOpenWebUiChat('c1');

      // The flow waits for the account's storage, loads the chat (from the
      // server without a copy here) and makes it the active conversation.
      check(selected).length.equals(1);
      check(selected.single.id).equals('c1');
      check(
        selected.single.metadata[kChatStorageKindMetadataKey],
      ).equals(ChatStorageKind.openWebUi.name);
    });

    test('a chat that fails to load does not throw', () async {
      final container = containerAnswering(
        ConversationSelectionResult.failed(
          StateError('storage'),
          StackTrace.empty,
        ),
      );

      await container.read(_navigatorProvider).openOpenWebUiChat('c1');

      check(selected.single.id).equals('c1');
    });
  });
}
