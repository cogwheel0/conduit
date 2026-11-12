import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

const _server = ServerConfig(
  id: 'account',
  name: 'Home',
  url: 'https://owui.example',
);

const _cached = BackendConfig(serverId: 'account');

final class _Storage implements OptimizedStorageService {
  @override
  Future<BackendConfig?> getLocalBackendConfig() async => _cached;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

void main() {
  test('a refresh behind the cached config that fails raises nothing outside '
      'the provider', () async {
    final workerManager = WorkerManager();
    final api = ApiService(serverConfig: _server, workerManager: workerManager);
    final escaped = <Object>[];
    late ProviderContainer container;
    // The container reports to the zone it was made in, as a host's does.
    runZonedGuarded(() {
      container = ProviderContainer(
        overrides: [
          optimizedStorageServiceProvider.overrideWithValue(_Storage()),
          apiServiceProvider.overrideWithValue(api),
          // The stored server list cannot be read: the refresh's first
          // step fails, with nobody waiting on it.
          activeServerProvider.overrideWith(
            (ref) => Future<ServerConfig?>.error(StateError('unreadable')),
          ),
        ],
        retry: (_, _) => null,
      );
    }, (error, _) => escaped.add(error));
    addTearDown(() {
      container.dispose();
      api.dispose();
      workerManager.dispose();
    });
    container.listen(backendConfigProvider, (_, _) {});

    final config = await container.read(backendConfigProvider.future);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    check(config)
        .isNotNull()
        .has((c) => c.serverId, 'serverId')
        .equals('account');
    check(escaped).isEmpty();
  });
}
