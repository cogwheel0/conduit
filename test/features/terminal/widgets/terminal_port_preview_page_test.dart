import 'dart:async';

import 'package:conduit/features/terminal/controllers/terminal_controller_gateways.dart';
import 'package:conduit/features/terminal/widgets/terminal_port_preview_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/platform/webview_cookie_helper.dart';
import 'package:conduit_core/features/terminal/controllers/terminal_port_preview_controller.dart';
import 'package:conduit_core/features/terminal/services/terminal_port_preview.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

void main() {
  setUpAll(() => registerFallbackValue(URLRequest()));

  final base = Uri.parse('https://owui.test/api/v1/terminals/t1');
  const session = TerminalBrowserSession(id: 'sid', token: 'ticket');
  const view = 'https://owui.test/api/v1/terminals/t1/browser/view/sid/ticket';
  const proxy = 'https://owui.test/api/v1/terminals/t1/proxy';

  late List<Uri> opened;
  late List<TerminalBrowserSession> closed;
  TerminalPreviewWebViewHost? host;

  setUp(() {
    opened = [];
    closed = [];
    host = null;
  });

  Widget page(TerminalPortPreview preview) => MaterialApp(
    localizationsDelegates: conduitLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: TerminalPortPreviewPage(
      preview: preview,
      openExternally: (uri) async {
        opened.add(uri);
        return true;
      },
      webViewBuilder: (context, webViewHost) {
        host = webViewHost;
        return Text('web ${webViewHost.preview.initialRequest!.uri}');
      },
    ),
  );

  TerminalPortPreview preview({
    Future<TerminalBrowserSession> Function()? openSession,
  }) => TerminalPortPreview(
    port: 5173,
    terminalBaseUri: base,
    bearerToken: 'jwt',
    openSession: openSession,
    closeSession: (session) async => closed.add(session),
  );

  // The page's progress bar runs until the web view finishes a load, which
  // the stand-in never does, so the page never settles on its own.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  AppLocalizations l10n(WidgetTester tester) => AppLocalizations.of(
    tester.element(find.byType(TerminalPortPreviewPage)),
  )!;

  testWidgets('shows the port through a session and closes it after', (
    tester,
  ) async {
    final opening = Completer<TerminalBrowserSession>();
    await tester.pumpWidget(page(preview(openSession: () => opening.future)));
    await tester.pump();
    expect(host, isNull);
    expect(find.text('localhost:5173'), findsOneWidget);

    opening.complete(session);
    await settle(tester);

    expect(
      find.text('web $view/frame/http/localhost%3A5173/'),
      findsOneWidget,
    );
    host!.preview
      ..pageChanged(Uri.parse('$view/frame/http/localhost%3A5173/docs'))
      ..titleChanged('Vite App');
    await tester.pump();
    expect(find.text('Vite App'), findsOneWidget);
    expect(find.text('localhost:5173/docs'), findsOneWidget);

    // A link the user taps that leaves the terminal opens in the system
    // browser.
    final policy = await host!.navigate(
      Uri.parse('$view/frame/https/example.com/guide'),
      history: false,
      userActivated: true,
    );
    expect(policy, NavigationActionPolicy.CANCEL);
    expect(opened, [Uri.parse('https://example.com/guide')]);

    // One without a tap, such as a redirect to a hosted login, asks first,
    // once however often the page tries.
    for (var i = 0; i < 3; i++) {
      final redirect = await host!.navigate(
        Uri.parse('$view/frame/https/login.example.com/'),
        history: false,
      );
      expect(redirect, NavigationActionPolicy.CANCEL);
    }
    // The page's spinner keeps running, so frames are pumped by hand.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(opened, hasLength(1));
    expect(find.text('https://login.example.com/'), findsOneWidget);
    await tester.tap(find.text(l10n(tester).terminalOpenInBrowserAction).last);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(opened.last, Uri.parse('https://login.example.com/'));

    // A session's page needs no credential, so it can open elsewhere too.
    await tester.tap(find.byTooltip(l10n(tester).terminalOpenInBrowserAction));
    await tester.pump();
    expect(opened.last, Uri.parse('$view/frame/http/localhost%3A5173/docs'));

    expect(closed, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(closed, [session]);
  });

  testWidgets('falls back to the proxy and keeps its link in the app', (
    tester,
  ) async {
    await tester.pumpWidget(
      page(preview(openSession: () async => throw Exception('older'))),
    );
    await settle(tester);

    expect(find.text('web $proxy/5173/'), findsOneWidget);
    expect(host!.preview.initialRequest!.headers, {
      'Authorization': 'Bearer jwt',
    });
    // The proxy's pages need the account's token: nothing to hand out.
    expect(
      find.byTooltip(l10n(tester).terminalOpenInBrowserAction),
      findsNothing,
    );

    final blocked = await host!.navigate(
      Uri.parse('https://owui.test/api/v1/chats/'),
      history: false,
    );
    expect(blocked, NavigationActionPolicy.CANCEL);
    expect(opened, isEmpty);

    await tester.pumpWidget(const SizedBox());
    expect(closed, isEmpty);
  });

  testWidgets('says when a page cannot be reached', (tester) async {
    await tester.pumpWidget(page(preview()));
    await settle(tester);
    final message = l10n(tester).terminalPortPreviewLoadFailed;
    expect(find.text(message), findsNothing);

    host!.loadFailed();
    await tester.pump();
    expect(find.text(message), findsOneWidget);

    // The end of the failed load keeps the message; a new load clears it.
    host!.loadingChanged(loading: false);
    await tester.pump();
    expect(find.text(message), findsOneWidget);
    host!.loadingChanged(loading: true);
    await tester.pump();
    expect(find.text(message), findsNothing);
  });

  // Pumps the confirmation in and out; the page's spinner never settles.
  Future<void> pumpDialog(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('a link iOS says was followed leaves at once only after a tap', (
    tester,
  ) async {
    await tester.pumpWidget(page(preview()));
    await settle(tester);
    final guide = Uri.parse('https://example.com/guide');
    final login = Uri.parse('https://login.example.com/');

    // The user taps the page: the link leaves for the system browser.
    await tester.tap(find.textContaining('web '));
    await tester.pump();
    final tapped = await host!.navigate(
      guide,
      history: false,
      linkActivated: true,
    );
    expect(tapped, NavigationActionPolicy.CANCEL);
    expect(opened, [guide]);

    // That tap is spent: a script clicking a link after it is asked about.
    await host!.navigate(login, history: false, linkActivated: true);
    await pumpDialog(tester);
    expect(opened, [guide]);
    expect(find.text(login.toString()), findsOneWidget);
    await tester.tap(find.text(l10n(tester).terminalOpenInBrowserAction).last);
    await pumpDialog(tester);
    expect(opened, [guide, login]);

    // So is one long after the last tap.
    await tester.tap(find.textContaining('web '));
    await tester.pump(const Duration(seconds: 2));
    await host!.navigate(guide, history: false, linkActivated: true);
    await pumpDialog(tester);
    expect(opened, [guide, login]);
    expect(find.text(guide.toString()), findsOneWidget);
    await tester.tap(find.text(l10n(tester).terminalOpenInBrowserAction).last);
    await pumpDialog(tester);
    expect(opened, [guide, login, guide]);

    // A drag scrolls the page rather than tapping a link.
    await tester.drag(find.textContaining('web '), const Offset(0, -200));
    await tester.pump();
    await host!.navigate(login, history: false, linkActivated: true);
    await pumpDialog(tester);
    expect(opened, hasLength(3));
    expect(find.text(login.toString()), findsOneWidget);
  });

  testWidgets('a tap spent on a page the script loaded cannot leave again', (
    tester,
  ) async {
    await tester.pumpWidget(page(preview(openSession: () async => session)));
    await settle(tester);
    final login = Uri.parse('https://login.example.com/');

    // Open Terminal's pages follow a tapped link by script, which iOS does
    // not report as a followed link.
    await tester.tap(find.textContaining('web '));
    await tester.pump();
    final docs = await host!.navigate(
      Uri.parse('$view/frame/http/localhost%3A5173/docs'),
      history: false,
    );
    expect(docs, NavigationActionPolicy.ALLOW);

    // The page it opened clicks a link straight away: the user is asked.
    await host!.navigate(login, history: false, linkActivated: true);
    await pumpDialog(tester);
    expect(opened, isEmpty);
    expect(find.text(login.toString()), findsOneWidget);
  });

  testWidgets('a form post that leaves the preview is turned back', (
    tester,
  ) async {
    await tester.pumpWidget(page(preview()));
    await settle(tester);
    final controller = _MockWebViewController();
    when(controller.stopLoading).thenAnswer((_) async {});
    when(
      () => controller.loadUrl(urlRequest: any(named: 'urlRequest')),
    ).thenAnswer((_) async {});
    host!.attach(controller);
    host!.preview.pageChanged(Uri.parse('$proxy/5173/form'));

    // The preview's own pages load as they are.
    host!.loadStarted(Uri.parse('$proxy/5173/form'));
    await tester.pump();
    verifyNever(controller.stopLoading);

    // Android posts a form to a site elsewhere without asking the rules:
    // the page goes back to where it was and the user is asked.
    host!.loadStarted(Uri.parse('https://collect.example/post'));
    await pumpDialog(tester);
    verify(controller.stopLoading).called(1);
    final captured = verify(
      () => controller.loadUrl(urlRequest: captureAny(named: 'urlRequest')),
    ).captured;
    final request = captured.single as URLRequest;
    expect(request.url.toString(), '$proxy/5173/form');
    expect(request.headers, {'Authorization': 'Bearer jwt'});
    expect(opened, isEmpty);
    expect(find.text('https://collect.example/post'), findsOneWidget);
    await tester.tap(find.text(l10n(tester).terminalOpenInBrowserAction).last);
    await pumpDialog(tester);
    expect(opened, [Uri.parse('https://collect.example/post')]);

    // One to Open WebUI itself is only turned back.
    host!.loadStarted(Uri.parse('https://owui.test/api/v1/chats'));
    await pumpDialog(tester);
    verify(controller.stopLoading).called(1);
    expect(opened, hasLength(1));
  });

  test('a navigation reports how the platform says it started', () async {
    final recorder = _RecordingHost();
    Future<NavigationActionPolicy> ask({
      String method = 'GET',
      bool mainFrame = true,
      bool? hasGesture,
      NavigationType? type,
    }) => terminalPreviewOverrideUrlLoading(
      recorder,
      NavigationAction(
        request: URLRequest(
          url: WebUri('https://example.com/'),
          method: method,
        ),
        isForMainFrame: mainFrame,
        hasGesture: hasGesture,
        navigationType: type,
      ),
    );

    // iOS says a link was followed, which a script can do too: not a tap.
    await ask(type: NavigationType.LINK_ACTIVATED);
    expect(recorder.calls.last, (
      history: false,
      userActivated: false,
      linkActivated: true,
    ));
    // Android says whether the user started it.
    await ask(hasGesture: true);
    expect(recorder.calls.last, (
      history: false,
      userActivated: true,
      linkActivated: false,
    ));
    await ask(method: 'POST', type: NavigationType.FORM_SUBMITTED);
    expect(recorder.calls.last.history, isTrue);
    await ask(type: NavigationType.BACK_FORWARD);
    expect(recorder.calls.last.history, isTrue);

    expect(
      await ask(mainFrame: false, type: NavigationType.LINK_ACTIVATED),
      NavigationActionPolicy.ALLOW,
    );
    expect(recorder.calls, hasLength(4));
  });

  test('the web view keeps a cookie store of its own on iOS only', () {
    final ios = terminalPreviewWebViewSettings(platform: TargetPlatform.iOS);
    final android = terminalPreviewWebViewSettings(
      platform: TargetPlatform.android,
    );

    expect(ios.incognito, isTrue);
    // A private Android web view would clear the whole app's cookies, so a
    // proxied page there shares the app's store, as before.
    expect(android.incognito, isFalse);
    for (final settings in [ios, android]) {
      expect(settings.javaScriptBridgeEnabled, isFalse);
      expect(settings.useShouldOverrideUrlLoading, isTrue);
      expect(settings.sharedCookiesEnabled, isFalse);
      expect(settings.allowFileAccess, isFalse);
    }
  });

  test('the injected script follows reported links only from the page', () {
    expect(
      terminalPreviewNavigationScript,
      contains('event.source !== window'),
    );
    expect(
      terminalPreviewNavigationScript,
      contains("'terminal-browser-navigate'"),
    );
    expect(
      terminalPreviewNavigationScript,
      contains("'terminal-browser-popup'"),
    );
  });

  test('pages shown as they are get the script that sends forms through', () {
    final base = Uri.parse('http://10.0.0.5:8000/');
    final plain = TerminalPreviewNavigator.proxy(terminalBaseUri: base);
    final keyed = TerminalPreviewNavigator.proxy(
      terminalBaseUri: base,
      bearerToken: 'key',
    );

    expect(terminalPreviewUserScripts(plain), [
      terminalPreviewNavigationScript,
      terminalPreviewFormScript('http://10.0.0.5:8000/proxy'),
    ]);
    expect(
      terminalPreviewFormScript('http://10.0.0.5:8000/proxy'),
      contains('const target = "http://10.0.0.5:8000/proxy";'),
    );
    // A form the page submits by script fires no submit event.
    expect(
      terminalPreviewFormScript('http://10.0.0.5:8000/proxy'),
      contains('HTMLFormElement.prototype.submit = function'),
    );
    // A control named "action" hides the form's own action property.
    expect(
      terminalPreviewFormScript('http://10.0.0.5:8000/proxy'),
      contains("getOwnPropertyDescriptor(\n    HTMLFormElement.prototype, 'action')"),
    );
    // Behind a credential the page's own post could not get through.
    expect(terminalPreviewUserScripts(keyed), [
      terminalPreviewNavigationScript,
    ]);
    expect(terminalPreviewUserScripts(null), [
      terminalPreviewNavigationScript,
    ]);
  });

  group("a sign-in proxy's cookies", () {
    final target = Uri.parse(
      'https://owui.test/api/v1/terminals/t1/browser/view/sid/tok/'
      'frame/http/localhost%3A5173/',
    );

    test('are set by a page of the app\'s own before the first one', () {
      final seed = terminalPreviewCookieSeed(
        cookies: const {
          'CF_Authorization': 'a.b-c',
          'bad name': 'x',
          'quoted': '"q"',
          'angle': '</script>',
        },
        target: target,
      )!;

      expect(seed.url, Uri.parse('https://owui.test/'));
      expect(
        seed.document,
        contains(
          'document.cookie = '
          '"CF_Authorization=a.b-c; path=/; secure; samesite=none";',
        ),
      );
      expect(seed.document, contains('location.replace("$target");'));
      // Nothing a Cookie header could not carry.
      expect(seed.document, isNot(contains('bad name')));
      expect(seed.document, isNot(contains('quoted')));
      // A value cannot close the script element.
      expect(seed.document, contains(r'angle=\u003c/script>'));
      expect('</script>'.allMatches(seed.document), hasLength(1));
    });

    test('are sent over plain http without the secure flag', () {
      final seed = terminalPreviewCookieSeed(
        cookies: const {'session': 'v'},
        target: Uri.parse('http://owui.lan/x'),
      )!;

      expect(seed.document, contains('"session=v; path=/";'));
    });

    test('that cannot be given leave no page of the app\'s own', () {
      expect(terminalPreviewCookieSeed(cookies: const {}, target: target), isNull);
      expect(
        terminalPreviewCookieSeed(cookies: const {'a b': 'c'}, target: target),
        isNull,
      );
    });

    Future<
      ({
        PlatformInAppWebViewWidgetCreationParams params,
        _SeedHost host,
      })
    >
    buildFor(WidgetTester tester, TargetPlatform platform) async {
      final webViews = _installWebViews();
      final preview = TerminalPortPreviewController(
        TerminalPortPreview(
          port: 5173,
          terminalBaseUri: Uri.parse('https://owui.test/api/v1/terminals/t1'),
          openSession: () async =>
              const TerminalBrowserSession(id: 'sid', token: 'tok'),
          proxyCookies: const {'CF_Authorization': 'cf'},
        ),
      );
      addTearDown(preview.dispose);
      await preview.start();
      final host = _SeedHost(preview);
      debugDefaultTargetPlatformOverride = platform;
      try {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Builder(
              builder: (context) => buildTerminalPreviewWebView(context, host),
            ),
          ),
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
      return (params: webViews.built.single, host: host);
    }

    testWidgets('go into a private store before the first page (iOS)', (
      tester,
    ) async {
      final (:params, :host) = await buildFor(tester, TargetPlatform.iOS);
      final controller = _MockWebViewController();

      expect(params.initialUrlRequest, isNull);
      expect(params.initialData!.baseUrl, WebUri('https://owui.test/'));
      expect(params.initialData!.data, contains('CF_Authorization=cf'));
      expect(params.initialData!.data, contains('location.replace('));

      // The app's own page is none of the preview's: let through, and not
      // reported as one of its loads.
      final seedUrl = WebUri('https://owui.test/');
      expect(
        await params.shouldOverrideUrlLoading!(
          controller,
          NavigationAction(
            request: URLRequest(url: seedUrl),
            isForMainFrame: true,
          ),
        ),
        NavigationActionPolicy.ALLOW,
      );
      params.onLoadStart!(controller, seedUrl);
      expect(host.navigated, isEmpty);
      expect(host.started, isEmpty);

      // The page it goes on to is the preview's again.
      final first = WebUri(
        'https://owui.test/api/v1/terminals/t1/browser/view/sid/tok/'
        'frame/http/localhost%3A5173/',
      );
      params.onLoadStart!(controller, first);
      expect(host.started, [first.uriValue]);

      // From then on the server's root is decided on like any page.
      await params.shouldOverrideUrlLoading!(
        controller,
        NavigationAction(request: URLRequest(url: seedUrl), isForMainFrame: true),
      );
      params.onLoadStart!(controller, seedUrl);
      expect(host.navigated, [seedUrl.uriValue]);
      expect(host.started, [first.uriValue, seedUrl.uriValue]);
    });

    testWidgets('are left alone where the store is shared (Android)', (
      tester,
    ) async {
      final (:params, host: _) = await buildFor(tester, TargetPlatform.android);

      expect(params.initialData, isNull);
      expect(
        params.initialUrlRequest!.url,
        WebUri(
          'https://owui.test/api/v1/terminals/t1/browser/view/sid/tok/'
          'frame/http/localhost%3A5173/',
        ),
      );
    });
  });

  test('ports open in the app\'s preview where it has a web view', () async {
    debugIsWebViewSupportedOverride = true;
    addTearDown(() => debugIsWebViewSupportedOverride = null);
    final shown = <TerminalPortPreview>[];
    final gateway = DefaultTerminalBrowserPlatformGateway(
      showPreview: (preview) async {
        shown.add(preview);
        return true;
      },
    );
    final target = preview();

    expect(await gateway.openPort(target), isTrue);
    expect(shown, [target]);
  });
}

class _MockWebViewController extends Mock implements InAppWebViewController {}

/// Plays the web view plugin: records each web view built.
final class _WebViews extends InAppWebViewPlatform {
  final built = <PlatformInAppWebViewWidgetCreationParams>[];

  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) {
    built.add(params);
    return _WebView(params);
  }
}

