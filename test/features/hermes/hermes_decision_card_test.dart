import 'package:conduit/features/hermes/models/hermes_run_event.dart';
import 'package:conduit/features/hermes/widgets/hermes_decision_card.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders its response field in a Cupertino tree', (tester) async {
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: const [DefaultMaterialLocalizations.delegate],
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
        localizationsDelegates: const [DefaultMaterialLocalizations.delegate],
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
        localizationsDelegates: const [DefaultMaterialLocalizations.delegate],
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
        localizationsDelegates: const [DefaultMaterialLocalizations.delegate],
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
    await tester.tap(find.text('beta'));
    await tester.tap(find.text('Send response'));
    await tester.pump();
    expect(answer, '["alpha","beta"]');
  });
}
