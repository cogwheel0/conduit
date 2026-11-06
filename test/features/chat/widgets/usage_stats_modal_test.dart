import 'package:conduit/features/chat/widgets/usage_stats_modal.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  Future<AppLocalizations> openSheet(
    WidgetTester tester,
    Map<String, dynamic> usage,
  ) async {
    late AppLocalizations l10n;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) {
              l10n = AppLocalizations.of(context)!;
              return TextButton(
                onPressed: () => UsageStatsModal.show(context, usage),
                child: const Text('open'),
              );
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return l10n;
  }

  testWidgets('usage Open WebUI marks incomplete says the figures may be low', (
    tester,
  ) async {
    final l10n = await openSheet(tester, <String, dynamic>{
      'input_tokens': 1500,
      'output_tokens': 120,
      'incomplete': true,
    });

    expect(find.text(l10n.usageTokenCount(120)), findsOneWidget);
    expect(find.text(l10n.usageIncomplete), findsOneWidget);
  });

  testWidgets('complete usage carries no such note', (tester) async {
    final l10n = await openSheet(tester, <String, dynamic>{
      'input_tokens': 1500,
      'output_tokens': 120,
    });

    expect(find.text(l10n.usageTokenCount(120)), findsOneWidget);
    expect(find.text(l10n.usageIncomplete), findsNothing);
  });

  test('the native sheet text carries the note too', () async {
    final l10n = await AppLocalizations.delegate.load(const Locale('de'));
    final partial = UsageStatsModal.buildUsageSummaryText(<String, dynamic>{
      'output_tokens': 120,
      'incomplete': true,
    }, l10n);
    expect(partial, endsWith(l10n.usageIncomplete));
    expect(
      UsageStatsModal.buildUsageSummaryText(<String, dynamic>{
        'output_tokens': 120,
      }, l10n),
      isNot(contains(l10n.usageIncomplete)),
    );
  });
}
