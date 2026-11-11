import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/legacy_design_compatibility.dart';
import 'package:conduit/shared/widgets/markdown/citation_badge.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _popoverChannel = MethodChannel('cn_popover');

const _tides = ChatSourceReference(
  title: 'Tide tables for small harbours',
  url: 'https://www.harbour.example/tides',
  snippet:
      '  High water at the north quay\n  comes forty minutes after the buoy. ',
);

class _Settings extends AppSettingsNotifier {
  @override
  AppSettings build() => const AppSettings();
}

void main() {
  late List<Map<Object?, Object?>> popovers;
  late String? popoverReply;
  late _BrowserPlatform browser;
  InAppWebViewPlatform? previousBrowser;

  setUp(() {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
    PlatformUiCapabilities.debugNativeIOS26Override = true;
    popovers = [];
    popoverReply = null;
    previousBrowser = InAppWebViewPlatform.instance;
    browser = _BrowserPlatform();
    InAppWebViewPlatform.instance = browser;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_popoverChannel, (call) async {
          if (call.method != 'show') return null;
          popovers.add(call.arguments as Map<Object?, Object?>);
          return popoverReply;
        });
  });

  tearDown(() {
    PlatformUiCapabilities.resetDebugOverrides();
    if (previousBrowser case final previous?) {
      InAppWebViewPlatform.instance = previous;
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_popoverChannel, null);
  });

  Future<void> host(WidgetTester tester, Widget badge) => tester.pumpWidget(
    ProviderScope(
      overrides: [appSettingsProvider.overrideWith(_Settings.new)],
      child: MaterialApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => LegacyDesignCompatibility(child: child!),
        home: Scaffold(body: Center(child: badge)),
      ),
    ),
  );

  Map<Object?, Object?> shownContent() =>
      popovers.single['content']! as Map<Object?, Object?>;

  testWidgets('a citation previews its source, and Open opens its link', (
    tester,
  ) async {
    popoverReply = 'open';
    await host(tester, const CitationBadge(sourceIndex: 0, sources: [_tides]));

    await tester.tap(find.text('harbour.example'));
    await tester.pumpAndSettle();

    expect(shownContent()['title'], 'Tide tables for small harbours');
    expect(
      shownContent()['message'],
      'harbour.example\n\n'
      'High water at the north quay comes forty minutes after the buoy.',
    );
    expect(shownContent()['actions'], [
      {'id': 'open', 'label': 'Open', 'style': 'default'},
      {'label': 'Close', 'style': 'cancel'},
    ]);
    // The popover answers once it has gone, so the link opens with no wait.
    expect(browser.opened, ['https://www.harbour.example/tides']);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets(
    'closing the preview opens nothing, and a caller\'s tap still wins',
    (tester) async {
      var tapped = false;
      await host(
        tester,
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CitationBadge(sourceIndex: 0, sources: [_tides]),
            CitationBadge(
              key: const ValueKey('handled'),
              sourceIndex: 0,
              sources: const [_tides],
              onTap: () => tapped = true,
            ),
          ],
        ),
      );

      await tester.tap(find.text('harbour.example').first);
      await tester.pumpAndSettle();
      expect(popovers, hasLength(1));
      expect(browser.opened, isEmpty);

      await tester.tap(find.byKey(const ValueKey('handled')));
      await tester.pumpAndSettle();
      expect(tapped, isTrue);
      expect(popovers, hasLength(1));
      expect(browser.opened, isEmpty);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('a source without a link previews its excerpt with Close alone', (
    tester,
  ) async {
    await host(
      tester,
      const CitationBadge(
        sourceIndex: 0,
        sources: [
          ChatSourceReference(
            title: 'Mooring plan.pdf',
            snippet: 'Visitor berths are on the east pontoon.',
          ),
        ],
      ),
    );

    await tester.tap(find.text('Mooring plan.pdf'));
    await tester.pumpAndSettle();

    expect(shownContent()['title'], 'Mooring plan.pdf');
    expect(
      shownContent()['message'],
      'Visitor berths are on the east pontoon.',
    );
    expect(shownContent()['actions'], [
      {'label': 'Close', 'style': 'cancel'},
    ]);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('before iOS 26 a citation opens its link straight away', (
    tester,
  ) async {
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 18;
    PlatformUiCapabilities.debugNativeIOS26Override = false;
    await host(tester, const CitationBadge(sourceIndex: 0, sources: [_tides]));

    await tester.tap(find.text('harbour.example'));
    await tester.pumpAndSettle();

    expect(popovers, isEmpty);
    expect(browser.opened, ['https://www.harbour.example/tides']);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  test('a bare link is titled by its site and a long excerpt is cut', () {
    final words = List.filled(80, 'shingle').join(' ');
    final preview = citationPreview(
      ChatSourceReference(
        url: 'https://www.beach.example/guide',
        snippet: words,
      ),
      0,
    );

    expect(preview.title, 'beach.example');
    expect(preview.message, endsWith('shingle…'));
    expect(preview.message!.length, lessThanOrEqualTo(241));
  });

  test('an excerpt without spaces is cut between whole characters', () {
    final preview = citationPreview(
      ChatSourceReference(title: 'Wave log', snippet: '🌊' * 300),
      0,
    );

    expect(preview.message, '${'🌊' * 240}…');
  });
}

class _BrowserPlatform extends InAppWebViewPlatform {
  final opened = <String>[];

  @override
  PlatformChromeSafariBrowser createPlatformChromeSafariBrowser(
    PlatformChromeSafariBrowserCreationParams params,
  ) => _Browser(params, opened);
}

class _Browser extends PlatformChromeSafariBrowser {
  _Browser(super.params, this.opened) : super.implementation();

  final List<String> opened;

  @override
  Future<void> open({
    WebUri? url,
    Map<String, String>? headers,
    List<WebUri>? otherLikelyURLs,
    WebUri? referrer,
    Object? options,
    ChromeSafariBrowserSettings? settings,
  }) async {
    opened.add(url.toString());
  }
}
