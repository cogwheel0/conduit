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

ChatMessage _assistantMessage({required bool isStreaming}) => ChatMessage(
  id: 'assistant-1',
  role: 'assistant',
  content: 'Thinking',
  timestamp: DateTime(2024, 1, 1),
  isStreaming: isStreaming,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<bool> toggles;
  late ProviderContainer container;

  setUp(() {
    toggles = <bool>[];
    container = ProviderContainer(
      overrides: [
        activeConversationProvider.overrideWith(
          () => _TestActiveConversationNotifier(),
        ),
        apiServiceProvider.overrideWithValue(null),
        socketServiceProvider.overrideWithValue(null),
        chatWakelockToggleProvider.overrideWithValue(({required bool enable}) {
          toggles.add(enable);
          return Future<void>.value();
        }),
      ],
    );
    addTearDown(container.dispose);
  });

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('holds the screen only while the assistant is streaming', () async {
    container.read(chatWakelockCoordinatorProvider);
    await settle();
    expect(toggles, isEmpty, reason: 'idle chats never touch the wakelock');

    final notifier = container.read(chatMessagesProvider.notifier);
    notifier.setMessages([_assistantMessage(isStreaming: true)]);
    await settle();
    expect(toggles, [true]);

    notifier.setMessages([_assistantMessage(isStreaming: false)]);
    await settle();
    expect(toggles, [true, false]);
  });

  test('ignores repeated streaming updates while already held', () async {
    container.read(chatWakelockCoordinatorProvider);
    final notifier = container.read(chatMessagesProvider.notifier);

    notifier.setMessages([_assistantMessage(isStreaming: true)]);
    notifier.setMessages([
      _assistantMessage(isStreaming: true).copyWith(content: 'Thinking more'),
    ]);
    await settle();
    expect(toggles, [true]);

    notifier.clearMessages();
    await settle();
    expect(toggles, [true, false]);
  });

  test(
    'releases the hold when the coordinator is disposed mid-stream',
    () async {
      container.read(chatWakelockCoordinatorProvider);
      container.read(chatMessagesProvider.notifier).setMessages([
        _assistantMessage(isStreaming: true),
      ]);
      await settle();
      expect(toggles, [true]);

      container.dispose();
      await settle();
      expect(toggles, [true, false]);
    },
  );

  test(
    'a process-owned generation keeps the lock after the chat switches',
    () async {
      container.read(chatWakelockCoordinatorProvider);
      final notifier = container.read(chatMessagesProvider.notifier);
      final release = holdLocalChatGeneration(container);
      notifier.setMessages([_assistantMessage(isStreaming: true)]);
      await settle();
      expect(toggles, [true]);

      // Switching chats replaces the visible list while the run continues.
      notifier.setMessages(const []);
      await settle();
      expect(toggles, [true], reason: 'the owned run still needs the screen');

      release();
      release();
      await settle();
      expect(toggles, [true, false]);
      expect(container.read(localChatGenerationActiveProvider), isFalse);
    },
  );

  test('a failing platform toggle does not break later toggles', () async {
    var calls = 0;
    final failing = ProviderContainer(
      overrides: [
        activeConversationProvider.overrideWith(
          () => _TestActiveConversationNotifier(),
        ),
        apiServiceProvider.overrideWithValue(null),
        socketServiceProvider.overrideWithValue(null),
        chatWakelockToggleProvider.overrideWithValue(({required bool enable}) {
          calls += 1;
          if (calls == 1) throw StateError('no wakelock on this platform');
          toggles.add(enable);
          return Future<void>.value();
        }),
      ],
    );
    addTearDown(failing.dispose);

    failing.read(chatWakelockCoordinatorProvider);
    final notifier = failing.read(chatMessagesProvider.notifier);
    notifier.setMessages([_assistantMessage(isStreaming: true)]);
    await settle();
    notifier.setMessages([_assistantMessage(isStreaming: false)]);
    await settle();

    expect(calls, 2);
    expect(toggles, [false]);
  });
}
