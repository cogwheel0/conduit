import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/services/settings_service.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/chat/providers/text_to_speech_provider.dart';
import 'package:conduit/features/chat/widgets/assistant_message_widget.dart';
import 'package:conduit/features/chat/widgets/streaming_turn_footer.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _TestTextToSpeechController extends TextToSpeechController {
  @override
  TextToSpeechState build() => const TextToSpeechState();
}

Widget _harness({
  required Widget child,
  required bool isChatStreaming,
  required double textScale,
}) {
  return ProviderScope(
    overrides: [
      appSettingsProvider.overrideWithValue(
        const AppSettings(disableHapticsWhileStreaming: true),
      ),
      streamingHapticsEnabledProvider.overrideWithValue(false),
      textToSpeechControllerProvider.overrideWith(
        _TestTextToSpeechController.new,
      ),
      isChatStreamingProvider.overrideWithValue(isChatStreaming),
    ],
    child: MaterialApp(
      theme: AppTheme.light(TweakcnThemes.t3Chat),
      localizationsDelegates: conduitLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, c) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: true,
          textScaler: TextScaler.linear(textScale),
        ),
        child: c!,
      ),
      home: Scaffold(
        body: Align(alignment: Alignment.topLeft, child: child),
      ),
    ),
  );
}

Widget _card(ChatMessage message, {required bool isStreaming}) {
  return AssistantMessageWidget(
    message: message,
    isStreaming: isStreaming,
    showFollowUps: false,
    animateOnMount: false,
    modelName: message.model,
    onCopy: () {},
    onRegenerate: () {},
    onDelete: () {},
  );
}

void main() {
  Future<void> probe(
    WidgetTester tester,
    String name, {
    required double textScale,
    List<ChatMessageVersion> versions = const [],
    List<ChatSourceReference> sources = const [],
    List<ChatStatusUpdate> statusHistory = const [],
    String content = 'Hello, this is the answer text for the probe.',
  }) async {
    final streamingMsg = ChatMessage(
      id: 'm-$name',
      role: 'assistant',
      content: content,
      timestamp: DateTime(2026),
      isStreaming: true,
      model: 'gpt-test',
      versions: versions,
      sources: sources,
      statusHistory: statusHistory,
    );
    final settledMsg = streamingMsg.copyWith(
      isStreaming: false,
      metadata: {'responseDone': true},
    );

    await tester.pumpWidget(
      _harness(
        isChatStreaming: true,
        textScale: textScale,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _card(streamingMsg, isStreaming: true),
            StreamingTurnFooter(message: streamingMsg),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    final streamingTotal = tester.getSize(find.byType(Column).first).height;

    await tester.pumpWidget(
      _harness(
        isChatStreaming: false,
        textScale: textScale,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [_card(settledMsg, isStreaming: false)],
        ),
      ),
    );
    await tester.pumpAndSettle();
    final settledTotal = tester.getSize(find.byType(Column).first).height;

    expect(
      settledTotal,
      moreOrLessEquals(streamingTotal, epsilon: 0.5),
      reason:
          '$name (scale $textScale): the settle transition must be '
          'extent-neutral — streaming card + typing indicator '
          '($streamingTotal) vs settled card ($settledTotal)',
    );
  }

  // The timeline swaps the typing-indicator footer (16 + 28 + 4) for the
  // in-card action row (16 + 32) at settle. These cases must be
  // extent-neutral so the bottom-anchored viewport does not jump; growth
  // from settle-only UI (sources row, text-scaled chips) is animated by the
  // AnimatedSize around the footer slot instead.
  testWidgets('the streaming-to-settled swap is extent-neutral', (
    tester,
  ) async {
    await probe(tester, 'plain-1.0', textScale: 1.0);
    await probe(tester, 'plain-1.3', textScale: 1.3);
    await probe(
      tester,
      'versions-1.0',
      textScale: 1.0,
      versions: [
        ChatMessageVersion(id: 'v1', content: 'old', timestamp: DateTime(2026)),
      ],
    );
    await probe(
      tester,
      'status-pending-1.0',
      textScale: 1.0,
      statusHistory: const [
        ChatStatusUpdate(description: 'Searching the web', done: false),
      ],
    );
    await probe(
      tester,
      'status-done-1.0',
      textScale: 1.0,
      statusHistory: const [
        ChatStatusUpdate(description: 'Searched the web', done: true),
      ],
    );
    await probe(
      tester,
      'reasoning-1.0',
      textScale: 1.0,
      content:
          '<details type="reasoning" done="true" duration="3">\n'
          '<summary>Thought for 3 seconds</summary>\n'
          '> thinking\n'
          '</details>\n'
          'Hello, this is the answer text for the probe.',
    );
  });
}
