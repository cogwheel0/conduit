import 'package:checks/checks.dart';
import 'package:conduit/features/auth/views/connection_issue_page.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The app can move to another route while a proxy sign-in is open; the
  // renewed session is still the one the account was read on.
  test('a renewed proxy session belongs to the route it was signed in on', () {
    final registry = OpenWebUiRegistry(
      servers: [
        OpenWebUiServer(
          id: 's',
          name: 'Home',
          endpoints: [
            OpenWebUiEndpoint(id: 'lan', url: 'http://10.0.0.2:3000'),
            OpenWebUiEndpoint(
              id: 'proxy',
              url: 'https://chat.example.com',
              customHeaders: const {'X-Gate': 'g'},
            ),
          ],
        ),
      ],
      accounts: [OpenWebUiAccount(id: 'a', serverId: 's')],
    );
    final viaProxy = registry.project(
      'a',
      selectedEndpoints: const {'s': 'proxy'},
    )!;
    const movedToLan = {'s': 'lan'};

    final renewed = renewedProxyRouteId(
      registry,
      viaProxy,
      selection: movedToLan,
    );

    check(renewed).equals('proxy');
    // Where saving the renewed cookies files them.
    final saved = registry.mergeServerConfigs([
      viaProxy.copyWith(
        customHeaders: {...viaProxy.customHeaders, 'Cookie': 'session=2'},
      ),
    ], selectedEndpoints: movedToLan);
    check(saved.account('a')!.capturedHeaders.keys).deepEquals([renewed]);
  });
}
