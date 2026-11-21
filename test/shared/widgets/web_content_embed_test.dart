import 'dart:async';
import 'dart:io';

import 'package:conduit/features/chat/services/video_attachment_cache.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/web_content_embed.dart';
import 'package:conduit/shared/widgets/web_embed_media_player.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:checks/checks.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
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
    localizationsDelegates: conduitLocalizationsDelegates,
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

    check(document)
        .contains('sandbox="allow-scripts allow-forms allow-popups"');
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
    check(document)
        .contains('sandbox="allow-scripts allow-forms allow-popups"');
    check(document).not((it) => it.contains('allow-same-origin'));
  });

  test('keeps remote tool URLs inside the sandboxed frame', () {
    final document = WebContentEmbed.debugWrapRemoteDocument(
      'https://example.com/widget?city=New%20York&units=metric',
    );

    check(document).contains(
      'src="https://example.com/widget?city=New%20York&amp;units=metric"',
    );
    check(document)
        .contains('sandbox="allow-scripts allow-forms allow-popups"');
    check(document).contains('referrerpolicy="no-referrer"');
    check(document).not((it) => it.contains('allow-same-origin'));
    check(document).not((it) => it.contains('srcdoc="https://example.com'));
  });

  test('builds a script-safe inline frame bootstrap', () {
    final bootstrap = WebContentEmbed.debugFrameBootstrapScript(
      '</script><script>steal()</script>',
    );

    check(bootstrap).contains(
      r'window.args = "\u003C/script\u003E\u003Cscript\u003Esteal()\u003C/script\u003E";',
    );
    check(bootstrap).contains(
      "parent.postMessage({ type: 'conduit-embed-height', height }, '*')",
    );
    check(bootstrap).contains('new ResizeObserver(reportHeight)');
    check(bootstrap).not((it) => it.contains('</script><script>steal()'));
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

  test('surfaces only main-document or configured remote-frame failures', () {
    check(
      WebContentEmbed.debugShouldSurfaceLoadFailure(
        isForMainFrame: true,
        remoteEmbedUrls: const [],
        requestUrl: 'https://embed.conduit.local/',
      ),
    ).isTrue();
    check(
      WebContentEmbed.debugShouldSurfaceLoadFailure(
        isForMainFrame: false,
        remoteEmbedUrls: const ['https://example.com/widget'],
        requestUrl: 'https://example.com/widget',
      ),
    ).isTrue();
    check(
      WebContentEmbed.debugShouldSurfaceLoadFailure(
        isForMainFrame: false,
        remoteEmbedUrls: const ['https://example.com/widget'],
        requestUrl: 'https://example.com/broken-image.png',
      ),
    ).isFalse();
    check(
      WebContentEmbed.debugShouldSurfaceLoadFailure(
        isForMainFrame: false,
        remoteEmbedUrls: const [],
        requestUrl: 'https://example.com/script.js',
      ),
    ).isFalse();
  });

  test('normalizes and tracks remote-frame document failure URLs', () {
    check(
      WebContentEmbed.debugShouldSurfaceLoadFailure(
        isForMainFrame: false,
        remoteEmbedUrls: const ['https://EXAMPLE.com:443'],
        requestUrl: 'https://example.com/',
      ),
    ).isTrue();
    check(
      WebContentEmbed.debugShouldSurfaceLoadFailure(
        isForMainFrame: false,
        remoteEmbedUrls: const [
          'https://example.com/widget',
          'https://cdn.example.net/redirected-widget',
        ],
        requestUrl: 'https://cdn.example.net/redirected-widget',
      ),
    ).isTrue();
  });

  test('all-frame bootstrap never exposes tool arguments', () {
    const secret = 'tool-argument-secret';
    check(WebContentEmbed.debugAllFrameBootstrapScript())
        .not((it) => it.contains(secret));
    check(WebContentEmbed.debugAllFrameBootstrapScript())
        .not((it) => it.contains('window.args ='));
    check(WebContentEmbed.debugAllFrameBootstrapScript()).contains(
      "parent.postMessage({ type: 'conduit-embed-height', height }, '*')",
    );
    check(WebContentEmbed.debugFrameBootstrapScript(secret)).contains(secret);
  });

  test('inline argument bootstrap does not duplicate height observers', () {
    final argumentsScript = WebContentEmbed.debugInlineArgumentsScript(
      'private-tool-argument',
    );

    check(argumentsScript).contains('window.args =');
    check(argumentsScript).contains('private-tool-argument');
    check(argumentsScript).not((it) => it.contains('ResizeObserver'));
    check(argumentsScript).not((it) => it.contains('postMessage'));
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
    check(WebContentEmbed.debugShouldAllowAutomaticNavigation('about:blank'))
        .isTrue();
    check(WebContentEmbed.debugShouldAllowAutomaticNavigation('about:srcdoc'))
        .isTrue();
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
    check(document)
        .not((it) => it.contains('</script><script>steal()</script>'));
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

  group('media on the account\'s server', () {
    const page =
        '<h3>Clips</h3>'
        '<audio controls title="Morning note" '
        'src="/api/v1/files/a1/content"></audio>'
        '<video controls title="Walkthrough">'
        '<source src="https://chat.example.test/api/v1/files/v1/content">'
        '</video>'
        '<audio controls src="https://cdn.example.test/public.mp3"></audio>';

    String framePage(WidgetTester tester) =>
        tester.widget<WebContentFrame>(find.byType(WebContentFrame)).source;

    testWidgets('plays beside the page instead of in it', (tester) async {
      await tester.pumpWidget(_buildServerHarness(page));

      check(framePage(tester))
        ..contains('<h3>Clips</h3>')
        ..contains('src="https://cdn.example.test/public.mp3"')
        ..not((it) => it.contains('/api/v1/files/'));
      check(find.byType(WebEmbedMediaPlayer).evaluate()).length.equals(2);
      check(find.text('Morning note').evaluate()).length.equals(1);
      check(find.text('Walkthrough').evaluate()).length.equals(1);
    });

    testWidgets('a page of nothing but that media shows only the player', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildServerHarness(
          '<!doctype html><html><body style="margin:0">'
          '<audio controls src="/api/v1/files/a1/content"></audio>'
          '</body></html>',
        ),
      );

      check(find.byType(WebContentFrame).evaluate()).isEmpty();
      check(find.byType(WebEmbedMediaPlayer).evaluate()).length.equals(1);
    });

    testWidgets('the credentials reach the player and never the page', (
      tester,
    ) async {
      final cache = _RecordingVideoCache();
      await tester.pumpWidget(_buildServerHarness(page, videoCache: cache));

      final html = framePage(tester);
      for (final document in [
        html,
        WebContentEmbed.debugWrapHtmlDocument(html),
      ]) {
        for (final secret in [
          _sessionToken,
          _proxySecret,
          'Authorization',
          'Bearer',
        ]) {
          check(because: secret, document).not((it) => it.contains(secret));
        }
      }

      await tester.tap(find.text('Walkthrough'));
      await tester.pump();

      check(cache.urls)
          .deepEquals(['https://chat.example.test/api/v1/files/v1/content']);
      final transport = cache.transports.single(cache.urls.single);
      addTearDown(() => transport.client.close(force: true));
      check(transport.ownsClient).isTrue();
      check(transport.client.options.headers)
        ..containsKey('Authorization')
        ..has(
          (it) => it['Authorization'],
          'Authorization',
        ).equals('Bearer $_sessionToken')
        ..has(
          (it) => it['X-Proxy-Session'],
          'X-Proxy-Session',
        ).equals(_proxySecret);
      check(transport.client.options.followRedirects).isFalse();
    });

    testWidgets('another backend\'s page stays exactly as written', (
      tester,
    ) async {
      await tester.pumpWidget(_buildServerHarness(page, openWebUi: false));

      check(framePage(tester)).equals(page);
      check(find.byType(WebEmbedMediaPlayer).evaluate()).isEmpty();
    });

    testWidgets('a mounted page follows the active server', (tester) async {
      const voiceNote =
          '<audio controls title="Morning note" '
          'src="/api/v1/files/a1/content"></audio>';
      Uri playing() => tester
          .widget<WebEmbedMediaPlayer>(find.byType(WebEmbedMediaPlayer))
          .item
          .url;
      await tester.pumpWidget(_buildServerHarness(voiceNote));
      check(
        playing(),
      ).equals(Uri.parse('https://chat.example.test/api/v1/files/a1/content'));

      _container(tester)
          .read(_activeApi.notifier)
          .set(_api('https://other.example.test'));
      await tester.pump();
      check(
        playing(),
      ).equals(Uri.parse('https://other.example.test/api/v1/files/a1/content'));

      _container(tester).read(_activeApi.notifier).set(null);
      await tester.pump();
      check(find.byType(WebEmbedMediaPlayer).evaluate()).isEmpty();
      check(framePage(tester)).equals(voiceNote);
    });

    testWidgets('another account on the same server starts the player over', (
      tester,
    ) async {
      final cache = _RecordingVideoCache();
      await tester.pumpWidget(_buildServerHarness(page, videoCache: cache));
      await tester.tap(find.text('Walkthrough'));
      await tester.pump();
      check(cache.urls).length.equals(1);
      check(find.byTooltip('Play').evaluate()).isEmpty();

      _container(tester).read(_activeToken.notifier).set('another-account');
      await tester.pump();

      // The first account's transfer is let go, and nothing of it is kept.
      check(cache.released).contains(cache.claims.single);
      check(find.byTooltip('Play').evaluate()).length.equals(1);

      await tester.tap(find.byTooltip('Play'));
      await tester.pump();
      check(cache.urls).length.equals(2);
      check(cache.cacheIdentities.last)
          .not((it) => it.equals(cache.cacheIdentities.first));
      final transport = cache.transports.last(cache.urls.last);
      addTearDown(() => transport.client.close(force: true));
      check(transport.client.options.headers['Authorization'])
          .equals('Bearer another-account');
    });

    group('audio', () {
      testWidgets('downloads into the cache before it plays', (tester) async {
        final cache = _RecordingVideoCache();
        await tester.pumpWidget(_buildServerHarness(page, videoCache: cache));

        await tester.tap(find.byTooltip('Play Audio'));
        await tester.pump();

        check(cache.urls)
            .deepEquals(['https://chat.example.test/api/v1/files/a1/content']);
        final transport = cache.transports.single(cache.urls.single);
        addTearDown(() => transport.client.close(force: true));
        check(transport.client.options.followRedirects).isFalse();
        check(transport.client.options.headers['Authorization'])
            .equals('Bearer $_sessionToken');
        // The file takes the format its reply names.
        check(cache.replyExtensions.single?.call('audio/mpeg')).equals('mp3');
        check(find.bySemanticsLabel('Loading audio...').evaluate())
            .isNotEmpty();

        // Another account starts over, and lets the first one's transfer go.
        _container(tester).read(_activeToken.notifier).set('another-account');
        await tester.pump();
        check(cache.released).contains(cache.claims.single);
        check(find.byTooltip('Play Audio').evaluate()).length.equals(1);
      });

      testWidgets(
        'a source that cannot be fetched gives way to the next, and Retry '
        'starts again from the first',
        (tester) async {
          const sources = [
            'https://chat.example.test/api/v1/files/a1/content',
            'https://chat.example.test/api/v1/files/a2/content',
          ];
          final cache = _RecordingVideoCache();
          await tester.pumpWidget(
            _buildServerHarness(
              '<audio controls title="Morning note">'
              '${sources.map((it) => '<source src="$it">').join()}'
              '</audio>',
              videoCache: cache,
            ),
          );

          await tester.tap(find.byTooltip('Play Audio'));
          await tester.pump();
          cache.pending[0].completeError(const HttpException('404'));
          await tester.pump();
          check(cache.urls).deepEquals(sources);

          cache.pending[1].completeError(const HttpException('sign-in page'));
          await tester.pump();
          check(find.text('Failed to load audio').evaluate()).length.equals(1);

          await tester.tap(find.byTooltip('Retry'));
          await tester.pump();
          check(cache.urls).deepEquals([...sources, sources.first]);
        },
      );
    });
  });
}

const _sessionToken = 'synthetic-session-token';
const _proxySecret = 'synthetic-proxy-secret';

ApiService _api(String url) => ApiService(
  serverConfig: ServerConfig(
    id: 'synthetic-$url',
    name: 'Synthetic',
    url: url,
    customHeaders: const {'X-Proxy-Session': _proxySecret},
  ),
  workerManager: WorkerManager(),
);

/// The active account's client, which a test can change under a mounted
/// embed.
final _activeApi = NotifierProvider<_ActiveApi, ApiService?>(_ActiveApi.new);

final class _ActiveApi extends Notifier<ApiService?> {
  @override
  ApiService? build() => _api('https://chat.example.test');

  void set(ApiService? api) => state = api;
}

/// The signed-in account's token, which a test can change under a mounted
/// embed.
final _activeToken = NotifierProvider<_ActiveToken, String>(_ActiveToken.new);

final class _ActiveToken extends Notifier<String> {
  @override
  String build() => _sessionToken;

  void set(String token) => state = token;
}

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(WebContentEmbed)));

