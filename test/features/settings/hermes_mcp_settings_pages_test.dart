import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/features/settings/pages/hermes_mcp_settings_pages.dart';
import 'package:conduit/features/settings/pages/hermes_page_ids.dart';
import 'package:conduit/features/settings/settings_page_module.dart';
import 'package:conduit/features/settings/settings_pages.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/platform/flutter_key_value_store.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_transport.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final AppLocalizations _l10n = lookupAppLocalizations(const Locale('en'));

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

/// The MCP pages as Settings drives them.
final class _Rig {
  _Rig(this.tester, this.container);

  final WidgetTester tester;
  final ProviderContainer container;

  HermesMcpSettingsPages get module => container
      .read(settingsPageModulesProvider)
      .whereType<HermesMcpSettingsPages>()
      .single;

  NativeSheetDetailConfig page(String id) =>
      container.read(settingsPagesProvider)[id]!;

  List<NativeSheetItemConfig> rows(String id) => [
    ...page(id).items,
    for (final section in page(id).sections) ...section.items,
  ];

  Iterable<String> titles(String id) => rows(id).map((row) => row.title);

  Future<void> open(String id) async {
    if (container.read(settingsPagesProvider)[id] == null) {
      container.read(settingsPagesProvider.notifier).register([
        NativeSheetDetailConfig(id: id, title: ''),
      ]);
    }
    await settle(module.hydrate(id, _l10n));
  }

  Future<void> change(String id, [Object? value = true]) =>
      settle(module.handleChange(id, value, _l10n));

