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
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html_unescape/html_unescape.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
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
      const sources = [
        'https://chat.example.test/api/v1/files/a1/content',
        'https://chat.example.test/api/v1/files/a2/content',
      ];

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
          final cache = _RecordingVideoCache();
          await tester.pumpWidget(
            _buildServerHarness(_audioElement(sources), videoCache: cache),
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

      group('in the player', () {
        late JustAudioPlatform devicePlayers;
        late _FakeAudioPlatform audio;

        setUp(() {
          devicePlayers = JustAudioPlatform.instance;
          audio = _FakeAudioPlatform();
          JustAudioPlatform.instance = audio;
        });
        tearDown(() => JustAudioPlatform.instance = devicePlayers);

        /// Does [action], and returns once [until] has completed and the row
        /// has rebuilt.
        ///
        /// just_audio waits on rxdart streams whose `first` completes only
        /// when the real event loop turns, since the cancel it waits for is
        /// chained off the root zone. A widget test's clock never turns that
        /// loop, so the steps that reach the player run in
        /// [WidgetTester.runAsync], and Play is pressed there, so that the row
        /// loads in that zone. A step ends on something the fakes see the row
        /// do, never after a time. Where the row meets a failure, that is it
        /// letting go of the failed file, which it does whether it moves on
        /// or shows the failure, so a wrong turn fails a check.
        Future<void> step(
          WidgetTester tester,
          FutureOr<void> Function() action, {
          required Future<void> Function() until,
        }) async {
          await tester.runAsync(() async {
            await action();
            await until();
          });
          await tester.pump();
        }

        /// Presses Play on an element of [sources] and finishes the first
        /// one's download, which a player is asked to open.
        Future<_RecordingVideoCache> play(WidgetTester tester) async {
          final cache = _RecordingVideoCache();
          await tester.pumpWidget(
            _buildServerHarness(_audioElement(sources), videoCache: cache),
          );
          await step(
            tester,
            () => tester.tap(find.byTooltip('Play Audio')),
            until: () => cache.fetched(1),
          );
          await step(
            tester,
            () => cache.pending[0].complete(_downloaded('a1')),
            until: () => audio.opened(0),
          );
          return cache;
        }

        testWidgets(
          'a file it cannot open gives way to the next source, and the last '
          'one shows the failure',
          (tester) async {
            final cache = await play(tester);

            await step(
              tester,
              audio.players[0].failLoadCall,
              until: () => cache.freed(_downloaded('a1')),
            );
            check(cache.urls).deepEquals(sources);

            await step(
              tester,
              () => cache.pending[1].complete(_downloaded('a2')),
              until: () => audio.opened(1),
            );
            await step(
              tester,
              audio.players[1].failLoadCall,
              until: () => cache.freed(_downloaded('a2')),
            );
            check(find.text('Failed to load audio').evaluate()).length
                .equals(1);
            check(find.byTooltip('Retry').evaluate()).length.equals(1);
            check(cache.urls).deepEquals(sources);
          },
        );

        testWidgets('a failure it reports twice moves on once', (tester) async {
          final cache = await play(tester);

          // A device player reports a file it cannot open both ways: an
          // error event, then the load call failing.
          await step(
            tester,
            audio.players[0].reportError,
            until: () => cache.freed(_downloaded('a1')),
          );
          await step(
            tester,
            () {
              audio.players[0].failLoadCall();
              cache.pending[1].complete(_downloaded('a2'));
            },
            // Moving on again would let the second download go unplayed.
            until: () =>
                Future.any([audio.opened(1), cache.freed(_downloaded('a2'))]),
          );
          check(cache.urls).deepEquals(sources);
          check(audio.players).length.equals(2);
          check(audio.players[1].file).equals(_downloaded('a2').path);

          // The row lets its last player go where that work can finish.
          await step(
            tester,
            () => tester.pumpWidget(const SizedBox()),
            until: () => cache.freed(_downloaded('a2')),
          );
        });

        testWidgets(
          'a failure once it plays shows the failure instead of the next '
          'source',
          (tester) async {
            final cache = await play(tester);
            await step(
              tester,
              audio.players[0].ready,
              until: () => audio.played(0),
            );
            check(find.byTooltip('Pause').evaluate()).length.equals(1);

            // A read error mid-file arrives only as an error event.
            await step(
              tester,
              audio.players[0].reportError,
              until: () => cache.freed(_downloaded('a1')),
            );
            check(find.text('Failed to load audio').evaluate()).length
                .equals(1);
            check(find.byTooltip('Retry').evaluate()).length.equals(1);
            check(find.byTooltip('Pause').evaluate()).isEmpty();
            check(cache.urls).deepEquals([sources.first]);
          },
        );
      });
    });
  });
}

