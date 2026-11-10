import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/features/hermes/views/hermes_mcp_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/platform/flutter_key_value_store.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_transport.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final class _MockWebSocketChannel extends Mock implements WebSocketChannel {}

final class _MockWebSocketSink extends Mock implements WebSocketSink {}

/// A Desktop Gateway with its dashboard: the gateway answers the MCP RPCs,
/// the dashboard its catalog ([dashboardCatalog], or a 404 when null) and
/// its install. Every RPC and install is recorded.
final class _Hermes implements HttpClientAdapter {
  _Hermes({this.dashboardCatalog, this.gatewayCatalog = const []}) {
    when(() => channel.ready).thenAnswer((_) async {});
    when(() => channel.stream).thenAnswer((_) {
      scheduleMicrotask(
        () => incoming.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {'type': 'gateway.ready', 'payload': {}},
          }),
        ),
      );
      return incoming.stream;
    });
    when(() => channel.sink).thenReturn(sink);
    when(() => sink.close()).thenAnswer((_) async {});
    when(() => sink.add(any())).thenAnswer((invocation) {
      final frame = Map<String, dynamic>.from(
        jsonDecode(invocation.positionalArguments.single as String) as Map,
      );
      final id = frame['id'];
      final method = frame['method'];
      if (id == null || method is! String) return;
      final params = Map<String, dynamic>.from(
        (frame['params'] as Map?) ?? const {},
      );
      rpcs.add((method, params));
      if (method == 'mcp.servers.list' &&
          failListOnceAdded &&
          servers.isNotEmpty) {
        scheduleMicrotask(
          () => incoming.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': id,
              'error': {'code': -32000, 'message': 'Unavailable'},
            }),
          ),
        );
        return;
      }
      final result = switch (method) {
        'mcp.servers.list' => {'servers': servers},
        'mcp.catalog' => {'servers': gatewayCatalog},
        'mcp.servers.add' => _added(params['name'] as String),
        _ => <String, Object?>{},
      };
      scheduleMicrotask(
        () => incoming.add(
          jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}),
        ),
      );
    });
  }

  final List<Map<String, Object?>>? dashboardCatalog;
  final List<Map<String, Object?>> gatewayCatalog;
  final channel = _MockWebSocketChannel();
  final sink = _MockWebSocketSink();
  final incoming = StreamController<dynamic>.broadcast();
  final rpcs = <(String, Map<String, dynamic>)>[];
  final installs = <Object?>[];
  final servers = <Map<String, Object?>>[];

  /// Names whose added server signs in with OAuth.
  final oauth = <String>{};

  /// Names the dashboard installs in the background, listed only later.
  final background = <String>{};

  /// Names the dashboard installs, then answers with an error.
  final failAfterInstall = <String>{};

  /// Whether the server list cannot be read once a server is added.
  var failListOnceAdded = false;

  Map<String, Object?> _added(String name) {
    servers.add({
      'name': name,
      'transport': 'http',
      'url': 'https://tides.example/mcp',
      'auth': oauth.contains(name) ? 'oauth' : null,
      'enabled': true,
    });
    return {'ok': true, 'name': name};
  }

  List<Map<String, dynamic>> calls(String method) => [
    for (final (sent, params) in rpcs)
      if (sent == method) params,
  ];

  late final service = HermesDesktopApiService(
    config: HermesConfig(
      enabled: true,
      baseUrl: 'https://hermes.example',
      mode: HermesBackendMode.desktopGateway,
      desktopCredentials: HermesDesktopCredentials(legacyToken: 'token'),
    ),
    dio: Dio()..httpClientAdapter = this,
    rpc: HermesDesktopRpcClient(
      channelFactory: (_, _, {httpClient}) => channel,
    ),
  );

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final (status, body) = switch ('${options.method} ${options.uri.path}') {
      'GET /api/status' => (
        200,
        {'auth_required': false, 'gateway_running': true},
      ),
      'GET /api/mcp/catalog' when dashboardCatalog != null => (
        200,
        {'entries': dashboardCatalog},
      ),
      'POST /api/mcp/catalog/install' => () {
        installs.add(options.data);
        final name = (options.data as Map)['name'] as String;
        final later = background.contains(name);
        if (!later) _added(name);
        if (failAfterInstall.contains(name)) {
          return (500, {'detail': 'Install failed'});
        }
        return (200, {'ok': true, 'name': name, 'background': later});
      }(),
      _ => (404, {'detail': 'Not Found'}),
    };
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  Future<void> dispose() async {
    service.close();
    await incoming.close();
  }
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
  });
  tearDown(PreferencesStore.debugReset);

  Future<void> openCatalog(WidgetTester tester, _Hermes hermes) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [hermesApiServiceProvider.overrideWithValue(hermes.service)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const HermesMcpPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.auto_awesome_outlined));
    await tester.pumpAndSettle();
  }

  Future<void> answer(WidgetTester tester, String value, String button) async {
    await tester.enterText(find.byType(TextField), value);
    await tester.tap(find.widgetWithText(TextButton, button));
    await tester.pumpAndSettle();
  }

  // A catalog server was added with its name only, so one that needs keys
  // was refused, or added without them.
  testWidgets('asks for what a catalog server needs and adds it with that', (
    tester,
  ) async {
    final hermes = _Hermes(
      dashboardCatalog: [
        {
          'name': 'tide-tables',
          'description': 'Tide times for the coast',
          'installed': false,
          'auth_type': 'api_key',
          'required_env': [
            {
              'name': 'TIDE_API_KEY',
              'prompt': 'Tide tables API key',
              'required': true,
            },
            {
              'name': 'TIDE_REGION',
              'prompt': 'Coast region',
              'required': false,
            },
          ],
        },
      ],
    );
    await openCatalog(tester, hermes);
    expect(
      find.text(
        'Tide times for the coast\nAsks for TIDE_API_KEY, '
        'TIDE_REGION',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('tide-tables'));
    await tester.pumpAndSettle();

    expect(find.text('Tide tables API key'), findsOneWidget);
    // Required: asked again until it is given.
    await answer(tester, '  ', 'Next');
    expect(find.text('Tide tables API key'), findsOneWidget);
    await answer(tester, 'synthetic-tide-key', 'Next');
    expect(find.text('Coast region'), findsOneWidget);
    // Optional: left out when empty.
    await answer(tester, '', 'Add');

    check(hermes.installs).deepEquals([
      {
        'name': 'tide-tables',
        'enable': true,
        'env': {'TIDE_API_KEY': 'synthetic-tide-key'},
      },
    ]);
    check(hermes.calls('mcp.servers.add')).isEmpty();
    await hermes.dispose();
  });

  testWidgets('a value cancelled adds nothing', (tester) async {
    final hermes = _Hermes(
      dashboardCatalog: [
        {
          'name': 'tide-tables',
          'installed': false,
          'required_env': [
            {'name': 'TIDE_API_KEY', 'prompt': 'Tide tables API key'},
          ],
        },
      ],
    );
    await openCatalog(tester, hermes);
    await tester.tap(find.text('tide-tables'));
    await tester.pumpAndSettle();
    await answer(tester, 'synthetic-tide-key', 'Cancel');

    check(hermes.installs).isEmpty();
    check(hermes.calls('mcp.servers.add')).isEmpty();
    await hermes.dispose();
  });

  testWidgets('a server whose values this connection cannot send is not '
      'offered', (tester) async {
    // No dashboard: the gateway's catalog names what an entry needs, and its
    // add takes no values.
    final hermes = _Hermes(
      gatewayCatalog: [
        {
          'name': 'tide-tables',
          'installed': false,
          'requires': ['TIDE_API_KEY'],
        },
        {'name': 'tide-notes', 'installed': false, 'requires': <String>[]},
      ],
    );
    await openCatalog(tester, hermes);
    expect(
      find.textContaining('which this connection cannot send'),
      findsOneWidget,
    );
    await tester.tap(find.text('tide-tables'));
    await tester.pumpAndSettle();
    check(hermes.calls('mcp.servers.add')).isEmpty();

    await tester.tap(find.text('tide-notes'));
    await tester.pumpAndSettle();
    check(
      hermes.calls('mcp.servers.add').map((it) => (it['name'], it['preset'])),
    ).deepEquals([('tide-notes', 'tide-notes')]);
    check(hermes.installs).isEmpty();
    await hermes.dispose();
  });

  // Added through the gateway, an entry skipped the setup the dashboard's
  // install runs for it.
  testWidgets('an entry from the dashboard is installed by it', (tester) async {
    final hermes = _Hermes(
      dashboardCatalog: [
        {'name': 'tide-notes', 'installed': false, 'required_env': <Object?>[]},
      ],
    );
    await openCatalog(tester, hermes);
    await tester.tap(find.text('tide-notes'));
    await tester.pumpAndSettle();

    check(hermes.installs).deepEquals([
      {'name': 'tide-notes', 'enable': true, 'env': <String, String>{}},
    ]);
    check(hermes.calls('mcp.servers.add')).isEmpty();
    await hermes.dispose();
  });

  // A failure after the install left the list without the server, so a
  // retry asked for every value again.
  testWidgets('the list shows a server added before a failure', (tester) async {
    final hermes = _Hermes(
      dashboardCatalog: [
        {'name': 'tide-notes', 'installed': false, 'required_env': <Object?>[]},
      ],
    )..failAfterInstall.add('tide-notes');
    await openCatalog(tester, hermes);
    await tester.tap(find.text('tide-notes'));
    await tester.pumpAndSettle();

    expect(find.text('Hermes MCP action failed.'), findsOneWidget);
    expect(find.text('tide-notes'), findsOneWidget);
    expect(find.text('No MCP servers configured.'), findsNothing);
    await hermes.dispose();
  });

  // With the list unreadable after the add, a server that signs in with
  // OAuth was left without signing in, and nothing said so.
  testWidgets('a list that cannot be read still goes on to sign in', (
    tester,
  ) async {
    final hermes = _Hermes(
      dashboardCatalog: [
        {
          'name': 'tide-calendar',
          'installed': false,
          'auth_type': 'oauth',
          'required_env': <Object?>[],
        },
      ],
    )..failListOnceAdded = true;
    await openCatalog(tester, hermes);
    await tester.tap(find.text('tide-calendar'));
    await tester.pumpAndSettle();

    check(hermes.calls('mcp.servers.oauth.start').map((it) => it['name']))
        .deepEquals(['tide-calendar']);
    await hermes.dispose();
  });

  testWidgets('one still installing says so, and when to sign in', (
    tester,
  ) async {
    final hermes =
        _Hermes(
            dashboardCatalog: [
              {
                'name': 'tide-calendar',
                'installed': false,
                'auth_type': 'oauth',
                'required_env': <Object?>[],
              },
            ],
          )
          ..oauth.add('tide-calendar')
          ..background.add('tide-calendar');
    await openCatalog(tester, hermes);
    await tester.tap(find.text('tide-calendar'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining(
        'Hermes is still installing tide-calendar. Once it '
        'is listed, sign in with Authenticate',
      ),
      findsOneWidget,
    );
    check(hermes.calls('mcp.servers.oauth.start')).isEmpty();
    await hermes.dispose();
  });

  testWidgets('a server that signs in with OAuth goes on to sign in', (
    tester,
  ) async {
    final hermes = _Hermes(
      dashboardCatalog: [
        {
          'name': 'tide-calendar',
          'installed': false,
          'auth_type': 'oauth',
          'required_env': <Object?>[],
        },
      ],
    )..oauth.add('tide-calendar');
    await openCatalog(tester, hermes);
    await tester.tap(find.text('tide-calendar'));
    await tester.pumpAndSettle();

    check(hermes.calls('mcp.servers.oauth.start').map((it) => it['name']))
        .deepEquals(['tide-calendar']);
    // The fake starts no sign-in, so it does not finish: the server is still
    // added, and the page says where to sign in again.
    expect(
      find.text(
        "Added tide-calendar, but signing in didn't finish. Use "
        'Authenticate from its menu to try again.',
      ),
      findsOneWidget,
    );
    await hermes.dispose();
  });
}
