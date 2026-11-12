import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/api_auth_interceptor.dart';
import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

const _server = ServerConfig(
  id: 'account',
  name: 'Home',
  url: 'https://owui.example',
);

const _cached = Model(id: 'cached-model', name: 'Cached model');

final class _Storage implements OptimizedStorageService {
  @override
  Future<List<Model>> getLocalModels() async => const [_cached];

  @override
  Future<void> saveLocalModels(List<Model> models) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

/// A server that cannot be reached: every model fetch fails to connect.
final class _UnreachableApi extends ApiService {
  _UnreachableApi(WorkerManager workerManager)
    : super(serverConfig: _server, workerManager: workerManager);

  var calls = 0;

  @override
  Future<List<Model>> getModels({
    bool includeHidden = false,
    ApiAuthSnapshot? authSnapshot,
  }) async {
    calls++;
    throw DioException.connectionError(
      requestOptions: RequestOptions(path: '/api/models'),
      reason: 'No route to host',
    );
  }
}

final class _Preferred extends PreferredBackendController {
  @override
  PreferredBackend build() => PreferredBackend.owui;
}

final class _Hermes extends HermesConfigController {
  @override
  HermesConfig build() => const HermesConfig();
}

final class _Discovery extends DirectModelDiscoveryController {
  @override
  Future<DirectModelDiscoveryState> build() async =>
      DirectModelDiscoveryState();

  @override
  Future<void> refresh() async {}
}

void main() {
  test('a server that cannot be reached at start leaves the cached models '
      'and raises nothing outside the provider', () async {
    final workerManager = WorkerManager();
    final api = _UnreachableApi(workerManager);
    final escaped = <Object>[];
    late ProviderContainer container;
    // The container reports to the zone it was made in, as a host's does.
    runZonedGuarded(() {
      container = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          preferredBackendProvider.overrideWith(_Preferred.new),
          isAuthenticatedProvider2.overrideWithValue(true),
          isAuthLoadingProvider2.overrideWithValue(false),
          authStatusProvider.overrideWithValue(AuthStatus.authenticated),
          authTokenProvider3.overrideWithValue('token'),
          activeServerProvider.overrideWith((ref) async => _server),
          apiServiceProvider.overrideWithValue(api),
          optimizedStorageServiceProvider.overrideWithValue(_Storage()),
          hermesConfigProvider.overrideWith(_Hermes.new),
          directModelDiscoveryProvider.overrideWith(_Discovery.new),
        ],
      );
    }, (error, _) => escaped.add(error));
    addTearDown(() {
      container.dispose();
      api.dispose();
      workerManager.dispose();
    });
    await container.read(activeServerProvider.future);

    // As a headless host reads it: a listener held for the read only.
    final subscription = container.listen<Future<List<Model>>>(
      modelsProvider.future,
      (_, _) {},
    );
    final List<Model> models;
    try {
      models = await subscription.read();
    } finally {
      subscription.close();
    }
    check(models.map((model) => model.id)).deepEquals([_cached.id]);

    // The refresh behind the cached list runs and fails.
    for (var i = 0; i < 20 && api.calls == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    check(api.calls).isGreaterThan(0);

    check(escaped).isEmpty();
    check(container.read(modelsProvider).value?.map((model) => model.id))
        .isNotNull()
        .deepEquals([_cached.id]);
  });
}
