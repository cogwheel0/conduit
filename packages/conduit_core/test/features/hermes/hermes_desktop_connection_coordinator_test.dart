import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_connection_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_bridge.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_connection_coordinator.dart';
import 'package:conduit_core/ports/external_url_port.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

void main() {
  test(
    'first-time native sign-in saves tokens and connects the gateway WebSocket',
    () async {
      final gateway = await _Gateway.start();
      addTearDown(gateway.close);
      final container = ProviderContainer(
        overrides: [hermesConfigProvider.overrideWith(_DisabledConfig.new)],
      );
      addTearDown(container.dispose);
      final browser = _CallbackBrowser();
      final saved = <HermesDesktopCredentials>[];
      final coordinator = HermesDesktopConnectionCoordinator(
        openExternalUrl: browser,
      );

      final draft = HermesConfig(
        enabled: false,
        baseUrl: gateway.baseUrl,
        mode: HermesBackendMode.desktopGateway,
        desktopAuthKind: HermesDesktopAuthKind.nativePkce,
      );
      await coordinator.signInNative(
        draft,
        onCredentialsChanged: (credentials) async => saved.add(credentials),
      );

      check(browser.opened.single.path).equals('/auth/native/authorize');
      check(saved.single.nativeTokens?.accessToken).equals('access');
      check(saved.single.nativeTokens?.refreshToken).equals('refresh');
      check(container.read(hermesApiServiceProvider)).isNull();
      check(
        await container
            .read(hermesConnectionGatewayProvider)
            .probe(draft.copyWith(desktopCredentials: saved.single)),
      ).isTrue();
      check(gateway.ticketAuthorizations).deepEquals(['Bearer access']);
      check(gateway.socketTickets).deepEquals(['native-ticket']);
      check(gateway.rpcMethods).deepEquals(['model.options']);
    },
  );

  test('first-time dashboard setup connects the gateway WebSocket', () async {
    final gateway = await _Gateway.start();
    addTearDown(gateway.close);
    final bridges = <_ProfileBridge>[];
    HermesDashboardBridge factory({
      required Uri root,
      required Map<String, String> accessHeaders,
    }) {
      final bridge = _ProfileBridge();
      bridges.add(bridge);
      return bridge;
    }

    final coordinator = HermesDesktopConnectionCoordinator(
      dashboardBridgeFactory: factory,
    );
    final container = ProviderContainer(
      overrides: [
        hermesConfigProvider.overrideWith(_DisabledConfig.new),
        hostHermesDashboardBridgeFactoryProvider.overrideWith((ref) => factory),
      ],
    );
    addTearDown(container.dispose);
    final draft = HermesConfig(
      enabled: false,
      baseUrl: gateway.baseUrl,
      mode: HermesBackendMode.desktopGateway,
      desktopAuthKind: HermesDesktopAuthKind.dashboardCookie,
    );

    final profiles = await coordinator.profiles(draft);

    check(profiles).deepEquals(['default', 'work']);
    check(bridges.single.closed).isTrue();
    check(container.read(hermesApiServiceProvider)).isNull();
    check(await container.read(hermesConnectionGatewayProvider).probe(draft))
        .isTrue();
    check(bridges.expand((bridge) => bridge.requests).toList())
        .deepEquals(['GET /api/profiles', 'POST /api/auth/ws-ticket']);
    check(gateway.socketTickets).deepEquals(['dashboard-ticket']);
    check(gateway.rpcMethods).deepEquals(['model.options']);
  });

  group('connection name suggestion', () {
    test('uses the Desktop profile title, else its name', () async {
      final gateway = await _Gateway.start(
        profiles: [
          {'name': 'default'},
          {
            'name': 'research',
            'ui_meta': {
              'hermes-bots': {'title': 'Research Bot'},
            },
          },
          {'name': 'plain'},
        ],
      );
      addTearDown(gateway.close);
      final container = ProviderContainer(
        overrides: [hermesConfigProvider.overrideWith(_DisabledConfig.new)],
      );
      addTearDown(container.dispose);
      final connection = container.read(hermesConnectionGatewayProvider);

      HermesConfig draft(String profile) => HermesConfig(
        baseUrl: gateway.baseUrl,
        mode: HermesBackendMode.desktopGateway,
        desktopAuthKind: HermesDesktopAuthKind.nativePkce,
        desktopProfile: profile,
        desktopCredentials: HermesDesktopCredentials(
          nativeTokens: HermesDesktopTokenSet(
            accessToken: 'access',
            refreshToken: 'refresh',
            expiresAt: DateTime.now().add(const Duration(hours: 1)),
          ),
        ),
      );

      check(
        await connection.suggestDisplayName(draft('research')),
      ).equals('Research Bot');
      check(await connection.suggestDisplayName(draft('plain'))).equals('plain');
      check(await connection.suggestDisplayName(draft('missing'))).isNull();
      check(gateway.rpcMethods).contains('profiles.list');
    });

    test('uses the first Responses model id', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path == '/v1/models') {
          check(
            request.headers.value(HttpHeaders.authorizationHeader),
          ).equals('Bearer key');
          request.response.write(
            jsonEncode({
              'object': 'list',
              'data': [
                {'id': 'my-agent', 'object': 'model'},
                {'id': 'alias', 'object': 'model'},
              ],
            }),
          );
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      });
      final container = ProviderContainer(
        overrides: [hermesConfigProvider.overrideWith(_DisabledConfig.new)],
      );
      addTearDown(container.dispose);

      check(
        await container
            .read(hermesConnectionGatewayProvider)
            .suggestDisplayName(
              HermesConfig(
                baseUrl: 'http://127.0.0.1:${server.port}/v1',
                apiKey: 'key',
              ),
            ),
      ).equals('my-agent');
    });
  });
}