Widget _buildServerHarness(
  String source, {
  VideoAttachmentCache? videoCache,
  bool openWebUi = true,
}) {
  return ProviderScope(
    overrides: [
      apiServiceProvider.overrideWith((ref) => ref.watch(_activeApi)),
      authTokenProvider3.overrideWith((ref) => ref.watch(_activeToken)),
      openWebUiAccountAvailableProvider.overrideWith(
        (ref) => ref.watch(_activeApi) != null,
      ),
      // A new session for each account, as signing in starts one.
      openWebUiAuthSessionEpochProvider.overrideWith((ref) {
        ref.watch(_activeToken);
        return Object();
      }),
      if (videoCache != null)
        videoAttachmentCacheProvider.overrideWithValue(videoCache),
    ],
    child: MaterialApp(
      theme: AppTheme.light(TweakcnThemes.t3Chat),
      localizationsDelegates: conduitLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: WebEmbedServerMediaScope(
            enabled: openWebUi,
            child: WebContentEmbed(source: source),
          ),
        ),
      ),
    ),
  );
}

/// Records what a video row fetches, and with what, and leaves each fetch
/// loading until the test ends it.
class _RecordingVideoCache extends VideoAttachmentCache {
  final List<String> urls = [];
  final List<String> cacheIdentities = [];
  final List<VideoTransport Function(String url)> transports = [];
  final List<Completer<File>> pending = [];
  final List<String Function(String? mediaType)?> replyExtensions = [];
  final List<VideoDownloadClaim> claims = [];
  final List<VideoDownloadClaim> released = [];

  @override
  void releaseDownload(VideoDownloadClaim claim) => released.add(claim);

  @override
  Future<File> fetchForPlayback({
    required VideoDownloadClaim claim,
    required String url,
    required String cacheIdentity,
    required String extension,
    required VideoTransport Function(String url) transport,
    required bool Function() isCurrent,
    String Function(String? mediaType)? extensionForReply,
  }) {
    claims.add(claim);
    urls.add(url);
    cacheIdentities.add(cacheIdentity);
    transports.add(transport);
    replyExtensions.add(extensionForReply);
    final fetch = Completer<File>();
    pending.add(fetch);
    return fetch.future;
  }
}
