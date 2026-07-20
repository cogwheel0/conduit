import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/streaming_helper.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:flutter/material.dart';
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

    test('append-only stream text materializes once after many deltas', () {
      final chunks = List<String>.generate(10000, (index) => 'token-$index ');

      final result = debugAccumulateStreamingTextForTesting(chunks);

      expect(result['length'], (result['value']! as String).length);
      expect(result['value'], chunks.join());
      expect(result['materializations'], 1);
    });

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

    testWidgets(
      'streaming content is visible in the frame scheduled for its flush',
      (tester) async {
        final container = buildContainer();

        final notifier = container.read(chatMessagesProvider.notifier);
        notifier.setMessages([
          _assistantMessage(content: 'Hello', isStreaming: true),
        ]);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: _StreamingContentProbe()),
          ),
        );
        expect(find.text('not-flushed'), findsOneWidget);

        notifier.appendToLastMessage(' world');
        expect(find.text('not-flushed'), findsOneWidget);

        // The scheduled frame both flushes the provider and rebuilds the live
        // tail. A post-frame flush would require one more pump here.
        await tester.pump();
        expect(find.text('Hello world'), findsOneWidget);

        notifier.clearMessages();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 1));
        container.dispose();
        await tester.pump(const Duration(milliseconds: 1));
      },
    );

    testWidgets('authoritative replacement bypasses the append cadence', (
      tester,
    ) async {
      final container = buildContainer();
      final notifier = container.read(chatMessagesProvider.notifier);
      notifier.setMessages([
        _assistantMessage(content: 'Hello', isStreaming: true),
      ]);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: _StreamingContentProbe()),
        ),
      );
      notifier.appendToLastMessage(' world');
      await tester.pump();
      expect(find.text('Hello world'), findsOneWidget);

      notifier.bufferLastMessageContent('Replacement body');
      await tester.pump();
      expect(find.text('Replacement body'), findsOneWidget);

      notifier.clearMessages();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
      container.dispose();
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('progressive replacement follows the append cadence', (
      tester,
    ) async {
      final container = buildContainer();
      final notifier = container.read(chatMessagesProvider.notifier);
      notifier.setMessages([
        _assistantMessage(content: 'Hello', isStreaming: true),
      ]);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: _StreamingContentProbe()),
        ),
      );
      notifier.appendToLastMessage(' world');
      await tester.pump();
      expect(find.text('Hello world'), findsOneWidget);

      notifier.bufferLastMessageContent(
        'Progressive reasoning',
        immediate: false,
      );
      await tester.pump();
      expect(find.text('Hello world'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.text('Progressive reasoning'), findsOneWidget);

      notifier.clearMessages();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
      container.dispose();
      await tester.pump(const Duration(milliseconds: 1));
    });

    test('stop generation preserves the visible partial response', () {
      final container = buildContainer();
      addTearDown(container.dispose);

      final notifier = container.read(chatMessagesProvider.notifier);
      notifier.setMessages([
        _assistantMessage(content: 'Hello', isStreaming: true),
      ]);
      notifier.appendToLastMessage(' world');

      container.read(stopGenerationProvider)();

      final message = container.read(chatMessagesProvider).single;
      expect(message.isStreaming, isFalse);
      expect(message.content, 'Hello world');
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

    test('Hermes tool failure replaces and finishes its pending row', () {
      final container = buildContainer();
      addTearDown(container.dispose);

      final notifier = container.read(chatMessagesProvider.notifier);
      notifier.setMessages([
        _assistantMessage(
          statusHistory: const [
            ChatStatusUpdate(
              action: 'hermes_tool_web_search',
              description: 'web_search',
              done: false,
            ),
          ],
        ),
      ]);

      notifier.appendStatusUpdate(
        'assistant-1',
        const ChatStatusUpdate(
          action: 'hermes_tool_web_search',
          description: 'web_search failed: provider unavailable',
          done: true,
        ),
      );

      final history = container.read(chatMessagesProvider).single.statusHistory;
      expect(history, hasLength(1));
      expect(history.single.done, isTrue);
      expect(
        history.single.description,
        'web_search failed: provider unavailable',
      );
    });

    test(
      'reasoning updates keep one row without splitting an interleaved Hermes tool',
      () {
        final container = buildContainer();
        addTearDown(container.dispose);

        final notifier = container.read(chatMessagesProvider.notifier);
        notifier.setMessages([_assistantMessage(isStreaming: true)]);

        var maxHistoryLength = 0;
        final subscription = container.listen<List<ChatMessage>>(
          chatMessagesProvider,
          (_, next) {
            maxHistoryLength =
                next.single.statusHistory.length > maxHistoryLength
                ? next.single.statusHistory.length
                : maxHistoryLength;
          },
          fireImmediately: false,
        );
        addTearDown(subscription.close);

        notifier.appendStatusUpdate(
          'assistant-1',
          const ChatStatusUpdate(
            action: 'hermes_tool_web_search',
            description: 'web_search',
            done: false,
          ),
        );
        for (var index = 0; index < 2000; index++) {
          notifier.appendStatusUpdate(
            'assistant-1',
            ChatStatusUpdate(
              action: 'reasoning',
              description: 'Thinking… fragment $index',
              done: false,
            ),
          );
        }
        notifier.appendStatusUpdate(
          'assistant-1',
          const ChatStatusUpdate(
            action: 'hermes_tool_web_search',
            description: 'web_search',
            done: true,
          ),
        );

        final history = container
            .read(chatMessagesProvider)
            .single
            .statusHistory;
        expect(maxHistoryLength, 2);
        expect(history, hasLength(2));
        expect(
          history.where((status) => status.action == 'reasoning'),
          hasLength(1),
        );
        expect(
          history
              .singleWhere((status) => status.action == 'reasoning')
              .description,
          'Thinking… fragment 1999',
        );
        final tool = history.singleWhere(
          (status) => status.action == 'hermes_tool_web_search',
        );
        expect(tool.done, isTrue);
      },
    );

    test('a repeated Hermes tool keeps its completed history row', () {
      final container = buildContainer();
      addTearDown(container.dispose);

      final notifier = container.read(chatMessagesProvider.notifier);
      notifier.setMessages([
        _assistantMessage(
          statusHistory: const [
            ChatStatusUpdate(
              action: 'hermes_tool_web_search',
              description: 'web_search',
              done: true,
            ),
          ],
        ),
      ]);

      notifier.appendStatusUpdate(
        'assistant-1',
        const ChatStatusUpdate(
          action: 'hermes_tool_web_search',
          description: 'web_search',
          done: false,
        ),
      );

      final history = container.read(chatMessagesProvider).single.statusHistory;
      expect(history, hasLength(2));
      expect(history.first.done, isTrue);
      expect(history.last.done, isFalse);
    });

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

    test('streaming cadence exposes stable size buckets', () {
      expect(
        debugStreamingContentUpdatePolicyForBuffer(999).bucket,
        StreamingContentSizeBucket.under1k,
      );
      expect(
        debugStreamingContentUpdatePolicyForBuffer(1000).bucket,
        StreamingContentSizeBucket.from1k,
      );
      expect(
        debugStreamingContentUpdatePolicyForBuffer(2000).bucket,
        StreamingContentSizeBucket.from2k,
      );
      expect(
        debugStreamingContentUpdatePolicyForBuffer(4000).bucket,
        StreamingContentSizeBucket.from4k,
      );
      expect(
        debugStreamingContentUpdatePolicyForBuffer(8000).bucket,
        StreamingContentSizeBucket.from8k,
      );
      expect(
        debugStreamingContentUpdatePolicyForBuffer(16000).bucket,
        StreamingContentSizeBucket.from16k,
      );
    });

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

class _StreamingContentProbe extends ConsumerWidget {
  const _StreamingContentProbe();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Text(ref.watch(streamingContentProvider) ?? 'not-flushed');
  }
}