final class _WebView extends PlatformInAppWebViewWidget {
  _WebView(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();

  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      throw UnimplementedError();

  @override
  void dispose() {}
}

/// Stands in for the web view plugin until the test ends.
_WebViews _installWebViews() {
  final previous = InAppWebViewPlatform.instance;
  final webViews = _WebViews();
  InAppWebViewPlatform.instance = webViews;
  addTearDown(() {
    if (previous != null) InAppWebViewPlatform.instance = previous;
  });
  return webViews;
}

/// Records what the web view reports of the preview's own pages.
final class _SeedHost implements TerminalPreviewWebViewHost {
  _SeedHost(this.preview);

  @override
  final TerminalPortPreviewController preview;
  final started = <Uri?>[];
  final navigated = <Uri>[];

  @override
  void attach(InAppWebViewController controller) {}

  @override
  void loadingChanged({required bool loading}) {}

  @override
  void loadStarted(Uri? page) => started.add(page);

  @override
  void historyChanged({required bool canGoBack, required bool canGoForward}) {}

  @override
  void loadFailed() {}

  @override
  Future<NavigationActionPolicy> navigate(
    Uri target, {
    required bool history,
    bool userActivated = false,
    bool linkActivated = false,
  }) async {
    navigated.add(target);
    return NavigationActionPolicy.ALLOW;
  }
}

final class _RecordingHost implements TerminalPreviewWebViewHost {
  final calls = <({bool history, bool userActivated, bool linkActivated})>[];

  @override
  Future<NavigationActionPolicy> navigate(
    Uri target, {
    required bool history,
    bool userActivated = false,
    bool linkActivated = false,
  }) async {
    calls.add((
      history: history,
      userActivated: userActivated,
      linkActivated: linkActivated,
    ));
    return NavigationActionPolicy.CANCEL;
  }

  @override
  Object? noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
