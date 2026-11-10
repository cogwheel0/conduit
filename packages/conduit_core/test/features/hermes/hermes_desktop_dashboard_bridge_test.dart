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
    bool urgent = false,
    bool Function()? beforeSend,
  }) async {
    requests.add(url);
    return (status: 200, body: '{"profiles":[{"name":"default"}]}');
  }

  @override
  Future<void> reload() async {}

  @override
  Future<void> close() async {}
}

/// Answers each `METHOD path` from [routes]; anything else is a 404.
final class _RoutesBridge implements HermesDashboardBridge {
  _RoutesBridge(this.routes);

  final Map<String, ({int status, String body})> routes;
  final List<String> requests = [];

  @override
  Future<({int status, String body})> request(
    String method,
    Uri url, {
    String? body,
    bool urgent = false,
    bool Function()? beforeSend,
  }) async {
    requests.add('$method $url');
    return routes['$method ${url.path}'] ??
        (status: 404, body: '{"detail":"Not Found"}');
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

  // A dashboard without the snapshot route (before Hermes 0.22.3) answers it
  // 404 and takes the plain delete. A fenced dashboard always has the route,
  // and refuses a delete without fences (409), so none is lost silently.
  test('a dashboard sign-in without snapshots takes the plain delete',
      () async {
    final bridge = _RoutesBridge({
      'DELETE /api/sessions/stored-1': (status: 200, body: '{"ok":true}'),
    });
    final service = HermesDesktopApiService(
      config: HermesConfig(
        enabled: true,
        baseUrl: 'https://hermes-a.example',
        mode: HermesBackendMode.desktopGateway,
        desktopAuthKind: HermesDesktopAuthKind.dashboardCookie,
      ),
      dashboardBridgeFactory: ({required root, required accessHeaders}) =>
          bridge,
    );
    addTearDown(service.close);

    await service.deleteSession('stored-1');

    check(bridge.requests).length.equals(2);
    check(bridge.requests.first)
        .startsWith('GET https://hermes-a.example/api/sessions/stored-1/'
            'mutation-snapshot');
    final delete = Uri.parse(bridge.requests.last.split(' ').last);
    check(bridge.requests.last).startsWith('DELETE ');
    check(
      delete.queryParameters.keys.toSet().intersection(const {
        'request_id',
        'expected_revision',
        'expected_generation',
      }),
    ).isEmpty();
  });
}
