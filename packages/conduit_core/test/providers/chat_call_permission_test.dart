import 'package:checks/checks.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

const _member = User(
  id: 'member',
  username: 'Member',
  email: 'member@example.test',
  role: 'user',
);
const _admin = User(
  id: 'admin',
  username: 'Admin',
  email: 'admin@example.test',
  role: 'admin',
);

void main() {
  ProviderContainer container({
    ApiService? api,
    User user = _member,
    Future<Map<String, dynamic>> Function()? permissions,
  }) {
    final c = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(
          api ??
              ApiService(
                serverConfig: const ServerConfig(
                  id: 'server',
                  name: 'Server',
                  url: 'https://example.test',
                ),
                workerManager: WorkerManager(),
              ),
        ),
        currentUserProvider2.overrideWith((ref) => user),
        userPermissionsProvider.overrideWith(
          (ref) => permissions?.call() ?? Future.value(const {}),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('a missing call permission means allowed, as on the web', () async {
    final c = container(permissions: () async => {'chat': <String, dynamic>{}});

    check(await c.read(chatCallPermittedProvider.future)).equals(true);
  });

  test('a call permission switched off is respected', () async {
    final c = container(
      permissions: () async => {
        'chat': {'call': false},
      },
    );

    check(await c.read(chatCallPermittedProvider.future)).equals(false);
  });

  test('an admin may always call', () async {
    final c = container(
      user: _admin,
      permissions: () async => {
        'chat': {'call': false},
      },
    );

    check(await c.read(chatCallPermittedProvider.future)).equals(true);
  });

  test('unreadable permissions are unknown, never allowed', () async {
    final c = container(permissions: () => Future.error(StateError('500')));

    check(await c.read(chatCallPermittedProvider.future)).isNull();
  });
}