  Future<void> settle(Future<Object?> work) async {
    var done = false;
    unawaited(work.whenComplete(() => done = true));
    for (var i = 0; i < 500 && !done; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await work;
  }
}

String _entryPage(String name) =>
    '$hermesMcpCatalogEntryPagePrefix${Uri.encodeComponent(name)}';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
  });
  tearDown(PreferencesStore.debugReset);

  /// Opens the MCP page, then the catalog.
  Future<_Rig> openCatalog(WidgetTester tester, _Hermes hermes) async {
    final container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [hermesApiServiceProvider.overrideWithValue(hermes.service)],
    );
    addTearDown(container.dispose);
    final rig = _Rig(tester, container);
    await rig.open(hermesMcpPageId);
    await rig.open(hermesMcpCatalogPageId);
    return rig;
  }

  /// Opens [name]'s catalog page and adds it with [values].
  Future<void> add(
    _Rig rig,
    String name, [
    Map<String, String> values = const {},
  ]) async {
    await rig.open(_entryPage(name));
    for (final MapEntry(:key, :value) in values.entries) {
      await rig.change(hermesMcpRowId('catalog-credential', name, key), value);
    }
    await rig.change(hermesMcpRowId('catalog-add', name));
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
    final rig = await openCatalog(tester, hermes);
    check(rig.rows(hermesMcpCatalogPageId).single.subtitle).equals(
      'Tide times for the coast\n'
      '${_l10n.hermesMcpCatalogAsks('TIDE_API_KEY, TIDE_REGION')}',
    );
    await rig.open(_entryPage('tide-tables'));
    check(rig.titles(_entryPage('tide-tables')))
      ..contains('Tide tables API key')
      ..contains('Coast region');

    // Required: refused until it is given.
    await add(rig, 'tide-tables', {'TIDE_API_KEY': '  '});
    check(hermes.installs).isEmpty();
    check(rig.titles(_entryPage('tide-tables')))
        .contains(_l10n.hermesMcpFillRequired);

    // Optional: left out when empty.
    await rig.change(
      hermesMcpRowId('catalog-credential', 'tide-tables', 'TIDE_API_KEY'),
      'synthetic-tide-key',
    );
    await rig.change(hermesMcpRowId('catalog-add', 'tide-tables'));

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

  testWidgets('a page left before Add adds nothing, and forgets its values', (
    tester,
  ) async {
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
    final rig = await openCatalog(tester, hermes);
    await rig.open(_entryPage('tide-tables'));
    await rig.change(
      hermesMcpRowId('catalog-credential', 'tide-tables', 'TIDE_API_KEY'),
      'synthetic-tide-key',
    );
    rig.module.pageLeft(_entryPage('tide-tables'));
    await rig.change(hermesMcpRowId('catalog-add', 'tide-tables'));

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
    final rig = await openCatalog(tester, hermes);
    final tables = rig
        .rows(hermesMcpCatalogPageId)
        .singleWhere((row) => row.title == 'tide-tables');
    check(tables.subtitle).equals(_l10n.hermesMcpCatalogNeeds('TIDE_API_KEY'));
    check(tables.disabled).isTrue();

    await add(rig, 'tide-notes');
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
    final rig = await openCatalog(tester, hermes);
    await add(rig, 'tide-notes');

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
    final rig = await openCatalog(tester, hermes);
    await add(rig, 'tide-notes');

    check(rig.titles(_entryPage('tide-notes')))
        .contains(_l10n.hermesMcpActionFailed);
    check(rig.titles(hermesMcpPageId))
      ..contains('tide-notes')
      ..not((it) => it.contains(_l10n.hermesMcpNone));
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
    final rig = await openCatalog(tester, hermes);
    await add(rig, 'tide-calendar');

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
    final rig = await openCatalog(tester, hermes);
    await add(rig, 'tide-calendar');

    check(rig.page(hermesMcpPageId).announcement)
        .equals(_l10n.hermesMcpStillInstallingSignIn('tide-calendar'));
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
    final rig = await openCatalog(tester, hermes);
    await add(rig, 'tide-calendar');

    check(hermes.calls('mcp.servers.oauth.start').map((it) => it['name']))
        .deepEquals(['tide-calendar']);
    // The fake starts no sign-in, so it does not finish: the server is still
    // added, and the page says where to sign in again.
    check(rig.page(hermesMcpPageId).announcement)
        .equals(_l10n.hermesMcpAddedSignInUnfinished('tide-calendar'));
    await hermes.dispose();
  });

  testWidgets("another connection's page shows none of the last one's "
      'servers', (tester) async {
    final hermes = _Hermes();
    hermes.servers.add({
      'name': 'tide-notes',
      'transport': 'http',
      'url': 'https://tides.example/mcp',
      'enabled': true,
    });
    final active = NotifierProvider<_Active, String?>(_Active.new);
    final container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        hermesApiServiceProvider.overrideWithValue(hermes.service),
        hermesActiveConnectionIdProvider.overrideWith(
          (ref) => ref.watch(active),
        ),
      ],
    );
    addTearDown(container.dispose);
    final rig = _Rig(tester, container);
    await rig.open(hermesMcpPageId);
    check(rig.titles(hermesMcpPageId)).contains('tide-notes');

    // Another connection in use, whose list cannot be read.
    container.read(active.notifier).use('work');
    hermes.failListOnceAdded = true;
    await rig.open(hermesMcpPageId);

    check(rig.titles(hermesMcpPageId)).not((it) => it.contains('tide-notes'));
    await hermes.dispose();
  });

  testWidgets('a server added by hand is sent with what was typed, and the '
      'key is not kept', (tester) async {
    final hermes = _Hermes();
    final container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [hermesApiServiceProvider.overrideWithValue(hermes.service)],
    );
    addTearDown(container.dispose);
    final rig = _Rig(tester, container);
    await rig.open(hermesMcpPageId);
    await rig.open(hermesMcpAddPageId);

    await rig.change(hermesMcpRowId('add-name'), 'tide-notes');
    await rig.change(hermesMcpRowId('add-url'), 'https://tides.example/mcp');
    await rig.change(hermesMcpRowId('add-key'), 'synthetic-mcp-key');
    await rig.change(hermesMcpRowId('add'));

    final sent = hermes.calls('mcp.servers.add').single;
    check(sent['name']).equals('tide-notes');
    check(sent.toString())
      ..contains('https://tides.example/mcp')
      ..contains('synthetic-mcp-key');
    check(rig.titles(hermesMcpPageId)).contains('tide-notes');

    // Opened again, the form starts empty.
    await rig.open(hermesMcpAddPageId);
    await rig.change(hermesMcpRowId('add-name'), 'tide-more');
    await rig.change(hermesMcpRowId('add'));
    final calls = hermes.calls('mcp.servers.add');
    check(calls).length.equals(2);
    check(calls.last['name']).equals('tide-more');
    check(calls.last.toString()).not((it) => it.contains('synthetic-mcp-key'));
    await hermes.dispose();
  });
}

/// The Hermes connection in use, switched by a test.
final class _Active extends Notifier<String?> {
  @override
  String? build() => 'home';

  void use(String id) => state = id;
}
