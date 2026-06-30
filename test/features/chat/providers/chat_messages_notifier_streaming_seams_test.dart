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

    test(
      'first conversation activation preserves a stale same-id stream echo',
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
          metadata: const {'modelName': 'GPT-4o'},
        );
        notifier.addMessages([userMessage, assistantMessage]);

        final staleServerEcho = _assistantMessage(
          id: 'assistant-1',
          content: '',
          isStreaming: false,
        );
        container
            .read(activeConversationProvider.notifier)
            .set(_conversation('local:first', [userMessage, staleServerEcho]));
        await Future<void>.delayed(Duration.zero);

        final messages = container.read(chatMessagesProvider);
        check(messages).length.equals(2);
        check(messages.last.id).equals('assistant-1');
        check(messages.last.isStreaming).isTrue();
        check(messages.last.metadata?['modelName']).equals('GPT-4o');

        notifier.clearMessages();
      },
    );

    test(
      'same-chat empty server echo does not retire the active stream',
      () async {
        final container = _buildContainer();
        addTearDown(container.dispose);

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
          metadata: const {'modelName': 'GPT-4o'},
        );
        final activeConversationNotifier = container.read(
          activeConversationProvider.notifier,
        );
        activeConversationNotifier.set(
          _conversation('chat-1', [userMessage, assistantMessage]),
        );
        await Future<void>.delayed(Duration.zero);
        check(container.read(chatMessagesProvider).last.isStreaming).isTrue();

        final staleServerEcho = _assistantMessage(
          id: 'assistant-1',
          content: '',
          isStreaming: false,
        );
        activeConversationNotifier.set(
          _conversation('chat-1', [userMessage, staleServerEcho]),
        );
        await Future<void>.delayed(Duration.zero);

        final messages = container.read(chatMessagesProvider);
        check(messages).length.equals(2);
        check(messages.last.id).equals('assistant-1');
        check(messages.last.isStreaming).isTrue();
        check(messages.last.metadata?['modelName']).equals('GPT-4o');

        container.read(chatMessagesProvider.notifier).clearMessages();
      },
    );

    test(
      'non-streaming echo with a non-empty completion field retires the stream',
      () async {
        final userMessage = ChatMessage(
          id: 'user-1',
          role: 'user',
          content: 'Hello',
          timestamp: DateTime(2024, 1, 1),
        );
        final completionEchoes = <String, ChatMessage>{
          'files': ChatMessage(
            id: 'assistant-1',
            role: 'assistant',
            content: '',
            timestamp: DateTime(2024, 1, 1),
            files: const [
              {'id': 'f1'},
            ],
          ),
          'output': ChatMessage(
            id: 'assistant-1',
            role: 'assistant',
            content: '',
            timestamp: DateTime(2024, 1, 1),
            output: const [
              {'type': 'text'},
            ],
          ),
          'embeds': ChatMessage(
            id: 'assistant-1',
            role: 'assistant',
            content: '',
            timestamp: DateTime(2024, 1, 1),
            embeds: const [
              {'url': 'https://example.com'},
            ],
          ),
          'followUps': ChatMessage(
            id: 'assistant-1',
            role: 'assistant',
            content: '',
            timestamp: DateTime(2024, 1, 1),
            followUps: const ['Ask again'],
          ),
          'responseDone': ChatMessage(
            id: 'assistant-1',
            role: 'assistant',
            content: '',
            timestamp: DateTime(2024, 1, 1),
            metadata: const {'responseDone': true},
          ),
          'error': ChatMessage(
            id: 'assistant-1',
            role: 'assistant',
            content: '',
            timestamp: DateTime(2024, 1, 1),
            error: const ChatMessageError(content: 'boom'),
          ),
          'sources': ChatMessage(
            id: 'assistant-1',
            role: 'assistant',
            content: '',
            timestamp: DateTime(2024, 1, 1),
            sources: const [
              ChatSourceReference(title: 'Doc', url: 'https://example.com'),
            ],
          ),
          'codeExecutions': ChatMessage(
            id: 'assistant-1',
            role: 'assistant',
            content: '',
            timestamp: DateTime(2024, 1, 1),
            codeExecutions: const [ChatCodeExecution(id: 'ce1')],
          ),
        };

        for (final entry in completionEchoes.entries) {
          final container = _buildContainer();
          final active = container.read(activeConversationProvider.notifier);
          active.set(
            _conversation('chat-1', [
              userMessage,
              _assistantMessage(
                id: 'assistant-1',
                content: '',
                isStreaming: true,
                metadata: const {'modelName': 'GPT-4o'},
              ),
            ]),
          );
          await Future<void>.delayed(Duration.zero);
          check(container.read(chatMessagesProvider).last.isStreaming).isTrue();

          active.set(_conversation('chat-1', [userMessage, entry.value]));
          await Future<void>.delayed(Duration.zero);

          check(
            container.read(chatMessagesProvider).last.isStreaming,
            because: 'completion field "${entry.key}" should retire the stream',
          ).isFalse();

          container.read(chatMessagesProvider.notifier).clearMessages();
          container.dispose();
        }
      },
    );

    test('server snapshot advancing past the streaming tail retires it', () async {
      final container = _buildContainer();
      addTearDown(container.dispose);

      final userMessage = ChatMessage(
        id: 'user-1',
        role: 'user',
        content: 'Hello',
        timestamp: DateTime(2024, 1, 1),
      );
      final active = container.read(activeConversationProvider.notifier);
      active.set(
        _conversation('chat-1', [
          userMessage,
          _assistantMessage(id: 'assistant-1', content: 'Partial', isStreaming: true),
        ]),
      );
      await Future<void>.delayed(Duration.zero);
      check(container.read(chatMessagesProvider).last.isStreaming).isTrue();

      active.set(
        _conversation('chat-1', [
          userMessage,
          _assistantMessage(id: 'assistant-1', content: 'Done', isStreaming: false),
          ChatMessage(
            id: 'user-2',
            role: 'user',
            content: 'Next',
            timestamp: DateTime(2024, 1, 1),
          ),
          _assistantMessage(
            id: 'assistant-2',
            content: 'New turn',
            isStreaming: false,
          ),
        ]),
      );
      await Future<void>.delayed(Duration.zero);

      final messages = container.read(chatMessagesProvider);
      check(messages).length.equals(4);
      check(
        messages.firstWhere((message) => message.id == 'assistant-1').isStreaming,
      ).isFalse();

      container.read(chatMessagesProvider.notifier).clearMessages();
    });

    test('a streaming row that is not the tail is not force-kept streaming', () async {
      final container = _buildContainer();
      addTearDown(container.dispose);

      final userMessage = ChatMessage(
        id: 'user-1',
        role: 'user',
        content: 'Hello',
        timestamp: DateTime(2024, 1, 1),
      );
      final secondUser = ChatMessage(
        id: 'user-2',
        role: 'user',
        content: 'Follow up',
        timestamp: DateTime(2024, 1, 1),
      );
      final active = container.read(activeConversationProvider.notifier);
      active.set(
        _conversation('chat-1', [
          userMessage,
          _assistantMessage(
            id: 'assistant-1',
            content: 'Streaming earlier',
            isStreaming: true,
          ),
          secondUser,
          _assistantMessage(id: 'assistant-2', content: 'Tail', isStreaming: false),
        ]),
      );
      await Future<void>.delayed(Duration.zero);

      active.set(
        _conversation('chat-1', [
          userMessage,
          _assistantMessage(
            id: 'assistant-1',
            content: 'Streaming earlier',
            isStreaming: false,
          ),
          secondUser,
          _assistantMessage(id: 'assistant-2', content: 'Tail', isStreaming: false),
        ]),
      );
      await Future<void>.delayed(Duration.zero);

      check(
        container
            .read(chatMessagesProvider)
            .firstWhere((message) => message.id == 'assistant-1')
            .isStreaming,
      ).isFalse();

      container.read(chatMessagesProvider.notifier).clearMessages();
    });

    test(
      'empty non-streaming echo preserves streaming-state, content, and modelName together',
      () async {
        final container = _buildContainer();
        addTearDown(container.dispose);

        final userMessage = ChatMessage(
          id: 'user-1',
          role: 'user',
          content: 'Hello',
          timestamp: DateTime(2024, 1, 1),
        );
        // Local streaming tail with a non-empty partial body and a modelName chip.
        final localTail = _assistantMessage(
          id: 'assistant-1',
          content: 'Partial streamed answer',
          isStreaming: true,
          metadata: const {'modelName': 'GPT-4o'},
        );
        final active = container.read(activeConversationProvider.notifier);
        active.set(_conversation('chat-1', [userMessage, localTail]));
        await Future<void>.delayed(Duration.zero);
        check(container.read(chatMessagesProvider).last.isStreaming).isTrue();

        // Lagging server echo: empty content, isStreaming:false, no modelName.
        final emptyEcho = _assistantMessage(
          id: 'assistant-1',
          content: '',
          isStreaming: false,
        );
        active.set(_conversation('chat-1', [userMessage, emptyEcho]));
        await Future<void>.delayed(Duration.zero);

        final merged = container.read(chatMessagesProvider).last;
        check(merged.isStreaming).isTrue(); // shouldPreserveStreamingState
        check(
          merged.content,
        ).equals('Partial streamed answer'); // preserveContent
        check(
          merged.metadata?['modelName'],
        ).equals('GPT-4o'); // shouldPreserveModelName

        container.read(chatMessagesProvider.notifier).clearMessages();
      },
    );

    test(
      'socket-resumed tail preserves streaming-state when a stale empty echo carries the foreign server id',
      () async {
        final container = _buildContainer();
        addTearDown(container.dispose);

        final userMessage = ChatMessage(
          id: 'user-1',
          role: 'user',
          content: 'Hello',
          timestamp: DateTime(2024, 1, 1),
        );
        final localTail = _assistantMessage(
          id: 'assistant-local',
          content: 'Partial',
          isStreaming: true,
          metadata: const {'modelName': 'GPT-4o'},
        );

        final notifier = container.read(chatMessagesProvider.notifier);
        final active = container.read(activeConversationProvider.notifier);
        active.set(_conversation('chat-1', [userMessage, localTail]));
        await Future<void>.delayed(Duration.zero);
        check(container.read(chatMessagesProvider).last.isStreaming).isTrue();

        // Socket resume bound a foreign server id to the local tail (must be
        // recorded while the tail is still state.last).
        notifier.recordResumeBoundRemoteMessageId(
          'assistant-local',
          'server-foreign',
        );

        // Lagging snapshot carries the FOREIGN id with empty, non-streaming
        // content: the boundToTail path must still preserve streaming-state.
        final foreignEcho = _assistantMessage(
          id: 'server-foreign',
          content: '',
          isStreaming: false,
        );
        active.set(_conversation('chat-1', [userMessage, foreignEcho]));
        await Future<void>.delayed(Duration.zero);

        final merged = container.read(chatMessagesProvider).last;
        check(merged.isStreaming).isTrue();
        check(merged.metadata?['modelName']).equals('GPT-4o');

        notifier.clearMessages();
      },
    );

    test(
      'shouldCleanupStreamingFromServer ignores a stale echo but retires real completions',
      () {
        final container = _buildContainer();
        addTearDown(container.dispose);
        final notifier = container.read(chatMessagesProvider.notifier);
        notifier.setMessages([
          _assistantMessage(
            id: 'assistant-1',
            content: 'Partial',
            isStreaming: true,
          ),
        ]);

        // A stale empty non-streaming echo must NOT retire the stream.
        check(
          notifier.debugShouldCleanupStreamingFromServer([
            _assistantMessage(id: 'assistant-1', content: '', isStreaming: false),
          ]),
        ).isFalse();

        // responseDone retires it.
        check(
          notifier.debugShouldCleanupStreamingFromServer([
            _assistantMessage(
              id: 'assistant-1',
              content: '',
              isStreaming: false,
              metadata: const {'responseDone': true},
            ),
          ]),
        ).isTrue();

        // An error retires it.
        check(
          notifier.debugShouldCleanupStreamingFromServer([
            ChatMessage(
              id: 'assistant-1',
              role: 'assistant',
              content: '',
              timestamp: DateTime(2024, 1, 1),
              error: const ChatMessageError(content: 'boom'),
            ),
          ]),
        ).isTrue();

        // A stale echo is still retired once the server has moved past this
        // turn: extra messages after the echo prove streaming completed, so the
        // echo must not keep the stream (and its footer/task state) attached to
        // a no-longer-tail message.
        check(
          notifier.debugShouldCleanupStreamingFromServer([
            _assistantMessage(
              id: 'assistant-1',
              content: '',
              isStreaming: false,
            ),
            ChatMessage(
              id: 'user-2',
              role: 'user',
              content: 'Next question',
              timestamp: DateTime(2024, 1, 1),
            ),
            _assistantMessage(
              id: 'assistant-2',
              content: 'Next answer',
              isStreaming: false,
            ),
          ]),
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

    test('preserved follow-ups also overwrite a stale empty followUps key in '
        'server metadata', () async {
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
    });

    test('content-preserving snapshot keeps local-only metadata (modelName) '
        'when the server snapshot lacks it', () async {
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
          .set(_conversation('chat-1', [userMessage, laggingServerAssistant]));
      await Future<void>.delayed(Duration.zero);

      final adopted = container.read(chatMessagesProvider).last;
      check(adopted.content).equals('Answer that streamed completely');
      check(adopted.metadata?['modelName']).equals('GPT-4o');
    });

    test('empty placeholder keeps its modelName when a pre-first-token server '
        'snapshot lacks it', () async {
      final container = _buildContainer();
      addTearDown(container.dispose);
      container.read(chatMessagesProvider.notifier);

      final userMessage = ChatMessage(
        id: 'user-1',
        role: 'user',
        content: 'Hello',
        timestamp: DateTime(2024, 1, 1),
      );
      // Fresh placeholder: no content yet, but already carries the modelName
      // chip written at send time.
      final placeholder = _assistantMessage(
        id: 'assistant-1',
        content: '',
        metadata: const {'modelName': 'GPT-4o'},
      );

      container
          .read(activeConversationProvider.notifier)
          .set(_conversation('chat-1', [userMessage, placeholder]));
      await Future<void>.delayed(Duration.zero);

      // Stale snapshot adopted before the first token: server content arrives
      // but without modelName.
      final serverFirstTokens = _assistantMessage(
        id: 'assistant-1',
        content: 'Hel',
      );
      container
          .read(activeConversationProvider.notifier)
          .set(_conversation('chat-1', [userMessage, serverFirstTokens]));
      await Future<void>.delayed(Duration.zero);

      final adopted = container.read(chatMessagesProvider).last;
      check(adopted.content).equals('Hel');
      check(adopted.metadata?['modelName']).equals('GPT-4o');
    });

    test(
      'an explicit empty server modelName does not blank the preserved local '
      'model name',
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
        final placeholder = _assistantMessage(
          id: 'assistant-1',
          content: '',
          metadata: const {'modelName': 'GPT-4o'},
        );

        container
            .read(activeConversationProvider.notifier)
            .set(_conversation('chat-1', [userMessage, placeholder]));
        await Future<void>.delayed(Duration.zero);

        // Server snapshot carries an explicit empty modelName.
        final serverWithBlankModel = _assistantMessage(
          id: 'assistant-1',
          content: 'Hel',
          metadata: const {'modelName': '   '},
        );
        container
            .read(activeConversationProvider.notifier)
            .set(_conversation('chat-1', [userMessage, serverWithBlankModel]));
        await Future<void>.delayed(Duration.zero);

        final adopted = container.read(chatMessagesProvider).last;
        check(adopted.metadata?['modelName']).equals('GPT-4o');
      },
    );

    test(
      'an older completed message defers to a corrected server snapshot; only '
      'the streaming tail is content-preserved',
      () async {
        final container = _buildContainer();
        addTearDown(container.dispose);
        container.read(chatMessagesProvider.notifier);

        final user1 = ChatMessage(
          id: 'user-1',
          role: 'user',
          content: 'Q1',
          timestamp: DateTime(2024, 1, 1),
        );
        final user2 = ChatMessage(
          id: 'user-2',
          role: 'user',
          content: 'Q2',
          timestamp: DateTime(2024, 1, 1),
        );
        // Older, already-completed assistant whose local body is longer than
        // the server's with a matching prefix — must NOT block a correction.
        final olderLocal = _assistantMessage(
          id: 'assistant-1',
          content: 'Answer one local-extra',
          metadata: const {'responseDone': true},
        );
        // Streaming tail: its longer local body is still preserved.
        final tailLocal = _assistantMessage(
          id: 'assistant-2',
          content: 'Answer two streamed completely',
          metadata: const {'transport': 'httpStream'},
        );

        container
            .read(activeConversationProvider.notifier)
            .set(
              _conversation('chat-1', [user1, olderLocal, user2, tailLocal]),
            );
        await Future<void>.delayed(Duration.zero);

        // Authoritative server snapshot: the older message is corrected
        // (shorter, same prefix); the tail still lags.
        final olderServer = _assistantMessage(
          id: 'assistant-1',
          content: 'Answer one',
        );
        final tailServer = _assistantMessage(
          id: 'assistant-2',
          content: 'Answer two',
        );
        container
            .read(activeConversationProvider.notifier)
            .set(
              _conversation('chat-1', [user1, olderServer, user2, tailServer]),
            );
        await Future<void>.delayed(Duration.zero);

        final messages = container.read(chatMessagesProvider);
        final older = messages.firstWhere((m) => m.id == 'assistant-1');
        final tail = messages.firstWhere((m) => m.id == 'assistant-2');
        // Older completed message defers to the server correction.
        check(older.content).equals('Answer one');
        // Streaming tail keeps its longer local body.
        check(tail.content).equals('Answer two streamed completely');
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
        container
            .read(chatMessagesProvider.notifier)
            .debugShouldProtectLocalStreamingState,
      ).isFalse();
    });
  });
}
