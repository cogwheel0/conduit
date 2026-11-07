import 'package:conduit/features/hermes/widgets/hermes_approval_card.dart';
import 'package:conduit/features/hermes/widgets/hermes_approval_cost_chip.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/features/hermes/models/hermes_approval_cost.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _overLimit =
    "MCP tool 'render' on UNTRUSTED server 'mesh-studio' wants to run. "
    "This call goes past the chat's spend limit. Costs about 5 credits. "
    "This chat has used about 48 credits on 'mesh-studio' (limit 50). "
    'This tool is write-capable (no readOnlyHint=true annotation) and may '
    'modify external state.';

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.light(TweakcnThemes.t3Chat),
  localizationsDelegates: conduitLocalizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

void main() {
  testWidgets('a paid call shows its price, spend and limit warning', (
    tester,
  ) async {
    final shown = hermesApprovalPresentation(_overLimit, null);
    final picked = <String>[];
    await tester.pumpWidget(
      _app(
        HermesApprovalCard(
          state: HermesApprovalState.pending,
          summary: shown.summary,
          cost: shown.cost,
          // A stale card offering more is still held to once or deny.
          choices: const ['once', 'session', 'always', 'deny'],
          onChoice: picked.add,
          onDecision: (_) {},
        ),
      ),
    );

    expect(find.text('≈ 5 credits'), findsOneWidget);
    expect(find.text('Used 48 credits of 50 · mesh-studio'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('hermes-approval-over-limit')),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Estimated cost: 5 credits'), findsOneWidget);
    // The sentences shown as chips leave the text; the rest stays.
    expect(find.textContaining('Costs about'), findsNothing);
    expect(find.textContaining('wants to run.'), findsOneWidget);
    expect(find.text('Allow once'), findsOneWidget);
    expect(find.text('Deny'), findsOneWidget);
    expect(find.text('Allow for session'), findsNothing);
    expect(find.text('Always allow'), findsNothing);

    await tester.tap(find.text('Allow once'));
    expect(picked, ['once']);
  });

  testWidgets('a REST card shows the price its run kept', (tester) async {
    final shown = hermesApprovalPresentation(
      "Server 'mesh-studio' is configured 'trust: untrusted'.",
      const HermesApprovalCost(
        cost: '2–5 credits',
        note: 'per image',
        limit: '50 credits',
        server: 'mesh-studio',
      ).toJson(),
    );
    await tester.pumpWidget(
      _app(
        HermesApprovalCard(
          state: HermesApprovalState.pending,
          summary: shown.summary,
          cost: shown.cost,
          onDecision: (_) {},
        ),
      ),
    );

    expect(find.text('2–5 credits · per image'), findsOneWidget);
    expect(find.text('Limit 50 credits · mesh-studio'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('hermes-approval-over-limit')),
      findsNothing,
    );
    expect(find.textContaining('trust: untrusted'), findsOneWidget);
  });

  testWidgets('an ordinary approval shows no chips', (tester) async {
    final shown = hermesApprovalPresentation('rm -rf build', null);
    await tester.pumpWidget(
      _app(
        HermesApprovalCard(
          state: HermesApprovalState.pending,
          summary: shown.summary,
          cost: shown.cost,
          onDecision: (_) {},
        ),
      ),
    );

    expect(find.text('rm -rf build'), findsOneWidget);
    expect(find.byKey(const ValueKey('hermes-approval-cost')), findsNothing);
    expect(find.byKey(const ValueKey('hermes-approval-spend')), findsNothing);
  });
}
