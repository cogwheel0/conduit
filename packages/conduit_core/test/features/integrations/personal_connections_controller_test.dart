import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/features/integrations/personal_connection_edits.dart';
import 'package:conduit_core/features/integrations/personal_connection_settings.dart';
import 'package:conduit_core/features/integrations/providers/personal_connections_providers.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import 'package:conduit_core/testing.dart';

const _server = ServerConfig(
  id: 'server-1',
  name: 'Home server',
  url: 'https://owui.example',
);

Map<String, dynamic> _tool(String id, String name) => <String, dynamic>{
  'type': 'openapi',
  'url': 'https://$id.example',
  'spec_type': 'url',
  'path': 'openapi.json',
  'auth_type': 'bearer',
  'key': 'key-$id',
  'config': <String, dynamic>{'enable': true},
  'info': <String, dynamic>{'id': id, 'name': name},
};

User _user(String id, {String role = 'admin'}) => User(
  id: id,
  username: id,
  email: '$id@example.test',
  name: 'Account $id',
  role: role,
);

/// An auth manager whose signed-in account tests can swap, as a sign-out and
/// sign-in on the same server would.
final class _Auth extends AuthStateManager {
  static AuthState initial = AuthState(
    status: AuthStatus.authenticated,
    token: 'token-a',
    user: _user('a'),
  );

  @override
  Future<AuthState> build() async => initial;

  void switchTo(String token, User user) => state = AsyncData(
    AuthState(status: AuthStatus.authenticated, token: token, user: user),
  );
}

final class _Config extends BackendConfigNotifier {
  @override
  Future<BackendConfig?> build() async =>
      const BackendConfig(serverId: 'server-1', enableDirectIntegrations: true);
}

