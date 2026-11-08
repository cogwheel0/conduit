import 'package:conduit/features/hermes/widgets/hermes_clarify_form_card.dart';
import 'package:conduit/features/hermes/widgets/hermes_message_interactions.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_clarify_form.dart';
import 'package:conduit_core/features/hermes/models/hermes_run_event.dart';
import 'package:conduit_core/features/hermes/services/hermes_run_transport.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

final _questions = hermesClarifyQuestions(const [
  {
    'qid': 'q0',
    'question': 'Which colour?',
    'choices': ['Teal (Recommended)', 'Amber'],
  },
  {
    'qid': 'q1',
    'question': 'Which sizes?',
    'choices': ['Small', 'Large'],
    'multi_select': true,
  },
  {'qid': 'q2', 'question': 'Anything else?'},
]);

Widget _app(Widget child) => CupertinoApp(
  localizationsDelegates: conduitLocalizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Theme(
    data: AppTheme.light(TweakcnThemes.t3Chat),
    child: SingleChildScrollView(child: child),
  ),
);

Finder _submit() => find.byKey(const ValueKey('hermes-clarify-submit'));

class _ActiveConversation extends ActiveConversationNotifier {
  @override
  Conversation? build() => Conversation(
    id: 'conversation',
    title: 'Conversation',
    createdAt: DateTime(2030),
    updatedAt: DateTime(2030),
    metadata: const {'hermesSessionId': 'session'},
  );
}

class _Messages extends ChatMessagesNotifier {
  @override
  List<ChatMessage> build() => const [];
}

