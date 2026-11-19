import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/database/account_storage_isolation.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

const _userA = User(
  id: 'user-a',
  username: 'a',
  email: 'a@example.test',
  role: 'user',
);

// Shaped like a JWT so the stored-token fast path accepts it.
const _tokenA = 'eyJhbGciOiJIUzI1NiJ9.eyJpZCI6ImEifQ.signature-for-account-a';

/// Selecting a server for an account being added, while the account in
/// charge settles: refused or undone, that account is left as it was.
void main() {
  setUpAll(() {
    registerFallbackValue(_userA);
    registerFallbackValue(
      const ServerConfig(id: 'fallback', name: 'F', url: 'https://f.example'),
    );
  });

  setUp(() {
    PreferencesStore.debugOverride(
      InMemoryKeyValueStore({PreferenceKeys.activeServerId: 'account-a'}),
    );
  });

  tearDown(PreferencesStore.debugReset);

  // An account added on a saved server is refused before storage writes
  // (the server lost the address it was made from) while the account in
  // charge is still settling: that account settles as it would have.
  test('a server selection refused before it writes leaves the account in '
      'charge to settle', () async {
    final storage = _Storage();
    final isolation = _RecordingIsolation();
    final tokenRead = Completer<String?>();
    when(() => storage.getAuthTokenStrict())
        .thenAnswer((_) => tokenRead.future);
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
      () => storage.selectUnauthenticatedServerConfig(
        any(),
        publish: any(named: 'publish'),
        canCommit: any(named: 'canCommit'),
        onRollbackUncertain: any(named: 'onRollbackUncertain'),
        joins: any(named: 'joins'),
        onWriting: any(named: 'onWriting'),
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
    // The account in charge is still reading its session.
    container.read(authStateManagerProvider);

    await container
        .read(authStateManagerProvider.notifier)
        .selectUnauthenticatedServerConfig(
          const ServerConfig(
            id: 'account-new',
            name: 'New',
            url: 'https://new.example',
          ),
          joins: (_) => false,
        );
    tokenRead.complete(_tokenA);

    final after = await _settledAuth(container);
    check(after.isLoading).isFalse();
    check(after.token).equals(_tokenA);
    check(after.isAuthenticated).isTrue();

    // Refused again once that account settled: nothing is published, so
    // the client a reply carries is never rebuilt.
    final published = <AsyncValue<AuthState>>[];
    final watch = container.listen<AsyncValue<AuthState>>(
      authStateManagerProvider,
      (_, next) => published.add(next),
    );
    addTearDown(watch.close);
    await container
        .read(authStateManagerProvider.notifier)
        .selectUnauthenticatedServerConfig(
          const ServerConfig(
            id: 'account-new',
            name: 'New',
            url: 'https://new.example',
          ),
          joins: (_) => false,
        );
    check(published).isEmpty();
    check(container.read(authStateManagerProvider).requireValue.token)
        .equals(_tokenA);
  });

  // A selection that began while the account in charge was still starting
  // up begins to write only after that account signed in. Put back, it
  // shows that account signed in, not the state from before it settled.
  for (final (name, cancelled) in [('fails', false), ('is cancelled', true)]) {
    test('a server selection that $name after the account in charge settled '
        'puts that account back signed in', () async {
      final storage = _Storage();
      final isolation = _RecordingIsolation();
      final tokenRead = Completer<String?>();
      final writeGate = Completer<void>();
      when(() => storage.getAuthTokenStrict())
          .thenAnswer((_) => tokenRead.future);
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
        () => storage.selectUnauthenticatedServerConfig(
          any(),
          publish: any(named: 'publish'),
          canCommit: any(named: 'canCommit'),
          onRollbackUncertain: any(named: 'onRollbackUncertain'),
          joins: any(named: 'joins'),
          onWriting: any(named: 'onWriting'),
        ),
      ).thenAnswer((invocation) async {
        // Waits for storage's lock while the account in charge settles.
        await writeGate.future;
        (invocation.namedArguments[#onWriting] as void Function())();
        if (!cancelled) throw StateError('the write failed');
        final publish =
            invocation.namedArguments[#publish] as FutureOr<void> Function();
        await publish();
        // The addition ended as it was published: put back.
        return false;
      });

      final container = ProviderContainer(
        overrides: [
          optimizedStorageServiceProvider.overrideWithValue(storage),
          apiServiceProvider.overrideWithValue(null),
          activeServerProvider.overrideWith((ref) async => null),
          openWebUiAccountStorageIsolationProvider.overrideWith(
            () => isolation,
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(openWebUiAccountStorageIsolationProvider);
      // The account in charge is still reading its session.
      container.read(authStateManagerProvider);

      final selecting = container
          .read(authStateManagerProvider.notifier)
          .selectUnauthenticatedServerConfig(
            const ServerConfig(
              id: 'account-new',
              name: 'New',
              url: 'https://new.example',
            ),
          )
          .then<Object?>((_) => null, onError: (Object error) => error);
      tokenRead.complete(_tokenA);
      final settled = await _settledAuth(container);
      check(settled.isAuthenticated).isTrue();

      writeGate.complete();
      await selecting;

      final after = container.read(authStateManagerProvider).requireValue;
      check(after.token).equals(_tokenA);
      check(after.isAuthenticated).isTrue();
    });
  }
}

/// The auth state once it is no longer loading: awaited as it is
/// published, never polled.
Future<AuthState> _settledAuth(ProviderContainer container) async {
  await container.read(authStateManagerProvider.future);
  final settled = Completer<AuthState>();
  final subscription = container.listen<AsyncValue<AuthState>>(
    authStateManagerProvider,
    (_, next) {
      final auth = next.value;
      if (auth != null && !auth.isLoading && !settled.isCompleted) {
        settled.complete(auth);
      }
    },
    fireImmediately: true,
  );
  try {
    return await settled.future;
  } finally {
    subscription.close();
  }
}

final class _Storage extends Mock implements OptimizedStorageService {}

/// Follows auth as the real barrier does, so auth telling it about a switch
/// runs against the same provider graph as in the app.
final class _RecordingIsolation extends OpenWebUiAccountStorageIsolation {
  @override
  void build() {
    ref.listen(authStateManagerProvider, (_, _) {});
  }
}
