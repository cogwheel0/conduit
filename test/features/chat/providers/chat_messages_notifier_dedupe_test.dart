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

ChatMessage _assistantMessage({
  String id = 'assistant-1',
  List<String> followUps = const [],
  List<ChatStatusUpdate> statusHistory = const [],
}) {
  return ChatMessage(
    id: id,
    role: 'assistant',
    content: 'Visible response body',
    timestamp: DateTime(2024, 1, 1),
    followUps: followUps,
    statusHistory: statusHistory,
  );
}

void main() {
  group('ChatMessagesNotifier dedupe', () {
    ProviderContainer buildContainer() {
      return ProviderContainer(
        overrides: [
          activeConversationProvider.overrideWith(
            () => _TestActiveConversationNotifier(),
          ),
          socketServiceProvider.overrideWithValue(null),
        ],
      );
    }

    test('setFollowUps skips identical lists and notifies on changes', () {
      final container = buildContainer();
      addTearDown(container.dispose);

      final notifier = container.read(chatMessagesProvider.notifier);
      notifier.setMessages([
        _assistantMessage(followUps: const ['Ask again']),
      ]);

      var notifications = 0;
      final subscription = container.listen<List<ChatMessage>>(
        chatMessagesProvider,
        (_, _) => notifications += 1,
        fireImmediately: false,
      );
      addTearDown(subscription.close);

      notifier.setFollowUps('assistant-1', const ['Ask again']);
      expect(notifications, 0);

      notifier.setFollowUps('assistant-1', const ['Try another']);
      expect(notifications, 1);
      expect(container.read(chatMessagesProvider).single.followUps, const [
        'Try another',
      ]);
    });

    test(
      'appendStatusUpdate skips duplicate rows and notifies on meaningful changes',
      () {
        final container = buildContainer();
        addTearDown(container.dispose);

        final notifier = container.read(chatMessagesProvider.notifier);
        final timestamp = DateTime(2024, 1, 1, 12);
        final baselineStatus = ChatStatusUpdate(
          action: 'search',
          description: 'Searching',
          done: false,
          occurredAt: timestamp,
        );
        notifier.setMessages([
          _assistantMessage(statusHistory: [baselineStatus]),
        ]);

        var notifications = 0;
        final subscription = container.listen<List<ChatMessage>>(
          chatMessagesProvider,
          (_, _) => notifications += 1,
          fireImmediately: false,
        );
        addTearDown(subscription.close);

        notifier.appendStatusUpdate(
          'assistant-1',
          baselineStatus.copyWith(
            occurredAt: timestamp.add(const Duration(seconds: 1)),
          ),
        );
        expect(notifications, 0);
        expect(container.read(chatMessagesProvider).single.statusHistory, [
          baselineStatus,
        ]);

        notifier.appendStatusUpdate(
          'assistant-1',
          baselineStatus.copyWith(
            done: true,
            occurredAt: timestamp.add(const Duration(seconds: 2)),
          ),
        );
        expect(notifications, 1);
        expect(
          container.read(chatMessagesProvider).single.statusHistory.single.done,
          isTrue,
        );
      },
    );
  });
}
