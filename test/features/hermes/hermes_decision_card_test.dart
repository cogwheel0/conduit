import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/features/hermes/models/hermes_run_event.dart';
import 'package:conduit/features/hermes/services/hermes_run_transport.dart';
import 'package:conduit/features/hermes/widgets/hermes_decision_card.dart';
import 'package:conduit/features/hermes/widgets/hermes_message_interactions.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _DecisionConversation extends ActiveConversationNotifier {
  @override
  Conversation? build() => Conversation(
    id: 'conversation',
    title: 'Conversation',
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
    metadata: const {'hermesSessionId': 'session'},
  );
}

void main() {
  test('selects the newest unresolved Hermes composer prompt', () {
    final approval = ChatMessage(
      id: 'approval',
      role: 'assistant',
      content: '',
      timestamp: DateTime(2026),
      metadata: const {
        'transport': kHermesTransport,
        kHermesApprovalMeta: {'state': 'resolving'},
      },
    );
    final decision = ChatMessage(
      id: 'decision',
      role: 'assistant',
      content: '',
      timestamp: DateTime(2026),
      metadata: {
        'transport': kHermesTransport,
        kHermesDecisionMeta: {
          'state': 'pending',
          'expiresAt': DateTime.now()
              .add(const Duration(hours: 1))
              .toUtc()
              .toIso8601String(),
        },
      },
    );

    expect(
      findPendingHermesComposerPrompt([approval, decision]),
      same(decision),
    );
  });

  test('ignores resolved and expired Hermes prompts', () {
    ChatMessage message(String id, Map<String, dynamic> metadata) =>
        ChatMessage(
          id: id,
          role: 'assistant',
          content: '',
          timestamp: DateTime(2026),
          metadata: {'transport': kHermesTransport, ...metadata},
        );

    expect(
      findPendingHermesComposerPrompt([
        message('approval', const {
          kHermesApprovalMeta: {'state': 'approved'},
        }),
        message('decision', {
          kHermesDecisionMeta: {
            'state': 'pending',
            'expiresAt': DateTime.now()
                .subtract(const Duration(minutes: 1))
                .toUtc()
                .toIso8601String(),
          },
        }),
      ]),
      isNull,
    );
  });

  testWidgets('a resolved approval cannot hide a pending decision', (
    tester,
  ) async {
    final message = ChatMessage(
      id: 'decision',
      role: 'assistant',
      content: '',
      timestamp: DateTime(2026),
      metadata: {
        'transport': kHermesTransport,
        kHermesApprovalMeta: const {'state': 'approved'},
        kHermesDecisionMeta: {
          'state': 'pending',
          'kind': HermesDecisionKind.clarification.name,
          'requestId': 'request',
          'runtimeId': 'runtime',
          'storedSessionId': 'session',
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
          activeConversationProvider.overrideWith(_DecisionConversation.new),
        ],
        child: CupertinoApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Theme(
            data: AppTheme.light(TweakcnThemes.t3Chat),
            child: HermesComposerPromptOverlay(message: message),
          ),
        ),
      ),
    );

    expect(find.text('Hermes needs clarification'), findsOneWidget);
    expect(find.text('Approved ✓'), findsNothing);
  });

  testWidgets('renders its response field in a Cupertino tree', (tester) async {
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Theme(
          data: AppTheme.light(TweakcnThemes.t3Chat),
          child: HermesDecisionCard(
            kind: HermesDecisionKind.clarification,
            onSubmit: (_) async => true,
          ),
        ),
      ),
    );

    expect(find.byType(TextField), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('MCP setup uses explicit setup and decline actions', (
    tester,
  ) async {
    final answers = <String>[];
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Theme(
          data: AppTheme.light(TweakcnThemes.t3Chat),
          child: HermesDecisionCard(
            kind: HermesDecisionKind.mcpSetup,
            mcpServer: 'github',
            mcpAction: 'authorize',
            onSubmit: (answer) async {
              answers.add(answer);
              return true;
            },
          ),
        ),
      ),
    );

    expect(find.byType(TextField), findsNothing);
    expect(find.text('authorize github'), findsOneWidget);
    await tester.tap(find.text('Set up'));
    await tester.pump();
    expect(answers, ['approve']);
  });

  testWidgets('keeps the answer when submission fails', (tester) async {
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Theme(
          data: AppTheme.light(TweakcnThemes.t3Chat),
          child: HermesDecisionCard(
            kind: HermesDecisionKind.clarification,
            onSubmit: (_) async => false,
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'keep this');
    await tester.tap(find.text('Send response'));
    await tester.pump();
    expect(find.text('keep this'), findsOneWidget);
  });

  testWidgets('submits the selected clarification choices', (tester) async {
    String? answer;
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Theme(
          data: AppTheme.light(TweakcnThemes.t3Chat),
          child: HermesDecisionCard(
            kind: HermesDecisionKind.clarification,
            choices: const ['alpha', 'beta'],
            multiSelect: true,
            onSubmit: (value) async {
              answer = value;
              return true;
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('alpha'));
    await tester.pump();
    await tester.tap(find.text('beta'));
    await tester.pump();
    await tester.tap(find.text('Send response'));
    await tester.pump();
    expect(answer, '["alpha","beta"]');
  });
}
