import 'package:checks/checks.dart';
import 'package:conduit/core/services/settings_service.dart';
import 'package:conduit/features/hermes/widgets/hermes_approval_card.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('both approval actions show progress while resolving', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [hapticEnabledProvider.overrideWithValue(false)],
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
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
}
