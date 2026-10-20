import 'package:checks/checks.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_bridge.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:test/test.dart';

final class _FakeBridge implements HermesDashboardBridge {
  final List<Uri> requests = [];

  @override
  Future<({int status, String body})> request(
    String method,
    Uri url, {
    String? body,
  }) async {
    requests.add(url);
    return (status: 200, body: '{"profiles":[{"name":"default"}]}');
  }

  @override
  Future<void> reload() async {}

  @override
  Future<void> close() async {}
}

void main() {
  test('the dashboard bridge takes the headers of the service that asks '
      'for it', () async {
    final opened = <({Uri root, Map<String, String> accessHeaders})>[];
    final bridge = _FakeBridge();
    final service = HermesDesktopApiService(
      config: HermesConfig(
        enabled: true,
        baseUrl: 'https://hermes-a.example/agent',
        mode: HermesBackendMode.desktopGateway,
        desktopAuthKind: HermesDesktopAuthKind.dashboardCookie,
        desktopCredentials: HermesDesktopCredentials(
          accessHeaders: const {'CF-Access-Client-Id': 'a-id'},
        ),
      ),
      // The host's factory gets root and headers from this service's own
      // configuration, not from whatever server the host holds now.
      dashboardBridgeFactory: ({required root, required accessHeaders}) {
        opened.add((root: root, accessHeaders: accessHeaders));
        return bridge;
      },
    );
    addTearDown(service.close);

    check(await service.listProfiles()).deepEquals(['default']);

    check(opened).length.equals(1);
    check(opened.single.root.toString())
        .equals('https://hermes-a.example/agent');
    check(opened.single.accessHeaders)
        .deepEquals({'CF-Access-Client-Id': 'a-id'});
    check(bridge.requests.single.host).equals('hermes-a.example');
  });
}
