import 'package:checks/checks.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/features/chat/providers/queued_completion_provider.dart';
import 'package:conduit/features/chat/widgets/conduit_streaming_orbit.dart';
import 'package:conduit/features/chat/widgets/streaming_turn_footer.dart';
import 'package:conduit/features/chat/widgets/thinking_status_label.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordedPlatformCall {
  const _RecordedPlatformCall(this.method, this.arguments);

  final String method;
  final Object? arguments;
}

Iterable<_RecordedPlatformCall> _lightImpactCalls(
  List<_RecordedPlatformCall> calls,
) => calls.where(
  (call) =>
      call.method == 'HapticFeedback.vibrate' &&
      call.arguments == 'HapticFeedbackType.lightImpact',
);

ProviderContainer _buildContainer() {
  return ProviderContainer(
    overrides: [
      appSettingsProvider.overrideWithValue(
        const AppSettings(disableHapticsWhileStreaming: true),
      ),
    ],
  );
}

ProviderContainer _buildHapticsContainer({bool enabled = true}) {
  return ProviderContainer(
    overrides: [
      appSettingsProvider.overrideWithValue(
        AppSettings(disableHapticsWhileStreaming: !enabled),
      ),
    ],
  );
}

Widget _buildHarness({
  required ProviderContainer container,
  required ChatMessage message,
}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: AppTheme.light(TweakcnThemes.t3Chat),
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Scaffold(body: StreamingTurnFooter(message: message)),
      ),
    ),
  );
}

