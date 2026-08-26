import 'package:checks/checks.dart';
import 'package:conduit/features/hermes/widgets/hermes_approval_card.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('both approval actions show progress while resolving', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: HermesApprovalCard(
              state: HermesApprovalState.resolving,
              onDecision: (_) {},
            ),
          ),
        ),
      ),
    );

    final buttons = tester
        .widgetList<ConduitButton>(find.byType(ConduitButton))
        .toList();
    check(buttons).has((items) => items.length, 'length').equals(2);
    check(buttons.every((button) => button.isLoading)).isTrue();
    check(buttons.every((button) => button.onPressed == null)).isTrue();
  });

  testWidgets('sends an advertised approval scope', (tester) async {
    String? choice;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: HermesApprovalCard(
              state: HermesApprovalState.pending,
              choices: const ['once', 'session', 'always', 'deny'],
              onChoice: (value) => choice = value,
              onDecision: (_) {},
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Allow for session'));
    expect(choice, 'session');
  });

  testWidgets('renders in the shared Cupertino composer surface', (
    tester,
  ) async {
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Theme(
          data: AppTheme.light(TweakcnThemes.t3Chat),
          child: HermesApprovalCard(
            state: HermesApprovalState.pending,
            onDecision: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Approval required'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
