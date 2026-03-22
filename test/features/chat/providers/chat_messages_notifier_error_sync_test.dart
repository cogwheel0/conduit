import 'package:checks/checks.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestActiveConversationNotifier extends ActiveConversationNotifier {
  @override
  Conversation? build() => null;
}

class _SyncingTestMessagesNotifier extends ChatMessagesNotifier {
  @override
  List<ChatMessage> build() => [];

  @override
  void setMessages(List<ChatMessage> messages) {
    state = messages;
  }

  @override
  void updateLastMessageWithFunction(
    ChatMessage Function(ChatMessage) updater,
  ) {
    if (state.isEmpty) return;
    final last = state.last;
    if (last.role != 'assistant') return;
    state = [...state.sublist(0, state.length - 1), updater(last)];
  }

  @override
  void finishStreaming() {
    if (state.isEmpty) return;
    final last = state.last;
    if (last.role != 'assistant' || !last.isStreaming) return;

    final updatedLast = last.copyWith(isStreaming: false);
    state = [...state.sublist(0, state.length - 1), updatedLast];

    final activeConversation = ref.read(activeConversationProvider);
    if (activeConversation == null) return;
    ref
        .read(activeConversationProvider.notifier)
        .set(
          activeConversation.copyWith(messages: List<ChatMessage>.from(state)),
        );
  }
}

void main() {
  group('ChatMessagesNotifier error finalization', () {
    test('finishStreaming syncs an early error into activeConversation', () {
      final container = ProviderContainer(
        overrides: [
          chatMessagesProvider.overrideWith(
            () => _SyncingTestMessagesNotifier(),
          ),
          activeConversationProvider.overrideWith(
            () => _TestActiveConversationNotifier(),
          ),
        ],
      );
      addTearDown(container.dispose);

      final timestamp = DateTime.now();
      final user = ChatMessage(
        id: 'user-1',
        role: 'user',
        content: 'Hello',
        timestamp: timestamp,
      );
      final assistant = ChatMessage(
        id: 'assistant-1',
        role: 'assistant',
        content: '',
        timestamp: timestamp,
        isStreaming: true,
      );

      container
          .read(activeConversationProvider.notifier)
          .set(
            Conversation(
              id: 'local:test-chat',
              title: 'New Chat',
              createdAt: timestamp,
              updatedAt: timestamp,
              messages: [user, assistant],
            ),
          );

      final notifier = container.read(chatMessagesProvider.notifier);
      notifier.setMessages([user, assistant]);

      notifier.updateLastMessageWithFunction(
        (message) => message.copyWith(
          error: const ChatMessageError(content: 'Transport setup failed'),
        ),
      );
      notifier.finishStreaming();

      final messages = container.read(chatMessagesProvider);
      check(messages).length.equals(2);
      check(messages.last.role).equals('assistant');
      check(messages.last.isStreaming).isFalse();
      check(messages.last.error).isNotNull();
      check(messages.last.error!.content).equals('Transport setup failed');

      final activeConversation = container.read(activeConversationProvider);
      check(activeConversation).isNotNull();
      check(activeConversation!.messages).length.equals(2);
      check(activeConversation.messages.last.isStreaming).isFalse();
      check(activeConversation.messages.last.error).isNotNull();
      check(
        activeConversation.messages.last.error!.content,
      ).equals('Transport setup failed');
    });
  });
}
