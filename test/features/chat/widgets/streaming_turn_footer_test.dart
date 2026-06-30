import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/services/settings_service.dart';
import 'package:conduit/features/chat/widgets/five_rotating_dots.dart';
import 'package:conduit/features/chat/widgets/streaming_turn_footer.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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
        const AppSettings(hapticFeedback: false),
      ),
    ],
  );
}

ProviderContainer _buildHapticsContainer({bool hapticFeedback = true}) {
  return ProviderContainer(
    overrides: [
      appSettingsProvider.overrideWithValue(
        AppSettings(hapticFeedback: hapticFeedback),
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

    final indicatorLeft = tester.getTopLeft(find.byType(FiveRotatingDots)).dx;
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

  testWidgets('does not fire the running haptic when suppressed on the footer', (
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
  });

  testWidgets('does not fire the running haptic when haptics are disabled', (
    tester,
  ) async {
    final container = _buildHapticsContainer(hapticFeedback: false);
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
  });
}
