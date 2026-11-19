import 'dart:async';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/account_storage_isolation.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/persistence/hive_boxes.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/ports/secure_key_value_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:drift/native.dart';
import 'package:hive_ce/hive.dart';
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

  group('a proxy sign-in staged for an account', () {
    late Directory tempDir;
    late WorkerManager workers;
    late AppDatabase database;
    late OptimizedStorageService storage;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('proxy-staged-test');
      Hive.init(tempDir.path);
      workers = WorkerManager(maxConcurrentTasks: 1);
      // The account's cache (its user), written at once: without one,
      // storage waits out its retries for a database to appear.
      database = AppDatabase(NativeDatabase.memory());
      storage = OptimizedStorageService(
        database: () => database,
        secureStorage: InMemorySecureKeyValueStore(),
        boxes: HiveBoxes(
          preferences: await Hive.openBox<dynamic>(HiveBoxNames.preferences),
          caches: await Hive.openBox<dynamic>(HiveBoxNames.caches),
          attachmentQueue: await Hive.openBox<dynamic>(
            HiveBoxNames.attachmentQueue,
          ),
          metadata: await Hive.openBox<dynamic>(HiveBoxNames.metadata),
        ),
        workerManager: workers,
      );
    });

    tearDown(() async {
      workers.dispose();
      await database.close();
      await Hive.close();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    // Another window moved the account to another address while its proxy
    // sign-in was staged: storage dropped its session, and the staged
    // sign-in stops. The session it would settle back to was the old
    // address's, and must not reach a client built for the new one.
    test('puts no session back once an edit moved its account', () async {
      const account = ServerConfig(
        id: 'account-a',
        name: 'A',
        url: 'https://a.example',
        isActive: true,
      );
      await storage.saveServerConfigs([account]);
      await storage.setActiveServerId(account.id);
      await storage.bindAccountUser(account.id, _userA.id);
      await storage.saveLocalUser(_userA);
      await storage.saveAuthToken(_tokenA);
      final container = ProviderContainer(
        overrides: [
          optimizedStorageServiceProvider.overrideWithValue(storage),
          apiServiceProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);
      final initial = await _settledAuth(container);
      check(initial.isAuthenticated).isTrue();
      check(initial.token).equals(_tokenA);

      final configs = storage.serverConfigRevision;
      await storage.saveServerConfigs([
        account.copyWith(url: 'https://a-moved.example'),
      ]);
      check(await storage.getAuthTokenStrict()).isNull();

      final committed = await container
          .read(authStateManagerProvider.notifier)
          .commitPrevalidatedProxySession(
            serverConfig: account,
            token: 'staged-session',
            user: _userA,
            configRevision: configs,
          );

      check(committed).isFalse();
      check(container.read(authStateManagerProvider).requireValue.token)
          .isNull();
      check(container.read(apiAuthTokenMirrorProvider)).isNull();
    });
  });
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
