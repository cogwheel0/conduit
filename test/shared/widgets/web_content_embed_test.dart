import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/web_content_embed.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _buildHarness({
  required String source,
  bool fillAvailableHeight = false,
  VoidCallback? onControllerReset,
}) {
  return MaterialApp(
    theme: AppTheme.light(TweakcnThemes.t3Chat),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: WebContentEmbed(
        source: source,
        deferUntilExpanded: true,
        initiallyExpanded: false,
        fillAvailableHeight: fillAvailableHeight,
        debugTreatAsSupported: true,
        debugSeedControllerForTesting: true,
        debugOnControllerReset: onControllerReset,
      ),
    ),
  );
}

void main() {
  test('wraps inline HTML in a sandboxed iframe', () {
    final document = WebContentEmbed.debugWrapHtmlDocument(
      '<div>chart</div><script>renderChart()</script>',
    );

    expect(document, contains('sandbox="allow-scripts allow-forms"'));
    expect(document, contains('referrerpolicy="no-referrer"'));
    expect(document, contains('srcdoc="'));
    expect(document, contains('&lt;script&gt;renderChart()&lt;/script&gt;'));
    expect(document, isNot(contains('<script>renderChart()</script>')));
  });

  test('escapes injected arguments before adding them to sandbox HTML', () {
    final document = WebContentEmbed.debugWrapHtmlDocument(
      '<html><head><title>embed</title></head><body></body></html>',
      argsText: '</script><script>steal()</script>',
    );

    expect(
      document,
      contains(
        r'window.args = &quot;\u003C/script\u003E\u003Cscript\u003Esteal()\u003C/script\u003E&quot;;',
      ),
    );
    expect(document, isNot(contains('</script><script>steal()</script>')));
  });

  test('full-height documents ignore sandbox resize messages', () {
    final document = WebContentEmbed.debugWrapHtmlDocument(
      '<div>chart</div>',
      fillAvailableHeight: true,
    );

    expect(document, contains('height: 100vh'));
    expect(document, contains('const fillAvailableHeight = true;'));
    expect(document, contains('if (fillAvailableHeight) return;'));
  });

  test('intrinsic-height documents retain sandbox resize handling', () {
    final document = WebContentEmbed.debugWrapHtmlDocument('<div>chart</div>');

    expect(document, contains('height: 360.0px'));
    expect(document, contains('const fillAvailableHeight = false;'));
    expect(document, contains(r'frame.style.height = `${clamped}px`;'));
  });

  testWidgets('collapsed source changes clear stale controllers', (
    tester,
  ) async {
    var resetCount = 0;

    await tester.pumpWidget(
      _buildHarness(
        source: '<div>first</div>',
        onControllerReset: () => resetCount += 1,
      ),
    );
    await tester.pump();

    expect(resetCount, 0);

    await tester.pumpWidget(
      _buildHarness(
        source: '<div>second</div>',
        onControllerReset: () => resetCount += 1,
      ),
    );
    await tester.pump();

    expect(resetCount, 1);
  });

  testWidgets('enabling full height clears the existing controller', (
    tester,
  ) async {
    var resetCount = 0;

    await tester.pumpWidget(
      _buildHarness(
        source: '<div>chart</div>',
        onControllerReset: () => resetCount += 1,
      ),
    );
    await tester.pump();

    await tester.pumpWidget(
      _buildHarness(
        source: '<div>chart</div>',
        fillAvailableHeight: true,
        onControllerReset: () => resetCount += 1,
      ),
    );
    await tester.pump();

    expect(resetCount, 1);
  });

  testWidgets('disabling full height clears the existing controller', (
    tester,
  ) async {
    var resetCount = 0;

    await tester.pumpWidget(
      _buildHarness(
        source: '<div>chart</div>',
        fillAvailableHeight: true,
        onControllerReset: () => resetCount += 1,
      ),
    );
    await tester.pump();

    await tester.pumpWidget(
      _buildHarness(
        source: '<div>chart</div>',
        onControllerReset: () => resetCount += 1,
      ),
    );
    await tester.pump();

    expect(resetCount, 1);
  });
}
