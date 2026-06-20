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

    test(
      'preserved follow-ups also overwrite a stale empty followUps key in '
      'server metadata',
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

        // Server snapshot drops the follow-ups AND carries an explicit empty
        // followUps in its metadata map.
        final serverAssistant = _assistantMessage(
          id: 'assistant-1',
          content: 'Answer',
          metadata: const {'followUps': <String>[]},
        );
        container
            .read(activeConversationProvider.notifier)
            .set(_conversation('chat-1', [userMessage, serverAssistant]));
        await Future<void>.delayed(Duration.zero);

        final adopted = container.read(chatMessagesProvider).last;
        check(adopted.followUps).deepEquals(['Ask again']);
        // The metadata mirror must match the typed field, not stay stale [].
        check(
          (adopted.metadata?['followUps'] as List).cast<String>(),
        ).deepEquals(['Ask again']);
      },
    );

    test(
      'content-preserving snapshot keeps local-only metadata (modelName) '
      'when the server snapshot lacks it',
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
        // Locally-streamed assistant carries the modelName chip this PR writes
        // to every placeholder, and is fresher than the server snapshot.
        final localAssistant = _assistantMessage(
          id: 'assistant-1',
          content: 'Answer that streamed completely',
          // Locally streamed: carries provenance (transport) plus the modelName
          // chip. The bug erased modelName when content was preserved.
          metadata: const {'transport': 'httpStream', 'modelName': 'GPT-4o'},
        );

        container
            .read(activeConversationProvider.notifier)
            .set(_conversation('chat-1', [userMessage, localAssistant]));
        await Future<void>.delayed(Duration.zero);

        // Server snapshot captured before the durable payload was finalized:
        // shorter content and no modelName.
        final laggingServerAssistant = _assistantMessage(
          id: 'assistant-1',
          content: 'Answer that',
        );
        container
            .read(activeConversationProvider.notifier)
            .set(
              _conversation('chat-1', [userMessage, laggingServerAssistant]),
            );
        await Future<void>.delayed(Duration.zero);

        final adopted = container.read(chatMessagesProvider).last;
        check(adopted.content).equals('Answer that streamed completely');
        check(adopted.metadata?['modelName']).equals('GPT-4o');
      },
    );
  });

  group('Feature C — local streaming protection invariants', () {
    // De-risk #1: a NORMAL send's protection behaviour must be byte-unchanged.
    // Registering a stream/subscription for the *current* streaming message id
    // makes protection hold; this is the exact seam dispatchChatTransport uses
    // for both normal sends and resume, so it pins the shared behaviour.
    test('registering subscriptions for the streaming tail enables '
        'protection (normal-send behaviour, unchanged)', () {
      final container = _buildContainer();
      addTearDown(container.dispose);

      final notifier = container.read(chatMessagesProvider.notifier);
      notifier.setMessages([
        _assistantMessage(id: 'assistant-1', content: '', isStreaming: true),
      ]);

      // No transport registered yet -> not protected.
      check(notifier.debugShouldProtectLocalStreamingState).isFalse();

      notifier.setSocketSubscriptions('assistant-1', [() {}]);

      // Matching id + active subscription -> protected.
      check(notifier.debugShouldProtectLocalStreamingState).isTrue();

      // Release streaming bookkeeping before the container disposes.
      notifier.cancelSocketSubscriptions();
      notifier.clearMessages();
    });

    // De-risk #2: resume must set protection true ONLY for the matching message
    // id. A subscription bound to a *different* message id than the streaming
    // tail must NOT protect (otherwise a stale resume would suppress adoption of
    // the genuine current message).
    test('subscriptions bound to a non-matching message id do NOT '
        'protect the streaming tail', () {
      final container = _buildContainer();
      addTearDown(container.dispose);

      final notifier = container.read(chatMessagesProvider.notifier);
      notifier.setMessages([
        _assistantMessage(id: 'assistant-1', content: '', isStreaming: true),
      ]);

      // Register against a foreign id (simulating a stale/other-message resume).
      notifier.setSocketSubscriptions('other-message', [() {}]);

      check(notifier.debugShouldProtectLocalStreamingState).isFalse();

      notifier.cancelSocketSubscriptions();
      notifier.clearMessages();
    });

    // De-risk #5 (offline branch): with no socket, _detectActiveOnOpen's resume
    // attach is a no-op, so opening a conversation registers no socket
    // subscriptions and protection stays false (identical to today's poll-only
    // behaviour). socketServiceProvider is overridden to null in _buildContainer.
    test('opening a conversation with no socket registers no resume '
        'subscriptions (offline poll-only fallback)', () async {
      final container = _buildContainer();
      addTearDown(container.dispose);

      // Materialize the notifier so it listens to conversation changes.
      container.read(chatMessagesProvider.notifier);

      container
          .read(activeConversationProvider.notifier)
          .set(
            _conversation('chat-1', [
              _assistantMessage(id: 'assistant-1', content: 'Partial'),
            ]),
          );
      await Future<void>.delayed(Duration.zero);

      // No socket -> no resume subscriptions -> not protected. (The 1s poll
      // fallback is gated on an API service, also null here, so it is inert.)
      check(
        container.read(chatMessagesProvider.notifier)
            .debugShouldProtectLocalStreamingState,
      ).isFalse();
    });
  });
}