/// An audio element that names [sources] in turn.
String _audioElement(List<String> sources) =>
    '<audio controls title="Morning note">'
    '${sources.map((it) => '<source src="$it">').join()}'
    '</audio>';

/// The media cache's copy of the file with [id].
File _downloaded(String id) => File('/synthetic-media-cache/$id.mp3');

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
  final _milestones = _Milestones();

  /// Completes once the row has asked for [count] fetches.
  Future<void> fetched(int count) => _milestones.wait(('fetch', count));

  /// Completes once the row has let go of the cached [file].
  Future<void> freed(File file) => _milestones.wait(('free', file.path));

  @override
  void releaseDownload(VideoDownloadClaim claim) => released.add(claim);

  @override
  void releaseCachePath(String? path) {
    super.releaseCachePath(path);
    _milestones.reach(('free', path));
  }

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
    _milestones.reach(('fetch', urls.length));
    return fetch.future;
  }
}

/// Futures for what the row has yet to do, each completed once it does.
final class _Milestones {
  final Set<Object?> _reached = {};
  final Map<Object?, Completer<void>> _waiting = {};

  void reach(Object? milestone) {
    _reached.add(milestone);
    _waiting.remove(milestone)?.complete();
  }

  Future<void> wait(Object? milestone) => _reached.contains(milestone)
      ? Future<void>.value()
      : (_waiting[milestone] ??= Completer<void>()).future;
}

/// The device's audio players, faked as just_audio's own tests fake them.
/// [players] holds each one the row makes, in order.
final class _FakeAudioPlatform extends JustAudioPlatform {
  final List<_FakeAudioPlayer> players = [];
  final _milestones = _Milestones();

  /// Completes once player [index] has been asked to open a file.
  Future<void> opened(int index) => _milestones.wait(('open', index));

  /// Completes once player [index] has been asked to play.
  Future<void> played(int index) => _milestones.wait(('play', index));

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    final index = players.length;
    final player = _FakeAudioPlayer(
      request.id,
      onOpen: () => _milestones.reach(('open', index)),
      onPlay: () => _milestones.reach(('play', index)),
    );
    players.add(player);
    return player;
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(
    DisposePlayerRequest request,
  ) async => DisposePlayerResponse();

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(
    DisposeAllPlayersRequest request,
  ) async => DisposeAllPlayersResponse();
}

/// One device player. Its load ends only when the test ends it.
final class _FakeAudioPlayer extends AudioPlayerPlatform {
  _FakeAudioPlayer(super.id, {required this.onOpen, required this.onPlay});

  static const _length = Duration(seconds: 42);

  final void Function() onOpen;
  final void Function() onPlay;
  final _events = StreamController<PlaybackEventMessage>.broadcast();
  final _loaded = Completer<LoadResponse>();

  /// The file the player was asked to open.
  String? file;

  /// The file opens and can play.
  void ready() {
    _send(ProcessingStateMessage.ready);
    _loaded.complete(LoadResponse(duration: _length));
  }

  /// The load call fails, as it does for a file the player cannot open.
  void failLoadCall() => _loaded.completeError(
    PlatformException(code: '1', message: 'synthetic: cannot open'),
  );

  /// An error event, which the device's players send for a file they cannot
  /// open and for a failure once one plays, such as a read error mid-file.
  void reportError() => _send(
    ProcessingStateMessage.idle,
    errorCode: 1,
    errorMessage: 'synthetic: cannot read',
  );

  void _send(
    ProcessingStateMessage state, {
    int? errorCode,
    String? errorMessage,
  }) => _events.add(
    PlaybackEventMessage(
      processingState: state,
      updateTime: DateTime.now(),
      updatePosition: Duration.zero,
      bufferedPosition: Duration.zero,
      duration: _length,
      icyMetadata: null,
      currentIndex: 0,
      androidAudioSessionId: null,
      errorCode: errorCode,
      errorMessage: errorMessage,
    ),
  );

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  @override
  Future<LoadResponse> load(LoadRequest request) {
    final playlist =
        request.audioSourceMessage as ConcatenatingAudioSourceMessage;
    final source = playlist.children.single as UriAudioSourceMessage;
    file = Uri.parse(source.uri).toFilePath();
    onOpen();
    return _loaded.future;
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    onPlay();
    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async => PauseResponse();

  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async =>
      DisposeResponse();

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async =>
      SetVolumeResponse();

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async =>
      SetSpeedResponse();

  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) async =>
      SetPitchResponse();

  @override
  Future<SetSkipSilenceResponse> setSkipSilence(
    SetSkipSilenceRequest request,
  ) async => SetSkipSilenceResponse();

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async =>
      SetLoopModeResponse();

  @override
  Future<SetShuffleModeResponse> setShuffleMode(
    SetShuffleModeRequest request,
  ) async => SetShuffleModeResponse();
}
