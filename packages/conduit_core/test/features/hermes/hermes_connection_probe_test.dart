import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_connection_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_bridge.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// While Hermes is disabled (onboarding) there is no live service, so the
/// connection probe builds a throwaway one. It must get the host's dashboard
/// bridge, or dashboard-cookie sign-in is reported as unreachable.
void main() {
  test('probe reaches the dashboard through the host WebView bridge', () async {
    final gateway = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => gateway.close(force: true));
    unawaited(() async {
      await for (final request in gateway) {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'auth_required': true,
            'auth_flows': ['cookie'],
          }),
        );
        await request.response.close();
      }
    }());

    final bridge = _RecordingBridge();
    final container = ProviderContainer(
      overrides: [
        hermesConfigProvider.overrideWith(_DisabledHermesConfig.new),
        hostHermesDashboardBridgeFactoryProvider.overrideWith(
          (ref) =>
              ({required Uri root}) => bridge,
        ),
      ],
    );
    addTearDown(container.dispose);

    // The chat WebSocket has no server behind it, so the probe itself returns
    // false. What matters is that the ws-ticket request went out through the
    // bridge instead of failing with "no WebView".
    await container
        .read(hermesConnectionGatewayProvider)
        .probe(
          HermesConfig(
            enabled: true,
            baseUrl: 'http://127.0.0.1:${gateway.port}',
            mode: HermesBackendMode.desktopGateway,
            desktopAuthKind: HermesDesktopAuthKind.dashboardCookie,
          ),
        );

    check(bridge.requests).contains('POST /api/auth/ws-ticket');
  });
}

final class _DisabledHermesConfig extends HermesConfigController {
  @override
  HermesConfig build() => const HermesConfig(enabled: false);
}

final class _RecordingBridge implements HermesDashboardBridge {
  final requests = <String>[];

  @override
  Future<({int status, String body})> request(
    String method,
    Uri url, {
    String? body,
  }) async {
    requests.add('$method ${url.path}');
    return (status: 200, body: jsonEncode({'ticket': 'ticket'}));
  }

  @override
  Future<void> reload() async {}

  @override
  Future<void> close() async {}
}
