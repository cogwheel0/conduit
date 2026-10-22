import 'dart:io';
import 'dart:ui' as ui;

import 'package:conduit/features/chat/widgets/assistant_message_widget.dart';
import 'package:conduit/features/chat/widgets/response_activity_indicator.dart';
import 'package:conduit/features/chat/providers/text_to_speech_provider.dart';
import 'package:conduit/features/hermes/providers/hermes_mobile_navigation.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/features/chat/providers/queued_completion_provider.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/response_animation.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

class _IdleSpeechController extends TextToSpeechController {
  @override
  TextToSpeechState build() => const TextToSpeechState();
}

void main() {
  final capture = GlobalKey();

  Future<void> snapshot(WidgetTester tester, String name) async {
    await tester.runAsync(() async {
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('output/response-animations/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  final waiting = ChatMessage(
    id: 'waiting',
    role: 'assistant',
    content: '',
    timestamp: DateTime(2026),
    isStreaming: true,
  );

  ProviderContainer container({
    bool reduced = false,
    QueuedCompletionInfo? queued,
  }) => ProviderContainer(
    overrides: [
      hermesMobileLayoutProvider.overrideWithValue(true),
      comparisonAnswerStopPermittedProvider.overrideWithValue(false),
      textToSpeechControllerProvider.overrideWith(_IdleSpeechController.new),
      appSettingsProvider.overrideWithValue(
        AppSettings(
          reduceMotion: reduced,
          responseFinishStyle: ResponseFinishStyle.clear,
          disableHapticsWhileStreaming: true,
        ),
      ),
      queuedCompletionInfoForMessageProvider('waiting')
          .overrideWith((ref) => Stream<QueuedCompletionInfo?>.value(queued)),
    ],
  );

  Widget harness(ProviderContainer scope, ChatMessage message) =>
      UncontrolledProviderScope(
        container: scope,
        child: MaterialApp(
          theme: AppTheme.dark(TweakcnThemes.t3Chat),
          themeAnimationDuration: Duration.zero,
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: RepaintBoundary(
            key: capture,
            child: Scaffold(
              body: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: AssistantMessageWidget(
                    message: message,
                    isStreaming: message.isStreaming,
                    animateOnMount: false,
                    suppressStreamingHaptics: true,
                    showFollowUps: false,
                    onDelete: () {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );

  testWidgets('empty bubble is replaced by one mark which fades on first text', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final bytes = ByteData.sublistView(
        File('design-previews/hermes-thinking/fonts/Roboto-Regular.ttf')
            .readAsBytesSync(),
      );
      await (FontLoader('Roboto')..addFont(Future.value(bytes))).load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final scope = container();
    addTearDown(scope.dispose);
    await tester.pumpWidget(harness(scope, waiting));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ResponseActivityIndicator), findsOneWidget);
    expect(
      find.byKey(const ValueKey('assistant-message-bubble-surface-waiting')),
      findsNothing,
    );
    final iconRect = tester.getRect(find.byType(ResponseActivityIndicator));
    expect(iconRect.size, const Size(28, 28));
    await snapshot(tester, 'waiting-mark');
    await tester.pumpWidget(
      harness(scope, waiting.copyWith(content: 'Here is the reply.')),
    );
    await tester.pump();
    await tester
        .pump(); // Paint the exit overlay after the first-content shell swap.
    expect(find.byType(ResponseActivityIndicator), findsNothing);
    expect(find.text('Here is the reply.', findRichText: true), findsOneWidget);
    expect(find.byKey(const ValueKey('response-finish-frame')), findsOneWidget);
    expect(
      tester.getRect(find.byKey(const ValueKey('response-finish-frame'))),
      iconRect,
    );
    await tester.pump(const Duration(milliseconds: 100));
    final fade = tester.widget<FadeTransition>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('response-finish-frame')),
            matching: find.byType(FadeTransition),
          )
          .first,
    );
    expect(fade.opacity.value, inExclusiveRange(0, 1));
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.byKey(const ValueKey('response-finish-frame')), findsNothing);
    await snapshot(tester, 'first-reply-text');
    // Later streaming batches keep the response body and never restart a mark.
    await tester.pumpWidget(
      harness(
        scope,
        waiting.copyWith(content: 'Here is the reply. More words.'),
      ),
    );
    expect(find.byType(ResponseActivityIndicator), findsNothing);
    expect(find.byKey(const ValueKey('response-finish-frame')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets(
    'a pending skill places its status text to the right of the mark',
    (tester) async {
      final scope = container();
      addTearDown(scope.dispose);
      await tester.pumpWidget(
        harness(
          scope,
          waiting.copyWith(
            statusHistory: const [
              ChatStatusUpdate(
                action: 'hermes_tool_search',
                description: 'Searching',
                done: false,
              ),
            ],
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      final indicator = tester.widget<ResponseActivityIndicator>(
        find.byType(ResponseActivityIndicator),
      );
      expect(indicator.style, ResponseIndicatorStyle.exchange);
      await snapshot(tester, 'waiting-skill-status');
      expect(
        tester.getRect(find.text('Searching').first).left,
        greaterThan(
          tester.getRect(find.byType(ResponseActivityIndicator)).right,
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  testWidgets('reduced motion clears the waiting mark without an exit', (
    tester,
  ) async {
    final scope = container(reduced: true);
    addTearDown(scope.dispose);
    await tester.pumpWidget(harness(scope, waiting));
    expect(
      tester
          .widget<ResponseActivityIndicator>(
            find.byType(ResponseActivityIndicator),
          )
          .animate,
      isFalse,
    );
    await tester.pumpWidget(harness(scope, waiting.copyWith(content: 'Reply')));
    await tester.pump();
    expect(find.byKey(const ValueKey('response-finish-frame')), findsNothing);
    expect(find.byType(ResponseActivityIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'queued offline recovery remains visible in the mobile waiting slot',
    (tester) async {
      final scope = container(
        queued: const QueuedCompletionInfo(
          databaseOwner: Object(),
          seq: 42,
          chatId: 'chat',
          scopedChatId: 'chat',
          assistantMessageId: 'waiting',
          phase: QueuedCompletionPhase.pending,
          isOffline: true,
          lastError: 'offline',
          nextAttemptAt: 123,
        ),
      );
      addTearDown(scope.dispose);
      await tester.pumpWidget(harness(scope, waiting));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Queued offline'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.byType(ResponseActivityIndicator), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );
}
