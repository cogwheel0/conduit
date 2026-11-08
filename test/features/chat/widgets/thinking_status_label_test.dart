import 'package:conduit/features/chat/widgets/thinking_status_label.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Widget _harness(Widget child, {bool disableAnimations = false}) {
  return MaterialApp(
    theme: AppTheme.light(TweakcnThemes.t3Chat),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: Scaffold(body: Center(child: child)),
    ),
  );
}

String _elapsedText(WidgetTester tester) {
  final texts = tester
      .widgetList<Text>(find.byType(Text))
      .map((text) => text.data ?? '')
      .where((data) => data != 'Thinking…')
      .toList();
  return texts.join();
}

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  test('formats the wait in short tabular units', () {
    expect(formatThinkingElapsed(l10n, 4), '4s');
    expect(formatThinkingElapsed(l10n, 59), '59s');
    expect(formatThinkingElapsed(l10n, 65), '1m 05s');
    expect(formatThinkingElapsed(l10n, 600), '10m 00s');
  });

  testWidgets('shows the elapsed time only after the first second', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(ThinkingStatusLabel(startedAt: DateTime.now())),
    );
    expect(find.text('Thinking…'), findsOneWidget);
    expect(_elapsedText(tester), isEmpty);

    // The clock is wall time; widget-test time is fake, so move the start.
    await tester.pumpWidget(
      _harness(
        ThinkingStatusLabel(
          startedAt: DateTime.now().subtract(const Duration(seconds: 3)),
        ),
      ),
    );
    await tester.pump();
    expect(_elapsedText(tester), '3s');
    final elapsed = tester.widget<Text>(find.text('3s'));
    expect(
      elapsed.style?.fontFeatures,
      contains(const FontFeature.tabularFigures()),
    );
  });

  testWidgets('sweeps in discrete steps, then rests', (tester) async {
    await tester.pumpWidget(
      _harness(ThinkingStatusLabel(startedAt: DateTime.now())),
    );
    expect(find.byType(ShaderMask), findsNothing);

    await tester.pump(ThinkingStatusLabel.restDuration);
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byType(ShaderMask), findsOneWidget);

    await tester.pump(ThinkingStatusLabel.sweepDuration);
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byType(ShaderMask), findsNothing);
  });

  testWidgets('stays still under Reduce Motion', (tester) async {
    await tester.pumpWidget(
      _harness(
        ThinkingStatusLabel(startedAt: DateTime.now(), animate: false),
        disableAnimations: true,
      ),
    );
    await tester.pump(ThinkingStatusLabel.restDuration * 3);
    expect(find.byType(ShaderMask), findsNothing);
  });

  testWidgets('pauses while the route is hidden', (tester) async {
    await tester.pumpWidget(
      _harness(
        TickerMode(
          enabled: false,
          child: ThinkingStatusLabel(startedAt: DateTime.now()),
        ),
      ),
    );
    await tester.pump(ThinkingStatusLabel.restDuration * 3);
    expect(find.byType(ShaderMask), findsNothing);
  });

  testWidgets('reads as one "Thinking…" element to VoiceOver', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _harness(
        ThinkingStatusLabel(
          startedAt: DateTime.now().subtract(const Duration(seconds: 5)),
        ),
      ),
    );
    await tester.pump();
    expect(find.bySemanticsLabel('Thinking…'), findsOneWidget);
    expect(find.bySemanticsLabel('5s'), findsNothing);
    handle.dispose();
  });
}
