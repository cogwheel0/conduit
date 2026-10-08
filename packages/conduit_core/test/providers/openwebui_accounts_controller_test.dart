import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/auth/openwebui_account_summaries.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/providers/openwebui_accounts_controller.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

final class _Storage implements OptimizedStorageService {
  String? active = 'a';

  /// Once set, reading the active account fails with it.
  Object? readError;

  @override
  Future<String?> getEffectiveActiveServerId() async {
    if (readError case final error?) throw error;
    return active;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

/// Moves [_Storage.active] as the real account changes would.
final class _Auth extends AuthStateManager {
  _Auth(this.storage, {this.duringSignOut});

  final _Storage storage;

  /// Runs while the sign-out waits on the server.
  final FutureOr<void> Function()? duringSignOut;
  final switches = <String>[];

  @override
  Future<AuthState> build() async =>
      const AuthState(status: AuthStatus.unauthenticated);

  @override
  Future<bool> signOutAccount(String accountId, {String? thenActivate}) async {
    await duringSignOut?.call();
    if (storage.active == accountId) storage.active = thenActivate;
    return false;
  }

  @override
  Future<bool> switchToAccount(String accountId) async {
    switches.add(accountId);
    storage.active = accountId;
    return true;
  }
}

final class _Hermes extends HermesConfigController {
  @override
  HermesConfig build() => const HermesConfig();
}

OpenWebUiAccountEntry _entry(
  String id, {
  bool hasSession = true,
  OpenWebUiAccountSummary? summary,
}) => OpenWebUiAccountEntry(
  account: OpenWebUiAccount(id: id, serverId: 'server'),
  server: OpenWebUiServer(
    id: 'server',
    name: 'Chat',
    endpoints: [
      OpenWebUiEndpoint(id: 'endpoint', url: 'https://chat.example'),
    ],
  ),
  summary: summary ?? const OpenWebUiAccountSummary(),
  isActive: false,
  hasSession: hasSession,
);

/// Signs out of the only account, with Direct profiles still loading
/// synchronously and resolving to [direct] once awaited.
Future<PreferredBackend> _signOutOfLastAccount(
  Future<List<DirectConnectionProfile>> Function() direct, {
  _Storage? storage,
}) async {
  final accountStorage = storage ?? _Storage();
  final container = ProviderContainer(
    overrides: [
      optimizedStorageServiceProvider.overrideWithValue(accountStorage),
      authStateManagerProvider.overrideWith(() => _Auth(accountStorage)),
      hermesConfigProvider.overrideWith(_Hermes.new),
      openWebUiAccountsProvider.overrideWith((ref) async => const []),
      accountChangeReplyGuardProvider.overrideWithValue(() => false),
      effectiveDirectConnectionProfilesProvider.overrideWithValue(
        const AsyncLoading(),
      ),
      effectiveDirectConnectionProfilesFutureProvider.overrideWith(
        (ref) => direct(),
      ),
    ],
  );
  addTearDown(container.dispose);

  await container.read(openWebUiAccountsControllerProvider).signOut('a');
  return container.read(preferredBackendProvider);
}

void main() {
  setUp(() async {
    PreferencesStore.installLoader(() async => InMemoryKeyValueStore());
    await PreferencesStore.ensureInitialized();
  });

  tearDown(PreferencesStore.debugReset);

  test(
    'signing out of the last account waits for Direct profiles still loading',
    () async {
      final profile = DirectConnectionProfile(
        id: 'profile',
        name: 'Provider',
        adapterKey: kOpenAiCompatibleAdapterKey,
        baseUrl: 'https://provider.example/v1',
      );
      check(profile.isUsable).isTrue();

      check(await _signOutOfLastAccount(() async => [profile]))
          .equals(PreferredBackend.direct);
    },
  );

  test('Direct profiles that fail to load count as no Direct', () async {
    check(await _signOutOfLastAccount(() async => throw StateError('locked')))
        .equals(PreferredBackend.unset);
  });

  test('an account a sign-in makes active while Direct profiles load keeps '
      'Open WebUI', () async {
    final storage = _Storage();

    final preferred = await _signOutOfLastAccount(() async {
      storage.active = 'c';
      return const [];
    }, storage: storage);

    check(preferred).equals(PreferredBackend.unset);
    check(PreferencesStore.getString(PreferenceKeys.preferredBackend)).isNull();
  });

  test('choosing the account in use while it is signed out goes to auth',
      () async {
    final storage = _Storage();
    final auth = _Auth(storage);
    final container = ProviderContainer(
      overrides: [
        optimizedStorageServiceProvider.overrideWithValue(storage),
        authStateManagerProvider.overrideWith(() => auth),
        hermesConfigProvider.overrideWith(_Hermes.new),
        openWebUiAccountsProvider.overrideWith((ref) async => const []),
        accountChangeReplyGuardProvider.overrideWithValue(() => false),
      ],
    );
    addTearDown(container.dispose);
    await container.read(authStateManagerProvider.future);

    final result = await container
        .read(openWebUiAccountsControllerProvider)
        .switchTo('a');

    // Auth can take up a session the account still has in its vault.
    check(auth.switches).deepEquals(['a']);
    check(result).equals(OpenWebUiAccountChangeResult.done);
  });

  test('a sign-out that cannot read the account in use afterwards changes '
      'nothing more', () async {
    final storage = _Storage();
    final container = ProviderContainer(
      overrides: [
        optimizedStorageServiceProvider.overrideWithValue(storage),
        authStateManagerProvider.overrideWith(
          () => _Auth(
            storage,
            duringSignOut: () => storage.readError = StateError('locked'),
          ),
        ),
        hermesConfigProvider.overrideWith(_Hermes.new),
        openWebUiAccountsProvider.overrideWith((ref) async => const []),
        accountChangeReplyGuardProvider.overrideWithValue(() => false),
      ],
    );
    addTearDown(container.dispose);

    final result = await container
        .read(openWebUiAccountsControllerProvider)
        .signOut('a');

    check(result).equals(OpenWebUiAccountChangeResult.needsSignIn);
    check(PreferencesStore.getString(PreferenceKeys.preferredBackend)).isNull();
  });

  test('the backend stays when the account in use cannot be read before '
      'falling back', () async {
    final storage = _Storage();
    final profile = DirectConnectionProfile(
      id: 'profile',
      name: 'Provider',
      adapterKey: kOpenAiCompatibleAdapterKey,
      baseUrl: 'https://provider.example/v1',
    );

    await _signOutOfLastAccount(() async {
      storage.readError = StateError('locked');
      return [profile];
    }, storage: storage);

    check(PreferencesStore.getString(PreferenceKeys.preferredBackend)).isNull();
  });

  test('leaving an addition goes back to the account signed in to last', () async {
    final storage = _Storage()..active = 'old';
    final container = ProviderContainer(
      overrides: [
        optimizedStorageServiceProvider.overrideWithValue(storage),
        authStateManagerProvider.overrideWith(() => _Auth(storage)),
        hermesConfigProvider.overrideWith(_Hermes.new),
        openWebUiAccountsProvider.overrideWith((ref) async {
          final summaries = ref.watch(openWebUiAccountSummariesProvider);
          return [
            for (final id in ['old', 'a', 'b', 'c'])
              _entry(id, hasSession: id != 'c', summary: summaries[id]),
          ];
        }),
        accountChangeReplyGuardProvider.overrideWithValue(() => false),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(openWebUiAccountsControllerProvider);

    await controller.switchTo('a');
    await Future<void>.delayed(const Duration(milliseconds: 1));
    // B is added and signed in to: its account is certified for its user.
    storage.active = 'b';
    await container
        .read(openWebUiAccountSummariesProvider.notifier)
        .recordUser(
          'b',
          const User(
            id: 'user-b',
            username: 'b',
            email: 'b@example.test',
            role: 'user',
          ),
        );
    // Another addition starts from B, and is left before signing in.
    storage.active = 'c';
    await controller.signOut('c');

    check(storage.active).equals('b');
  });

  group('with several accounts', () {
    late _Storage storage;
    late _Auth auth;
    late ProviderContainer container;
    late List<String?> hostChanges;

    void start({FutureOr<void> Function()? duringSignOut}) {
      storage = _Storage();
      auth = _Auth(storage, duringSignOut: duringSignOut);
      hostChanges = [];
      container = ProviderContainer(
        overrides: [
          optimizedStorageServiceProvider.overrideWithValue(storage),
          authStateManagerProvider.overrideWith(() => auth),
          hermesConfigProvider.overrideWith(_Hermes.new),
          openWebUiAccountsProvider.overrideWith(
            (ref) async => [
              _entry('a'),
              _entry('b'),
              _entry('c', hasSession: false),
            ],
          ),
          accountChangeReplyGuardProvider.overrideWithValue(() => false),
          hostActiveAccountChangedProvider.overrideWithValue(hostChanges.add),
        ],
      );
      addTearDown(container.dispose);
    }

    test('a switch landing during the active account\'s sign-out is left '
        'alone', () async {
      start(duringSignOut: () => storage.active = 'c');

      await container.read(openWebUiAccountsControllerProvider).signOut('a');

      check(storage.active).equals('c');
      check(hostChanges).isEmpty();
      check(container.read(openWebUiAccountSummariesProvider)).isEmpty();
      check(container.read(preferredBackendProvider))
          .equals(PreferredBackend.unset);
      check(PreferencesStore.getString(PreferenceKeys.preferredBackend))
          .isNull();
    });

    test('account changes run one at a time', () async {
      final serverAsked = Completer<void>();
      start(duringSignOut: () => serverAsked.future);
      final controller = container.read(openWebUiAccountsControllerProvider);

      final signingOut = controller.signOut('a');
      final switching = controller.switchTo('c');
      await pumpEventQueue();

      check(auth.switches).isEmpty();
      serverAsked.complete();
      await signingOut;
      check(await switching).equals(OpenWebUiAccountChangeResult.done);
      check(auth.switches).deepEquals(['c']);
    });
  });
}
