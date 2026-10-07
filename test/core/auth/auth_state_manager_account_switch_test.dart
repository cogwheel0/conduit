import 'package:checks/checks.dart';
import 'package:conduit/platform/flutter_key_value_store.dart';
import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/database/account_storage_isolation.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
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

  /// Follows auth as the real barrier does, so auth telling it about a switch
  /// runs against the same provider graph as in the app.
  @override
  void build() {
    ref.listen(authStateManagerProvider, (_, _) {});
  }

  @override
  void beginAccountSwitch() => switches++;
}
