import 'package:conduit/features/chat/widgets/response_activity_indicator.dart';
import 'package:conduit/features/chat/widgets/streaming_turn_footer.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/response_animation.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/features/chat/providers/queued_completion_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

final _running = ChatMessage(
  id: 'turn',
  role: 'assistant',
  content: 'Hello',
  timestamp: DateTime(2026),
  isStreaming: true,
);

Widget _harness(ProviderContainer container, ChatMessage message) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        themeAnimationDuration: Duration.zero,
        theme: AppTheme.dark(TweakcnThemes.t3Chat),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: StreamingTurnFooter(message: message),
          ),
        ),
      ),
    );

ProviderContainer _container({
  ResponseFinishStyle finish = ResponseFinishStyle.fade,
  bool reduced = false,
}) => ProviderContainer(
  overrides: [
    queuedCompletionInfoForMessageProvider('turn')
        .overrideWith((ref) => Stream<QueuedCompletionInfo?>.value(null)),
    appSettingsProvider.overrideWithValue(
      AppSettings(
        thinkingIndicatorStyle: ResponseIndicatorStyle.gather,
        skillIndicatorStyle: ResponseIndicatorStyle.fold,
        responseFinishStyle: finish,
        reduceMotion: reduced,
        disableHapticsWhileStreaming: true,
      ),
    ),
  ],
);

void main() {
  testWidgets('selected styles follow pending skills and return to thinking', (
    tester,
  ) async {
    final container = _container();
    addTearDown(container.dispose);
    await tester.pumpWidget(_harness(container, _running));
    expect(
      tester
          .widget<ResponseActivityIndicator>(
            find.byType(ResponseActivityIndicator),
          )
          .style,
      ResponseIndicatorStyle.gather,
    );
    final skill = _running.copyWith(
      statusHistory: const [
        ChatStatusUpdate(action: 'reasoning'),
        ChatStatusUpdate(action: 'hermes_tool_search', done: false),
      ],
    );
    await tester.pumpWidget(_harness(container, skill));
    expect(
      tester
          .widget<ResponseActivityIndicator>(
            find.byType(ResponseActivityIndicator),
          )
          .style,
      ResponseIndicatorStyle.fold,
    );
    final done = skill.copyWith(
      statusHistory: const [
        ChatStatusUpdate(action: 'hermes_tool_search', done: true),
      ],
    );
    await tester.pumpWidget(_harness(container, done));
    expect(
      tester
          .widget<ResponseActivityIndicator>(
            find.byType(ResponseActivityIndicator),
          )
          .style,
      ResponseIndicatorStyle.gather,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final finish in ResponseFinishStyle.values) {
    testWidgets(
      '${finish.name} completes without extra footer height or ongoing tickers',
      (tester) async {
        final container = _container(finish: finish);
        addTearDown(container.dispose);
        await tester.pumpWidget(_harness(container, _running));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpWidget(
          _harness(
            container,
            _running.copyWith(metadata: {'responseDone': true}),
          ),
        );
        await tester.pump();
        expect(find.byType(ResponseActivityIndicator), findsNothing);
        expect(tester.getSize(find.byType(StreamingTurnFooter)).height, 0);
        expect(
          find.byKey(const ValueKey('response-finish-frame')),
          finish == ResponseFinishStyle.clear ? findsNothing : findsOneWidget,
        );
        await tester.pump(const Duration(milliseconds: 250));
        await tester.pump();
        expect(
          find.byKey(const ValueKey('response-finish-frame')),
          findsNothing,
        );
        expect(tester.binding.transientCallbackCount, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'no finish effect for reduced motion, errors, or completed history',
    (tester) async {
      final reduced = _container(reduced: true);
      addTearDown(reduced.dispose);
      await tester.pumpWidget(_harness(reduced, _running));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpWidget(
        _harness(reduced, _running.copyWith(isStreaming: false)),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('response-finish-frame')), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
      final enabled = _container();
      addTearDown(enabled.dispose);
      await tester.pumpWidget(_harness(enabled, _running));
      await tester.pumpWidget(
        _harness(
          enabled,
          _running.copyWith(error: const ChatMessageError(content: 'Failed')),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('response-finish-frame')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        _harness(enabled, _running.copyWith(isStreaming: false)),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('response-finish-frame')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  testWidgets('completion exit cancels when backgrounded or disposed', (
    tester,
  ) async {
    final container = _container();
    addTearDown(container.dispose);
    await tester.pumpWidget(_harness(container, _running));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(
      _harness(container, _running.copyWith(isStreaming: false)),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('response-finish-frame')), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(find.byKey(const ValueKey('response-finish-frame')), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(_harness(container, _running));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(
      _harness(container, _running.copyWith(isStreaming: false)),
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(find.byKey(const ValueKey('response-finish-frame')), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });
}
