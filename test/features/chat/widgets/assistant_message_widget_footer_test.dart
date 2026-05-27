import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/features/chat/providers/assistant_response_builder_provider.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/chat/providers/text_to_speech_provider.dart';
import 'package:conduit/features/chat/widgets/assistant_message_widget.dart';
import 'package:conduit/features/chat/widgets/enhanced_attachment.dart';
import 'package:conduit/features/chat/widgets/follow_up_suggestions.dart';
import 'package:conduit/features/chat/widgets/streaming_status_widget.dart';
import 'package:conduit/features/chat/widgets/sources/openwebui_sources.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestTextToSpeechController extends TextToSpeechController {
  @override
  TextToSpeechState build() => const TextToSpeechState();
}

class _RecordingTextToSpeechController extends TextToSpeechController {
  _RecordingTextToSpeechController(this.onToggle);

  final VoidCallback onToggle;

  @override
  TextToSpeechState build() =>
      const TextToSpeechState(initialized: true, available: true);

  @override
  Future<void> toggleForMessage({
    required String messageId,
    required String text,
  }) async {
    onToggle();
  }
}

Widget _buildHarness(Widget child) {
  return MaterialApp(
    theme: AppTheme.light(TweakcnThemes.t3Chat),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  );
}

Widget _buildAssistantHarness(
  ChatMessage message, {
  bool showFollowUps = false,
  bool isStreaming = false,
  VoidCallback? onCopy,
  VoidCallback? onRegenerate,
}) {
  return ProviderScope(
    overrides: [
      textToSpeechControllerProvider.overrideWith(
        _TestTextToSpeechController.new,
      ),
    ],
    child: MaterialApp(
      theme: AppTheme.light(TweakcnThemes.t3Chat),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: AssistantMessageWidget(
          message: message,
          isStreaming: isStreaming,
          showFollowUps: showFollowUps,
          animateOnMount: false,
          modelName: message.model,
          onCopy: onCopy ?? () {},
          onRegenerate: onRegenerate ?? () {},
          onDelete: () {},
        ),
      ),
    ),
  );
}

