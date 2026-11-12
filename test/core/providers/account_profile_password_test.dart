import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/models/account_metadata.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
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
  test('a profile saved for a session since replaced is not kept as the '
      "new one's", () async {
    final saving = _ProfileApi(server: 'home', user: 'ada')
      ..saveGate = Completer<void>();
    ApiService current = saving;
    final container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [apiServiceProvider.overrideWith((ref) => current)],
    );
    addTearDown(container.dispose);
    await container.read(accountProfileProvider.future);

    final save = container
        .read(accountProfileProvider.notifier)
        .save(name: 'Ada Saved', profileImageUrl: '');
    await Future<void>.delayed(Duration.zero);
    current = _ProfileApi(server: 'work', user: 'grace');
    container.invalidate(apiServiceProvider);
    await container.read(accountProfileProvider.future);
    saving.saveGate!.complete();
    await save;

    check(container.read(accountProfileProvider).value?.id).equals('grace');
  });

  test('a refresh answered after a newer one is dropped', () async {
    final home = _ProfileApi(server: 'home', user: 'ada');
    final container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [apiServiceProvider.overrideWithValue(home)],
    );
    addTearDown(container.dispose);
    final listening = container.listen(accountProfileProvider, (_, _) {});
    addTearDown(listening.close);
    await container.read(accountProfileProvider.future);
    final profile = container.read(accountProfileProvider.notifier);

    final gate = home.readGate = Completer<void>();
    home.nextName = 'Ada Before';
    final first = profile.refresh();
    await Future<void>.delayed(Duration.zero);
    home
      ..readGate = null
      ..nextName = 'Ada After';
    await profile.refresh();
    gate.complete();
    await first;

    check(container.read(accountProfileProvider).value?.name)
        .equals('Ada After');
  });

  test("a refresh that lands after another server's profile was read is "
      'dropped', () async {
    final home = _ProfileApi(server: 'home', user: 'ada');
    ApiService current = home;
    final container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [apiServiceProvider.overrideWith((ref) => current)],
    );
    addTearDown(container.dispose);
    final listening = container.listen(accountProfileProvider, (_, _) {});
    addTearDown(listening.close);
    await container.read(accountProfileProvider.future);

    home.readGate = Completer<void>();
    final refreshing = container
        .read(accountProfileProvider.notifier)
        .refresh();
    await Future<void>.delayed(Duration.zero);
    current = _ProfileApi(server: 'work', user: 'grace');
    container.invalidate(apiServiceProvider);
    await container.read(accountProfileProvider.future);
    home.readGate!.complete();
    await refreshing;

    final profile = container.read(accountProfileProvider.notifier);
    check(container.read(accountProfileProvider).value?.id).equals('grace');
    check(profile.profileOn('work')?.id).equals('grace');
    check(profile.profileOn('home')).isNull();
  });

  test("a profile kept through a failed read of another server's is not "
      "that server's", () async {
    ApiService current = _ProfileApi(server: 'home', user: 'ada');
    final container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [apiServiceProvider.overrideWith((ref) => current)],
    );
    addTearDown(container.dispose);
    final listening = container.listen(accountProfileProvider, (_, _) {});
    addTearDown(listening.close);
    await container.read(accountProfileProvider.future);

    // The same user id on another server, which cannot be read.
    current = _ProfileApi(server: 'work', user: 'ada')..fails = true;
    container.invalidate(apiServiceProvider);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    final profile = container.read(accountProfileProvider.notifier);
    check(profile.profileOn('work')).isNull();
    check(profile.profileOn('home')?.id).equals('ada');
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

final class _ProfileApi extends ApiService {
  _ProfileApi({required String server, required this.user})
    : super(
        serverConfig: ServerConfig(
          id: server,
          name: server,
          url: 'https://$server.example.test',
        ),
        workerManager: WorkerManager(),
      );

  final String user;
  Completer<void>? saveGate;
  Completer<void>? readGate;
  bool fails = false;

  /// The name the next read answers with, taken as the read is sent.
  String? nextName;

  AccountMetadata _profile(String name) => AccountMetadata(
    id: user,
    email: '$user@example.test',
    name: name,
    role: 'user',
    isActive: true,
  );

  @override
  Future<AccountMetadata> getAccountMetadata() async {
    final name = nextName ?? user;
    await readGate?.future;
    if (fails) throw StateError('offline');
    return _profile(name);
  }

  @override
  Future<AccountMetadata> updateAccountMetadata({
    required String name,
    required String profileImageUrl,
    String? bio,
    String? gender,
    String? dateOfBirth,
    String? timezone,
  }) async {
    await saveGate?.future;
    return _profile(name);
  }
}
