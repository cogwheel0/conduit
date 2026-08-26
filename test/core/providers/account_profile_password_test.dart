import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/auth/auth_state_manager.dart';
import 'package:conduit/core/models/account_metadata.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('successful password update logs out the revoked session', () async {
    final api = _PasswordApi();
    final container = _container(api);
    addTearDown(container.dispose);

    await container
        .read(accountProfileProvider.notifier)
        .updatePassword(password: 'old-password', newPassword: 'new-password');

    final auth = container.read(
      authStateManagerProvider.notifier,
    ) as _LogoutSpyAuthStateManager;
    check(api.updates)
        .deepEquals([(password: 'old-password', newPassword: 'new-password')]);
    check(auth.logoutCalls).equals(1);
  });

  test('failed password update keeps the current session', () async {
    final api = _PasswordApi()..failure = StateError('rejected');
    final container = _container(api);
    addTearDown(container.dispose);

    await check(
      container
          .read(accountProfileProvider.notifier)
          .updatePassword(
            password: 'wrong-password',
            newPassword: 'new-password',
          ),
    ).throws<StateError>();

    final auth = container.read(
      authStateManagerProvider.notifier,
    ) as _LogoutSpyAuthStateManager;
    check(auth.logoutCalls).equals(0);
  });

  test('password update does not log out a replacement session', () async {
    final originalApi = _PasswordApi()..updateGate = Completer<void>();
    var currentApi = originalApi;
    final container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWith((ref) => currentApi),
        authStateManagerProvider.overrideWith(_LogoutSpyAuthStateManager.new),
      ],
    );
    addTearDown(container.dispose);

    final update = container
        .read(accountProfileProvider.notifier)
        .updatePassword(password: 'old-password', newPassword: 'new-password');
    await Future<void>.delayed(Duration.zero);

    currentApi = _PasswordApi();
    container.invalidate(apiServiceProvider);
    check(container.read(apiServiceProvider)).identicalTo(currentApi);
    originalApi.updateGate!.complete();
    await update;

    final auth = container.read(
      authStateManagerProvider.notifier,
    ) as _LogoutSpyAuthStateManager;
    check(auth.logoutCalls).equals(0);
  });
}

ProviderContainer _container(_PasswordApi api) => ProviderContainer(
  overrides: [
    apiServiceProvider.overrideWithValue(api),
    authStateManagerProvider.overrideWith(_LogoutSpyAuthStateManager.new),
  ],
);

final class _LogoutSpyAuthStateManager extends AuthStateManager {
  var logoutCalls = 0;

  @override
  Future<AuthState> build() async =>
      const AuthState(status: AuthStatus.authenticated, token: 'session-token');

  @override
  Future<void> logout() async {
    logoutCalls++;
  }
}

final class _PasswordApi extends ApiService {
  _PasswordApi()
    : super(
        serverConfig: const ServerConfig(
          id: 'server',
          name: 'Server',
          url: 'https://example.test',
        ),
        workerManager: WorkerManager(),
      );

  final updates = <({String password, String newPassword})>[];
  Object? failure;
  Completer<void>? updateGate;

  @override
  Future<AccountMetadata> getAccountMetadata() async => const AccountMetadata(
    id: 'user',
    email: 'user@example.test',
    name: 'User',
    role: 'user',
    isActive: true,
  );

  @override
  Future<void> updateAccountPassword({
    required String password,
    required String newPassword,
  }) async {
    final error = failure;
    if (error != null) throw error;
    await updateGate?.future;
    updates.add((password: password, newPassword: newPassword));
  }
}