void main() {
  testWidgets('shows empty-stream indicator immediately while running', (
    tester,
  ) async {
    final container = _buildContainer();
    addTearDown(container.dispose);
    final message = ChatMessage(
      id: 'assistant-live',
      role: 'assistant',
      content: '',
      timestamp: DateTime(2026),
      isStreaming: true,
    );

    await tester.pumpWidget(
      _buildHarness(container: container, message: message),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('typing')), findsOneWidget);
  });

  testWidgets(
    'shows the orbit only while the reply works with nothing to read',
    (tester) async {
      final container = _buildContainer();
      addTearDown(container.dispose);
      final empty = ChatMessage(
        id: 'assistant-live',
        role: 'assistant',
        content: '',
        timestamp: DateTime.now(),
        isStreaming: true,
      );
      double orbitOpacity() => tester
          .widget<AnimatedOpacity>(
            find.byKey(const ValueKey('streaming-turn-orbit-opacity')),
          )
          .opacity;

      await tester.pumpWidget(
        _buildHarness(container: container, message: empty),
      );
      await tester.pump();
      // "Thinking…" lives in the reply's first line now, not here; the
      // orbit keeps its place but stays hidden, so nothing moves later.
      expect(find.byType(ThinkingStatusLabel), findsNothing);
      expect(find.byType(ConduitStreamingOrbit), findsOneWidget);
      expect(orbitOpacity(), 0);
      final rowHeight = tester
          .getSize(find.byKey(const ValueKey('typing')))
          .height;

      // A visible status row stands in for the answer: the orbit says the
      // turn is still working.
      await tester.pumpWidget(
        _buildHarness(
          container: container,
          message: empty.copyWith(
            statusHistory: const [
              ChatStatusUpdate(action: 'web_search', description: 'Searching'),
            ],
          ),
        ),
      );
      await tester.pump();
      expect(orbitOpacity(), 1);

      // Once text streams, the text itself (and Stop in the composer) says
      // the reply is still coming; a spinner a line below would float
      // unattached. The row keeps its height for the action row.
      await tester.pumpWidget(
        _buildHarness(
          container: container,
          message: empty.copyWith(content: 'Hello'),
        ),
      );
      await tester.pump();
      expect(orbitOpacity(), 0);
      expect(
        tester.getSize(find.byKey(const ValueKey('typing'))).height,
        rowHeight,
      );
    },
  );

  test('the orbit never shows beside reply text', () {
    final message = ChatMessage(
      id: 'assistant-live',
      role: 'assistant',
      content: '',
      timestamp: DateTime(2026),
      isStreaming: true,
    );
    check(shouldShowStreamingOrbit(message: message, hasStreamedContent: false))
        .isFalse(); // "Thinking…" holds the first line instead.
    check(shouldShowStreamingOrbit(message: message, hasStreamedContent: true))
        .isFalse();
    check(
      shouldShowStreamingOrbit(
        message: message.copyWith(content: 'Partial answer'),
        hasStreamedContent: false,
      ),
    ).isFalse();
    check(
      shouldShowStreamingOrbit(
        message: message.copyWith(
          statusHistory: const [ChatStatusUpdate(description: 'Reading')],
        ),
        hasStreamedContent: false,
      ),
    ).isTrue();
  });

  testWidgets('Thinking holds the first line and cross-fades in place', (
    tester,
  ) async {
    final startedAt = DateTime.now();
    const lineKey = ValueKey('first-line');
    Widget harness({required bool showing, required String content}) =>
        MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: ReplyFirstLineThinking(
                startedAt: startedAt,
                showing: showing,
                child: content.isEmpty
                    ? const SizedBox.shrink()
                    : Text(content, key: lineKey),
              ),
            ),
          ),
        );

    await tester.pumpWidget(harness(showing: true, content: ''));
    final label = find.byKey(ReplyFirstLineThinking.labelKey);
    expect(label, findsOneWidget);
    final labelTop = tester.getTopLeft(label);
    final heightWhileThinking = tester
        .getSize(find.byType(ReplyFirstLineThinking))
        .height;
    // Set in the reply's body type: one line of the answer's own height.
    expect(heightWhileThinking, closeTo(24, 0.5));

    await tester.pumpWidget(harness(showing: false, content: 'Hello'));
    await tester.pump(const Duration(milliseconds: 16));
    // The first words start where the label stood; the label fades out over
    // them instead of moving.
    expect(tester.getTopLeft(find.byKey(lineKey)), labelTop);
    expect(tester.getTopLeft(label), labelTop);
    expect(
      tester.getSize(find.byType(ReplyFirstLineThinking)).height,
      greaterThanOrEqualTo(tester.getSize(find.byKey(lineKey)).height),
    );
    // The label is gone well before the first words finish fading in, so the
    // two lines never read through each other.
    await tester.pump(ReplyFirstLineThinking.exitDuration);
    expect(label, findsNothing);
    await tester.pumpAndSettle();
    expect(label, findsNothing);
  });

  test('a reply shows Thinking in its first line only until it shows '
      'anything', () {
    final empty = ChatMessage(
      id: 'assistant-live',
      role: 'assistant',
      content: '',
      timestamp: DateTime(2026),
      isStreaming: true,
    );
    expect(
      shouldShowReplyFirstLineThinking(message: empty, displayedContent: ''),
      isTrue,
    );
    expect(
      shouldShowReplyFirstLineThinking(message: empty, displayedContent: 'Hi'),
      isFalse,
    );
    expect(
      shouldShowReplyFirstLineThinking(
        message: empty.copyWith(isStreaming: false),
        displayedContent: '',
      ),
      isFalse,
    );
  });

  test('the thinking label yields to anything the reply shows', () {
    final empty = ChatMessage(
      id: 'assistant-live',
      role: 'assistant',
      content: '',
      timestamp: DateTime(2026),
      isStreaming: true,
    );
    expect(
      shouldShowThinkingLabel(message: empty, hasStreamedContent: false),
      isTrue,
    );
    expect(
      shouldShowThinkingLabel(message: empty, hasStreamedContent: true),
      isFalse,
    );
    expect(
      shouldShowThinkingLabel(
        message: empty.copyWith(
          statusHistory: const [
            ChatStatusUpdate(action: 'search', description: 'Searching'),
          ],
        ),
        hasStreamedContent: false,
      ),
      isFalse,
    );
    expect(
      shouldShowThinkingLabel(
        message: empty.copyWith(
          statusHistory: const [
            ChatStatusUpdate(action: 'hidden', hidden: true),
          ],
        ),
        hasStreamedContent: false,
      ),
      isTrue,
    );
  });

  testWidgets('stays visible once streaming content arrives', (tester) async {
    final container = _buildContainer();
    addTearDown(container.dispose);
    final empty = ChatMessage(
      id: 'assistant-live',
      role: 'assistant',
      content: '',
      timestamp: DateTime(2026),
      isStreaming: true,
    );

    await tester.pumpWidget(
      _buildHarness(container: container, message: empty),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('typing')), findsOneWidget);

    // Re-pump the same message id with content arriving so the footer is driven
    // through the empty -> content transition rather than asserting a static
    // single state.
    final withContent = empty.copyWith(content: 'Hello');
    await tester.pumpWidget(
      _buildHarness(container: container, message: withContent),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('typing')), findsOneWidget);
  });

  testWidgets('left-aligns the running indicator in its footer row', (
    tester,
  ) async {
    final container = _buildContainer();
    addTearDown(container.dispose);
    final message = ChatMessage(
      id: 'assistant-live',
      role: 'assistant',
      content: 'Hello',
      timestamp: DateTime(2026),
      isStreaming: true,
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 320,
                  child: StreamingTurnFooter(message: message),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final indicatorLeft = tester
        .getTopLeft(find.byType(ConduitStreamingOrbit))
        .dx;
    expect(indicatorLeft, lessThan(48));
  });

  testWidgets('stays visible while status rows are pending', (tester) async {
    final container = _buildContainer();
    addTearDown(container.dispose);
    final pending = ChatMessage(
      id: 'assistant-status',
      role: 'assistant',
      content: '',
      timestamp: DateTime(2026),
      isStreaming: true,
      statusHistory: const [
        ChatStatusUpdate(action: 'search', description: 'Searching'),
      ],
    );
    final done = pending.copyWith(
      statusHistory: const [
        ChatStatusUpdate(
          action: 'search',
          description: 'Searching',
          done: true,
        ),
      ],
    );

    await tester.pumpWidget(
      _buildHarness(container: container, message: pending),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('typing')), findsOneWidget);

    await tester.pumpWidget(_buildHarness(container: container, message: done));
    await tester.pump();

    expect(find.byKey(const ValueKey('typing')), findsOneWidget);
  });

  test(
    'active assistant streams show the footer until response completion',
    () {
      final streaming = ChatMessage(
        id: 'assistant-live',
        role: 'assistant',
        content: '',
        timestamp: DateTime(2026),
        isStreaming: true,
      );

      expect(shouldShowStreamingTurnFooter(message: streaming), isTrue);
      expect(
        shouldShowStreamingTurnFooter(
          message: streaming.copyWith(content: 'Hello'),
        ),
        isTrue,
      );
      // `responseDone` settles the turn even while the transport flag is still
      // streaming, so the typing footer must hide (the "responseDone gap").
      expect(
        shouldShowStreamingTurnFooter(
          message: streaming.copyWith(metadata: const {'responseDone': true}),
        ),
        isFalse,
      );
      expect(
        shouldShowStreamingTurnFooter(
          message: streaming.copyWith(files: const [{}]),
        ),
        isTrue,
      );
      // An errored turn is failed, not running — the footer is suppressed even
      // while `isStreaming` is still set.
      expect(
        shouldShowStreamingTurnFooter(
          message: streaming.copyWith(
            error: const ChatMessageError(content: 'boom'),
          ),
        ),
        isFalse,
      );
      expect(
        shouldShowStreamingTurnFooter(
          message: streaming.copyWith(
            isStreaming: false,
            metadata: const {'responseDone': true},
          ),
        ),
        isFalse,
      );
    },
  );

  testWidgets('hides typing indicator while a queued completion is pending', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWithValue(
          const AppSettings(disableHapticsWhileStreaming: true),
        ),
        queuedCompletionInfoForMessageProvider('assistant-queued').overrideWith(
          (ref) => Stream<QueuedCompletionInfo?>.value(
            const QueuedCompletionInfo(
              databaseOwner: Object(),
              seq: 1,
              chatId: 'chat-1',
              scopedChatId: 'chat-1',
              assistantMessageId: 'assistant-queued',
              phase: QueuedCompletionPhase.pending,
              isOffline: true,
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final message = ChatMessage(
      id: 'assistant-queued',
      role: 'assistant',
      content: '',
      timestamp: DateTime(2026),
      isStreaming: true,
    );

    await tester.pumpWidget(
      _buildHarness(container: container, message: message),
    );
    await tester.pump();

    expect(find.byType(ConduitStreamingOrbit), findsNothing);
    expect(find.byKey(const ValueKey('typing')), findsNothing);
  });

  testWidgets('fires one running haptic and re-arms on message id change', (
    tester,
  ) async {
    final container = _buildHapticsContainer();
    addTearDown(container.dispose);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <_RecordedPlatformCall>[];
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(_RecordedPlatformCall(call.method, call.arguments));
      return null;
    });
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    try {
      final running = ChatMessage(
        id: 'assistant-1',
        role: 'assistant',
        content: '',
        timestamp: DateTime(2026),
        isStreaming: true,
      );

      await tester.pumpWidget(
        _buildHarness(container: container, message: running),
      );
      await tester.pump();
      expect(_lightImpactCalls(calls), hasLength(1));

      // Same id, content arrives, still running: the fire-once guard holds.
      await tester.pumpWidget(
        _buildHarness(
          container: container,
          message: running.copyWith(content: 'Hi'),
        ),
      );
      await tester.pump();
      expect(_lightImpactCalls(calls), hasLength(1));

      // A new running message id re-arms the haptic.
      final next = ChatMessage(
        id: 'assistant-2',
        role: 'assistant',
        content: '',
        timestamp: DateTime(2026),
        isStreaming: true,
      );
      await tester.pumpWidget(
        _buildHarness(container: container, message: next),
      );
      await tester.pump();
      expect(_lightImpactCalls(calls), hasLength(2));
    } finally {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
    'does not fire the running haptic when suppressed on the footer',
    (tester) async {
      final container = _buildHapticsContainer();
      addTearDown(container.dispose);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <_RecordedPlatformCall>[];
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        calls.add(_RecordedPlatformCall(call.method, call.arguments));
        return null;
      });
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.light(TweakcnThemes.t3Chat),
              home: MediaQuery(
                data: const MediaQueryData(disableAnimations: true),
                child: Scaffold(
                  body: StreamingTurnFooter(
                    message: ChatMessage(
                      id: 'assistant-1',
                      role: 'assistant',
                      content: '',
                      timestamp: DateTime(2026),
                      isStreaming: true,
                    ),
                    suppressStreamingHaptics: true,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(_lightImpactCalls(calls), isEmpty);
      } finally {
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'does not fire the running haptic when streaming haptics are disabled',
    (tester) async {
      final container = _buildHapticsContainer(enabled: false);
      addTearDown(container.dispose);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <_RecordedPlatformCall>[];
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        calls.add(_RecordedPlatformCall(call.method, call.arguments));
        return null;
      });
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      try {
        await tester.pumpWidget(
          _buildHarness(
            container: container,
            message: ChatMessage(
              id: 'assistant-1',
              role: 'assistant',
              content: '',
              timestamp: DateTime(2026),
              isStreaming: true,
            ),
          ),
        );
        await tester.pump();

        expect(_lightImpactCalls(calls), isEmpty);
      } finally {
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets('hides the typing indicator once the turn settles', (
    tester,
  ) async {
    final container = _buildContainer();
    addTearDown(container.dispose);
    final running = ChatMessage(
      id: 'assistant-live',
      role: 'assistant',
      content: '',
      timestamp: DateTime(2026),
      isStreaming: true,
    );

    await tester.pumpWidget(
      _buildHarness(container: container, message: running),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('typing')), findsOneWidget);

    await tester.pumpWidget(
      _buildHarness(
        container: container,
        message: running.copyWith(metadata: const {'responseDone': true}),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('typing')), findsNothing);
    expect(
      find.byKey(const ValueKey('streaming-turn-footer-empty')),
      findsOneWidget,
    );
  });

  testWidgets('does not replay the running haptic when the footer remounts', (
    tester,
  ) async {
    final container = _buildHapticsContainer();
    addTearDown(container.dispose);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <_RecordedPlatformCall>[];
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(_RecordedPlatformCall(call.method, call.arguments));
      return null;
    });
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    try {
      final running = ChatMessage(
        id: 'assistant-1',
        role: 'assistant',
        content: '',
        timestamp: DateTime(2026),
        isStreaming: true,
      );

      await tester.pumpWidget(
        _buildHarness(container: container, message: running),
      );
      await tester.pump();
      check(_lightImpactCalls(calls)).length.equals(1);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pumpWidget(
        _buildHarness(container: container, message: running),
      );
      await tester.pump();

      check(_lightImpactCalls(calls)).length.equals(1);
    } finally {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
    're-arms the running haptic after hiding and reshowing on the same id',
    (tester) async {
      final container = _buildHapticsContainer();
      addTearDown(container.dispose);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <_RecordedPlatformCall>[];
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        calls.add(_RecordedPlatformCall(call.method, call.arguments));
        return null;
      });
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      try {
        final running = ChatMessage(
          id: 'assistant-1',
          role: 'assistant',
          content: '',
          timestamp: DateTime(2026),
          isStreaming: true,
        );

        await tester.pumpWidget(
          _buildHarness(container: container, message: running),
        );
        await tester.pump();
        expect(_lightImpactCalls(calls), hasLength(1));

        // Settling (responseDone) hides the footer and re-arms the guard via
        // _syncRunningHaptic(false) — without a message-id change.
        await tester.pumpWidget(
          _buildHarness(
            container: container,
            message: running.copyWith(metadata: const {'responseDone': true}),
          ),
        );
        await tester.pump();
        expect(_lightImpactCalls(calls), hasLength(1));

        // Back to running on the SAME id: the guard re-fires exactly once more.
        await tester.pumpWidget(
          _buildHarness(container: container, message: running),
        );
        await tester.pump();
        expect(_lightImpactCalls(calls), hasLength(2));
      } finally {
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
