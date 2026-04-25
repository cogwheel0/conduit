import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/features/chat/providers/text_to_speech_provider.dart';
import 'package:conduit/features/chat/widgets/assistant_message_widget.dart';
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

Widget _buildHarness(Widget child) {
  return MaterialApp(
    theme: AppTheme.light(TweakcnThemes.t3Chat),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  );
}

Widget _buildAssistantHarness(ChatMessage message) {
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
          isStreaming: false,
          showFollowUps: false,
          animateOnMount: false,
          modelName: message.model,
          onCopy: () {},
          onRegenerate: () {},
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
    expect(find.byIcon(Icons.info_outline), findsOneWidget);
    expect(find.byIcon(Icons.chevron_left), findsNothing);
    expect(find.byIcon(Icons.chevron_right), findsNothing);
    expect(find.byIcon(Icons.more_horiz_rounded), findsOneWidget);

    final infoPosition = tester.getTopLeft(find.byIcon(Icons.info_outline));
    final sourcePosition = tester.getTopLeft(find.text('1 Source'));
    final versionPosition = tester.getTopLeft(find.text('2/2'));
    final overflowPosition = tester.getTopLeft(
      find.byIcon(Icons.more_horiz_rounded),
    );

    expect(sourcePosition.dx, greaterThan(infoPosition.dx));
    expect(versionPosition.dx, greaterThan(sourcePosition.dx));
    expect(overflowPosition.dx, greaterThan(sourcePosition.dx));
    expect(overflowPosition.dx, greaterThan(versionPosition.dx));

    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await tester.pumpAndSettle();

    expect(find.text('Prev'), findsOneWidget);
    expect(find.text('Next'), findsOneWidget);
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
}
