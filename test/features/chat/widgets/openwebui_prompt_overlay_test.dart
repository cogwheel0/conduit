import 'package:conduit/core/models/openwebui_chat_prompt.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/chat/widgets/modern_chat_input.dart';
import 'package:conduit/features/chat/widgets/openwebui_prompt_overlay.dart';
import 'package:conduit/features/hermes/models/hermes_capabilities.dart';
import 'package:conduit/features/hermes/models/hermes_model.dart';
import 'package:conduit/features/hermes/providers/hermes_providers.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('collects multiple questions and a free-form answer', (
    tester,
  ) async {
    Map<String, dynamic>? submitted;
    await _pump(
      tester,
      OpenWebUiPromptOverlay(
        prompt: _askPrompt,
        onAnswer: (answers) => submitted = answers,
        onDecision: (_) {},
      ),
    );

    await tester.tap(find.byKey(const ValueKey('openwebui-option-scope-0')));
    await tester.pump();
    await tester.tap(find.text('Next'));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('openwebui-other-detail')),
      'Only files',
    );
    await tester.pump();
    await tester.tap(find.text('Submit'));
    await tester.pump();

    expect(submitted, {
      'scope': {
        'type': 'option',
        'option_index': 0,
        'label': 'This chat',
        'description': 'Use this chat only',
      },
      'detail': {'type': 'other', 'text': 'Only files'},
    });
  });

  testWidgets('keeps a failed approval visible with an inline error', (
    tester,
  ) async {
    await _pump(
      tester,
      OpenWebUiPromptOverlay(
        prompt: const OpenWebUiComposerPrompt(
          identity: 'tool:1',
          kind: OpenWebUiComposerPromptKind.toolApproval,
          title: 'filesystem',
          message: '<script>alert(1)</script>',
        ),
        onDecision: (_) => throw StateError('server rejected request'),
      ),
    );

    expect(find.text('<script>alert(1)</script>'), findsOneWidget);
    await tester.tap(find.text('Approve'));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('openwebui-prompt-overlay')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('openwebui-prompt-error')),
      findsOneWidget,
    );
  });

  testWidgets('announces the current question and fraction', (tester) async {
    await _pump(
      tester,
      OpenWebUiPromptOverlay(
        prompt: _askPrompt,
        onAnswer: (_) {},
        onDecision: (_) {},
      ),
    );

    final overlay = tester.getSemantics(
      find.byKey(const ValueKey('openwebui-prompt-overlay')),
    );
    expect(overlay.label, contains('Scope'));
    expect(overlay.label, isNot(contains('Approval required')));
    final progressLabel = tester.getSemantics(find.text('1/2')).label;
    expect(progressLabel, contains('1/2'));
    expect(progressLabel, isNot(contains('1 of 2')));
  });

  testWidgets('attached overlay renders above the composer shell', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          selectedModelProvider.overrideWithValue(hermesSyntheticModel()),
          isChatStreamingProvider.overrideWithValue(false),
          hermesCapabilitiesProvider.overrideWith(
            (_) => Future.value(const HermesCapabilities()),
          ),
          apiServiceProvider.overrideWithValue(null),
          webSearchAvailableProvider.overrideWithValue(false),
          imageGenerationAvailableProvider.overrideWithValue(false),
        ],
        child: MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ModernChatInput(
              onSendMessage: (_) {},
              attachedOverlay: const Text(
                'Attached approval',
                key: ValueKey('attached-approval'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final overlayTop = tester
        .getTopLeft(find.byKey(const ValueKey('attached-approval')))
        .dy;
    final composerTop = tester
        .getTopLeft(find.byKey(const ValueKey('composer-native-shell')))
        .dy;
    expect(overlayTop, lessThan(composerTop));
  });

  testWidgets('remains usable with large accessibility text', (tester) async {
    await _pump(
      tester,
      OpenWebUiPromptOverlay(
        prompt: _askPrompt,
        onAnswer: (_) {},
        onDecision: (_) {},
      ),
      textScaler: const TextScaler.linear(2.5),
    );

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('openwebui-prompt-overlay')),
      findsOneWidget,
    );
  });
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: conduitLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
        child: child!,
      ),
      home: Scaffold(
        body: Center(child: SizedBox(width: 420, child: child)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

const _askPrompt = OpenWebUiComposerPrompt(
  identity: 'ask:1',
  kind: OpenWebUiComposerPromptKind.askUser,
  questions: [
    OpenWebUiPromptQuestion(
      id: 'scope',
      header: 'Scope',
      question: 'Which scope?',
      options: [
        OpenWebUiPromptOption(
          label: 'This chat',
          description: 'Use this chat only',
        ),
        OpenWebUiPromptOption(
          label: 'All chats',
          description: 'Use every chat',
        ),
      ],
      allowOther: false,
    ),
    OpenWebUiPromptQuestion(
      id: 'detail',
      header: 'Details',
      question: 'What should be included?',
      options: [
        OpenWebUiPromptOption(label: 'Files', description: 'Include files'),
        OpenWebUiPromptOption(label: 'Notes', description: 'Include notes'),
      ],
      allowOther: true,
    ),
  ],
);
