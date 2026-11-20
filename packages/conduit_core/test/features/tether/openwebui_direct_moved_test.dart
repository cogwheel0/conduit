import 'package:checks/checks.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

const _server = ServerConfig(
  id: 'server-1',
  name: 'Home server',
  url: 'https://owui.example',
);

final class _Config extends BackendConfigNotifier {
  _Config(this.config);

  final BackendConfig config;

  @override
  Future<BackendConfig?> build() async => config;
}

void main() {
  Future<bool> moved(BackendConfig config) async {
    final api = ApiService(serverConfig: _server, workerManager: WorkerManager());
    addTearDown(api.dispose);
    final container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(api),
        isAuthenticatedProvider2.overrideWithValue(true),
        backendConfigProvider.overrideWith(() => _Config(config)),
      ],
    );
    addTearDown(container.dispose);
    await container.read(backendConfigProvider.future);
    return container.read(openWebUiDirectConnectionsMovedToTetherProvider);
  }

  test('a server says it moved direct connections to Tether from 0.13.4', () async {
    check(
      await moved(const BackendConfig(serverId: 'server-1', version: '0.13.4')),
    ).isTrue();
    check(
      await moved(const BackendConfig(serverId: 'server-1', version: '0.13.3')),
    ).isFalse();
    check(await moved(const BackendConfig(serverId: 'server-1'))).isFalse();
    // Another server's cached config says nothing about this one.
    check(
      await moved(const BackendConfig(serverId: 'server-2', version: '0.13.4')),
    ).isFalse();
  });
}
