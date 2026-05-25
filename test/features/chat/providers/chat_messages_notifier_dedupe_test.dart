import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestActiveConversationNotifier extends ActiveConversationNotifier {
  @override
  Conversation? build() => null;
}

ChatMessage _assistantMessage({
  String id = 'assistant-1',
  String content = 'Visible response body',
  bool isStreaming = false,
  List<String> followUps = const [],
  List<ChatStatusUpdate> statusHistory = const [],
  Map<String, dynamic>? usage,
}) {
  return ChatMessage(
    id: id,
    role: 'assistant',
    content: content,
    timestamp: DateTime(2024, 1, 1),
    isStreaming: isStreaming,
    followUps: followUps,
    statusHistory: statusHistory,
    usage: usage,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ChatMessagesNotifier dedupe', () {
    ProviderContainer buildContainer() {
      return ProviderContainer(
        overrides: [
          activeConversationProvider.overrideWith(
            () => _TestActiveConversationNotifier(),
          ),
          apiServiceProvider.overrideWithValue(null),
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
      'setFollowUps folds buffered streaming content into one notification',
      () {
        final container = buildContainer();
        addTearDown(container.dispose);

        final notifier = container.read(chatMessagesProvider.notifier);
        notifier.setMessages([
          _assistantMessage(content: 'Buffered', isStreaming: true),
        ]);

        var notifications = 0;
        final subscription = container.listen<List<ChatMessage>>(
          chatMessagesProvider,
          (_, _) => notifications += 1,
          fireImmediately: false,
        );
        addTearDown(subscription.close);

        notifier.appendToLastMessage(' content');
        expect(notifications, 0);

        notifier.setFollowUps('assistant-1', const ['Ask again']);
        expect(notifications, 1);
        expect(
          container.read(chatMessagesProvider).single.content,
          'Buffered content',
        );
        expect(container.read(chatMessagesProvider).single.followUps, const [
          'Ask again',
        ]);

        notifier.clearMessages();
      },
    );

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

    test('chatMessageByIdProvider only notifies the changed message', () async {
      final container = buildContainer();
      addTearDown(container.dispose);

      final notifier = container.read(chatMessagesProvider.notifier);
      notifier.setMessages([
        _assistantMessage(id: 'assistant-1', content: 'First'),
        _assistantMessage(id: 'assistant-2', content: 'Second'),
      ]);

      var firstNotifications = 0;
      var secondNotifications = 0;
      final firstSubscription = container.listen<ChatMessage?>(
        chatMessageByIdProvider('assistant-1'),
        (_, _) => firstNotifications += 1,
        fireImmediately: false,
      );
      final secondSubscription = container.listen<ChatMessage?>(
        chatMessageByIdProvider('assistant-2'),
        (_, _) => secondNotifications += 1,
        fireImmediately: false,
      );
      addTearDown(firstSubscription.close);
      addTearDown(secondSubscription.close);

      notifier.setFollowUps('assistant-1', const ['Ask again']);
      await Future<void>.delayed(Duration.zero);

      expect(firstNotifications, 1);
      expect(secondNotifications, 0);
    });

    test(
      'chatMessageStructureSignatureProvider ignores usage-only changes',
      () {
        final container = buildContainer();
        addTearDown(container.dispose);

        final notifier = container.read(chatMessagesProvider.notifier);
        notifier.setMessages([
          _assistantMessage(usage: const {'total_tokens': 1}),
        ]);

        var notifications = 0;
        final subscription = container.listen<String>(
          chatMessageStructureSignatureProvider,
          (_, _) => notifications += 1,
          fireImmediately: false,
        );
        addTearDown(subscription.close);

        notifier.updateMessageById(
          'assistant-1',
          (current) => current.copyWith(usage: const {'total_tokens': 2}),
        );

        expect(notifications, 0);
      },
    );

    test('streaming cadence grows with mobile response length', () {
      expect(
        debugStreamingContentUpdateIntervalForBuffer(
          999,
          platform: TargetPlatform.android,
        ),
        const Duration(milliseconds: 100),
      );
      expect(
        debugStreamingContentUpdateIntervalForBuffer(
          1000,
          platform: TargetPlatform.android,
        ),
        const Duration(milliseconds: 160),
      );
      expect(
        debugStreamingContentUpdateIntervalForBuffer(
          4000,
          platform: TargetPlatform.android,
        ),
        const Duration(milliseconds: 300),
      );
      expect(
        debugStreamingContentUpdateIntervalForBuffer(
          8000,
          platform: TargetPlatform.android,
        ),
        const Duration(milliseconds: 500),
      );
      expect(
        debugStreamingContentUpdateIntervalForBuffer(
          16000,
          platform: TargetPlatform.android,
        ),
        const Duration(milliseconds: 750),
      );
    });

    test('streaming cadence stays less aggressive off mobile', () {
      expect(
        debugStreamingContentUpdateIntervalForBuffer(
          4000,
          platform: TargetPlatform.macOS,
        ),
        const Duration(milliseconds: 180),
      );
      expect(
        debugStreamingContentUpdateIntervalForBuffer(
          8000,
          platform: TargetPlatform.macOS,
        ),
        const Duration(milliseconds: 280),
      );
      expect(
        debugStreamingContentUpdateIntervalForBuffer(
          16000,
          platform: TargetPlatform.macOS,
        ),
        const Duration(milliseconds: 420),
      );
      expect(
        debugStreamingContentUpdateIntervalForBuffer(
          16000,
          isWeb: true,
          platform: TargetPlatform.android,
        ),
        const Duration(milliseconds: 420),
      );
    });
  });
}
