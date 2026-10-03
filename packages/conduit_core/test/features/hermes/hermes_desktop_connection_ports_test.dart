import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_bridge.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_connection_coordinator.dart';
import 'package:conduit_core/ports/external_url_port.dart';
import 'package:test/test.dart';

/// Before Hermes is enabled (onboarding) there is no live service, so the
/// coordinator builds throwaway ones. They need the host's browser and
/// dashboard WebView bridge, or both sign-in paths fail with a generic
/// "could not connect" error.
void main() {
  late HttpServer gateway;
  late Uri baseUrl;

  setUp(() async {
    gateway = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = Uri.parse('http://127.0.0.1:${gateway.port}');
    unawaited(() async {
      await for (final request in gateway) {
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
            await utf8.decoder.bind(request).join();
            request.response.write(
              jsonEncode({
                'access_token': 'access',
                'refresh_token': 'refresh',
                'expires_at':
                    DateTime.now()
                        .toUtc()
                        .add(const Duration(minutes: 15))
                        .millisecondsSinceEpoch ~/
                    1000,
              }),
            );
          default:
            request.response.statusCode = 404;
        }
        await request.response.close();
      }
    }());
  });

  tearDown(() => gateway.close(force: true));

  HermesConfig nativeConfig() => HermesConfig(
    enabled: true,
    baseUrl: baseUrl.toString(),
    mode: HermesBackendMode.desktopGateway,
    desktopAuthKind: HermesDesktopAuthKind.nativePkce,
  );

  test('native sign-in opens the browser through the supplied port', () async {
    final opened = <Uri>[];
    final port = _CallbackBrowser(opened);
    final saved = <HermesDesktopCredentials>[];

    await HermesDesktopConnectionCoordinator(openExternalUrl: port)
        .signInNative(
          nativeConfig(),
          onCredentialsChanged: (credentials) async => saved.add(credentials),
        );

    check(opened).length.equals(1);
    check(opened.single.path).equals('/auth/native/authorize');
    check(opened.single.queryParameters['code_challenge_method'])
        .equals('S256');
    check(saved.single.nativeTokens?.accessToken).equals('access');
  });

  test('native sign-in without a browser port reports it cannot start', () {
    final signIn = const HermesDesktopConnectionCoordinator().signInNative(
      nativeConfig(),
      onCredentialsChanged: (_) async {},
    );
    check(signIn).throws<StateError>(
      (error) => error
          .has((e) => e.message, 'message')
          .contains('Could not open Hermes sign-in'),
    );
  });

  test('dashboard requests use the supplied WebView bridge', () async {
    final bridge = _FakeBridge();
    final profiles =
        await HermesDesktopConnectionCoordinator(
          dashboardBridgeFactory: ({required Uri root}) => bridge,
        ).profiles(
          HermesConfig(
            enabled: true,
            baseUrl: baseUrl.toString(),
            mode: HermesBackendMode.desktopGateway,
            desktopAuthKind: HermesDesktopAuthKind.dashboardCookie,
          ),
        );

    check(profiles).deepEquals(['default']);
    check(bridge.requests).deepEquals(['GET /api/profiles']);
  });

  test('dashboard requests without a bridge report the missing WebView', () {
    final profiles = const HermesDesktopConnectionCoordinator().profiles(
      HermesConfig(
        enabled: true,
        baseUrl: baseUrl.toString(),
        mode: HermesBackendMode.desktopGateway,
        desktopAuthKind: HermesDesktopAuthKind.dashboardCookie,
      ),
    );
    check(profiles).throws<StateError>(
      (error) => error.has((e) => e.message, 'message').contains('no WebView'),
    );
  });
}

/// Plays the user's browser: follows the authorize URL straight back to the
/// loopback callback the app is listening on.
final class _CallbackBrowser implements OpenExternalUrlPort {
  _CallbackBrowser(this.opened);

  final List<Uri> opened;

  @override
  Future<bool> open(Uri url) async {
    opened.add(url);
    final redirect = Uri.parse(url.queryParameters['redirect_uri']!).replace(
      queryParameters: {
        'code': 'one-time',
        'state': url.queryParameters['state']!,
      },
    );
    unawaited(() async {
      final client = HttpClient();
      try {
        final response = await (await client.getUrl(redirect)).close();
        await response.drain<void>();
      } finally {
        client.close(force: true);
      }
    }());
    return true;
  }
}

final class _FakeBridge implements HermesDashboardBridge {
  final requests = <String>[];

  @override
  Future<({int status, String body})> request(
    String method,
    Uri url, {
    String? body,
  }) async {
    requests.add('$method ${url.path}');
    return (
      status: 200,
      body: jsonEncode({
        'profiles': [
          {'name': 'default'},
        ],
      }),
    );
  }

  @override
  Future<void> reload() async {}

  @override
  Future<void> close() async {}
}