void main() {
  testWidgets('answers every question with one submit', (tester) async {
    Map<String, String?>? sent;
    await tester.pumpWidget(
      _app(
        HermesClarifyFormCard(
          questions: _questions,
          onSubmit: (answers) async {
            sent = answers;
            return true;
          },
        ),
      ),
    );

    expect(find.text('1. Which colour?'), findsOneWidget);
    expect(find.text('2. Which sizes?'), findsOneWidget);
    expect(find.text('3. Anything else?'), findsOneWidget);
    expect(find.text('0 of 3 done'), findsOneWidget);
    // The recommendation is a badge; the choice itself is bare.
    expect(find.textContaining('Recommended'), findsOneWidget);
    expect(find.textContaining('(Recommended)'), findsNothing);
    expect(find.text('Answer or skip each question.'), findsOneWidget);

    for (final choice in [find.textContaining('Teal'), find.text('Small')]) {
      await tester.tap(choice);
      await tester.pump();
    }
    // A long form scrolls inside the card.
    await tester.ensureVisible(find.text('Large'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Large'));
    await tester.pump();
    expect(find.text('2 of 3 done'), findsOneWidget);

    // Not every question is settled yet: the button does nothing.
    await tester.tap(_submit(), warnIfMissed: false);
    await tester.pump();
    expect(sent, isNull);

    final skip = find.byKey(const ValueKey('hermes-clarify-q2-skip'));
    await tester.ensureVisible(skip);
    await tester.pumpAndSettle();
    await tester.tap(skip);
    await tester.pump();
    expect(find.text('3 of 3 done'), findsOneWidget);
    expect(find.text('Answer or skip each question.'), findsNothing);

    await tester.tap(_submit());
    await tester.pumpAndSettle();
    expect(sent, {'q0': 'Teal', 'q1': '["Small","Large"]', 'q2': null});
    expect(find.text('Response sent'), findsOneWidget);
  });

  testWidgets('typed words replace a picked single choice', (tester) async {
    Map<String, String?>? sent;
    await tester.pumpWidget(
      _app(
        HermesClarifyFormCard(
          questions: [_questions.first],
          onSubmit: (answers) async {
            sent = answers;
            return true;
          },
        ),
      ),
    );

    // A lone question has no number and no counter.
    expect(find.text('Which colour?'), findsOneWidget);
    expect(find.textContaining(' done'), findsNothing);
    await tester.tap(find.text('Amber'));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('hermes-clarify-q0-text')),
      'Violet',
    );
    await tester.pump();
    await tester.tap(_submit());
    await tester.pumpAndSettle();
    expect(sent, {'q0': 'Violet'});
  });

  testWidgets('shows answers locked elsewhere and leaves them out', (
    tester,
  ) async {
    Map<String, String?>? sent;
    await tester.pumpWidget(
      _app(
        HermesClarifyFormCard(
          questions: hermesClarifyQuestions(
            const [
              {'qid': 'q0', 'question': 'First?'},
              {
                'qid': 'q1',
                'question': 'Which sizes?',
                'choices': ['Small', 'Large'],
                'multi_select': true,
              },
              {'qid': 'q2', 'question': 'Third?'},
            ],
            answers: const {'q1': '["Small","Large"]', 'q2': null},
          ),
          onSubmit: (answers) async {
            sent = answers;
            return true;
          },
        ),
      ),
    );

    expect(find.text('Small, Large'), findsOneWidget);
    expect(find.text('Skipped'), findsOneWidget);
    expect(find.text('2 of 3 done'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('hermes-clarify-q1-skip')),
      findsNothing,
    );

    await tester.enterText(
      find.byKey(const ValueKey('hermes-clarify-q0-text')),
      'Yes',
    );
    await tester.pump();
    await tester.tap(_submit());
    await tester.pumpAndSettle();
    expect(sent, {'q0': 'Yes'});
  });

  testWidgets('keeps the answers and says so when sending fails', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      _app(
        HermesClarifyFormCard(
          questions: [_questions.last],
          onSubmit: (_) async {
            attempts++;
            return false;
          },
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('hermes-clarify-q2-text')),
      'keep this',
    );
    await tester.pump();
    await tester.tap(_submit());
    await tester.pumpAndSettle();

    expect(attempts, 1);
    expect(find.text("Couldn't send your answers. Try again."), findsOneWidget);
    expect(find.text('keep this'), findsOneWidget);
    expect(find.text('Response sent'), findsNothing);
  });

  testWidgets('a pending question form shows above the composer', (
    tester,
  ) async {
    final message = ChatMessage(
      id: 'decision',
      role: 'assistant',
      content: '',
      timestamp: DateTime(2030),
      metadata: {
        'transport': kHermesTransport,
        kHermesDecisionMeta: {
          'state': 'pending',
          'kind': HermesDecisionKind.clarification.name,
          'requestId': 'srq-f1',
          'runtimeId': 'runtime',
          'storedSessionId': 'session',
          'prompt': 'Which colour?',
          'questions': [for (final q in _questions) q.toJson()],
          'expiresAt': DateTime.now()
              .add(const Duration(hours: 1))
              .toUtc()
              .toIso8601String(),
        },
      },
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeConversationProvider.overrideWith(_ActiveConversation.new),
          chatMessagesProvider.overrideWith(_Messages.new),
        ],
        child: _app(HermesComposerPromptOverlay(message: message)),
      ),
    );

    expect(find.byType(HermesClarifyFormCard), findsOneWidget);
    expect(find.text('3. Anything else?'), findsOneWidget);
  });

  // A REST run started without a session (its creation failed) still asks
  // its questions; the answer names the run, the prompt and generation.
  testWidgets('a REST run question without a session still shows', (
    tester,
  ) async {
    final message = ChatMessage(
      id: 'run-question',
      role: 'assistant',
      content: '',
      timestamp: DateTime(2030),
      metadata: {
        'transport': kHermesTransport,
        kHermesDecisionMeta: {
          'state': 'pending',
          'kind': HermesDecisionKind.clarification.name,
          'requestId': 'prompt-1',
          'runtimeId': 'run-1',
          'executionGeneration': 3,
          'prompt': 'Which colour?',
          'questions': [_questions.first.toJson()],
          'expiresAt': DateTime.now()
              .add(const Duration(hours: 1))
              .toUtc()
              .toIso8601String(),
        },
      },
    );
    expect(findPendingHermesComposerPrompt([message]), same(message));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeConversationProvider.overrideWith(_ActiveConversation.new),
          chatMessagesProvider.overrideWith(_Messages.new),
        ],
        child: _app(HermesComposerPromptOverlay(message: message)),
      ),
    );

    expect(find.byType(HermesClarifyFormCard), findsOneWidget);
    expect(find.text('Which colour?'), findsOneWidget);
  });

  testWidgets('a long form keeps to the space above the keyboard', (
    tester,
  ) async {
    final questions = hermesClarifyQuestions([
      for (var q = 0; q < kMaxHermesClarifyQuestions; q++)
        {
          'qid': 'q$q',
          'question': 'Synthetic question $q?',
          'choices': ['First', 'Second'],
        },
    ]);
    await tester.pumpWidget(
      _app(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(400, 800),
            viewInsets: EdgeInsets.only(bottom: 400),
          ),
          child: HermesClarifyFormCard(
            questions: questions,
            onSubmit: (_) async => true,
          ),
        ),
      ),
    );

    final scroll = find.descendant(
      of: find.byType(HermesClarifyFormCard),
      matching: find.byType(SingleChildScrollView),
    );
    // Its share of the 400 points above the keyboard, not of the screen.
    expect(tester.getSize(scroll.first).height, lessThanOrEqualTo(180));
  });
}