final class _DisabledConfig extends HermesConfigController {
  @override
  HermesConfig build() => const HermesConfig(enabled: false);
}

final class _Gateway {
  _Gateway(this.server, {this.profiles = const []});

  final HttpServer server;

  /// Rows `profiles.list` answers with.
  final List<Map<String, Object?>> profiles;
  final sockets = <WebSocket>[];
  final ticketAuthorizations = <String?>[];
  final socketTickets = <String?>[];
  final rpcMethods = <String>[];
  String get baseUrl => 'http://127.0.0.1:${server.port}';

  static Future<_Gateway> start({
    List<Map<String, Object?>> profiles = const [],
  }) async {
    final gateway = _Gateway(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      profiles: profiles,
    );
    gateway.server.listen(gateway.handle);
    return gateway;
  }

  Future<void> handle(HttpRequest request) async {
    if (request.uri.path == '/api/ws' &&
        WebSocketTransformer.isUpgradeRequest(request)) {
      final ticket = request.uri.queryParameters['ticket'];
      socketTickets.add(ticket);
      if (ticket != 'native-ticket' && ticket != 'dashboard-ticket') {
        request.response.statusCode = HttpStatus.unauthorized;
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {'type': 'gateway.ready', 'payload': {}},
        }),
      );
      socket.listen((raw) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        rpcMethods.add(frame['method'] as String);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': frame['id'],
            'result': frame['method'] == 'profiles.list'
                ? {'profiles': profiles}
                : {},
          }),
        );
      });
      return;
    }
    request.response.headers.contentType = ContentType.json;
    switch (request.uri.path) {
      case '/api/status':
        request.response.write(
          jsonEncode({
            'auth_required': true,
            'auth_flows': ['cookie', 'native_pkce'],
          }),
        );
      case '/auth/native/token':
        await request.drain<void>();
        request.response.write(
          jsonEncode({
            'access_token': 'access',
            'refresh_token': 'refresh',
            'expires_at':
                DateTime.now()
                    .add(const Duration(minutes: 15))
                    .millisecondsSinceEpoch ~/
                1000,
          }),
        );
      case '/api/auth/ws-ticket':
        final authorization = request.headers.value(
          HttpHeaders.authorizationHeader,
        );
        ticketAuthorizations.add(authorization);
        if (request.method == 'POST' && authorization == 'Bearer access') {
          request.response.write(jsonEncode({'ticket': 'native-ticket'}));
        } else {
          request.response.statusCode = HttpStatus.unauthorized;
        }
      default:
        request.response.statusCode = HttpStatus.notFound;
    }
    await request.response.close();
  }

  Future<void> close() async {
    for (final socket in sockets) {
      await socket.close();
    }
    await server.close(force: true);
  }
}

final class _CallbackBrowser implements OpenExternalUrlPort {
  final opened = <Uri>[];

  @override
  Future<bool> open(Uri url) async {
    opened.add(url);
    final callback = Uri.parse(url.queryParameters['redirect_uri']!).replace(
      queryParameters: {
        'code': 'one-time-code',
        'state': url.queryParameters['state']!,
      },
    );
    unawaited(() async {
      final client = HttpClient();
      try {
        final response = await (await client.getUrl(callback)).close();
        await response.drain<void>();
      } finally {
        client.close(force: true);
      }
    }());
    return true;
  }
}

final class _ProfileBridge implements HermesDashboardBridge {
  bool closed = false;
  final requests = <String>[];

  @override
  Future<({int status, String body})> request(
    String method,
    Uri url, {
    String? body,
  }) async {
    requests.add('$method ${url.path}');
    if (method == 'POST' && url.path == '/api/auth/ws-ticket') {
      return (status: 200, body: jsonEncode({'ticket': 'dashboard-ticket'}));
    }
    if (method != 'GET' || url.path != '/api/profiles') {
      return (status: 404, body: '{}');
    }
    return (
      status: 200,
      body: jsonEncode({
        'profiles': [
          {'name': 'default'},
          {'name': 'work'},
        ],
      }),
    );
  }

  @override
  Future<void> reload() async {}

  @override
  Future<void> close() async => closed = true;
}
