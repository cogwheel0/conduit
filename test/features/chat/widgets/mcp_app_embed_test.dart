import 'dart:async';
import 'dart:convert';

import 'package:conduit/features/chat/widgets/mcp_app_embed.dart';
import 'package:conduit/features/chat/widgets/chat_timeline_viewport.dart';
import 'package:conduit/features/direct_connections/widgets/direct_mcp_app_view.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/features/mcp_apps/mcp_app_host.dart';
import 'package:conduit_core/features/mcp_apps/openwebui_mcp_app.dart';
import 'package:conduit_core/features/mcp_apps/mcp_app_resource_cache.dart';
import 'package:conduit_core/database/models/chat_transcript_window.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _app = OpenWebUiMcpApp(
  serverId: 'maps',
  toolName: 'show_map',
  binding: 'b',
);

/// Refuses every app request as a server whose secret key changed would.
final class _RefusingApi extends ApiService {
  _RefusingApi()
    : super(
        serverConfig: const ServerConfig(
          id: 's',
          name: 'S',
          url: 'http://localhost:0',
        ),
        workerManager: WorkerManager(),
      );

  final requests = <String>[];

  @override
  Future<Map<String, dynamic>> runMcpAppRequest(
    OpenWebUiMcpApp app, {
    required String method,
    Map<String, dynamic> params = const <String, dynamic>{},
    CancelToken? cancelToken,
  }) async {
    requests.add(method);
    throw const McpAppRpcException('Invalid app binding. Run the tool again.');
  }
}

/// Serves the app's page, with [csp] as its policy, and runs the tools it
/// calls.
final class _ServingApi extends ApiService {
  _ServingApi({
    this.csp = "default-src 'none'",
    this.html = '<p>app</p>',
    String serverId = 's',
  }) : super(
         serverConfig: ServerConfig(
           id: serverId,
           name: 'S',
           url: 'http://localhost:0',
         ),
         workerManager: WorkerManager(),
       );

  final String? csp;
  String html;
  final requests =
      <
        ({String method, Map<String, dynamic> params, CancelToken? cancelToken})
      >[];

  /// While set, the page is sent only once it completes.
  Completer<void>? hold;
  bool _closed = false;

  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }

  @override
  Future<Map<String, dynamic>> runMcpAppRequest(
    OpenWebUiMcpApp app, {
    required String method,
    Map<String, dynamic> params = const <String, dynamic>{},
    CancelToken? cancelToken,
  }) async {
    requests.add((method: method, params: params, cancelToken: cancelToken));
    if (method == 'ui/resource') {
      await hold?.future;
      // As Dio's closed adapter refuses a request it had not sent yet.
      if (_closed) throw const McpAppRpcException('The app request failed.');
      return {
        'html': html,
        'csp': ?csp,
        'ui': const <String, dynamic>{},
        'tool': const {'name': 'show_map'},
      };
    }
    return {'content': const <Object?>[]};
  }
}

/// Plays the web view plugin: records each web view the embed builds.
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

/// The page's side of a web view: the bridge handler the embed registers,
/// and the scripts it runs to deliver messages.
final class _Page extends PlatformInAppWebViewController {
  _Page()
    : super.implementation(
        const PlatformInAppWebViewControllerCreationParams(id: 'mcp-app'),
      );

  final handlers = <String, Function>{};
  final delivered = <String>[];

  @override
  void addJavaScriptHandler({
    required String handlerName,
    required Function callback,
  }) => handlers[handlerName] = callback;

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async {
    delivered.add(source);
    return null;
  }
}

/// An app opened in the embed, its web view created as the plugin would.
final class _OpenApp {
  _OpenApp(this.webViews);

  final _WebViews webViews;
  final page = _Page();
  late final controller = InAppWebViewController.fromPlatform(platform: page);

  /// The web view as the embed built it last.
  PlatformInAppWebViewWidgetCreationParams get view => webViews.built.last;

  Uri get documentUrl => view.initialData!.baseUrl!.uriValue;

  Future<NavigationActionPolicy?> navigate(Uri url) async =>
      view.shouldOverrideUrlLoading!(
        controller,
        NavigationAction(
          request: URLRequest(url: WebUri(url.toString())),
          isForMainFrame: true,
          hasGesture: false,
        ),
      );

