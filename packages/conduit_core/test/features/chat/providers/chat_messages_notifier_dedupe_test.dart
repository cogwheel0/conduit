import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/streaming_helper.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:riverpod/riverpod.dart';
import 'package:conduit_core/ports/app_lifecycle.dart';
import 'package:conduit_core/providers/host_ports.dart';
import 'package:conduit_core/testing.dart';
import 'package:test/test.dart';

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
  group('ChatMessagesNotifier dedupe', () {
    late FakeAppLifecycle lifecycle;

    setUp(() => lifecycle = FakeAppLifecycle());
    tearDown(() => lifecycle.dispose());

    ProviderContainer buildContainer() {
      return ProviderContainer(
        overrides: [
          activeConversationProvider.overrideWith(
            () => _TestActiveConversationNotifier(),
          ),
          apiServiceProvider.overrideWithValue(null),
          socketServiceProvider.overrideWithValue(null),
          // Driven through the port rather than by calling the observer
          // method: that is the path production takes, so the subscription
          // itself is under test too.
          appLifecycleProvider.overrideWithValue(lifecycle),
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

    test('background streaming bypasses frame and timer batching', () {
      final container = buildContainer();
      addTearDown(container.dispose);
      final notifier = container.read(chatMessagesProvider.notifier);
      notifier.setMessages([
        _assistantMessage(content: 'Hello', isStreaming: true),
      ]);

      notifier.appendToLastMessage(' world');
      expect(container.read(streamingContentProvider), isNull);

      lifecycle.emit(AppLifecyclePhase.paused);
      expect(container.read(streamingContentProvider), 'Hello world');

      notifier.appendToLastMessage(' again');
      expect(container.read(streamingContentProvider), 'Hello world again');

      notifier.clearMessages();
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

    test('appendStatusUpdate skips duplicate rows and notifies on meaningful changes', () {
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
    });

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

    test('reasoning updates keep one row without splitting an interleaved Hermes tool', () {
      final container = buildContainer();
      addTearDown(container.dispose);

      final notifier = container.read(chatMessagesProvider.notifier);
      notifier.setMessages([_assistantMessage(isStreaming: true)]);

      var maxHistoryLength = 0;
      final subscription = container.listen<List<ChatMessage>>(
        chatMessagesProvider,
        (_, next) {
          maxHistoryLength = next.single.statusHistory.length > maxHistoryLength
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

      final history = container.read(chatMessagesProvider).single.statusHistory;
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
    });

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

    test('streaming cadence stays fixed regardless of response length', () {
      for (final length in [0, 999, 1000, 4000, 16000, 64000]) {
        for (final platform in ['android', 'iOS', 'macOS']) {
          expect(
            debugStreamingContentUpdateIntervalForBuffer(
              length,
              platform: platform,
            ),
            streamingContentUpdateInterval,
            reason: 'length=$length platform=$platform',
          );
        }
      }
      expect(streamingContentUpdateInterval, const Duration(milliseconds: 100));
    });

    // -----------------------------------------------------------------------
    // Streaming-content flush state machine (characterization).
    //
    // Pins the observable behaviour of the
    // `_scheduleStreamingContentUpdate` -> `_scheduleStreamingContentFrame` ->
    // `_flushStreamingContentUpdate` chain, plus
    // `_realizePendingStreamingSnapshot` and
    // `_messageWithBufferedStreamingContent`.
    //
    // `_StreamingContentFlushReason` is private and only ever reaches
    // `PerformanceProfiler.instant`, which writes to the `dart:developer`
    // timeline and exposes no test hook. Reasons are therefore pinned by their
    // observable consequence — frame-scheduled vs synchronous, coalesced vs
    // one-per-delta, published vs immediately cleared — never by name.
    group('streaming content flush state machine', () {
      ChatMessage streamingTail({String content = 'Hello'}) =>
          _assistantMessage(content: content, isStreaming: true);

      test('background deltas flush synchronously, one emission per delta', () {
        final container = buildContainer();
        addTearDown(container.dispose);

        final notifier = container.read(chatMessagesProvider.notifier);
        notifier.setMessages([streamingTail()]);

        final emissions = <String?>[];
        final subscription = container.listen<String?>(
          streamingContentProvider,
          (_, next) => emissions.add(next),
          fireImmediately: false,
        );
        addTearDown(subscription.close);

        lifecycle.emit(AppLifecyclePhase.paused);
        notifier.appendToLastMessage(' a');
        notifier.appendToLastMessage(' b');
        notifier.appendToLastMessage(' c');

        // Backgrounded, both the cadence timer and the frame callback are
        // bypassed, so nothing coalesces: every delta publishes on its own.
        expect(emissions, <String?>['Hello a', 'Hello a b', 'Hello a b c']);

        notifier.clearMessages();
      });

      test('terminal completion publishes the buffer and clears it in the same call', () {
        final container = buildContainer();
        addTearDown(container.dispose);

        final notifier = container.read(chatMessagesProvider.notifier);
        notifier.setMessages([streamingTail()]);

        final emissions = <String?>[];
        final subscription = container.listen<String?>(
          streamingContentProvider,
          (_, next) => emissions.add(next),
          fireImmediately: false,
        );
        addTearDown(subscription.close);

        notifier.appendToLastMessage(' world');
        expect(emissions, isEmpty, reason: 'no frame has run yet');

        notifier.finishStreaming();

        // `_completeStreamingMessage` flushes synchronously (terminal) and then
        // calls `_clearStreamingContent()`, so the flushed value is published
        // and immediately replaced by null in the same synchronous call. Only
        // the fold into the message list survives. Pinned as observed: for
        // subscribers of `streamingContentProvider` the terminal emission looks
        // like wasted work.
        expect(emissions, <String?>['Hello world', null]);

        final message = container.read(chatMessagesProvider).single;
        expect(message.content, 'Hello world');
        expect(message.isStreaming, isFalse);
      });

      test(
        'stop-preserving flushes synchronously and leaves the partial visible',
        () {
          final container = buildContainer();
          addTearDown(container.dispose);

          final notifier = container.read(chatMessagesProvider.notifier);
          notifier.setMessages([streamingTail()]);

          final emissions = <String?>[];
          final subscription = container.listen<String?>(
            streamingContentProvider,
            (_, next) => emissions.add(next),
            fireImmediately: false,
          );
          addTearDown(subscription.close);

          notifier.appendToLastMessage(' world');
          expect(emissions, isEmpty, reason: 'no frame has run yet');

          notifier.cancelActiveMessageStreamPreservingContent();

          // Unlike the terminal path this one does not clear, so the partial
          // response stays visible and the row is still marked streaming.
          expect(emissions, <String?>['Hello world']);
          final message = container.read(chatMessagesProvider).single;
          expect(message.content, 'Hello world');
          expect(message.isStreaming, isTrue);

          notifier.clearMessages();
        },
      );

      test('syncStreamingBuffer realizes one pending snapshot into the tail '
          'without a visible flush', () {
        final container = buildContainer();
        addTearDown(container.dispose);

        final notifier = container.read(chatMessagesProvider.notifier);
        notifier.setMessages([streamingTail(content: 'Intro')]);

        var materializations = 0;
        for (var index = 0; index < 3; index += 1) {
          notifier.bufferLastMessageContentSnapshot(() {
            materializations += 1;
            return 'Intro revision $index';
          });
        }
        expect(materializations, 0);

        var messageNotifications = 0;
        final subscription = container.listen<List<ChatMessage>>(
          chatMessagesProvider,
          (_, _) => messageNotifications += 1,
          fireImmediately: false,
        );
        addTearDown(subscription.close);

        notifier.syncStreamingBuffer();

        // Only the newest snapshot is materialized, and folding it into the
        // message list is independent of the visible flush — which is still
        // waiting for a frame that never arrives in a plain `test`.
        expect(materializations, 1);
        expect(
          container.read(chatMessagesProvider).single.content,
          'Intro revision 2',
        );
        expect(messageNotifications, 1);
        expect(container.read(streamingContentProvider), isNull);

        // A second sync with nothing new is a no-op:
        // `_messageWithBufferedStreamingContent` returns the same instance
        // once the buffer matches the tail.
        notifier.syncStreamingBuffer();
        expect(messageNotifications, 1);
      });

      test('a snapshot that throws is swallowed and keeps the last realized content', () {
        final container = buildContainer();
        addTearDown(container.dispose);

        final notifier = container.read(chatMessagesProvider.notifier);
        notifier.setMessages([streamingTail(content: 'Intro')]);

        notifier.bufferLastMessageContentSnapshot(
          () => throw StateError('projection failed'),
        );
        notifier.syncStreamingBuffer();

        // `_realizePendingStreamingSnapshot` logs and drops the failure, so the
        // buffer keeps whatever it last held.
        expect(container.read(chatMessagesProvider).single.content, 'Intro');

        // The failed projection is discarded rather than retried, and the next
        // one still lands.
        notifier.bufferLastMessageContentSnapshot(() => 'Recovered');
        notifier.syncStreamingBuffer();
        expect(
          container.read(chatMessagesProvider).single.content,
          'Recovered',
        );
      });

      test('buffered deltas are stranded once the streaming row stops being the tail', () {
        final container = buildContainer();
        addTearDown(container.dispose);

        final notifier = container.read(chatMessagesProvider.notifier);
        notifier.setMessages([streamingTail()]);
        notifier.appendToLastMessage(' world');
        notifier.addMessage(
          ChatMessage(
            id: 'user-2',
            role: 'user',
            content: 'next question',
            timestamp: DateTime(2024, 1, 2),
          ),
        );

        notifier.syncStreamingBuffer();

        // `_messageWithBufferedStreamingContent` only ever folds into
        // `state.last`. Pinned as observed: the buffered ' world' is dropped
        // instead of being merged into the assistant row that owns it. This
        // looks like a narrow data-loss path, left unchanged here.
        expect(
          container
              .read(chatMessagesProvider)
              .map((message) => message.content)
              .toList(),
          <String>['Hello', 'next question'],
        );
      });
    });
  });
}
