import 'package:conduit/features/navigation/providers/chat_back_provider.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Conversation _chat(String id) => withChatStorageProvenance(
  Conversation(
    id: id,
    title: id,
    createdAt: DateTime.utc(2026, 10, 26),
    updatedAt: DateTime.utc(2026, 10, 26),
  ),
  ChatStorageKind.openWebUi,
);

void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  bool opensList() => container.read(chatBackOpensListProvider);

  void open(Conversation chat, {bool chatOnScreen = true}) {
    container
        .read(chatBackOpensListProvider.notifier)
        .switchTo(chat, chatOnScreen: chatOnScreen);
    container.read(activeConversationProvider.notifier).set(chat);
  }

  test('the chat the app opens into keeps the close prompt', () {
    expect(opensList(), isFalse);

    // A new chat gaining its first message is not a switch.
    container.read(activeConversationProvider.notifier).set(_chat('sent'));
    expect(opensList(), isFalse);
  });

  test('switching to another chat makes back open the list', () {
    open(_chat('older'));

    expect(opensList(), isTrue);
  });

  test('reopening the chat on screen is not a switch', () {
    container.read(activeConversationProvider.notifier).set(_chat('launch'));

    open(_chat('launch'));

    expect(opensList(), isFalse);
  });

  test('reopening a chat left for a channel or folder is a switch', () {
    container.read(activeConversationProvider.notifier).set(_chat('launch'));

    // The chat stays active behind the channel, but it is not on screen.
    open(_chat('launch'), chatOnScreen: false);

    expect(opensList(), isTrue);
  });

  test('a new chat is the top screen again', () {
    open(_chat('older'));

    container.read(activeConversationProvider.notifier).clear();
    expect(opensList(), isFalse);

    // Sending in that new chat keeps it the top screen.
    container.read(activeConversationProvider.notifier).set(_chat('sent'));
    expect(opensList(), isFalse);
  });

  test('a switch from one switched chat to another keeps the list', () {
    open(_chat('older'));
    open(_chat('oldest'));

    expect(opensList(), isTrue);
  });
}
