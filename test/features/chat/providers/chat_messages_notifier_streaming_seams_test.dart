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

ChatMessage _assistantMessage({
  String id = 'assistant-1',
  String content = 'Visible response body',
  bool isStreaming = false,
  List<String> followUps = const <String>[],
  Map<String, dynamic>? metadata,
}) {
  return ChatMessage(
    id: id,
    role: 'assistant',
    content: content,
    timestamp: DateTime(2024, 1, 1),
    isStreaming: isStreaming,
    followUps: followUps,
    metadata: metadata,
  );
}

Conversation _conversation(String id, List<ChatMessage> messages) {
  return Conversation(
    id: id,
    title: 'Test chat',
    createdAt: DateTime(2024, 1, 1),
    updatedAt: DateTime(2024, 1, 1),
    messages: messages,
  );
}

ProviderContainer _buildContainer() {
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ChatMessagesNotifier streaming seams', () {
    test('conversation switch cancels active stream subscriptions', () async {
      final container = _buildContainer();
      addTearDown(container.dispose);

      container
          .read(activeConversationProvider.notifier)
          .set(
            _conversation('chat-1', [
              _assistantMessage(content: 'Draft', isStreaming: true),
            ]),
          );

      var subscriptionDisposed = false;
      var teardownDisposed = false;
      container.read(chatMessagesProvider.notifier).setSocketSubscriptions(
        'assistant-1',
        [() => subscriptionDisposed = true],
        onDispose: () => teardownDisposed = true,
      );

      container
          .read(activeConversationProvider.notifier)
          .set(
            _conversation('chat-2', [
              _assistantMessage(id: 'assistant-2', content: 'Other chat'),
            ]),
          );
      await Future<void>.delayed(Duration.zero);

      check(subscriptionDisposed).isTrue();
      check(teardownDisposed).isTrue();
      check(
        container.read(chatMessagesProvider).single.id,
      ).equals('assistant-2');
    });

    test('streaming buffer sync keeps the assistant message streaming', () {
      final container = _buildContainer();
      addTearDown(container.dispose);

      final notifier = container.read(chatMessagesProvider.notifier);
      notifier.setMessages([
        _assistantMessage(content: 'Buffered', isStreaming: true),
      ]);

      notifier.appendToLastMessage(' content');
      notifier.syncStreamingBuffer();

      final message = container.read(chatMessagesProvider).single;
      check(message.content).equals('Buffered content');
      check(message.isStreaming).isTrue();

      notifier.clearMessages();
    });

    test(
      'batched optimistic turn exposes user and assistant together',
      () async {
        final container = _buildContainer();
        addTearDown(container.dispose);

        final notifier = container.read(chatMessagesProvider.notifier);
        var notifications = 0;
        final subscription = container.listen<List<ChatMessage>>(
          chatMessagesProvider,
          (_, _) => notifications += 1,
          fireImmediately: false,
        );
        addTearDown(subscription.close);

        notifier.addMessages([
          ChatMessage(
            id: 'user-1',
            role: 'user',
            content: 'Hello',
            timestamp: DateTime(2024, 1, 1),
          ),
          _assistantMessage(id: 'assistant-1', content: '', isStreaming: true),
        ]);
        await Future<void>.delayed(Duration.zero);

        final messages = container.read(chatMessagesProvider);
        check(notifications).equals(1);
        check(messages).length.equals(2);
        check(messages.last.id).equals('assistant-1');
        check(messages.last.isStreaming).isTrue();

        notifier.clearMessages();
      },
    );

    test(
      'first conversation activation preserves optimistic stream row',
      () async {
        final container = _buildContainer();
        addTearDown(container.dispose);

        final notifier = container.read(chatMessagesProvider.notifier);
        final userMessage = ChatMessage(
          id: 'user-1',
          role: 'user',
          content: 'Hello',
          timestamp: DateTime(2024, 1, 1),
        );
        final assistantMessage = _assistantMessage(
          id: 'assistant-1',
          content: '',
          isStreaming: true,
        );
        notifier.addMessages([userMessage, assistantMessage]);
        final optimisticMessages = container.read(chatMessagesProvider);

        var notifications = 0;
        final subscription = container.listen<List<ChatMessage>>(
          chatMessagesProvider,
          (_, _) => notifications += 1,
          fireImmediately: false,
        );
        addTearDown(subscription.close);

        container
            .read(activeConversationProvider.notifier)
            .set(_conversation('local:first', [userMessage, assistantMessage]));
        await Future<void>.delayed(Duration.zero);

        check(notifications).equals(0);
        check(
          identical(container.read(chatMessagesProvider), optimisticMessages),
        ).isTrue();

        notifier.clearMessages();
      },
    );

    test('send failure converts active placeholder to an error row', () {
      final container = _buildContainer();
      addTearDown(container.dispose);

      final notifier = container.read(chatMessagesProvider.notifier);
      notifier.setMessages([
        ChatMessage(
          id: 'user-1',
          role: 'user',
          content: 'Hello',
          timestamp: DateTime(2024, 1, 1),
        ),
        _assistantMessage(id: 'assistant-1', content: '', isStreaming: true),
      ]);

      notifier.failLastStreamingAssistant(Exception('500'));

      final messages = container.read(chatMessagesProvider);
      check(messages).length.equals(2);
      check(messages.last.id).equals('assistant-1');
      check(messages.last.isStreaming).isFalse();
      check(messages.last.error).isNotNull();
      check(
        messages.last.error!.content ?? '',
      ).contains('server returned an error');
    });

    test('durable assistant payload preserves display modelName', () {
      final payload = debugBuildDurableAssistantPayloadForTesting(
        id: 'assistant-1',
        parentId: 'user-1',
        modelId: 'openai/gpt-4o',
        modelName: 'GPT-4o',
        timestamp: 1700000000,
      );

      check(payload['model']).equals('openai/gpt-4o');
      check(payload['modelName']).equals('GPT-4o');
    });

    test(
      'streaming content-only changes keep the structure signature stable',
      () async {
        final container = _buildContainer();
        addTearDown(container.dispose);

        final notifier = container.read(chatMessagesProvider.notifier);
        notifier.setMessages([
          _assistantMessage(content: 'Draft', isStreaming: true),
        ]);
        final initialSignature = container.read(
          chatMessageStructureSignatureProvider,
        );
        var notifications = 0;
        final subscription = container.listen<String>(
          chatMessageStructureSignatureProvider,
          (_, _) => notifications += 1,
          fireImmediately: false,
        );
        addTearDown(subscription.close);

        notifier.updateMessageById(
          'assistant-1',
          (current) => current.copyWith(content: 'Draft plus more content'),
        );
        await Future<void>.delayed(Duration.zero);

        check(
          container.read(chatMessageStructureSignatureProvider),
        ).equals(initialSignature);
        check(notifications).equals(0);

        notifier.clearMessages();
      },
    );

    test('streaming completion keeps the structure signature stable', () async {
      final container = _buildContainer();
      addTearDown(container.dispose);

      final notifier = container.read(chatMessagesProvider.notifier);
      notifier.setMessages([
        _assistantMessage(content: 'Final response', isStreaming: true),
      ]);
      final initialSignature = container.read(
        chatMessageStructureSignatureProvider,
      );
      var notifications = 0;
      final subscription = container.listen<String>(
        chatMessageStructureSignatureProvider,
        (_, _) => notifications += 1,
        fireImmediately: false,
      );
      addTearDown(subscription.close);

      notifier.updateMessageById(
        'assistant-1',
        (current) => current.copyWith(isStreaming: false),
      );
      await Future<void>.delayed(Duration.zero);

      check(
        container.read(chatMessageStructureSignatureProvider),
      ).equals(initialSignature);
      check(notifications).equals(0);

      notifier.clearMessages();
    });

    test(
      'server snapshots do not clear already-visible follow-ups for same response',
      () async {
        final container = _buildContainer();
        addTearDown(container.dispose);
        container.read(chatMessagesProvider.notifier);

        final userMessage = ChatMessage(
          id: 'user-1',
          role: 'user',
          content: 'Hello',
          timestamp: DateTime(2024, 1, 1),
        );
        final localAssistant = _assistantMessage(
          id: 'assistant-1',
          content: 'Answer',
          followUps: const ['Ask again'],
        );

        container
            .read(activeConversationProvider.notifier)
            .set(_conversation('chat-1', [userMessage, localAssistant]));
        await Future<void>.delayed(Duration.zero);

        final serverAssistantWithoutFollowUps = _assistantMessage(
          id: 'assistant-1',
          content: 'Answer',
        );
        container
            .read(activeConversationProvider.notifier)
            .set(
              _conversation('chat-1', [
                userMessage,
                serverAssistantWithoutFollowUps,
              ]),
            );
        await Future<void>.delayed(Duration.zero);

        check(
          container.read(chatMessagesProvider).last.followUps,
        ).deepEquals(['Ask again']);
      },
    );

    test(
      'server snapshots do not clear already-visible response content',
      () async {
        final container = _buildContainer();
        addTearDown(container.dispose);
        container.read(chatMessagesProvider.notifier);

        final userMessage = ChatMessage(
          id: 'user-1',
          role: 'user',
          content: 'Hello',
          timestamp: DateTime(2024, 1, 1),
        );
        final localAssistant = _assistantMessage(
          id: 'assistant-1',
          content: 'Answer that streamed completely',
          followUps: const ['Ask again'],
          metadata: const {'transport': 'httpStream'},
        );

        container
            .read(activeConversationProvider.notifier)
            .set(_conversation('chat-1', [userMessage, localAssistant]));
        await Future<void>.delayed(Duration.zero);

        final laggingServerAssistant = _assistantMessage(
          id: 'assistant-1',
          content: '',
        );
        container
            .read(activeConversationProvider.notifier)
            .set(
              _conversation('chat-1', [userMessage, laggingServerAssistant]),
            );
        await Future<void>.delayed(Duration.zero);

        check(
          container.read(chatMessagesProvider).last.content,
        ).equals('Answer that streamed completely');
        check(
          container.read(chatMessagesProvider).last.followUps,
        ).deepEquals(['Ask again']);
      },
    );
  });
}
