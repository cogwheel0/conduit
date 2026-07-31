import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/web_content_embed.dart';
import 'package:checks/checks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html_unescape/html_unescape.dart';
import 'package:mocktail/mocktail.dart';

abstract interface class _ExternalLinkLauncher {
  Future<bool> call(String url);
}

class _MockExternalLinkLauncher extends Mock implements _ExternalLinkLauncher {}

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

    check(
      document,
    ).contains('sandbox="allow-scripts allow-forms allow-popups"');
    check(document).contains('referrerpolicy="no-referrer"');
    check(document).contains('srcdoc="');
    check(document).contains('&lt;script&gt;renderChart()&lt;/script&gt;');
    check(document).not((it) => it.contains('<script>renderChart()</script>'));
  });

  test('allows popup links without granting same-origin access', () {
    final document = WebContentEmbed.debugWrapHtmlDocument(
      '<a href="https://example.com/story" target="_blank">Read more</a>',
    );
    final decodedDocument = HtmlUnescape().convert(document);

    check(decodedDocument).contains('target="_blank"');
    check(
      document,
    ).contains('sandbox="allow-scripts allow-forms allow-popups"');
    check(document).not((it) => it.contains('allow-same-origin'));
  });

  test('keeps remote tool URLs inside the sandboxed frame', () {
    final document = WebContentEmbed.debugWrapRemoteDocument(
      'https://example.com/widget?city=New%20York&units=metric',
    );

    check(document).contains(
      'src="https://example.com/widget?city=New%20York&amp;units=metric"',
    );
    check(
      document,
    ).contains('sandbox="allow-scripts allow-forms allow-popups"');
    check(document).contains('referrerpolicy="no-referrer"');
    check(document).not((it) => it.contains('allow-same-origin'));
    check(document).not((it) => it.contains('srcdoc="https://example.com'));
  });

  test('opens only user-activated external navigations', () {
    check(
      WebContentEmbed.debugShouldOpenNavigationExternally(
        targetUrl: 'https://example.com/story',
        currentUrl: 'https://embed.example.com/widget',
        userActivated: true,
      ),
    ).isTrue();
    check(
      WebContentEmbed.debugShouldOpenNavigationExternally(
        targetUrl: 'https://example.com/story',
        currentUrl: 'https://embed.example.com/widget',
        userActivated: false,
      ),
    ).isFalse();
    check(
      WebContentEmbed.debugShouldOpenNavigationExternally(
        targetUrl: 'https://embed.example.com/widget#forecast',
        currentUrl: 'https://embed.example.com/widget',
        userActivated: true,
      ),
    ).isFalse();
  });

  test('keeps inline document fragments inside the embed', () {
    check(
      WebContentEmbed.debugShouldAllowInlineFragmentNavigation(
        'about:srcdoc#forecast',
      ),
    ).isTrue();
    check(
      WebContentEmbed.debugShouldAllowInlineFragmentNavigation(
        'about:blank#forecast',
      ),
    ).isTrue();
    check(
      WebContentEmbed.debugShouldAllowInlineFragmentNavigation('about:srcdoc'),
    ).isFalse();
    check(
      WebContentEmbed.debugShouldAllowInlineFragmentNavigation(
        'javascript:#forecast',
      ),
    ).isFalse();
  });

  test(
    'requires positive activation evidence when gesture data is present',
    () {
      check(
        WebContentEmbed.debugHasUserActivationEvidence(
          hasGesture: true,
          linkActivated: false,
        ),
      ).isTrue();
      check(
        WebContentEmbed.debugHasUserActivationEvidence(
          hasGesture: false,
          linkActivated: true,
        ),
      ).isFalse();
      check(
        WebContentEmbed.debugHasUserActivationEvidence(
          hasGesture: null,
          linkActivated: true,
        ),
      ).isTrue();
      check(
        WebContentEmbed.debugHasUserActivationEvidence(
          hasGesture: null,
          linkActivated: false,
        ),
      ).isFalse();
    },
  );

  test('automatic embed navigation is limited to web redirects', () {
    check(
      WebContentEmbed.debugShouldAllowAutomaticNavigation(
        'https://example.com/redirect',
      ),
    ).isTrue();
    check(
      WebContentEmbed.debugShouldAllowAutomaticNavigation('about:blank'),
    ).isTrue();
    check(
      WebContentEmbed.debugShouldAllowAutomaticNavigation('about:srcdoc'),
    ).isTrue();
    check(
      WebContentEmbed.debugShouldAllowAutomaticNavigation(
        'mailto:reader@example.com',
      ),
    ).isFalse();
    check(
      WebContentEmbed.debugShouldAllowAutomaticNavigation(
        'javascript:alert(1)',
      ),
    ).isFalse();
  });

  test('popup handling does not depend on platform gesture metadata', () {
    check(
      WebContentEmbed.debugShouldHandleCreateWindow(
        requestIsCurrent: true,
        targetUrl: 'https://example.com/story',
      ),
    ).isTrue();
    check(
      WebContentEmbed.debugShouldHandleCreateWindow(
        requestIsCurrent: false,
        targetUrl: 'https://example.com/story',
      ),
    ).isFalse();
    check(
      WebContentEmbed.debugShouldHandleCreateWindow(
        requestIsCurrent: true,
        targetUrl: 'javascript:alert(1)',
      ),
    ).isFalse();
  });

  test('resolves platform-approved popups whose URL Android omits', () {
    check(
      WebContentEmbed.debugShouldResolveMissingPopupUrl(
        requestIsCurrent: true,
        targetUrl: null,
      ),
    ).isTrue();
    check(
      WebContentEmbed.debugShouldResolveMissingPopupUrl(
        requestIsCurrent: true,
        targetUrl: 'https://example.com/story',
      ),
    ).isFalse();
    check(
      WebContentEmbed.debugShouldResolveMissingPopupUrl(
        requestIsCurrent: false,
        targetUrl: null,
      ),
    ).isFalse();
  });

  test('rejects disallowed embed links before invoking the launcher', () async {
    final launcher = _MockExternalLinkLauncher();
    when(() => launcher(any())).thenAnswer((_) async => true);

    check(
      await WebContentEmbed.debugOpenExternalLink(
        'javascript:alert(1)',
        launcher: launcher.call,
      ),
    ).isFalse();
    verifyNever(() => launcher(any()));

    check(
      await WebContentEmbed.debugOpenExternalLink(
        'https://example.com/story',
        launcher: launcher.call,
      ),
    ).isTrue();
    verify(() => launcher('https://example.com/story')).called(1);
  });

  test('escapes injected arguments before adding them to sandbox HTML', () {
    final document = WebContentEmbed.debugWrapHtmlDocument(
      '<html><head><title>embed</title></head><body></body></html>',
      argsText: '</script><script>steal()</script>',
    );

    check(document).contains(
      r'window.args = &quot;\u003C/script\u003E\u003Cscript\u003Esteal()\u003C/script\u003E&quot;;',
    );
    check(
      document,
    ).not((it) => it.contains('</script><script>steal()</script>'));
  });

  test('full-height documents ignore sandbox resize messages', () {
    final document = WebContentEmbed.debugWrapHtmlDocument(
      '<div>chart</div>',
      fillAvailableHeight: true,
    );

    check(document).contains('height: 100vh');
    check(document).contains('const fillAvailableHeight = true;');
    check(document).contains('if (fillAvailableHeight) return;');
  });

  test('intrinsic-height documents retain sandbox resize handling', () {
    final document = WebContentEmbed.debugWrapHtmlDocument('<div>chart</div>');

    check(document).contains('height: 360.0px');
    check(document).contains('const fillAvailableHeight = false;');
    check(document).contains(r'frame.style.height = `${clamped}px`;');
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
