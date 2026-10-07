import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/platform/flutter_key_value_store.dart';
import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/database/account_storage_isolation.dart';
import 'package:conduit_core/auth/api_auth_interceptor.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _userA = User(
  id: 'user-a',
  username: 'a',
  email: 'a@example.test',
  role: 'user',
);

const _userB = User(
  id: 'user-b',
  username: 'b',
  email: 'b@example.test',
  role: 'user',
);

// Shaped like a JWT so the stored-token fast path accepts them.
const _tokenA = 'eyJhbGciOiJIUzI1NiJ9.eyJpZCI6ImEifQ.signature-for-account-a';
const _tokenB = 'eyJhbGciOiJIUzI1NiJ9.eyJpZCI6ImIifQ.signature-for-account-b';

/// Switching accounts must never let a request go to the next account's
/// server carrying the previous account's bearer.
///
/// The API client is rebuilt from the active server and the token mirror.
/// If the active id moved first, there would be a moment with server B and
/// token A. So auth goes tokenless, and the storage barrier is told, before
/// storage moves the active id.
void main() {
  setUpAll(() => registerFallbackValue(_userA));

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      PreferenceKeys.activeServerId: 'account-a',
    });
    PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
  });

  tearDown(PreferencesStore.debugReset);

  test('auth is tokenless before the active account moves', () async {
    final storage = _Storage();
    final isolation = _RecordingIsolation();
    var storedToken = _tokenA;
    var cachedUser = _userA;
    when(() => storage.getAuthTokenStrict())
        .thenAnswer((_) async => storedToken);
    when(() => storage.getLocalUserWithAvatar())
        .thenAnswer((_) async => cachedUser);
    when(() => storage.saveLocalUser(any())).thenAnswer((_) async {});
    when(
      () => storage.saveLocalUserWithAvatar(
        any(),
        avatarUrl: any(named: 'avatarUrl'),
      ),
    ).thenAnswer((_) async {});
    when(() => storage.getActiveServerId())
        .thenAnswer((_) async => 'account-a');
    when(() => storage.getEffectiveActiveServerId())
        .thenAnswer((_) async => 'account-a');

    final container = ProviderContainer(
      overrides: [
        optimizedStorageServiceProvider.overrideWithValue(storage),
        apiServiceProvider.overrideWithValue(null),
        activeServerProvider.overrideWith((ref) async => null),
        openWebUiAccountStorageIsolationProvider.overrideWith(() => isolation),
      ],
    );
    addTearDown(container.dispose);

    container.read(openWebUiAccountStorageIsolationProvider);
    final initial = await _settledAuth(container);
    check(initial.token).equals(_tokenA);

    String? mirroredTokenAtSwitch = 'not-observed';
    String? authTokenAtSwitch = 'not-observed';
    var barrierToldBeforeSwitch = false;
    when(
      () => storage.switchActiveServer(
        fromServerId: 'account-a',
        toServerId: 'account-b',
      ),
    ).thenAnswer((_) async {
      mirroredTokenAtSwitch = container.read(apiAuthTokenMirrorProvider);
      authTokenAtSwitch = container
          .read(authStateManagerProvider)
          .asData
          ?.value
          .token;
      barrierToldBeforeSwitch = isolation.switches == 1;
      storedToken = _tokenB;
      cachedUser = _userB;
      await PreferencesStore.put(PreferenceKeys.activeServerId, 'account-b');
      return true;
    });

    final signedIn = await container
        .read(authStateManagerProvider.notifier)
        .switchToAccount('account-b');

    check(mirroredTokenAtSwitch).isNull();
    check(authTokenAtSwitch).isNull();
    check(barrierToldBeforeSwitch).isTrue();
    check(signedIn).isTrue();
    final after = container.read(authStateManagerProvider).requireValue;
    check(after.token).equals(_tokenB);
    check(after.user?.id).equals(_userB.id);
  });

  test('an account without a session settles signed out', () async {
    final storage = _Storage();
    final isolation = _RecordingIsolation();
    when(() => storage.getAuthTokenStrict()).thenAnswer((_) async => _tokenA);
    when(() => storage.getLocalUserWithAvatar())
        .thenAnswer((_) async => _userA);
    when(() => storage.saveLocalUser(any())).thenAnswer((_) async {});
    when(
      () => storage.saveLocalUserWithAvatar(
        any(),
        avatarUrl: any(named: 'avatarUrl'),
      ),
    ).thenAnswer((_) async {});
    when(() => storage.getActiveServerId())
        .thenAnswer((_) async => 'account-a');
    when(() => storage.getEffectiveActiveServerId())
        .thenAnswer((_) async => 'account-a');
    when(
      () => storage.switchActiveServer(
        fromServerId: 'account-a',
        toServerId: 'account-b',
      ),
    ).thenAnswer((_) async => false);

    final container = ProviderContainer(
      overrides: [
        optimizedStorageServiceProvider.overrideWithValue(storage),
        apiServiceProvider.overrideWithValue(null),
        activeServerProvider.overrideWith((ref) async => null),
        openWebUiAccountStorageIsolationProvider.overrideWith(() => isolation),
      ],
    );
    addTearDown(container.dispose);
    container.read(openWebUiAccountStorageIsolationProvider);
    await _settledAuth(container);

    final signedIn = await container
        .read(authStateManagerProvider.notifier)
        .switchToAccount('account-b');

    check(signedIn).isFalse();
    final after = container.read(authStateManagerProvider).requireValue;
    check(after.status).equals(AuthStatus.unauthenticated);
    check(after.token).isNull();
    check(container.read(apiAuthTokenMirrorProvider)).isNull();
  });

  test('a sign-out that storage refuses settles back on the account', () async {
    final storage = _Storage();
    final isolation = _RecordingIsolation();
    when(() => storage.getAuthTokenStrict()).thenAnswer((_) async => _tokenA);
    when(() => storage.getLocalUserWithAvatar())
        .thenAnswer((_) async => _userA);
    when(() => storage.saveLocalUser(any())).thenAnswer((_) async {});
    when(
      () => storage.saveLocalUserWithAvatar(
        any(),
        avatarUrl: any(named: 'avatarUrl'),
      ),
    ).thenAnswer((_) async {});
    when(() => storage.getActiveServerId())
        .thenAnswer((_) async => 'account-a');
    when(() => storage.getEffectiveActiveServerId())
        .thenAnswer((_) async => 'account-a');
    when(
      () => storage.removeAccount(
        'account-a',
        thenActivate: any(named: 'thenActivate'),
      ),
    ).thenThrow(StateError('keychain unavailable'));

    final container = ProviderContainer(
      overrides: [
        optimizedStorageServiceProvider.overrideWithValue(storage),
        apiServiceProvider.overrideWithValue(null),
        activeServerProvider.overrideWith((ref) async => null),
        openWebUiAccountStorageIsolationProvider.overrideWith(() => isolation),
      ],
    );
    addTearDown(container.dispose);
    container.read(openWebUiAccountStorageIsolationProvider);
    await _settledAuth(container);

    await check(
      container
          .read(authStateManagerProvider.notifier)
          .signOutAccount('account-a'),
    ).throws<StateError>();

    // Not left loading and tokenless: storage still holds the session, so
    // the account is still signed in.
    final after = container.read(authStateManagerProvider).requireValue;
    check(after.isLoading).isFalse();
    check(after.token).equals(_tokenA);
  });

  test('a merge storage declines deletes nothing', () async {
    final storage = _Storage();
    final isolation = _RecordingIsolation();
    when(() => storage.getAuthTokenStrict()).thenAnswer((_) async => _tokenA);
    when(() => storage.getLocalUserWithAvatar())
        .thenAnswer((_) async => _userA);
    when(() => storage.saveLocalUser(any())).thenAnswer((_) async {});
    when(
      () => storage.saveLocalUserWithAvatar(
        any(),
        avatarUrl: any(named: 'avatarUrl'),
      ),
    ).thenAnswer((_) async {});
    when(() => storage.getActiveServerId())
        .thenAnswer((_) async => 'account-a');
    // A switch landed between the check and the storage lock.
    when(
      () => storage.mergeActiveAccountInto(
        'account-b',
        expectedSourceAccountId: 'account-a',
      ),
    ).thenAnswer((_) async => false);

    final container = ProviderContainer(
      overrides: [
        optimizedStorageServiceProvider.overrideWithValue(storage),
        apiServiceProvider.overrideWithValue(null),
        activeServerProvider.overrideWith((ref) async => null),
        openWebUiAccountStorageIsolationProvider.overrideWith(() => isolation),
      ],
    );
    addTearDown(container.dispose);
    container.read(openWebUiAccountStorageIsolationProvider);
    await _settledAuth(container);

    final merged = await container
        .read(authStateManagerProvider.notifier)
        .mergeActiveAccountInto(
          'account-b',
          expectedSourceAccountId: 'account-a',
        );

    check(merged).isFalse();
    check(isolation.purged).isEmpty();
  });

  test('a sign-out overtaken by a switch leaves the account now in use', () async {
    final storage = _Storage();
    final isolation = _RecordingIsolation();
    var active = 'account-a';
    var token = _tokenA;
    when(() => storage.getAuthTokenStrict()).thenAnswer((_) async => token);
    when(() => storage.getLocalUserWithAvatar())
        .thenAnswer((_) async => active == 'account-a' ? _userA : _userB);
    when(() => storage.saveLocalUser(any())).thenAnswer((_) async {});
    when(
      () => storage.saveLocalUserWithAvatar(
        any(),
        avatarUrl: any(named: 'avatarUrl'),
      ),
    ).thenAnswer((_) async {});
    when(() => storage.getActiveServerId()).thenAnswer((_) async => active);
    when(() => storage.getEffectiveActiveServerId())
        .thenAnswer((_) async => active);
    when(() => storage.removeInactiveAccount('account-a'))
        .thenAnswer((_) async => true);
    final workerManager = WorkerManager();
    // A switch to B finishes while the server is asked to end A's session.
    final api = _LoggingOutApi(workerManager, onLogout: () {
      active = 'account-b';
      token = _tokenB;
    });
    addTearDown(() {
      api.dispose();
      workerManager.dispose();
    });

    final container = ProviderContainer(
      overrides: [
        optimizedStorageServiceProvider.overrideWithValue(storage),
        apiServiceProvider.overrideWithValue(api),
        activeServerProvider.overrideWith((ref) async => null),
        openWebUiAccountStorageIsolationProvider.overrideWith(() => isolation),
      ],
    );
    addTearDown(container.dispose);
    container.read(openWebUiAccountStorageIsolationProvider);
    await _settledAuth(container);

    await container
        .read(authStateManagerProvider.notifier)
        .signOutAccount('account-a');

    // B's session was never touched: no boundary, no signed-out B.
    check(isolation.switches).equals(0);
    check(container.read(authStateManagerProvider).requireValue.status)
        .not((it) => it.equals(AuthStatus.unauthenticated));
    check(isolation.purged).deepEquals(['account-a']);
    verify(() => storage.removeInactiveAccount('account-a')).called(1);
  });

  test('a sign-out of an inactive account overtaken by a switch to it '
      'settles tokenless', () async {
    final storage = _Storage();
    final isolation = _RecordingIsolation();
    String? active = 'account-a';
    String? token = _tokenA;
    when(() => storage.getAuthTokenStrict()).thenAnswer((_) async => token);
    when(() => storage.getLocalUserWithAvatar())
        .thenAnswer((_) async => active == 'account-b' ? _userB : _userA);
    when(() => storage.saveLocalUser(any())).thenAnswer((_) async {});
    when(
      () => storage.saveLocalUserWithAvatar(
        any(),
        avatarUrl: any(named: 'avatarUrl'),
      ),
    ).thenAnswer((_) async {});
    when(() => storage.getActiveServerId()).thenAnswer((_) async => active);
    when(() => storage.getEffectiveActiveServerId())
        .thenAnswer((_) async => active);
    when(() => storage.vaultedTokenFor('account-b'))
        .thenAnswer((_) async => _tokenB);
    when(() => storage.getOpenWebUiRegistryStrict()).thenAnswer(
      (_) async => OpenWebUiRegistry.empty.mergeServerConfigs(const [
        ServerConfig(id: 'account-a', name: 'A', url: 'https://a.example'),
        ServerConfig(id: 'account-b', name: 'B', url: 'https://b.example'),
      ]),
    );
    when(
      () => storage.switchActiveServer(
        fromServerId: 'account-a',
        toServerId: 'account-b',
      ),
    ).thenAnswer((_) async {
      active = 'account-b';
      token = _tokenB;
      return true;
    });
    // Storage decides under its own lock whether B is active.
    when(() => storage.removeInactiveAccount('account-b'))
        .thenAnswer((_) async => active != 'account-b');
    when(() => storage.removeAccount('account-b')).thenAnswer((_) async {
      active = null;
      token = null;
      return false;
    });
    late final ProviderContainer container;
    final workerManager = WorkerManager();
    addTearDown(workerManager.dispose);
    // The user switches to B while its vaulted session is ended on the
    // server.
    final api = _LoggingOutApi(
      workerManager,
      serverConfig: const ServerConfig(
        id: 'account-b',
        name: 'B',
        url: 'https://b.example',
      ),
      onLogout: () => container
          .read(authStateManagerProvider.notifier)
          .switchToAccount('account-b'),
    );

    container = ProviderContainer(
      overrides: [
        optimizedStorageServiceProvider.overrideWithValue(storage),
        apiServiceProvider.overrideWithValue(null),
        activeServerProvider.overrideWith((ref) async => null),
        openWebUiAccountStorageIsolationProvider.overrideWith(() => isolation),
        savedCredentialAuthApiFactoryProvider.overrideWithValue(
          ({required serverConfig, required workerManager}) => api,
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(openWebUiAccountStorageIsolationProvider);
    await _settledAuth(container);

    final signedIn = await container
        .read(authStateManagerProvider.notifier)
        .signOutAccount('account-b');

    // B is gone, so nothing may go on carrying its bearer: the next API
    // client would send it to whichever server is left.
    check(signedIn).isFalse();
    final after = container.read(authStateManagerProvider).requireValue;
    check(after.token).isNull();
    check(after.status).not((it) => it.equals(AuthStatus.authenticated));
    check(container.read(apiAuthTokenMirrorProvider)).isNull();
    check(isolation.switches).equals(2);
    check(isolation.purged).deepEquals(['account-b']);
  });
}

/// The auth state once its first restore has finished. The provider's
/// future resolves on the first published value, which is the restore's own
/// loading state.
Future<AuthState> _settledAuth(ProviderContainer container) async {
  await container.read(authStateManagerProvider.future);
  for (var i = 0; i < 100; i++) {
    final auth = container.read(authStateManagerProvider).requireValue;
    if (!auth.isLoading) return auth;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  return container.read(authStateManagerProvider).requireValue;
}

final class _Storage extends Mock implements OptimizedStorageService {}

final class _RecordingIsolation extends OpenWebUiAccountStorageIsolation {
  int switches = 0;
  final purged = <String>[];

  @override
  Future<void> purgeAccount(String accountId) async => purged.add(accountId);

  /// Follows auth as the real barrier does, so auth telling it about a switch
  /// runs against the same provider graph as in the app.
  @override
  void build() {
    ref.listen(authStateManagerProvider, (_, _) {});
  }

  @override
  void beginAccountSwitch() => switches++;
}

/// An API client whose server logout runs [onLogout] instead of a request.
final class _LoggingOutApi extends ApiService {
  _LoggingOutApi(
    WorkerManager workerManager, {
    required this.onLogout,
    super.serverConfig = const ServerConfig(
      id: 'account-a',
      name: 'A',
      url: 'https://a.example',
    ),
  }) : super(workerManager: workerManager);

  final FutureOr<void> Function() onLogout;

  @override
  Future<void> logout({ApiAuthSnapshot? authSnapshot}) async => onLogout();
}