  /// Posts [message] from the page over the MCP Apps bridge.
  Future<Object?> post(Map<String, Object?> message) {
    final script = view.initialUserScripts!.first.source;
    final token = RegExp(r'const bridgeToken = "([0-9a-f]+)"')
        .firstMatch(script)!
        .group(1);
    final data = JavaScriptHandlerFunctionData(
      args: [token, jsonEncode(message)],
      isMainFrame: true,
      origin: WebUri(documentUrl.origin),
      requestUrl: WebUri(documentUrl.toString()),
    );
    // Called as the plugin calls it: a handler that takes any argument
    // counts as the older kind (a list of arguments) and is handed the bare
    // arguments.
    final handler = page.handlers.values.single;
    if (handler is dynamic Function(List<dynamic>)) {
      return Future<Object?>.value(handler(data.args));
    }
    return Future<Object?>.value((handler as JavaScriptHandlerFunction)(data));
  }
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

/// Opens the app and creates its web view, whose page has not loaded yet.
Future<_OpenApp> _openApp(WidgetTester tester, ApiService api) async {
  final webViews = _installWebViews();
  await tester.pumpWidget(_harness(api));
  await tester.pump();
  await tester.pump();
  final app = _OpenApp(webViews);
  app.view.onWebViewCreated!(app.controller);
  return app;
}

/// An app opened under a 400 pt stand-in for its web view at the top of
/// the chat, whose 600 pt viewport is the test screen's. Drags on the
/// stand-in go to the app's recognizer; each side counts the drags it wins.
final class _DragProbe {
  _DragProbe(this.app);

  final _OpenApp app;
  late final HorizontalDragGestureRecognizer recognizer;
  int appDrags = 0;
  int chatDrags = 0;