void main() {
  late FakeUserSettingsServer settingsServer;
  late ApiService api;
  late ProviderContainer container;
  var permissions = <String, dynamic>{};

  setUp(() {
    PreferencesStore.debugOverride(InMemoryKeyValueStore());
    permissions = <String, dynamic>{};
    _Auth.initial = AuthState(
      status: AuthStatus.authenticated,
      token: 'token-a',
      user: _user('a'),
    );
    settingsServer = FakeUserSettingsServer(const <String, dynamic>{})
      ..addAccount('token-a', <String, dynamic>{
        'ui': <String, dynamic>{
          'toolServers': <dynamic>[_tool('a1', 'A one')],
        },
      })
      ..addAccount('token-b', <String, dynamic>{
        'ui': <String, dynamic>{
          'toolServers': <dynamic>[_tool('b1', 'B one')],
        },
      });
    api = ApiService(
      serverConfig: _server,
      workerManager: WorkerManager(),
      authToken: 'token-a',
    );
    api.dio.httpClientAdapter = settingsServer;
    container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(api),
        activeServerProvider.overrideWith((ref) async => _server),
        authStateManagerProvider.overrideWith(_Auth.new),
        backendConfigProvider.overrideWith(_Config.new),
        userPermissionsProvider.overrideWith((ref) async => permissions),
        reviewerModeProvider.overrideWithValue(false),
      ],
    );
    addTearDown(container.dispose);
  });

  Future<void> signInAs(String token, User user) async {
    // The initial build must finish first, or it would overwrite the switch.
    await container.read(authStateManagerProvider.future);
    api.updateAuthToken(token);
    (container.read(authStateManagerProvider.notifier) as _Auth).switchTo(
      token,
      user,
    );
    // Let the dependent providers rebuild for the new account.
    await container.pump();
  }

  test('lists the signed-in account and says where it is stored', () async {
    // Keep the auth state and active server resolved before reading.
    await container.read(authStateManagerProvider.future);
    await container.read(activeServerProvider.future);
    await container.read(backendConfigProvider.future);

    final snapshot = await container.read(personalConnectionsProvider.future);

    check(snapshot).isNotNull();
    check(snapshot!.accountName).equals('Account a');
    check(snapshot.serverName).equals('Home server');
    check(snapshot.toolServers.map((e) => e.displayName))
        .deepEquals(<String>['A one']);
  });

  test('a save that lands after an account switch changes nothing for the new account', () async {
    await container.read(authStateManagerProvider.future);
    await container.read(activeServerProvider.future);
    await container.read(backendConfigProvider.future);
    final owner = (await container.read(personalConnectionsProvider.future))!
        .session;
    container.read(selectedToolIdsProvider.notifier).set(const <String>[
      'direct_server:b1',
    ]);
    settingsServer.gateFirstPost();

    final save = container
        .read(personalConnectionsProvider.notifier)
        .save(
          owner,
          PersonalConnectionKind.toolServer,
          AddPersonalConnection(_tool('a2', 'A two')),
        );
    await settingsServer.postEntered.future;
    // Account A's request is already on the wire; now B signs in.
    await signInAs('token-b', _user('b'));
    settingsServer.releasePost.complete();
    final outcome = await save;

    // The write reached account A's settings, and only theirs.
    check(outcome.stale).isTrue();
    check(
      (settingsServer.settingsOf('token-a')['ui']['toolServers'] as List).map(
        (e) => e['info']['id'],
      ),
    ).deepEquals(<String>['a1', 'a2']);
    check(
      (settingsServer.settingsOf('token-b')['ui']['toolServers'] as List).map(
        (e) => e['info']['id'],
      ),
    ).deepEquals(<String>['b1']);
    check(
      settingsServer.log
          .where((r) => r.method == 'POST')
          .map((r) => r.authorization),
    ).deepEquals(<String?>['Bearer token-a']);
    // Nothing about A's result leaked into B's view or selection.
    final snapshot = await container.read(personalConnectionsProvider.future);
    check(snapshot!.accountName).equals('Account b');
    check(snapshot.toolServers.map((e) => e.displayName))
        .deepEquals(<String>['B one']);
    check(container.read(selectedToolIdsProvider))
        .deepEquals(<String>['direct_server:b1']);
    check(container.read(personalSelectionNoticeProvider)).isEmpty();
  });

  test('a write queued before an account switch is refused instead of sent as the new account', () async {
    await container.read(authStateManagerProvider.future);
    await container.read(activeServerProvider.future);
    await container.read(backendConfigProvider.future);
    final owner = (await container.read(personalConnectionsProvider.future))!
        .session;
    settingsServer.gateFirstGet();
    final getsBefore = settingsServer.log.length;

    final save = container
        .read(personalConnectionsProvider.notifier)
        .save(
          owner,
          PersonalConnectionKind.toolServer,
          AddPersonalConnection(_tool('a2', 'A two')),
        );
    await settingsServer.firstGetEntered.future;
    await signInAs('token-b', _user('b'));
    settingsServer.releaseFirstGet.complete();

    await expectLater(save, throwsA(anything));
    final sentAfterSwitch = settingsServer.log.skip(getsBefore);
    check(sentAfterSwitch.where((r) => r.method == 'POST')).isEmpty();
    check(
      (settingsServer.settingsOf('token-b')['ui']['toolServers'] as List)
          .length,
    ).equals(1);
  });

  test(
    'a claim held when the permission is withdrawn cannot save, and nothing is sent',
    () async {
      permissions = <String, dynamic>{
        'features': <String, dynamic>{'direct_tool_servers': true},
      };
      await signInAs('token-b', _user('b', role: 'user'));
      await container.read(activeServerProvider.future);
      await container.read(backendConfigProvider.future);
      await container.read(userPermissionsProvider.future);
      final owner = (await container.read(personalConnectionsProvider.future))!
          .session;

      // The same account loses the permission while its screen is open.
      permissions = <String, dynamic>{};
      container.invalidate(userPermissionsProvider);
      await container.read(userPermissionsProvider.future);
      final before = settingsServer.log.length;

      check(container.read(personalConnectionsAccessProvider).block)
          .equals(PersonalConnectionsBlock.noPermission);
      await expectLater(
        container
            .read(personalConnectionsProvider.notifier)
            .save(
              owner,
              PersonalConnectionKind.toolServer,
              AddPersonalConnection(_tool('b2', 'B two')),
            ),
        throwsA(isA<PersonalConnectionsOwnerChanged>()),
      );
      check(settingsServer.log.length).equals(before);
    },
  );

  test('a user granted direct_tool_servers may manage connections', () async {
    permissions = <String, dynamic>{
      'features': <String, dynamic>{'direct_tool_servers': true},
    };
    await signInAs('token-b', _user('b', role: 'user'));
    await container.read(activeServerProvider.future);
    await container.read(backendConfigProvider.future);
    await container.read(userPermissionsProvider.future);

    check(container.read(personalConnectionsAccessProvider).available).isTrue();
  });
}
