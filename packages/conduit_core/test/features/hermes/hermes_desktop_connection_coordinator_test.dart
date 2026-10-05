import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_bridge.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_connection_coordinator.dart';
import 'package:conduit_core/ports/external_url_port.dart';
import 'package:test/test.dart';

void main() {
  test(
    'first-time native sign-in opens the browser and saves tokens',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
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
          default:
            request.response.statusCode = 404;
        }
        await request.response.close();
      });
      final browser = _CallbackBrowser();
      final saved = <HermesDesktopCredentials>[];
      final coordinator = HermesDesktopConnectionCoordinator(
        openExternalUrl: browser,
      );

      await coordinator.signInNative(
        HermesConfig(
          enabled: true,
          baseUrl: 'http://127.0.0.1:${server.port}',
          mode: HermesBackendMode.desktopGateway,
          desktopAuthKind: HermesDesktopAuthKind.nativePkce,
        ),
        onCredentialsChanged: (credentials) async => saved.add(credentials),
      );

      check(browser.opened.single.path).equals('/auth/native/authorize');
      check(saved.single.nativeTokens?.accessToken).equals('access');
      check(saved.single.nativeTokens?.refreshToken).equals('refresh');
    },
  );

  test(
    'first-time dashboard profile loading uses and closes the host bridge',
    () async {
      final bridge = _ProfileBridge();
      final coordinator = HermesDesktopConnectionCoordinator(
        dashboardBridgeFactory: ({required root, required accessHeaders}) =>
            bridge,
      );

      final profiles = await coordinator.profiles(
        const HermesConfig(
          enabled: true,
          baseUrl: 'https://hermes.example',
          mode: HermesBackendMode.desktopGateway,
          desktopAuthKind: HermesDesktopAuthKind.dashboardCookie,
        ),
      );

      check(profiles).deepEquals(['default', 'work']);
      check(bridge.closed).isTrue();
    },
  );
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

  @override
  Future<({int status, String body})> request(
    String method,
    Uri url, {
    String? body,
  }) async => (
    status: 200,
    body: jsonEncode({
      'profiles': [
        {'name': 'default'},
        {'name': 'work'},
      ],
    }),
  );

  @override
  Future<void> reload() async {}

  @override
  Future<void> close() async => closed = true;
}
