import 'package:checks/checks.dart';
import 'package:conduit_core/features/terminal/models/terminal_models.dart';
import 'package:conduit_core/features/terminal/services/terminal_service.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:test/test.dart';

void main() {
  TerminalService serviceWith(Map<String, String> headers) {
    final api = ApiService(
      serverConfig: ServerConfig(
        id: 's',
        name: 'S',
        url: 'https://owui.test',
        customHeaders: headers,
      ),
      workerManager: WorkerManager(),
    );
    addTearDown(api.dispose);
    return TerminalService(api);
  }

  final system = TerminalServerInfo(
    kind: TerminalServerKind.system,
    selectionId: 'system:primary',
    baseUrl: Uri.parse('https://owui.test/api/v1/terminals/t1'),
  );
  final direct = TerminalServerInfo(
    kind: TerminalServerKind.direct,
    selectionId: 'https://direct.test',
    baseUrl: Uri.parse('https://direct.test'),
  );

  test("an Open WebUI terminal gets the sign-in proxy's cookies alone", () {
    final service = serviceWith({
      'cookie':
          'CF_Authorization=cf; token=jwt; oauth_session_id=o; '
          'oauth_id_token=i; owui-session=s; mfa_challenge=m',
      'Cookie': '_oauth2_proxy=p',
      'X-Other': 'kept out',
    });

    // Open WebUI's own cookies, its account token among them, stay out.
    check(service.proxyCookiesForServer(system)).deepEquals({
      'CF_Authorization': 'cf',
      '_oauth2_proxy': 'p',
    });
  });

  test('a direct terminal gets none', () {
    final service = serviceWith({'Cookie': 'CF_Authorization=cf'});

    check(service.proxyCookiesForServer(direct)).isEmpty();
  });

  test('a server without a sign-in proxy gives none', () {
    check(serviceWith(const {}).proxyCookiesForServer(system)).isEmpty();
  });
}
