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
import 'package:mocktail/mocktail.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

final class _LastAccountStorage implements OptimizedStorageService {
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

/// Moves [_LastAccountStorage.active] as the real account changes would.
final class _LastAccountAuth extends AuthStateManager {
  _LastAccountAuth(this.storage, {this.duringSignOut});

  final _LastAccountStorage storage;

  /// Runs while the sign-out waits on the server.
  final FutureOr<void> Function()? duringSignOut;
  final switches = <String>[];
  final signedOut = <String>[];

  @override
  Future<AuthState> build() async =>
      const AuthState(status: AuthStatus.unauthenticated);

  @override
  Future<bool> signOutAccount(String accountId, {String? thenActivate}) async {
    signedOut.add(accountId);
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

/// Signs in when told to, and records the accounts it folds sign-ins into.
final class _SigningInAuth extends AuthStateManager {
  final merges = <(String, String)>[];

  /// What a merge does: fold, or fail and put the session back. It fails a
  /// few times at most, so merging without end shows as a count, not a hang.
  bool mergeFails = false;

  @override
  Future<AuthState> build() async =>
      const AuthState(status: AuthStatus.unauthenticated);

  void signIn(String token, User user) => state = AsyncData(
    AuthState(status: AuthStatus.authenticated, token: token, user: user),
  );

  @override
  Future<bool> mergeActiveAccountInto(
    String targetAccountId, {
    required String expectedSourceAccountId,
    String? expectedToken,
  }) async {
    merges.add((targetAccountId, expectedSourceAccountId));
    if (!mergeFails || merges.length > 3) return true;
    // Storage refused; the session is put back, and published again.
    final current = state.requireValue;
    state = const AsyncData(AuthState(status: AuthStatus.loading));
    state = AsyncData(current);
    return false;
  }
}

/// Serves the registry once [release] completes.
final class _HeldRegistryStorage implements OptimizedStorageService {
  _HeldRegistryStorage(this.registry);

  final OpenWebUiRegistry registry;
  final Completer<void> release = Completer<void>();

  @override
  Future<OpenWebUiRegistry> getOpenWebUiRegistryStrict() async {
    await release.future;
    return registry;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

final class _EmptyHermes extends HermesConfigController {
  @override
  HermesConfig build() => const HermesConfig();
}

OpenWebUiAccountEntry _accountEntry(
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
  _LastAccountStorage? storage,
}) async {
  final accountStorage = storage ?? _LastAccountStorage();
  final container = ProviderContainer(
    overrides: [
      optimizedStorageServiceProvider.overrideWithValue(accountStorage),
      authStateManagerProvider.overrideWith(
        () => _LastAccountAuth(accountStorage),
      ),
      hermesConfigProvider.overrideWith(_EmptyHermes.new),
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

/// The decisions the account controller makes before asking auth to act:
/// whether a reply may be cut off, which account takes over, and which
/// sign-ins may be abandoned.
void main() {
  late _Storage storage;
  late _RecordingAuth auth;
  var replyInProgress = false;
  var repliesStopped = 0;
  var activeId = 'a';
  var accounts = <OpenWebUiAccountEntry>[];

  final server = OpenWebUiServer(
    id: 's',
    name: 'Home',
    endpoints: [OpenWebUiEndpoint(id: 'e', url: 'https://chat.example')],
  );

  OpenWebUiAccountEntry entry(
    String id, {
    String? userId,
    bool hasSession = true,
    DateTime? lastUsedAt,
  }) => OpenWebUiAccountEntry(
    account: OpenWebUiAccount(id: id, serverId: 's', userId: userId ?? id),
    server: server,
    summary: OpenWebUiAccountSummary(lastUsedAt: lastUsedAt),
    isActive: id == activeId,
    hasSession: hasSession,
  );

  ProviderContainer container() {
    final container = ProviderContainer(
      overrides: [
        optimizedStorageServiceProvider.overrideWithValue(storage),
        authStateManagerProvider.overrideWith(() => auth),
        openWebUiAccountsProvider.overrideWith((ref) async => accounts),
        accountChangeReplyGuardProvider.overrideWithValue(
          () => replyInProgress,
        ),
        accountChangeStopRepliesProvider.overrideWithValue(
          () => repliesStopped++,
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  setUp(() async {
    PreferencesStore.installLoader(() async => InMemoryKeyValueStore());
    await PreferencesStore.ensureInitialized();
    storage = _Storage();
    auth = _RecordingAuth();
    replyInProgress = false;
    repliesStopped = 0;
    activeId = 'a';
    accounts = [];
    when(
      () => storage.getEffectiveActiveServerId(),
    ).thenAnswer((_) async => activeId);
  });

  tearDown(PreferencesStore.debugReset);

  group('switching', () {
    test('will not cut off a reply unless told to', () async {
      replyInProgress = true;
      final controller = container().read(openWebUiAccountsControllerProvider);

      check(await controller.switchTo('b'))
          .equals(OpenWebUiAccountChangeResult.blockedByActiveReply);
      check(auth.switchedTo).isEmpty();

      check(await controller.switchTo('b', force: true))
          .equals(OpenWebUiAccountChangeResult.done);
      check(repliesStopped).equals(1);
      check(auth.switchedTo).deepEquals(['b']);
    });

    test('reports an account that needs a sign-in', () async {
      auth.signedInAfterSwitch = false;
      final controller = container().read(openWebUiAccountsControllerProvider);

      check(await controller.switchTo('b'))
          .equals(OpenWebUiAccountChangeResult.needsSignIn);
    });

    test('does nothing for the account already active', () async {
      final controller = container().read(openWebUiAccountsControllerProvider);

      check(await controller.switchTo('a'))
          .equals(OpenWebUiAccountChangeResult.alreadyActive);
      check(auth.switchedTo).isEmpty();
    });
  });

  group('signing out of the active account', () {
    test('hands over to the most recent account still signed in', () async {
      accounts = [
        entry('a'),
        entry('older', lastUsedAt: DateTime(2026, 1, 1)),
        entry('signed-out', hasSession: false, lastUsedAt: DateTime(2026, 9)),
        entry('newer', lastUsedAt: DateTime(2026, 6, 1)),
      ];
      final controller = container().read(openWebUiAccountsControllerProvider);

      await controller.signOut('a');

      check(auth.signedOut).deepEquals([('a', 'newer')]);
    });

    test('of an inactive account touches nothing else', () async {
      accounts = [entry('a'), entry('b')];
      replyInProgress = true;
      final controller = container().read(openWebUiAccountsControllerProvider);

      check(await controller.signOut('b'))
          .equals(OpenWebUiAccountChangeResult.done);
      // A takes over only if a sign-in makes B active meanwhile.
      check(auth.signedOut).deepEquals([('b', 'a')]);
      check(repliesStopped).equals(0);
    });
  });

  group('abandoning a sign-in', () {
    test('drops an added account that never signed in', () async {
      accounts = [
        entry('a', hasSession: false).withUser(null),
        entry('b', lastUsedAt: DateTime(2026, 9)),
      ];
      final container_ = container();
      container_.read(accountAdditionOriginProvider.notifier).begin('b');

      check(await container_.read(pendingSignInAbandonableProvider.future))
          .isTrue();
      check(
        await container_
            .read(openWebUiAccountsControllerProvider)
            .abandonPendingSignIn(),
      ).isTrue();
      check(auth.signedOut).deepEquals([('a', 'b')]);
    });

    test('leaves an account carried over without a known user alone',
        () async {
      // Migrated from before accounts existed, with no owner on record: it
      // looks like an unfinished addition, but none is in progress.
      accounts = [
        entry('a', hasSession: false).withUser(null),
        entry('b', lastUsedAt: DateTime(2026, 9)),
      ];
      final container_ = container();

      check(await container_.read(pendingSignInAbandonableProvider.future))
          .isFalse();
      check(
        await container_
            .read(openWebUiAccountsControllerProvider)
            .abandonPendingSignIn(),
      ).isFalse();
      check(auth.signedOut).isEmpty();
    });

    test('keeps an added account whose sign-in finishes meanwhile', () async {
      accounts = [
        entry('a', hasSession: false).withUser(null),
        entry('b', lastUsedAt: DateTime(2026, 9)),
      ];
      var reads = 0;
      // The sign-in lands once the account has been found still pending.
      when(() => storage.getEffectiveActiveServerId()).thenAnswer((_) async {
        if (++reads == 2) auth.signIn();
        return activeId;
      });
      final container_ = container();
      container_.read(accountAdditionOriginProvider.notifier).begin('b');
      await container_.read(authStateManagerProvider.future);

      check(
        await container_
            .read(openWebUiAccountsControllerProvider)
            .abandonPendingSignIn(),
      ).isFalse();
      check(auth.signedOut).isEmpty();
    });

    test('keeps an account that has signed in before', () async {
      accounts = [entry('a', hasSession: false), entry('b')];
      final container_ = container();

      check(await container_.read(pendingSignInAbandonableProvider.future))
          .isFalse();
      check(
        await container_
            .read(openWebUiAccountsControllerProvider)
            .abandonPendingSignIn(),
      ).isFalse();
      check(auth.signedOut).isEmpty();
    });

    test('keeps it when there is nowhere to go back to', () async {
      accounts = [
        entry('a', hasSession: false).withUser(null),
        entry('b', hasSession: false),
      ];
      final container_ = container();

      check(await container_.read(pendingSignInAbandonableProvider.future))
          .isFalse();
    });
  });

  group('with no account left', () {
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
      final storage = _LastAccountStorage();

      final preferred = await _signOutOfLastAccount(() async {
        storage.active = 'c';
        return const [];
      }, storage: storage);

      check(preferred).equals(PreferredBackend.unset);
      check(
        PreferencesStore.getString(PreferenceKeys.preferredBackend),
      ).isNull();
    });
  });

  test('a duplicate account whose merge fails is not merged again and again',
      () async {
    const userA = User(id: 'user-a', username: 'a', email: 'a@x', role: 'user');
    final storage = _HeldRegistryStorage(
      OpenWebUiRegistry(
        servers: [
          OpenWebUiServer(
            id: 's',
            name: 'Chat',
            endpoints: [OpenWebUiEndpoint(id: 'e', url: 'https://chat.example')],
          ),
        ],
        accounts: [
          OpenWebUiAccount(id: 'a', serverId: 's', userId: 'user-a'),
          OpenWebUiAccount(id: 'added', serverId: 's'),
        ],
      ),
    )..release.complete();
    final auth = _SigningInAuth()..mergeFails = true;
    final container = ProviderContainer(
      overrides: [
        optimizedStorageServiceProvider.overrideWithValue(storage),
        authStateManagerProvider.overrideWith(() => auth),
      ],
    );
    addTearDown(container.dispose);
    container.read(openWebUiDuplicateAccountReconcilerProvider);
    await container.read(authStateManagerProvider.future);

    await PreferencesStore.put(PreferenceKeys.activeServerId, 'added');
    auth.signIn('token', userA);
    await pumpEventQueue();

    check(auth.merges).deepEquals([('a', 'added')]);
  });

  test('a sign-in published while another is reconciled is still folded '
      'into its account', () async {
    const userA = User(id: 'user-a', username: 'a', email: 'a@x', role: 'user');
    const userB = User(id: 'user-b', username: 'b', email: 'b@x', role: 'user');
    final storage = _HeldRegistryStorage(
      OpenWebUiRegistry(
        servers: [
          OpenWebUiServer(
            id: 's',
            name: 'Chat',
            endpoints: [OpenWebUiEndpoint(id: 'e', url: 'https://chat.example')],
          ),
        ],
        accounts: [
          OpenWebUiAccount(id: 'a', serverId: 's', userId: 'user-a'),
          OpenWebUiAccount(id: 'b', serverId: 's', userId: 'user-b'),
          OpenWebUiAccount(id: 'added-1', serverId: 's'),
          OpenWebUiAccount(id: 'added-2', serverId: 's'),
        ],
      ),
    );
    final auth = _SigningInAuth();
    final container = ProviderContainer(
      overrides: [
        optimizedStorageServiceProvider.overrideWithValue(storage),
        authStateManagerProvider.overrideWith(() => auth),
      ],
    );
    addTearDown(container.dispose);
    container.read(openWebUiDuplicateAccountReconcilerProvider);
    await container.read(authStateManagerProvider.future);

    // A's sign-in is being reconciled when B's lands; A's is then stale.
    await PreferencesStore.put(PreferenceKeys.activeServerId, 'added-1');
    auth.signIn('token-1', userA);
    await PreferencesStore.put(PreferenceKeys.activeServerId, 'added-2');
    auth.signIn('token-2', userB);
    storage.release.complete();
    await pumpEventQueue();

    check(auth.merges).deepEquals([('b', 'added-2')]);
  });

  test('an inactive account is signed out of when the others cannot be read',
      () async {
    final storage = _LastAccountStorage();
    final auth = _LastAccountAuth(storage);
    final container = ProviderContainer(
      overrides: [
        optimizedStorageServiceProvider.overrideWithValue(storage),
        authStateManagerProvider.overrideWith(() => auth),
        hermesConfigProvider.overrideWith(_EmptyHermes.new),
        openWebUiAccountsProvider.overrideWith(
          (ref) async => throw StateError('locked'),
        ),
        accountChangeReplyGuardProvider.overrideWithValue(() => false),
      ],
    );
    addTearDown(container.dispose);

    await container.read(openWebUiAccountsControllerProvider).signOut('b');

    check(auth.signedOut).deepEquals(['b']);
  });

  test('choosing the account in use while it is signed out goes to auth',
      () async {
    final storage = _LastAccountStorage();
    final auth = _LastAccountAuth(storage);
    var listed = 0;
    final container = ProviderContainer(
      overrides: [
        optimizedStorageServiceProvider.overrideWithValue(storage),
        authStateManagerProvider.overrideWith(() => auth),
        hermesConfigProvider.overrideWith(_EmptyHermes.new),
        openWebUiAccountsProvider.overrideWith((ref) async {
          listed++;
          return const [];
        }),
        accountChangeReplyGuardProvider.overrideWithValue(() => false),
      ],
    );
    addTearDown(container.dispose);
    await container.read(authStateManagerProvider.future);
    // The accounts list as shown before, the account signed out.
    await container.read(openWebUiAccountsProvider.future);

    final result = await container
        .read(openWebUiAccountsControllerProvider)
        .switchTo('a');

    // Auth can take up a session the account still has in its vault.
    check(auth.switches).deepEquals(['a']);
    check(result).equals(OpenWebUiAccountChangeResult.done);
    // And the accounts list is read again, showing it signed in.
    await container.read(openWebUiAccountsProvider.future);
    check(listed).equals(2);
  });

  test('a sign-out that cannot read the account in use afterwards changes '
      'nothing more', () async {
    final storage = _LastAccountStorage();
    final container = ProviderContainer(
      overrides: [
        optimizedStorageServiceProvider.overrideWithValue(storage),
        authStateManagerProvider.overrideWith(
          () => _LastAccountAuth(
            storage,
            duringSignOut: () => storage.readError = StateError('locked'),
          ),
        ),
        hermesConfigProvider.overrideWith(_EmptyHermes.new),
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
    final storage = _LastAccountStorage();
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
    final storage = _LastAccountStorage()..active = 'old';
    final container = ProviderContainer(
      overrides: [
        optimizedStorageServiceProvider.overrideWithValue(storage),
        authStateManagerProvider.overrideWith(() => _LastAccountAuth(storage)),
        hermesConfigProvider.overrideWith(_EmptyHermes.new),
        openWebUiAccountsProvider.overrideWith((ref) async {
          final summaries = ref.watch(openWebUiAccountSummariesProvider);
          return [
            for (final id in ['old', 'a', 'b', 'c'])
              _accountEntry(id, hasSession: id != 'c', summary: summaries[id]),
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
    late _LastAccountStorage storage;
    late _LastAccountAuth auth;
    late ProviderContainer container;
    late List<String?> hostChanges;

    void start({FutureOr<void> Function()? duringSignOut}) {
      storage = _LastAccountStorage();
      auth = _LastAccountAuth(storage, duringSignOut: duringSignOut);
      hostChanges = [];
      container = ProviderContainer(
        overrides: [
          optimizedStorageServiceProvider.overrideWithValue(storage),
          authStateManagerProvider.overrideWith(() => auth),
          hermesConfigProvider.overrideWith(_EmptyHermes.new),
          openWebUiAccountsProvider.overrideWith(
            (ref) async => [
              _accountEntry('a'),
              _accountEntry('b'),
              _accountEntry('c', hasSession: false),
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

    test('leaving an addition while a sign-in lands elsewhere leaves that '
        'alone', () async {
      start(duringSignOut: () => storage.active = 'elsewhere');
      container.read(accountAdditionOriginProvider.notifier).begin('a');
      storage.active = 'c';

      check(
        await container
            .read(openWebUiAccountsControllerProvider)
            .abandonPendingSignIn(),
      ).isTrue();

      check(storage.active).equals('elsewhere');
      check(hostChanges).isEmpty();
      check(container.read(openWebUiAccountSummariesProvider)).isEmpty();
    });

    test('leaving an addition waits for a change in progress', () async {
      final serverAsked = Completer<void>();
      start(duringSignOut: () => serverAsked.future);
      container.read(accountAdditionOriginProvider.notifier).begin('a');
      storage.active = 'c';
      final controller = container.read(openWebUiAccountsControllerProvider);

      final signingOut = controller.signOut('a');
      final leaving = controller.abandonPendingSignIn();
      await pumpEventQueue();

      check(auth.signedOut).deepEquals(['a']);
      serverAsked.complete();
      await signingOut;
      check(await leaving).isTrue();
      check(auth.signedOut).deepEquals(['a', 'c']);
    });
  });

  test('cancelling an addition goes back to the account signed in to last', () async {
    final storage = _LastAccountStorage()..active = 'old';
    final container = ProviderContainer(
      overrides: [
        optimizedStorageServiceProvider.overrideWithValue(storage),
        authStateManagerProvider.overrideWith(() => _LastAccountAuth(storage)),
        hermesConfigProvider.overrideWith(_EmptyHermes.new),
        openWebUiAccountsProvider.overrideWith((ref) async {
          final summaries = ref.watch(openWebUiAccountSummariesProvider);
          return [
            for (final id in ['old', 'a', 'b', 'c'])
              _accountEntry(id, hasSession: id != 'c', summary: summaries[id]),
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
    // Another addition starts from B, and is cancelled before signing in.
    container.read(accountAdditionOriginProvider.notifier).begin('b');
    storage.active = 'c';

    check(await controller.abandonPendingSignIn()).isTrue();
    check(storage.active).equals('b');
  });
}

extension on OpenWebUiAccountEntry {
  OpenWebUiAccountEntry withUser(String? userId) => OpenWebUiAccountEntry(
    account: account.copyWith(userId: userId),
    server: server,
    summary: summary,
    isActive: isActive,
    hasSession: hasSession,
  );
}

final class _Storage extends Mock implements OptimizedStorageService {}

final class _RecordingAuth extends AuthStateManager {
  final switchedTo = <String>[];
  final signedOut = <(String, String?)>[];
  bool signedInAfterSwitch = true;

  @override
  Future<AuthState> build() async =>
      const AuthState(status: AuthStatus.unauthenticated);

  @override
  Future<bool> switchToAccount(String accountId) async {
    switchedTo.add(accountId);
    return signedInAfterSwitch;
  }

  @override
  Future<bool> signOutAccount(String accountId, {String? thenActivate}) async {
    signedOut.add((accountId, thenActivate));
    return thenActivate != null;
  }

  void signIn() => state = const AsyncData(
    AuthState(
      status: AuthStatus.authenticated,
      token: 'token',
      user: User(id: 'user', username: 'u', email: 'u@x', role: 'user'),
    ),
  );
}