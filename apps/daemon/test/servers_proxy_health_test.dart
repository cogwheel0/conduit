@TestOn('vm')
library;

import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/api_auth_interceptor.dart';
import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduitd/conduitd.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// A sign-in proxy turning a server's requests away tells the core that the
/// account's proxy session expired, but only for the account the check was
/// made for.
void main() {
  late _Api api;
  late _Manager manager;
  late Object epoch;
  late ProviderContainer container;

  setUp(() async {
    api = _Api();
    manager = _Manager();
    epoch = Object();
    container = ProviderContainer(
      overrides: [
        optimizedStorageServiceProvider.overrideWithValue(_Storage()),
        activeServerProvider.overrideWith((ref) async => _server),
        apiServiceProvider.overrideWith((ref) => api),
        authStateManagerProvider.overrideWith(() => manager),
        openWebUiAuthSessionEpochProvider.overrideWith((ref) => epoch),
      ],
    );
    addTearDown(container.dispose);
    await container.read(authStateManagerProvider.future);
  });

  test(
    'a proxy refusal for the account in charge is its session expiring',
    () async {
      final status = ServersService(container).status();
      await api.asked.future;
      api.health.complete(HealthCheckResult.proxyAuthRequired);
      await status;
      check(manager.issues).equals(1);
    },
  );

  test('a proxy refusal that comes back after another account took over is '
      'not that account\'s', () async {
    final status = ServersService(container).status();
    await api.asked.future;
    // Another account signs in while the check is out.
    epoch = Object();
    container.invalidate(openWebUiAuthSessionEpochProvider);
    api.health.complete(HealthCheckResult.proxyAuthRequired);
    await status;
    check(manager.issues).equals(0);
  });
}

/// Reached through a sign-in proxy: its cookie rides on every request.
const _server = ServerConfig(
  id: 'account-robin',
  name: 'Harbour',
  url: 'https://harbour.example',
  customHeaders: <String, String>{'Cookie': 'proxy_session=synthetic'},
);

final class _Storage implements OptimizedStorageService {
  @override
  Future<String?> getActiveServerId() async => _server.id;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

/// No Open WebUI config comes back, and the health check is held by the
/// test.
final class _Api extends ApiService {
  _Api() : super(serverConfig: _server, workerManager: WorkerManager());

  final asked = Completer<void>();
  final health = Completer<HealthCheckResult>();

  @override
  Future<BackendConfig?> verifyAndGetConfig() async => null;

  @override
  Future<HealthCheckResult> checkHealthWithProxyDetection({
    bool throwOnConnectionError = false,
  }) {
    asked.complete();
    return health.future;
  }
}

final class _Manager extends AuthStateManager {
  var issues = 0;

  @override
  Future<AuthState> build() async =>
      const AuthState(status: AuthStatus.authenticated, token: 'token');

  @override
  void onAuthIssue([AuthFailureKind? kind]) => issues++;
}