Future<void> _tapVersionControl(
  WidgetTester tester, {
  required IconData visibleIcon,
  required String overflowLabel,
}) async {
  final visibleFinder = find.byIcon(visibleIcon);
  if (visibleFinder.evaluate().isNotEmpty) {
    await tester.tap(visibleFinder);
    await tester.pumpAndSettle();
    return;
  }

  await tester.tap(find.byIcon(Icons.more_horiz_rounded));
  await tester.pumpAndSettle();
  await tester.tap(find.text(overflowLabel));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('source chip opens a details bottom sheet', (tester) async {
    const sources = <ChatSourceReference>[
      ChatSourceReference(
        title: 'OpenAI Research',
        snippet: 'A first source summary for the sheet.',
      ),
      ChatSourceReference(
        title: 'API Docs',
        snippet: 'A second source summary for the sheet.',
      ),
    ];

    await tester.pumpWidget(
      _buildHarness(
        const Center(child: OpenWebUISourcesWidget(sources: sources)),
      ),
    );

    expect(find.text('2 Sources'), findsOneWidget);

    await tester.tap(find.text('2 Sources'));
    await tester.pumpAndSettle();

    expect(find.text('OpenAI Research'), findsOneWidget);
    expect(find.text('A first source summary for the sheet.'), findsOneWidget);
    expect(find.text('API Docs'), findsOneWidget);
    expect(find.text('A second source summary for the sheet.'), findsOneWidget);
  });

  testWidgets('assistant footer caps inline actions and overflows extras', (
    tester,
  ) async {
    final message = ChatMessage(
      id: 'assistant-message',
      role: 'assistant',
      content: 'Listen to this response.',
      timestamp: DateTime(2024, 1, 1),
      sources: const [
        ChatSourceReference(
          title: 'Source A',
          snippet: 'Source details shown in the bottom sheet.',
        ),
      ],
      usage: const {'total_tokens': 24},
      versions: [
        ChatMessageVersion(
          id: 'assistant-message-v1',
          content: 'Older version',
          timestamp: DateTime(2023, 12, 31),
        ),
      ],
    );

    await tester.pumpWidget(_buildAssistantHarness(message));
    await tester.pumpAndSettle();

    expect(find.text('1 Source'), findsOneWidget);
    expect(find.text('2/2'), findsOneWidget);
    expect(find.byIcon(Icons.content_copy), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsOneWidget);
    expect(find.byIcon(Icons.chevron_left), findsNothing);
    expect(find.byIcon(Icons.chevron_right), findsNothing);
    expect(find.byIcon(Icons.more_horiz_rounded), findsOneWidget);

    final refreshPosition = tester.getTopLeft(find.byIcon(Icons.refresh));
    final sourcePosition = tester.getTopLeft(find.text('1 Source'));
    final versionPosition = tester.getTopLeft(find.text('2/2'));
    final overflowPosition = tester.getTopLeft(
      find.byIcon(Icons.more_horiz_rounded),
    );

    expect(sourcePosition.dx, greaterThan(refreshPosition.dx));
    expect(versionPosition.dx, greaterThan(sourcePosition.dx));
    expect(overflowPosition.dx, greaterThan(sourcePosition.dx));
    expect(overflowPosition.dx, greaterThan(versionPosition.dx));

    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await tester.pumpAndSettle();

    expect(find.text('Prev'), findsOneWidget);
    expect(find.text('Next'), findsOneWidget);
    expect(find.text('Info'), findsOneWidget);
  });

  testWidgets('assistant header follows the active version model', (
    tester,
  ) async {
    final message = ChatMessage(
      id: 'assistant-message',
      role: 'assistant',
      content: 'Current version',
      timestamp: DateTime(2024, 1, 1),
      model: 'Model B',
      versions: [
        ChatMessageVersion(
          id: 'assistant-message-v1',
          content: 'Older version',
          timestamp: DateTime(2023, 12, 31),
          model: 'Model A',
        ),
      ],
    );

    await tester.pumpWidget(_buildAssistantHarness(message));
    await tester.pumpAndSettle();

    expect(find.text('Model B'), findsOneWidget);

    await _tapVersionControl(
      tester,
      visibleIcon: Icons.chevron_left,
      overflowLabel: 'Prev',
    );

    expect(find.text('Model A'), findsOneWidget);
    expect(find.text('Model B'), findsNothing);

    await _tapVersionControl(
      tester,
      visibleIcon: Icons.chevron_right,
      overflowLabel: 'Next',
    );

    expect(find.text('Model B'), findsOneWidget);
    expect(find.text('Model A'), findsNothing);
  });

  testWidgets('pending-only finished statuses do not leave an empty gap', (
    tester,
  ) async {
    final baseline = ChatMessage(
      id: 'assistant-baseline',
      role: 'assistant',
      content: 'Visible response body',
      timestamp: DateTime(2024, 1, 1),
    );
    final pendingOnly = baseline.copyWith(
      id: 'assistant-pending',
      statusHistory: const [
        ChatStatusUpdate(description: 'Searching...', done: false),
      ],
    );

    await tester.pumpWidget(_buildAssistantHarness(baseline));
    await tester.pumpAndSettle();
    final baselineDy = tester.getTopLeft(find.text('Visible response body')).dy;

    await tester.pumpWidget(_buildAssistantHarness(pendingOnly));
    await tester.pumpAndSettle();

    expect(find.byType(StreamingStatusWidget), findsNothing);
    expect(find.text('Searching...'), findsNothing);
    expect(
      tester.getTopLeft(find.text('Visible response body')).dy,
      closeTo(baselineDy, 0.001),
    );
  });

  testWidgets('finished nullable-done statuses remain visible', (tester) async {
    final message = ChatMessage(
      id: 'assistant-nullable-status',
      role: 'assistant',
      content: 'Visible response body',
      timestamp: DateTime(2024, 1, 1),
      statusHistory: const [
        ChatStatusUpdate(description: 'Generating image...'),
      ],
    );

    await tester.pumpWidget(_buildAssistantHarness(message));
    await tester.pumpAndSettle();

    expect(find.text('Generating image...'), findsOneWidget);
    expect(find.byType(StreamingStatusWidget), findsOneWidget);
  });

  testWidgets('follow-ups update in place without size transitions', (
    tester,
  ) async {
    final baseline = ChatMessage(
      id: 'assistant-follow-ups',
      role: 'assistant',
      content: 'Visible response body',
      timestamp: DateTime(2024, 1, 1),
    );

    await tester.pumpWidget(
      _buildAssistantHarness(baseline, showFollowUps: true),
    );
    await tester.pumpAndSettle();

    expect(find.byType(FollowUpSuggestionBar), findsNothing);

    await tester.pumpWidget(
      _buildAssistantHarness(
        baseline.copyWith(followUps: const ['Ask again']),
        showFollowUps: true,
      ),
    );
    await tester.pump();

    expect(find.byType(SizeTransition), findsNothing);
    expect(find.byType(FollowUpSuggestionBar), findsOneWidget);
    expect(find.text('Ask again'), findsOneWidget);

    await tester.pumpWidget(
      _buildAssistantHarness(
        baseline.copyWith(followUps: const ['Try another angle']),
        showFollowUps: true,
      ),
    );
    await tester.pump();

    expect(find.byType(SizeTransition), findsNothing);
    expect(find.byType(FollowUpSuggestionBar), findsOneWidget);
    expect(find.text('Ask again'), findsNothing);
    expect(find.text('Try another angle'), findsOneWidget);
  });

  testWidgets(
    'response-done metadata shows footer actions while keeping follow-ups busy',
    (tester) async {
      final message = ChatMessage(
        id: 'assistant-response-done',
        role: 'assistant',
        content: 'Visible response body',
        timestamp: DateTime(2024, 1, 1),
        isStreaming: true,
        metadata: const {'responseDone': true},
        followUps: const ['Ask again'],
      );

      await tester.pumpWidget(
        _buildAssistantHarness(message, isStreaming: true, showFollowUps: true),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.content_copy), findsOneWidget);
      expect(find.byIcon(Icons.refresh), findsOneWidget);
      expect(find.byType(FollowUpSuggestionBar), findsOneWidget);
      expect(find.text('Ask again'), findsOneWidget);
      expect(
        tester
            .widget<FollowUpSuggestionBar>(find.byType(FollowUpSuggestionBar))
            .isBusy,
        isTrue,
      );
    },
  );

  testWidgets(
    'response-done metadata keeps copy disabled until streaming fully settles',
    (tester) async {
      var copyTapCount = 0;
      final message = ChatMessage(
        id: 'assistant-response-done-copy',
        role: 'assistant',
        content: 'Visible response body',
        timestamp: DateTime(2024, 1, 1),
        isStreaming: true,
        metadata: const {'responseDone': true},
      );

      await tester.pumpWidget(
        _buildAssistantHarness(
          message,
          isStreaming: true,
          onCopy: () => copyTapCount += 1,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.content_copy), findsOneWidget);

      await tester.tap(find.byIcon(Icons.content_copy));
      await tester.pump();

      expect(copyTapCount, 0);
    },
  );

  testWidgets(
    'response-done metadata renders long plain content with final body mode',
    (tester) async {
      final message = ChatMessage(
        id: 'assistant-response-done-body',
        role: 'assistant',
        content: List<String>.generate(13, (index) => 'Line $index').join('\n'),
        timestamp: DateTime(2024, 1, 1),
        isStreaming: true,
        metadata: const {'responseDone': true},
      );

      await tester.pumpWidget(
        _buildAssistantHarness(message, isStreaming: true),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('assistant-streaming-plain-text')),
        findsNothing,
      );
      expect(find.byType(SelectionArea), findsOneWidget);
    },
  );

  testWidgets(
    'response-done metadata passes final body mode to custom builders',
    (tester) async {
      final message = ChatMessage(
        id: 'assistant-response-done-builder',
        role: 'assistant',
        content: 'Visible response body',
        timestamp: DateTime(2024, 1, 1),
        isStreaming: true,
        metadata: const {'responseDone': true},
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            textToSpeechControllerProvider.overrideWith(
              _TestTextToSpeechController.new,
            ),
            assistantResponseBuilderProvider.overrideWith(
              (ref) => (context, response) {
                return Text('builder-streaming:${response.isStreaming}');
              },
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: AssistantMessageWidget(
                message: message,
                isStreaming: true,
                showFollowUps: false,
                animateOnMount: false,
                modelName: message.model,
                onCopy: () {},
                onRegenerate: () {},
                onDelete: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('builder-streaming:false'), findsOneWidget);
    },
  );

  testWidgets(
    'response-done metadata keeps tts disabled until streaming fully settles',
    (tester) async {
      var ttsToggleCount = 0;
      final message = ChatMessage(
        id: 'assistant-response-done-tts',
        role: 'assistant',
        content: 'Visible response body',
        timestamp: DateTime(2024, 1, 1),
        isStreaming: true,
        metadata: const {'responseDone': true},
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            textToSpeechControllerProvider.overrideWith(
              () => _RecordingTextToSpeechController(() => ttsToggleCount += 1),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: AssistantMessageWidget(
                message: message,
                isStreaming: true,
                showFollowUps: false,
                animateOnMount: false,
                modelName: message.model,
                onCopy: () {},
                onRegenerate: () {},
                onDelete: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.volume_up), findsOneWidget);

      await tester.tap(find.byIcon(Icons.volume_up));
      await tester.pump();

      expect(ttsToggleCount, 0);
    },
  );

  testWidgets('response-done metadata re-enables attachment animations', (
    tester,
  ) async {
    final message = ChatMessage(
      id: 'assistant-response-done-attachment',
      role: 'assistant',
      content: '',
      timestamp: DateTime(2024, 1, 1),
      isStreaming: true,
      metadata: const {'responseDone': true},
      attachmentIds: const ['attachment-1'],
    );

    await tester.pumpWidget(_buildAssistantHarness(message, isStreaming: true));
    await tester.pumpAndSettle();

    expect(find.byType(EnhancedAttachment), findsOneWidget);
    expect(
      tester
          .widget<EnhancedAttachment>(find.byType(EnhancedAttachment))
          .disableAnimation,
      isFalse,
    );
  });

  testWidgets(
    'response-done metadata keeps regenerate disabled until streaming fully settles',
    (tester) async {
      var regenerateTapCount = 0;
      final message = ChatMessage(
        id: 'assistant-response-done-regenerate',
        role: 'assistant',
        content: 'Visible response body',
        timestamp: DateTime(2024, 1, 1),
        isStreaming: true,
        metadata: const {'responseDone': true},
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            textToSpeechControllerProvider.overrideWith(
              _TestTextToSpeechController.new,
            ),
            isChatStreamingProvider.overrideWith((ref) => true),
          ],
          child: MaterialApp(
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: AssistantMessageWidget(
                message: message,
                isStreaming: true,
                showFollowUps: false,
                animateOnMount: false,
                modelName: message.model,
                onCopy: () {},
                onRegenerate: () => regenerateTapCount += 1,
                onDelete: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.refresh), findsOneWidget);

      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pump();

      expect(regenerateTapCount, 0);
    },
  );
}