  static Future<_DragProbe> open(WidgetTester tester) async {
    final webViews = _installWebViews();
    _DragProbe? probe;
    await tester.pumpWidget(
      _harness(
        _ServingApi(),
        child: Column(
          children: [
            GestureDetector(
              onVerticalDragUpdate: (_) => probe?.chatDrags++,
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (event) => probe?.recognizer.addPointer(event),
                child: const SizedBox(width: 800, height: 400),
              ),
            ),
            const McpAppEmbed(app: _app, cacheId: 'message:tool-call'),
          ],
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final app = _OpenApp(webViews);
    app.view.onWebViewCreated!(app.controller);
    final opened = _DragProbe(app);
    opened.recognizer =
        app.view.gestureRecognizers!.single.constructor()
            as HorizontalDragGestureRecognizer;
    addTearDown(opened.recognizer.dispose);
    opened.recognizer
      ..onDown = (_) {}
      ..onStart = (_) => opened.appDrags++;
    return probe = opened;
  }
}

Widget _harness(
  ApiService api, {
  OpenWebUiMcpApp app = _app,
  Widget? child,
  String userId = 'invented-user',
  String? cacheId = 'message:tool-call',
}) => ProviderScope(
  overrides: [
    appDatabaseProvider.overrideWithValue(null),
    apiServiceProvider.overrideWithValue(api),
    currentUserProvider2.overrideWithValue(
      User(
        id: userId,
        username: 'invented',
        email: 'invented@example.com',
        role: 'user',
      ),
    ),
  ],
  child: MaterialApp(
    theme: AppTheme.light(TweakcnThemes.t3Chat),
    localizationsDelegates: conduitLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: SingleChildScrollView(
        child: child ?? McpAppEmbed(app: app, cacheId: cacheId),
      ),
    ),
  ),
);

void main() {
  test('the sealed web view keeps other web sessions on Android', () {
    // The plugin's Android incognito deletes every web view's cookies.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final android = directMcpAppWebViewSettings('https://a.mcp-app.invalid');
    expect(android.incognito, isFalse);
    expect(android.thirdPartyCookiesEnabled, isFalse);
    expect(android.domStorageEnabled, isFalse);

    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(
      directMcpAppWebViewSettings('https://a.mcp-app.invalid').incognito,
      isTrue,
    );
  });

  test("a script request by path is left to the page's security policy", () {
    const connect = ['https://api.example'];
    bool allowed(String url) => mcpAppScriptRequestAllowed(
      Uri.parse(url),
      connect,
      pageScheme: 'https',
    );

    // Resolved by the browser against a base the policy allows, then held
    // to connect-src there.
    expect(allowed('/data'), isTrue);
    expect(allowed('data.json'), isTrue);
    // Another host by scheme-relative address is still checked here.
    expect(allowed('//api.example/data'), isTrue);
    expect(allowed('//evil.example/data'), isFalse);
    expect(allowed('https://api.example/data'), isTrue);
    expect(allowed('https://evil.example/data'), isFalse);
    expect(
      mcpAppScriptRequestAllowed(null, connect, pageScheme: 'https'),
      isFalse,
    );
  });

  testWidgets('a fetch by path goes on, one to an undeclared host stops', (
    tester,
  ) async {
    final app = await _openApp(tester, _ServingApi());
    final hook = app.view.shouldInterceptFetchRequest!;

    final byPath = await hook(
      app.controller,
      FetchRequest(url: WebUri('/data')),
    );
    final elsewhere = await hook(
      app.controller,
      FetchRequest(url: WebUri('//evil.example/data')),
    );

    expect(byPath!.action, isNot(FetchRequestAction.ABORT));
    expect(elsewhere!.action, FetchRequestAction.ABORT);

    // Unparsable here, though the web view would drop the tab and go on.
    final unparsable = await hook(
      app.controller,
      FetchRequest(url: WebUri('//evil.example:8\t0/foo')),
    );
    expect(unparsable!.action, FetchRequestAction.ABORT);
  });

  test('the bridge takes only MCP Apps messages from the page', () {
    final script = mcpAppBridgeScript(
      bridgeName: 'bridge',
      bridgeToken: 'token',
      deliverName: 'deliver',
    );
    expect(script, contains("message.jsonrpc === '2.0'"));
    expect(script, contains('nativePostMessage(message, ...rest)'));
    expect(script, contains('writable: false'));
  });

  test("a form's submit reaches the app's handlers but loads no page", () {
    final script = mcpAppBridgeScript(
      bridgeName: 'bridge',
      bridgeToken: 'token',
      deliverName: 'deliver',
    );
    // The listener runs first; a cancelled submit stays cancelled.
    final submit = RegExp(
      r"addEventListener\('submit', \(event\) => \{([^}]*)\}, true\);",
    ).firstMatch(script)!.group(1)!;
    expect(submit.trim(), 'event.preventDefault();');
  });

  test("the tool prompt's buttons are in the user's language", () {
    final english = lookupAppLocalizations(const Locale('en'));
    for (final locale in AppLocalizations.supportedLocales) {
      if (locale.languageCode == 'en') continue;
      final l10n = lookupAppLocalizations(locale);
      expect(
        l10n.directMcpApprovalDeny,
        isNot(english.directMcpApprovalDeny),
        reason: '$locale',
      );
      expect(
        l10n.mcpAppToolCallAllow,
        isNot(english.mcpAppToolCallAllow),
        reason: '$locale',
      );
    }
  });

  testWidgets('an app the server sends no security policy for is not shown', (
    tester,
  ) async {
    final webViews = _installWebViews();
    await tester.pumpWidget(_harness(_ServingApi(csp: null)));

    await tester.pumpAndSettle();

    expect(
      find.text(
        'The app could not be loaded: '
        'The server sent no security policy for the app.',
      ),
      findsOneWidget,
    );
    expect(webViews.built, isEmpty);
  });

  testWidgets('an app page has a host of its own, with no shared parent', (
    tester,
  ) async {
    // Android keeps one cookie store for the whole app. The only parent
    // domain of the page's host is the top-level `.invalid`, so a cookie the
    // page sets cannot be read by another app's page.
    final app = await _openApp(tester, _ServingApi());

    expect(
      app.documentUrl.host,
      matches(RegExp(r'^mcp-app-[0-9a-f]{36}\.invalid$')),
    );
    expect(
      mcpAppDocumentUrl('ab12'),
      Uri.parse('https://mcp-app-ab12.invalid/index.html'),
    );
  });

  testWidgets('another app in the same place gets a page host of its own', (
    tester,
  ) async {
    // On Android one cookie store serves the whole app, so a later page on
    // the same host could read what the earlier one left.
    final api = _ServingApi();
    final first = await _openApp(tester, api);
    final firstHost = first.documentUrl.host;
    final firstToken = RegExp(r'const bridgeToken = "([0-9a-f]+)"')
        .firstMatch(first.view.initialUserScripts!.first.source)!
        .group(1);

    await tester.pumpWidget(
      _harness(
        api,
        app: const OpenWebUiMcpApp(
          serverId: 'maps',
          toolName: 'show_map',
          binding: 'other',
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final second = first.webViews.built.last;
    expect(first.webViews.built, hasLength(2));
    expect(second.initialData!.baseUrl!.uriValue.host, isNot(firstHost));
    expect(
      second.initialData!.baseUrl!.uriValue.host,
      matches(RegExp(r'^mcp-app-[0-9a-f]{36}\.invalid$')),
    );
    expect(
      second.initialUserScripts!.first.source,
      isNot(contains('const bridgeToken = "$firstToken"')),
    );
  });

  testWidgets("an app's own doctype stays first", (tester) async {
    // Before the host's tags it would be ignored, and the page laid out in
    // quirks mode.
    final app = await _openApp(
      tester,
      _ServingApi(html: '<!DOCTYPE html>\n<html><body>app</body></html>'),
    );
    final document = app.view.initialData!.data;

    expect(document, startsWith('<!DOCTYPE html><meta'));
    expect('<!DOCTYPE'.allMatches(document), hasLength(1));
    expect(document, contains('Content-Security-Policy'));
    expect(document, endsWith('\n<html><body>app</body></html>'));
  });

  testWidgets('comments before an app\'s doctype move with it', (tester) async {
    final app = await _openApp(
      tester,
      _ServingApi(
        html: '<!-- built by tool -->\n<!DOCTYPE html><html><body>app</body></html>',
      ),
    );
    final document = app.view.initialData!.data;

    expect(
      document,
      startsWith('<!-- built by tool -->\n<!DOCTYPE html><meta'),
    );
    expect('<!DOCTYPE'.allMatches(document), hasLength(1));
    expect(document, endsWith('<html><body>app</body></html>'));
  });

  testWidgets('an app without a doctype gets the host tags first', (
    tester,
  ) async {
    final app = await _openApp(tester, _ServingApi());

    expect(
      app.view.initialData!.data,
      startsWith('<meta http-equiv="X-DNS-Prefetch-Control"'),
    );
  });

  testWidgets('an app loads automatically when mounted', (tester) async {
    final api = _RefusingApi();
    await tester.pumpWidget(_harness(api));
    await tester.pumpAndSettle();

    expect(find.text('Open App'), findsNothing);
    expect(api.requests, ['ui/resource']);
    await tester.pump(const Duration(seconds: 31));
    expect(api.requests, ['ui/resource']);
  });

  testWidgets("a refused app says the server's reason and can be retried", (
    tester,
  ) async {
    final api = _RefusingApi();
    // Its row leaves and comes back without asking the server again.
    for (var mount = 0; mount < 3; mount++) {
      await tester.pumpWidget(_harness(api));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'The app could not be loaded: '
          'Invalid app binding. Run the tool again.',
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(_harness(api, child: const SizedBox()));
    }
    expect(api.requests, ['ui/resource']);

    await tester.pumpWidget(_harness(api));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(api.requests, ['ui/resource', 'ui/resource']);
  });

  testWidgets('a load cut short by scrolling away goes on only to be kept', (
    tester,
  ) async {
    final api = _ServingApi()..hold = Completer<void>();
    final webViews = _installWebViews();
    Future<void> mount({String? cacheId = 'message:tool-call'}) async {
      await tester.pumpWidget(_harness(api, cacheId: cacheId));
      await tester.pump();
      await tester.pump();
    }

    Future<void> unmount() =>
        tester.pumpWidget(_harness(api, child: const SizedBox()));

    // Outside a saved chat nothing keeps the page, so it stops with its row.
    await mount(cacheId: null);
    await unmount();
    expect(api.requests.single.cancelToken!.isCancelled, isTrue);

    await mount();
    await unmount();
    // Back while the first request is still on its way.
    await mount();
    await unmount();
    api.hold!.complete();
    await tester.pump();
    await mount();

    expect(api.requests.map((request) => request.method), [
      'ui/resource',
      'ui/resource',
    ]);
    expect(api.requests.last.cancelToken!.isCancelled, isFalse);
    expect(webViews.built.single.initialData!.data, contains('<p>app</p>'));
  });

  testWidgets('another version of the reply automatically loads its app', (
    tester,
  ) async {
    // Two answers calling the same tool share its binding.
    final api = _RefusingApi();
    await tester.pumpWidget(_harness(api));
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);

    await tester.pumpWidget(
      _harness(
        api,
        app: const OpenWebUiMcpApp(
          serverId: 'maps',
          toolName: 'show_map',
          binding: 'b',
          arguments: {'city': 'Bergen'},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Open App'), findsNothing);
    expect(find.text('Retry'), findsOneWidget);
    expect(api.requests, ['ui/resource', 'ui/resource']);
  });

  testWidgets('retry fetches repaired HTML when a cached app did not start', (
    tester,
  ) async {
    final api = _ServingApi();
    final app = await _openApp(tester, api);
    // iOS asks before loading the page, and lets it load once.
    expect(await app.navigate(app.documentUrl), NavigationActionPolicy.ALLOW);

    await tester.pump(const Duration(seconds: 31));
    expect(find.text('The app did not start.'), findsOneWidget);

    api.html = '<p>repaired app</p>';
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();

    expect(app.view.initialData!.data, contains('repaired app'));
    expect(api.requests.map((request) => request.method), [
      'ui/resource',
      'ui/resource',
    ]);
    expect(await app.navigate(app.documentUrl), NavigationActionPolicy.ALLOW);
  });

  testWidgets('revisiting uses the resource with a fresh isolated page', (
    tester,
  ) async {
    final api = _ServingApi();
    final app = await _openApp(tester, api);
    final firstOrigin = app.documentUrl;
    await tester.pumpWidget(_harness(api, child: const SizedBox()));
    await tester.pumpWidget(_harness(api));
    await tester.pump();
    await tester.pump();

    expect(api.requests.map((request) => request.method), ['ui/resource']);
    expect(app.documentUrl, isNot(firstOrigin));

    final secondOrigin = app.documentUrl;
    await tester.pumpWidget(
      _harness(
        api,
        app: const OpenWebUiMcpApp(
          serverId: 'maps',
          toolName: 'show_map',
          binding: 'b',
          arguments: {'city': 'Oslo'},
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(api.requests.map((request) => request.method), [
      'ui/resource',
      'ui/resource',
    ]);
    expect(app.documentUrl, isNot(secondOrigin));

    final otherAccount = _ServingApi(serverId: 'another-server');
    await tester.pumpWidget(_harness(otherAccount));
    await tester.pump();
    await tester.pump();
    expect(otherAccount.requests.map((request) => request.method), [
      'ui/resource',
    ]);
    expect(app.documentUrl, isNot(firstOrigin));
  });

  testWidgets('a new API client for the same account keeps the app open', (
    tester,
  ) async {
    final api = _ServingApi();
    final app = await _openApp(tester, api);
    await app.post({
      'jsonrpc': '2.0',
      'method': 'ui/notifications/initialized',
    });
    await tester.pump();
    final page = app.documentUrl;

    // A refreshed token rebuilds the client; the account stays the same.
    final refreshed = _ServingApi();
    await tester.pumpWidget(_harness(refreshed));
    await tester.pump();
    await tester.pump();

    // Reopening would load a new page under a new origin.
    expect(app.documentUrl, page);
    expect(api.requests.map((request) => request.method), ['ui/resource']);
    expect(refreshed.requests, isEmpty);

    // The app's own requests go through the current client.
    final call = app.post({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/call',
      'params': {'name': 'zoom', 'arguments': <String, Object?>{}},
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('Allow'));
    await tester.pumpAndSettle();
    await call;
    expect(refreshed.requests.map((request) => request.method), ['tools/call']);
  });

  testWidgets('a load the refreshed client closed is asked again, not failed', (
    tester,
  ) async {
    final webViews = _installWebViews();
    final stale = _ServingApi()..hold = Completer<void>();
    await tester.pumpWidget(_harness(stale));
    await tester.pump();
    await tester.pump();

    // A token refresh replaces the client while the page is on its way.
    final refreshed = _ServingApi();
    await tester.pumpWidget(_harness(refreshed));
    stale.dispose();
    stale.hold!.complete();
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey<String>('mcp-app-card')), findsNothing);
    expect(refreshed.requests.map((request) => request.method), [
      'ui/resource',
    ]);
    expect(webViews.built.single.initialData!.data, contains('<p>app</p>'));
  });

  testWidgets('size notifications expand long apps and shrink dynamically', (
    tester,
  ) async {
    final app = await _openApp(tester, _ServingApi());
    await app.post({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'ui/initialize',
      'params': {
        'protocolVersion': '2026-01-26',
        'appInfo': {'name': 'test', 'version': '1'},
        'appCapabilities': {},
      },
    });
    expect(app.page.delivered.join(), isNot(contains('maxHeight')));
    for (final height in [2000, 10000, 2500, 120]) {
      await app.post({
        'jsonrpc': '2.0',
        'method': 'ui/notifications/size-changed',
        'params': {'height': height},
      });
      await tester.pump();
      expect(
        tester
            .getSize(find.byKey(const ValueKey<String>('mcp-app-view')))
            .height,
        height,
      );
    }
  });

  for (final reverse in [false, true]) {
    for (final dragging in [false, true]) {
      for (final inside in [false, true]) {
        testWidgets(
          'app resize preserves the reader (reverse=$reverse, dragging=$dragging, inside=$inside)',
          (tester) async {
            final api = _ServingApi();
            final webViews = _installWebViews();
            final timeline = ChatTimelineViewportController();
            addTearDown(() async {
              await tester.pumpWidget(const SizedBox());
              timeline.dispose();
            });
            final ids = List.generate(20, (i) => 'message-$i');
            await tester.pumpWidget(
              _harness(
                api,
                child: SizedBox(
                  height: 600,
                  child: ChatTimelineViewport(
                    controller: timeline,
                    ownerGeneration: 1,
                    initialAnchor: reverse
                        ? const ChatScrollAnchor(
                            messageId: 'message-15',
                            offsetWithinMessage: 0,
                          )
                        : null,
                    messageIds: ids,
                    rowBuilder: (_, i) => Column(
                      children: [
                        if (i == 12 || i == 13)
                          McpAppEmbed(app: _app, cacheId: ids[i]),
                        SizedBox(height: 160, child: Text(ids[i])),
                      ],
                    ),
                    topContentInset: 0,
                    bottomPadding: 0,
                    horizontalPadding: 0,
                    cacheExtent: 1200,
                    physics: const ClampingScrollPhysics(),
                    maintainVisibleAnchor: true,
                    followLatest: false,
                    pinAutomatic: false,
                    onPointerDown: () {},
                    onUserDragStart: () {},
                    onUserDragEnd: () {},
                    onMetricsChanged: (_) {},
                    onPinEndSpaceChanged: (_) {},
                    onTrailingRefresh: () async {},
                    onNativeScrollToTop: () async {},
                  ),
                ),
              ),
            );
            await tester.pump();
            await tester.pump();
            final pages = <_OpenApp>[];
            Future<void> initializePages() async {
              for (final view in webViews.built.skip(pages.length).toList()) {
                final page = _OpenApp(_WebViews()..built.add(view));
                pages.add(page);
                page.view.onWebViewCreated!(page.controller);
                await page.post({
                  'jsonrpc': '2.0',
                  'method': 'ui/notifications/initialized',
                });
                if (inside) {
                  await page.post({
                    'jsonrpc': '2.0',
                    'method': 'ui/notifications/size-changed',
                    'params': {'height': 2000},
                  });
                }
              }
              await tester.pump();
            }

            await initializePages();
            final target = inside ? ids[13] : ids[14];
            final seek = timeline.jumpMessageToTop(target);
            await tester.pump();
            await initializePages();
            await initializePages();
            await tester.pumpAndSettle();
            await seek;
            if (inside) {
              final scroll = await tester.startGesture(const Offset(700, 300));
              await scroll.moveBy(const Offset(0, -140));
              await tester.pump();
              await scroll.up();
              await tester.pumpAndSettle();
              expect(timeline.rowRect(target)!.top, lessThan(0));
              expect(timeline.rowRect(target)!.bottom, greaterThan(600));
            }
            final gesture = dragging
                ? await tester.startGesture(const Offset(700, 300))
                : null;
            await gesture?.moveBy(const Offset(0, 30));
            await tester.pump();
            final before = timeline.rowRect(target)!.top;
            for (final app in pages) {
              await app.post({
                'jsonrpc': '2.0',
                'method': 'ui/notifications/size-changed',
                'params': {'height': 4000},
              });
            }
            await gesture?.moveBy(const Offset(0, 15));
            await tester.pump();
            expect(
              timeline.rowRect(target)?.top,
              closeTo(before + (dragging ? 15 : 0), 1),
            );
            await tester.pump();
            expect(
              timeline.rowRect(target)?.top,
              closeTo(before + (dragging ? 15 : 0), 1),
            );
            await gesture?.cancel();
          },
        );
      }
    }
  }

  testWidgets('cache keys hash the existing invocation identity', (
    tester,
  ) async {
    final api = _ServingApi();
    _installWebViews();
    await tester.pumpWidget(
      _harness(
        api,
        app: const OpenWebUiMcpApp(
          serverId: 'maps',
          toolName: 'show_map',
          binding: 'b',
          arguments: {'city': 'Invented harbor'},
          result: {'summary': 'Synthetic route'},
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final cache = ProviderScope.containerOf(
      tester.element(find.byType(McpAppEmbed)),
    ).read(mcpAppResourceCacheProvider);
    // Known SHA-256 of the original JSON identity, including input and result.
    expect(
      cache['7502bf804c126e44228a1afe02aa232aa582aba63fbf98937390dbfc85149c3e']
          ?.resource
          .html,
      '<p>app</p>',
    );
  });

  testWidgets('reopening reserves the last height before the new page loads', (
    tester,
  ) async {
    final api = _ServingApi();
    final app = await _openApp(tester, api);
    await app.post({
      'jsonrpc': '2.0',
      'method': 'ui/notifications/size-changed',
      'params': {'height': 10000},
    });
    await tester.pump();
    final firstOrigin = app.documentUrl;
    await tester.pumpWidget(_harness(api, child: const SizedBox()));
    await tester.pumpWidget(_harness(api));
    expect(tester.getSize(find.byType(McpAppEmbed)).height, 10000);
    await tester.pump();
    expect(tester.getSize(find.byType(McpAppEmbed)).height, 10000);
    expect(app.documentUrl, isNot(firstOrigin));
    expect(api.requests, hasLength(1));
  });

  testWidgets('identical invocations in different messages fetch fresh HTML', (
    tester,
  ) async {
    final api = _ServingApi(html: '<p>first version</p>');
    final app = await _openApp(tester, api);
    api.html = '<p>updated version</p>';
    await tester.pumpWidget(
      _harness(api, cacheId: 'another-message:tool-call'),
    );
    await tester.pump();
    await tester.pump();
    expect(api.requests, hasLength(2));
    expect(app.view.initialData!.data, contains('updated version'));
  });

  testWidgets('a revised tool result fetches fresh HTML for the same message', (
    tester,
  ) async {
    final api = _ServingApi(html: '<p>first version</p>');
    final app = await _openApp(tester, api);
    api.html = '<p>revised version</p>';
    await tester.pumpWidget(
      _harness(
        api,
        app: const OpenWebUiMcpApp(
          serverId: 'maps',
          toolName: 'show_map',
          binding: 'b',
          result: {'revision': 2},
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(api.requests, hasLength(2));
    expect(app.view.initialData!.data, contains('revised version'));
  });

  for (final method in [
    'ui/notifications/size-changed',
    'conduit/canvas-rects',
  ]) {
    testWidgets('canvases own pans while ordinary content scrolls ($method)', (
      tester,
    ) async {
      final probe = await _DragProbe.open(tester);
      await probe.app.post({
        'jsonrpc': '2.0',
        'method': method,
        'params': {
          'height': 2000,
          '_conduitCanvasRects': [
            [0, 0, 200, 400],
          ],
        },
      });
      await tester.pump();
      await tester.dragFrom(const Offset(100, 200), const Offset(0, -100));
      expect(probe.appDrags, 1);
      expect(probe.chatDrags, 0);
      await tester.dragFrom(const Offset(100, 200), const Offset(60, -100));
      expect(probe.appDrags, 2);
      expect(probe.chatDrags, 0);
      await tester.dragFrom(const Offset(300, 200), const Offset(0, -100));
      expect(probe.appDrags, 2);
      expect(probe.chatDrags, greaterThan(0));
      await tester.dragFrom(const Offset(300, 200), const Offset(100, 0));
      expect(probe.appDrags, 3);
    });
  }

  testWidgets('a canvas report over the message limit is dropped unread', (
    tester,
  ) async {
    final probe = await _DragProbe.open(tester);
    await probe.app.post({
      'jsonrpc': '2.0',
      'method': 'conduit/canvas-rects',
      'params': {
        '_conduitCanvasRects': [
          [0, 0, 200, 400],
        ],
        'pad': 'x' * kMcpAppMaxMessageBytes,
      },
    });

    await tester.dragFrom(const Offset(100, 200), const Offset(0, -100));
    expect(probe.appDrags, 0);
    expect(probe.chatDrags, greaterThan(0));
  });

  testWidgets('a region as tall as the chat leaves it vertical drags', (
    tester,
  ) async {
    final probe = await _DragProbe.open(tester);
    Future<void> reportRegion(double height) => probe.app.post({
      'jsonrpc': '2.0',
      'method': 'conduit/canvas-rects',
      'params': {
        '_conduitCanvasRects': [
          [0, 0, 800, height],
        ],
      },
    });

    // A wrapper around the whole app, as tall as the chat's viewport or more.
    for (final height in [600.0, 2000.0]) {
      await reportRegion(height);
      await tester.dragFrom(const Offset(100, 200), const Offset(0, -100));
      expect(probe.appDrags, 0);
      expect(probe.chatDrags, greaterThan(0));
    }
    probe.chatDrags = 0;
    await tester.dragFrom(const Offset(100, 200), const Offset(100, 0));
    expect(probe.appDrags, 1);

    // A map shorter than the chat keeps its vertical pans.
    await reportRegion(300);
    await tester.dragFrom(const Offset(100, 200), const Offset(0, -100));
    expect(probe.appDrags, 2);
    expect(probe.chatDrags, 0);
  });

  testWidgets('resize rounding noise and unrenderable heights are ignored', (
    tester,
  ) async {
    final app = await _openApp(tester, _ServingApi());
    Future<void> resize(Object height) async {
      await app.post({
        'jsonrpc': '2.0',
        'method': 'ui/notifications/size-changed',
        'params': {'height': height},
      });
      await tester.pump();
    }

    await resize(10000);
    for (final height in [10000.1, 9999.9, 0, -1, 1e300, '20000']) {
      await resize(height);
      expect(tester.getSize(find.byType(McpAppEmbed)).height, 10000);
    }
    await resize(50000);
    expect(tester.getSize(find.byType(McpAppEmbed)).height, 50000);
    await resize(2000);
    expect(tester.getSize(find.byType(McpAppEmbed)).height, 2000);
  });

  testWidgets('the resource cache is bounded and clears on session changes', (
    tester,
  ) async {
    final api = _ServingApi();
    _installWebViews();
    for (var i = 0; i < 33; i++) {
      await tester.pumpWidget(
        _harness(
          api,
          app: OpenWebUiMcpApp(
            serverId: 'maps',
            toolName: 'show_map',
            binding: '$i',
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }
    expect(api.requests, hasLength(33));
    await tester.pumpWidget(
      _harness(
        api,
        app: const OpenWebUiMcpApp(
          serverId: 'maps',
          toolName: 'show_map',
          binding: '0',
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(api.requests, hasLength(34));
    await tester.pumpWidget(
      _harness(
        api,
        app: const OpenWebUiMcpApp(
          serverId: 'maps',
          toolName: 'show_map',
          binding: '0',
        ),
        userId: 'another-user',
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(api.requests, hasLength(35));
  });

  testWidgets('on Android the loaded page cannot load itself again', (
    tester,
  ) async {
    final app = await _openApp(tester, _ServingApi());
    // Android starts the page without asking shouldOverrideUrlLoading.
    app.view.onLoadStart?.call(
      app.controller,
      WebUri(app.documentUrl.toString()),
    );

    expect(await app.navigate(app.documentUrl), NavigationActionPolicy.CANCEL);
  });

  testWidgets("the page cannot open Android's file picker", (tester) async {
    final app = await _openApp(tester, _ServingApi());

    expect(app.view.initialSettings?.useOnShowFileChooser, isTrue);
    final response = await app.view.onShowFileChooser?.call(
      app.controller,
      ShowFileChooserRequest(
        acceptTypes: const ['*/*'],
        isCaptureEnabled: false,
        mode: ShowFileChooserRequestMode.OPEN,
      ),
    );
    expect(response?.handledByClient, isTrue);
    expect(response?.filePaths, isNull);
  });

  testWidgets('a tool call shows every argument before it runs', (
    tester,
  ) async {
    final api = _ServingApi();
    final app = await _openApp(tester, api);
    await app.post({
      'jsonrpc': '2.0',
      'method': 'ui/notifications/initialized',
    });
    await tester.pumpAndSettle();

    // A long field first, and what matters after it.
    final arguments = {'note': 'x' * 3000, 'target': 'all-records'};
    final call = app.post({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/call',
      'params': {'name': 'delete', 'arguments': arguments},
    });
    await tester.pumpAndSettle();

    expect(
      find.textContaining(
        const JsonEncoder.withIndent('  ').convert(arguments),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Allow'));
    await tester.pumpAndSettle();
    await call;
    expect(api.requests.last.method, 'tools/call');
    expect(api.requests.last.params, {
      'name': 'delete',
      'arguments': arguments,
    });

    // A started app is told it is going, and is not waited for.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
  });
}
