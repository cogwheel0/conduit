// The startup rule: the active conversation lives in memory for one app
// session and is never restored. A cold start (a new provider container)
// opens a new chat, however many chats with messages exist. The app must not
// persist or restore it (a reported "relaunch reopens the last chat" traced
// to a relaunch that kept the old process, not to any restore in the code).
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

Conversation _chatWithMessages() => Conversation(
  id: 'chat-1',
  title: 'A chat with messages',
  createdAt: DateTime(2026, 9, 30),
  updatedAt: DateTime(2026, 9, 30),
  messages: [
    ChatMessage(
      id: 'm1',
      role: 'user',
      content: 'hello',
      timestamp: DateTime(2026, 9, 30),
    ),
    ChatMessage(
      id: 'm2',
      role: 'assistant',
      content: 'hi',
      timestamp: DateTime(2026, 9, 30),
    ),
  ],
);

void main() {
  test('a new session starts on a new chat, not the last one', () {
    final first = ProviderContainer();
    first.read(activeConversationProvider.notifier).set(_chatWithMessages());
    expect(first.read(activeConversationProvider)?.id, 'chat-1');
    first.dispose();

    // The relaunch: a new container over the same (persisted) data.
    final second = ProviderContainer();
    addTearDown(second.dispose);
    expect(second.read(activeConversationProvider), isNull);
  });

  test('starting a new chat clears the open one', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(activeConversationProvider.notifier)
        .set(_chatWithMessages());

    container.read(activeConversationProvider.notifier).clear();

    expect(container.read(activeConversationProvider), isNull);
  });
}
