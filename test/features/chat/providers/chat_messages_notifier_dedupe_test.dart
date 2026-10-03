import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:conduit_core/providers/host_ports.dart';
import 'package:conduit_core/testing.dart';
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

    testWidgets(
      'lazy progressive snapshots materialize once per visible flush',
      (tester) async {
        final container = buildContainer();
        final notifier = container.read(chatMessagesProvider.notifier);
        notifier.setMessages([
          _assistantMessage(content: 'Intro', isStreaming: true),
        ]);
        var materializations = 0;

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: _StreamingContentProbe()),
          ),
        );

        for (var index = 0; index < 100; index += 1) {
          notifier.bufferLastMessageContentSnapshot(() {
            materializations += 1;
            return 'Intro reasoning revision $index';
          });
        }
        expect(materializations, 0);

        await tester.pump();
        expect(materializations, 1);
        expect(find.text('Intro reasoning revision 99'), findsOneWidget);

        notifier.clearMessages();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 1));
        container.dispose();
        await tester.pump(const Duration(milliseconds: 1));
      },
    );

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

      test('foreground flushes are frame-gated and land nothing without one', () {
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

        // A plain `test` runs on the automated binding but never pumps, so the
        // `SchedulerBinding.scheduleFrameCallback` registered by
        // `_scheduleStreamingContentFrame` stays queued for the life of the
        // test. Every foreground flush path goes through that callback.
        notifier.appendToLastMessage(' a');
        notifier.appendToLastMessage(' b');
        notifier.appendToLastMessage(' c');

        expect(emissions, isEmpty);
        expect(container.read(streamingContentProvider), isNull);
        // The message list is untouched as well: until a flush or an explicit
        // sync, the buffer is the only place the deltas exist.
        expect(container.read(chatMessagesProvider).single.content, 'Hello');
      });

      testWidgets(
        'first delta flushes on the next frame, later deltas wait out the '
        'cadence window and coalesce into one emission',
        (tester) async {
          final container = buildContainer();
          final notifier = container.read(chatMessagesProvider.notifier);
          notifier.setMessages([streamingTail()]);

          final emissions = <String?>[];
          final subscription = container.listen<String?>(
            streamingContentProvider,
            (_, next) => emissions.add(next),
            fireImmediately: false,
          );

          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: const MaterialApp(home: _StreamingContentProbe()),
            ),
          );

          // Nothing is visible yet, so the first delta takes the "first
          // content" path straight to a frame, skipping the cadence timer.
          // Deltas 2 and 3 find a frame already scheduled and are swallowed by
          // the `_streamingContentFrameScheduled` guard.
          notifier.appendToLastMessage(' a');
          notifier.appendToLastMessage(' b');
          notifier.appendToLastMessage(' c');
          expect(emissions, isEmpty);

          final flushedNotBefore = DateTime.now();
          await tester.pump();
          expect(emissions, <String?>['Hello a b c']);
          expect(find.text('Hello a b c'), findsOneWidget);

          notifier.appendToLastMessage(' d');
          notifier.appendToLastMessage(' e');
          // The cadence clock is `DateTime.now()` (real wall time) while
          // `Timer` runs on the binding's fake clock, so "the window is still
          // open" is only knowable in real time. In practice the gap here is
          // sub-millisecond; the guard keeps a stalled machine from flaking the
          // strict assertion while the unconditional ones below still run.
          final cadenceWindowStillOpen =
              DateTime.now().difference(flushedNotBefore) <
              streamingContentUpdateInterval;
          await tester.pump();
          if (cadenceWindowStillOpen) {
            expect(
              emissions,
              <String?>['Hello a b c'],
              reason:
                  'a delta inside the cadence window waits for the timer, '
                  'not for the next frame',
            );
          }

          // Elapsing the interval fires the cadence timer, which schedules the
          // frame; `pump(duration)` then runs that frame in the same call.
          await tester.pump(streamingContentUpdateInterval);
          expect(emissions, <String?>['Hello a b c', 'Hello a b c d e']);
          expect(find.text('Hello a b c d e'), findsOneWidget);

          subscription.close();
          notifier.clearMessages();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(milliseconds: 1));
          container.dispose();
          await tester.pump(const Duration(milliseconds: 1));
        },
      );

      testWidgets(
        'an immediate replacement preempts the buffered delta but still waits '
        'for a frame',
        (tester) async {
          final container = buildContainer();
          final notifier = container.read(chatMessagesProvider.notifier);
          notifier.setMessages([streamingTail()]);

          final emissions = <String?>[];
          final subscription = container.listen<String?>(
            streamingContentProvider,
            (_, next) => emissions.add(next),
            fireImmediately: false,
          );

          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: const MaterialApp(home: _StreamingContentProbe()),
            ),
          );

          notifier.appendToLastMessage(' a');
          await tester.pump();
          expect(emissions, <String?>['Hello a']);

          notifier.appendToLastMessage(' pending');
          notifier.replaceLastMessageContent('Replaced');

          // `immediate: true` only skips the cadence timer; the flush is still
          // a frame callback, so nothing is visible in the calling turn.
          expect(container.read(streamingContentProvider), 'Hello a');
          expect(emissions, <String?>['Hello a']);

          await tester.pump();
          // The buffered ' pending' delta is never emitted: a replacement
          // rewrites the whole buffer, so the intermediate value is dropped.
          expect(emissions, <String?>['Hello a', 'Replaced']);
          expect(find.text('Replaced'), findsOneWidget);

          subscription.close();
          notifier.clearMessages();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(milliseconds: 1));
          container.dispose();
          await tester.pump(const Duration(milliseconds: 1));
        },
      );

      testWidgets(
        'a flush whose content matches the visible value emits nothing',
        (tester) async {
          final container = buildContainer();
          final notifier = container.read(chatMessagesProvider.notifier);
          notifier.setMessages([streamingTail()]);

          final emissions = <String?>[];
          final subscription = container.listen<String?>(
            streamingContentProvider,
            (_, next) => emissions.add(next),
            fireImmediately: false,
          );

          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: const MaterialApp(home: _StreamingContentProbe()),
            ),
          );

          notifier.appendToLastMessage(' world');
          await tester.pump();
          expect(emissions, <String?>['Hello world']);

          // A new buffer version that resolves to the same string still runs the
          // flush (the version guard passes), but the provider is left alone.
          notifier.bufferLastMessageContentSnapshot(() => 'Hello world');
          await tester.pump(streamingContentUpdateInterval);
          expect(emissions, <String?>['Hello world']);

          subscription.close();
          notifier.clearMessages();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(milliseconds: 1));
          container.dispose();
          await tester.pump(const Duration(milliseconds: 1));
        },
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
