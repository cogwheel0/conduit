import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

const _server = ServerConfig(
  id: 'server-1',
  name: 'Home server',
  url: 'https://owui.example',
);

const _user = User(
  id: 'user-1',
  username: 'ava',
  email: 'ava@example.test',
  role: 'user',
);

const _enforced = <String, dynamic>{
  'chat': {'temporary': true, 'temporary_enforced': true},
};

final class _ActiveConversation extends ActiveConversationNotifier {
  _ActiveConversation(this._initial);

  final Conversation? _initial;

  @override
  Conversation? build() => _initial;
}

final class _Settings extends AppSettingsNotifier {
  @override
  AppSettings build() => const AppSettings();
}

/// Open WebUI 0.12 refuses to create chats for a non-admin with
/// `chat.temporary_enforced` on, so a new chat must start temporary rather
/// than queue a create the server will never accept.
void main() {
  late WorkerManager workerManager;
  late ApiService api;

  setUp(() {
    workerManager = WorkerManager();
    api = ApiService(serverConfig: _server, workerManager: workerManager);
  });

  tearDown(() {
    api.dispose();
    workerManager.dispose();
  });

  ProviderContainer containerWith({
    User user = _user,
    FutureOr<Map<String, dynamic>> Function()? permissions,
    Conversation? active,
  }) {
    final container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(api),
        currentUserProvider2.overrideWith((ref) => user),
        appSettingsProvider.overrideWith(_Settings.new),
        activeConversationProvider.overrideWith(
          () => _ActiveConversation(active),
        ),
        userPermissionsProvider.overrideWith(
          (ref) async => await (permissions ?? () => _enforced)(),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<void> settle(ProviderContainer container) async {
    await container.read(userPermissionsProvider.future);
    await Future<void>.delayed(Duration.zero);
  }

  test('is enforced only for a non-admin with both permissions on', () async {
    final enforced = containerWith();
    await settle(enforced);
    check(enforced.read(temporaryChatEnforcedProvider)).isTrue();

    final admin = containerWith(user: _user.copyWith(role: 'admin'));
    await settle(admin);
    check(admin.read(temporaryChatEnforcedProvider)).isFalse();

    final optional = containerWith(
      permissions: () => {
        'chat': {'temporary': true, 'temporary_enforced': false},
      },
    );
    await settle(optional);
    check(optional.read(temporaryChatEnforcedProvider)).isFalse();

    final unreported = containerWith(permissions: () => const {});
    await settle(unreported);
    check(unreported.read(temporaryChatEnforcedProvider)).isFalse();
  });

  test('a new chat starts temporary once the permissions arrive', () async {
    final permissions = Completer<Map<String, dynamic>>();
    final container = containerWith(permissions: () => permissions.future);
    final sub = container.listen(temporaryChatEnabledProvider, (_, _) {});
    addTearDown(sub.close);
    check(container.read(temporaryChatEnabledProvider)).isFalse();

    permissions.complete(_enforced);
    await settle(container);

    check(container.read(temporaryChatEnabledProvider)).isTrue();

    container.read(temporaryChatEnabledProvider.notifier).set(false);
    container.read(temporaryChatEnabledProvider.notifier).startNewChat();
    check(container.read(temporaryChatEnabledProvider)).isTrue();
  });

  test('an open saved chat stays saved when the permissions arrive', () async {
    final permissions = Completer<Map<String, dynamic>>();
    final container = containerWith(
      permissions: () => permissions.future,
      active: Conversation(
        id: 'chat-1',
        title: 'Saved',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
    );
    final sub = container.listen(temporaryChatEnabledProvider, (_, _) {});
    addTearDown(sub.close);

    permissions.complete(_enforced);
    await settle(container);

    check(container.read(temporaryChatEnabledProvider)).isFalse();
  });
}
