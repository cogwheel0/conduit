import 'dart:async';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/core/auth/auth_state_manager.dart';
import 'package:conduit/core/auth/api_auth_interceptor.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/models/user.dart';
import 'package:conduit/core/persistence/persistence_keys.dart';
import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/optimized_storage_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const previousConfig = ServerConfig(
    id: 'previous',
    name: 'Previous',
    url: 'https://previous.example',
    isActive: true,
  );
  const candidate = ServerConfig(
    id: 'candidate',
    name: 'Candidate',
    url: 'https://candidate.example',
    isActive: true,
  );
  const user = User(
    id: 'user',
    username: 'user',
    email: 'user@example.test',
    role: 'user',
  );
  const token = 'validated-proxy-token';

  setUpAll(() {
    registerFallbackValue(<ServerConfig>[]);
    registerFallbackValue(candidate);
    registerFallbackValue((
      revision: 0,
      serverConfig: previousConfig,
      requireActive: true,
    ));
    registerFallbackValue(<String, String>{});
    registerFallbackValue(() => true);
    registerFallbackValue(() {});
  });

  test('an older delayed retry reset cannot clear a newer window', () async {
    final releaseOlderReset = Completer<void>();
    var generation = 1;
    var resetCount = 0;

    final olderReset = resetAuthRetryStateWhenCurrent(
      delay: releaseOlderReset.future,
      scheduledGeneration: generation,
      currentGeneration: () => generation,
      reset: () => resetCount++,
    );
    generation = 2;
    releaseOlderReset.complete();
    await olderReset;

    check(resetCount).equals(0);
  });

  test('a newer server selection fences the older publication', () async {
    SharedPreferences.setMockInitialValues({});
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());
    addTearDown(PreferencesStore.debugReset);
    final storage = _Storage();
    when(() => storage.getAuthTokenStrict()).thenAnswer((_) async => '');
    when(
      () => storage.getSavedCredentialsStrict(),
    ).thenAnswer((_) async => null);
    when(() => storage.saveLocalUser(null)).thenAnswer((_) async {});
    final firstEntered = Completer<void>();
    final releaseFirst = Completer<void>();
    final publishedServerIds = <String>[];
    when(
      () => storage.selectUnauthenticatedServerConfig(
        any(),
        publish: any(named: 'publish'),
        canCommit: any(named: 'canCommit'),
        onRollbackUncertain: any(named: 'onRollbackUncertain'),
      ),
    ).thenAnswer((invocation) async {
      final config = invocation.positionalArguments.single as ServerConfig;
      final canCommit =
          invocation.namedArguments[#canCommit] as bool Function();
      final publish =
          invocation.namedArguments[#publish] as FutureOr<void> Function();
      if (config.id == previousConfig.id) {
        firstEntered.complete();
        await releaseFirst.future;
      }
      if (!canCommit()) return false;
      await publish();
      publishedServerIds.add(config.id);
      return true;
    });

    final container = ProviderContainer(
      overrides: [
        optimizedStorageServiceProvider.overrideWithValue(storage),
        apiServiceProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);
    await container.read(authStateManagerProvider.future);
    await _waitForAuthStatus(container, AuthStatus.unauthenticated);
    final notifier = container.read(authStateManagerProvider.notifier);

    final olderSelection = notifier.selectUnauthenticatedServerConfig(
      previousConfig,
    );
    await firstEntered.future;
    await notifier.selectUnauthenticatedServerConfig(candidate);
    releaseFirst.complete();
    await olderSelection;

    check(publishedServerIds).deepEquals([candidate.id]);
    check(
      container.read(authStateManagerProvider).requireValue.status,
    ).equals(AuthStatus.unauthenticated);
  });

  test('a rolled-back login publication restores in-memory auth', () async {
    SharedPreferences.setMockInitialValues({});
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());
    addTearDown(PreferencesStore.debugReset);
    final storage = _Storage();
    when(() => storage.getAuthTokenStrict()).thenAnswer((_) async => '');
    when(
      () => storage.getSavedCredentialsStrict(),
    ).thenAnswer((_) async => null);
    when(() => storage.saveLocalUser(null)).thenAnswer((_) async {});
    when(
      () => storage.captureServerSessionOwnership(
        validatedConfig: any(named: 'validatedConfig'),
        requireActive: true,
      ),
    ).thenAnswer(
      (_) async =>
          (revision: 1, serverConfig: previousConfig, requireActive: true),
    );
    when(
      () => storage.commitExistingServerSession(
        ownership: any(named: 'ownership'),
        token: any(named: 'token'),
        canCommit: any(named: 'canCommit'),
        publish: any(named: 'publish'),
        rememberedCredentials: any(named: 'rememberedCredentials'),
        onRollbackUncertain: any(named: 'onRollbackUncertain'),
      ),
    ).thenAnswer((invocation) async {
      final publish =
          invocation.namedArguments[#publish] as FutureOr<void> Function();
      await publish();
      throw StateError('durable publication rollback');
    });
    final api = _SuccessfulAuthApi();
    final container = ProviderContainer(
      overrides: [
        optimizedStorageServiceProvider.overrideWithValue(storage),
        apiServiceProvider.overrideWithValue(api),
        defaultModelProvider.overrideWith((ref) async => null),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(api.dispose);
    await container.read(authStateManagerProvider.future);
    await _waitForAuthStatus(container, AuthStatus.unauthenticated);

    await check(
      container
          .read(authStateManagerProvider.notifier)
          .login('user', 'password'),
    ).throws<Exception>();

    final auth = container.read(authStateManagerProvider).requireValue;
    check(auth.status).equals(AuthStatus.unauthenticated);
    check(auth.token).isNull();
    check(auth.user).isNull();
    check(auth.isLoading).isFalse();
    check(api.authToken).isNull();
  });

  test(
    'login keeps the replacement API authenticated when clearing logout fence',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      PreferencesStore.debugOverride(await SharedPreferences.getInstance());
      addTearDown(PreferencesStore.debugReset);

      final storage = _Storage();
      when(() => storage.getAuthTokenStrict()).thenAnswer((_) async => '');
      when(
        () => storage.getSavedCredentialsStrict(),
      ).thenAnswer((_) async => null);
      when(() => storage.saveLocalUser(null)).thenAnswer((_) async {});
      when(
        () =>
            storage.saveLocalUserWithAvatar(user, avatarUrl: user.profileImage),
      ).thenAnswer((_) async {});
      when(
        () => storage.captureServerSessionOwnership(
          validatedConfig: any(named: 'validatedConfig'),
          requireActive: true,
        ),
      ).thenAnswer(
        (_) async =>
            (revision: 1, serverConfig: previousConfig, requireActive: true),
      );
      when(
        () => storage.commitExistingServerSession(
          ownership: any(named: 'ownership'),
          token: any(named: 'token'),
          canCommit: any(named: 'canCommit'),
          publish: any(named: 'publish'),
          rememberedCredentials: any(named: 'rememberedCredentials'),
          onRollbackUncertain: any(named: 'onRollbackUncertain'),
        ),
      ).thenAnswer((invocation) async {
        final canCommit =
            invocation.namedArguments[#canCommit] as bool Function();
        final publish =
            invocation.namedArguments[#publish] as FutureOr<void> Function();
        if (!canCommit()) return false;
        await publish();
        return canCommit();
      });

      final createdApis = <_SuccessfulAuthApi>[];
      final container = ProviderContainer(
        overrides: [
          optimizedStorageServiceProvider.overrideWithValue(storage),
          apiServiceProvider.overrideWith((ref) {
            ref.watch(incompleteLogoutFenceProvider);
            final api = _SuccessfulAuthApi();
            createdApis.add(api);
            ref.onDispose(api.dispose);
            return api;
          }),
          defaultModelProvider.overrideWith((ref) async => null),
        ],
      );
      addTearDown(container.dispose);
      await container.read(authStateManagerProvider.future);
      await _waitForAuthStatus(container, AuthStatus.unauthenticated);

      check(
        await container
            .read(incompleteLogoutFenceProvider.notifier)
            .persist(true),
      ).isTrue();
      final preLoginApi = container.read(apiServiceProvider);
      check(preLoginApi).isNotNull();

      check(
        await container
            .read(authStateManagerProvider.notifier)
            .login('user', 'password'),
      ).isTrue();

      final activeApi = container.read(apiServiceProvider);
      check(activeApi).isNotNull();
      check(activeApi!.authToken).equals(token);
      check(identical(activeApi, preLoginApi)).isFalse();
      check(createdApis.length >= 3).isTrue();
    },
  );

  test(
    'prevalidated proxy persistence failure restores config and session',
    () async {
      final storage = _Storage();
      when(() => storage.getAuthTokenStrict()).thenAnswer((_) async => '');
      when(
        () => storage.getSavedCredentialsStrict(),
      ).thenAnswer((_) async => null);
      when(() => storage.saveLocalUser(null)).thenAnswer((_) async {});
      when(() => storage.stageServerConfigCandidate(candidate)).thenAnswer(
        (_) async => (
          configs: const [previousConfig],
          activeServerId: previousConfig.id,
          transactionId: 7,
        ),
      );
      when(
        () => storage.commitServerConfigCandidateSession(
          candidate: candidate,
          transactionId: 7,
          token: token,
          canCommit: any(named: 'canCommit'),
          publish: any(named: 'publish'),
          onRollbackUncertain: any(named: 'onRollbackUncertain'),
        ),
      ).thenThrow(StateError('keychain'));
      when(
        () => storage.discardServerConfigCandidate(
          candidate: any(named: 'candidate'),
          transactionId: any(named: 'transactionId'),
        ),
      ).thenAnswer((_) async => true);

      final container = ProviderContainer(
        overrides: [
          optimizedStorageServiceProvider.overrideWithValue(storage),
          apiServiceProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);
      await container.read(authStateManagerProvider.future);
      await _waitForAuthStatus(container, AuthStatus.unauthenticated);

      await expectLater(
        container
            .read(authStateManagerProvider.notifier)
            .commitPrevalidatedProxySession(
              serverConfig: candidate,
              token: token,
              user: user,
            ),
        throwsA(isA<Exception>()),
      );

      final auth = container.read(authStateManagerProvider).requireValue;
      check(auth.status).equals(AuthStatus.unauthenticated);
      check(auth.token).isNull();
      check(auth.user).isNull();
      verify(
        () => storage.discardServerConfigCandidate(
          candidate: candidate,
          transactionId: 7,
        ),
      ).called(1);
    },
  );

  test('prevalidated proxy publishes only after token persistence', () async {
    final storage = _Storage();
    when(() => storage.getAuthTokenStrict()).thenAnswer((_) async => '');
    when(
      () => storage.getSavedCredentialsStrict(),
    ).thenAnswer((_) async => null);
    when(() => storage.saveLocalUser(null)).thenAnswer((_) async {});
    when(
      () => storage.saveLocalUserWithAvatar(user, avatarUrl: null),
    ).thenAnswer((_) async {});
    when(() => storage.stageServerConfigCandidate(candidate)).thenAnswer(
      (_) async => (
        configs: const [previousConfig],
        activeServerId: previousConfig.id,
        transactionId: 11,
      ),
    );
    when(
      () => storage.commitServerConfigCandidateSession(
        candidate: candidate,
        transactionId: 11,
        token: token,
        canCommit: any(named: 'canCommit'),
        publish: any(named: 'publish'),
        onRollbackUncertain: any(named: 'onRollbackUncertain'),
      ),
    ).thenAnswer((invocation) async {
      final canCommit =
          invocation.namedArguments[#canCommit] as bool Function();
      final publish =
          invocation.namedArguments[#publish] as FutureOr<void> Function();
      if (!canCommit()) return false;
      await publish();
      return true;
    });

    var defaultModelReads = 0;
    final container = ProviderContainer(
      overrides: [
        optimizedStorageServiceProvider.overrideWithValue(storage),
        apiServiceProvider.overrideWithValue(null),
        defaultModelProvider.overrideWith((ref) async {
          defaultModelReads += 1;
          return null;
        }),
      ],
    );
    addTearDown(container.dispose);
    await container.read(authStateManagerProvider.future);
    await _waitForAuthStatus(container, AuthStatus.unauthenticated);

    final committed = await container
        .read(authStateManagerProvider.notifier)
        .commitPrevalidatedProxySession(
          serverConfig: candidate,
          token: token,
          user: user,
        );

    check(committed).isTrue();
    final auth = container.read(authStateManagerProvider).requireValue;
    check(auth.status).equals(AuthStatus.authenticated);
    check(auth.token).equals(token);
    check(auth.user).equals(user);
    await Future<void>.delayed(Duration.zero);
    check(defaultModelReads).equals(0);
    verify(
      () => storage.commitServerConfigCandidateSession(
        candidate: candidate,
        transactionId: 11,
        token: token,
        canCommit: any(named: 'canCommit'),
        publish: any(named: 'publish'),
        onRollbackUncertain: any(named: 'onRollbackUncertain'),
      ),
    ).called(1);
    verifyNever(
      () => storage.discardServerConfigCandidate(
        candidate: any(named: 'candidate'),
        transactionId: any(named: 'transactionId'),
      ),
    );
  });

  test(
    'authenticated publication replaced synchronously cannot cache a stale user',
    () async {
      final storage = _Storage();
      when(() => storage.getAuthTokenStrict()).thenAnswer((_) async => '');
      when(
        () => storage.getSavedCredentialsStrict(),
      ).thenAnswer((_) async => null);
      when(() => storage.saveLocalUser(null)).thenAnswer((_) async {});
      when(() => storage.stageServerConfigCandidate(candidate)).thenAnswer(
        (_) async => (
          configs: const [previousConfig],
          activeServerId: previousConfig.id,
          transactionId: 13,
        ),
      );
      when(
        () => storage.commitServerConfigCandidateSession(
          candidate: candidate,
          transactionId: 13,
          token: token,
          canCommit: any(named: 'canCommit'),
          publish: any(named: 'publish'),
          onRollbackUncertain: any(named: 'onRollbackUncertain'),
        ),
      ).thenAnswer((invocation) async {
        final publish =
            invocation.namedArguments[#publish] as FutureOr<void> Function();
        await publish();
        return true;
      });

      final container = ProviderContainer(
        overrides: [
          optimizedStorageServiceProvider.overrideWithValue(storage),
          apiServiceProvider.overrideWithValue(null),
          defaultModelProvider.overrideWith((ref) async => null),
        ],
      );
      addTearDown(container.dispose);
      await container.read(authStateManagerProvider.future);
      await _waitForAuthStatus(container, AuthStatus.unauthenticated);

      var replaced = false;
      final subscription = container.listen(authStateManagerProvider, (
        previous,
        next,
      ) {
        if (replaced || next.asData?.value.isAuthenticated != true) return;
        replaced = true;
        container.read(authStateManagerProvider.notifier).onAuthIssue();
      });
      addTearDown(subscription.close);

      check(
        await container
            .read(authStateManagerProvider.notifier)
            .commitPrevalidatedProxySession(
              serverConfig: candidate,
              token: token,
              user: user,
            ),
      ).isTrue();
      await Future<void>.delayed(Duration.zero);

      check(replaced).isTrue();
      check(
        container.read(authStateManagerProvider).requireValue.status,
      ).equals(AuthStatus.error);
      verifyNever(() => storage.saveLocalUserWithAvatar(user, avatarUrl: null));
    },
  );

  test('overlapping failures restore the last settled auth state', () async {
    final storage = _Storage();
    when(() => storage.getAuthTokenStrict()).thenAnswer((_) async => '');
    when(
      () => storage.getSavedCredentialsStrict(),
    ).thenAnswer((_) async => null);
    when(() => storage.saveLocalUser(null)).thenAnswer((_) async {});
    var stageCall = 0;
    when(() => storage.stageServerConfigCandidate(candidate)).thenAnswer(
      (_) async => (
        configs: const [previousConfig],
        activeServerId: previousConfig.id,
        transactionId: ++stageCall,
      ),
    );
    when(
      () => storage.discardServerConfigCandidate(
        candidate: any(named: 'candidate'),
        transactionId: any(named: 'transactionId'),
      ),
    ).thenAnswer((_) async => true);
    final firstCommitEntered = Completer<void>();
    final releaseFirstCommit = Completer<void>();
    var commitCall = 0;
    when(
      () => storage.commitServerConfigCandidateSession(
        candidate: candidate,
        transactionId: any(named: 'transactionId'),
        token: token,
        canCommit: any(named: 'canCommit'),
        publish: any(named: 'publish'),
        onRollbackUncertain: any(named: 'onRollbackUncertain'),
      ),
    ).thenAnswer((_) async {
      commitCall++;
      if (commitCall == 1) {
        firstCommitEntered.complete();
        await releaseFirstCommit.future;
        return false;
      }
      throw StateError('second persistence failed');
    });

    final container = ProviderContainer(
      overrides: [
        optimizedStorageServiceProvider.overrideWithValue(storage),
        apiServiceProvider.overrideWithValue(null),
        defaultModelProvider.overrideWith((ref) async => null),
      ],
    );
    addTearDown(container.dispose);
    await container.read(authStateManagerProvider.future);
    await _waitForAuthStatus(container, AuthStatus.unauthenticated);
    final notifier = container.read(authStateManagerProvider.notifier);

    final first = notifier.commitPrevalidatedProxySession(
      serverConfig: candidate,
      token: token,
      user: user,
    );
    await firstCommitEntered.future;
    await expectLater(
      notifier.commitPrevalidatedProxySession(
        serverConfig: candidate,
        token: token,
        user: user,
      ),
      throwsA(isA<Exception>()),
    );

    final afterSecond = container.read(authStateManagerProvider).requireValue;
    check(afterSecond.status).equals(AuthStatus.unauthenticated);
    check(afterSecond.isLoading).isFalse();
    releaseFirstCommit.complete();
    check(await first).isFalse();
    final settled = container.read(authStateManagerProvider).requireValue;
    check(settled.status).equals(AuthStatus.unauthenticated);
    check(settled.isLoading).isFalse();
  });

  test(
    'incomplete proxy rollback never republishes the previous token',
    () async {
      final storage = _Storage();
      when(() => storage.getAuthTokenStrict()).thenAnswer((_) async => '');
      when(
        () => storage.getSavedCredentialsStrict(),
      ).thenAnswer((_) async => null);
      when(() => storage.saveLocalUser(null)).thenAnswer((_) async {});
      when(
        () => storage.saveLocalUserWithAvatar(user, avatarUrl: null),
      ).thenAnswer((_) async {});
      var stageCall = 17;
      when(() => storage.stageServerConfigCandidate(candidate)).thenAnswer(
        (_) async => (
          configs: const [previousConfig],
          activeServerId: previousConfig.id,
          transactionId: ++stageCall,
        ),
      );
      var commitCall = 0;
      when(
        () => storage.commitServerConfigCandidateSession(
          candidate: candidate,
          transactionId: any(named: 'transactionId'),
          token: token,
          canCommit: any(named: 'canCommit'),
          publish: any(named: 'publish'),
          onRollbackUncertain: any(named: 'onRollbackUncertain'),
        ),
      ).thenAnswer((invocation) async {
        if (++commitCall == 1) {
          final publish =
              invocation.namedArguments[#publish] as FutureOr<void> Function();
          await publish();
          return true;
        }
        throw const ServerConfigSessionRollbackException(
          commitError: 'candidate write failed',
          rollbackError: 'baseline restore failed',
        );
      });
      late ProviderContainer container;
      var tokenWasClearedBeforeConfigInvalidation = false;
      when(
        () => storage.discardServerConfigCandidate(
          candidate: candidate,
          transactionId: 19,
        ),
      ).thenAnswer((_) async {
        tokenWasClearedBeforeConfigInvalidation =
            container.read(authStateManagerProvider).requireValue.token == null;
        return false;
      });

      container = ProviderContainer(
        overrides: [
          optimizedStorageServiceProvider.overrideWithValue(storage),
          apiServiceProvider.overrideWithValue(null),
          defaultModelProvider.overrideWith((ref) async => null),
        ],
      );
      addTearDown(container.dispose);
      await container.read(authStateManagerProvider.future);
      await _waitForAuthStatus(container, AuthStatus.unauthenticated);

      final notifier = container.read(authStateManagerProvider.notifier);
      check(
        await notifier.commitPrevalidatedProxySession(
          serverConfig: candidate,
          token: token,
          user: user,
        ),
      ).isTrue();
      check(
        container.read(authStateManagerProvider).requireValue.status,
      ).equals(AuthStatus.authenticated);

      await expectLater(
        notifier.commitPrevalidatedProxySession(
          serverConfig: candidate,
          token: token,
          user: user,
        ),
        throwsA(isA<Exception>()),
      );

      final auth = container.read(authStateManagerProvider).requireValue;
      check(auth.status).equals(AuthStatus.unauthenticated);
      check(auth.token).isNull();
      check(auth.user).isNull();
      check(auth.isLoading).isFalse();
      check(tokenWasClearedBeforeConfigInvalidation).isTrue();
    },
  );

  test(
    'superseded rollback uncertainty poisons a newer failing attempt',
    () async {
      final storage = _Storage();
      when(() => storage.getAuthTokenStrict()).thenAnswer((_) async => '');
      when(
        () => storage.getSavedCredentialsStrict(),
      ).thenAnswer((_) async => null);
      when(() => storage.saveLocalUser(null)).thenAnswer((_) async {});
      when(
        () => storage.saveLocalUserWithAvatar(user, avatarUrl: null),
      ).thenAnswer((_) async {});
      var stageCall = 29;
      when(() => storage.stageServerConfigCandidate(candidate)).thenAnswer(
        (_) async => (
          configs: const [previousConfig],
          activeServerId: previousConfig.id,
          transactionId: ++stageCall,
        ),
      );
      when(
        () => storage.discardServerConfigCandidate(
          candidate: candidate,
          transactionId: any(named: 'transactionId'),
        ),
      ).thenAnswer((_) async => false);

      final olderCommitEntered = Completer<void>();
      final newerCommitEntered = Completer<void>();
      final releaseOlderCommit = Completer<void>();
      final releaseNewerCommit = Completer<void>();
      var commitCall = 0;
      when(
        () => storage.commitServerConfigCandidateSession(
          candidate: candidate,
          transactionId: any(named: 'transactionId'),
          token: token,
          canCommit: any(named: 'canCommit'),
          publish: any(named: 'publish'),
          onRollbackUncertain: any(named: 'onRollbackUncertain'),
        ),
      ).thenAnswer((invocation) async {
        switch (++commitCall) {
          case 1:
            final publish =
                invocation.namedArguments[#publish]
                    as FutureOr<void> Function();
            await publish();
            return true;
          case 2:
            olderCommitEntered.complete();
            await releaseOlderCommit.future;
            throw const ServerConfigSessionRollbackException(
              commitError: 'superseded candidate write failed',
              rollbackError: 'superseded baseline restore failed',
            );
          default:
            newerCommitEntered.complete();
            await releaseNewerCommit.future;
            throw StateError('newer persistence failed');
        }
      });

      final container = ProviderContainer(
        overrides: [
          optimizedStorageServiceProvider.overrideWithValue(storage),
          apiServiceProvider.overrideWithValue(null),
          defaultModelProvider.overrideWith((ref) async => null),
        ],
      );
      addTearDown(container.dispose);
      await container.read(authStateManagerProvider.future);
      await _waitForAuthStatus(container, AuthStatus.unauthenticated);
      final notifier = container.read(authStateManagerProvider.notifier);
      check(
        await notifier.commitPrevalidatedProxySession(
          serverConfig: candidate,
          token: token,
          user: user,
        ),
      ).isTrue();

      final older = notifier.commitPrevalidatedProxySession(
        serverConfig: candidate,
        token: token,
        user: user,
      );
      await olderCommitEntered.future;
      final newer = notifier.commitPrevalidatedProxySession(
        serverConfig: candidate,
        token: token,
        user: user,
      );
      await newerCommitEntered.future;

      releaseOlderCommit.complete();
      await expectLater(older, throwsA(isA<Exception>()));
      final poisonedLoading = container
          .read(authStateManagerProvider)
          .requireValue;
      check(poisonedLoading.status).equals(AuthStatus.loading);
      check(poisonedLoading.token).isNull();
      check(poisonedLoading.user).isNull();

      releaseNewerCommit.complete();
      await expectLater(newer, throwsA(isA<Exception>()));
      final settled = container.read(authStateManagerProvider).requireValue;
      check(settled.status).equals(AuthStatus.unauthenticated);
      check(settled.token).isNull();
      check(settled.user).isNull();
      check(settled.isLoading).isFalse();
    },
  );

  test(
    'foreground ownership rejection settles tokenless for every auth mode',
    () async {
      for (final mode in _MixedAuthMode.values) {
        final storage = _Storage();
        when(() => storage.getAuthTokenStrict()).thenAnswer((_) async => '');
        when(
          () => storage.getSavedCredentialsStrict(),
        ).thenAnswer((_) async => null);
        when(() => storage.saveLocalUser(null)).thenAnswer((_) async {});
        when(
          () => storage.saveLocalUserWithAvatar(user, avatarUrl: null),
        ).thenAnswer((_) async {});
        when(
          () => storage.captureServerSessionOwnership(
            validatedConfig: any(named: 'validatedConfig'),
            requireActive: true,
          ),
        ).thenAnswer(
          (_) async =>
              (revision: 1, serverConfig: previousConfig, requireActive: true),
        );
        when(
          () => storage.commitExistingServerSession(
            ownership: any(named: 'ownership'),
            token: any(named: 'token'),
            canCommit: any(named: 'canCommit'),
            publish: any(named: 'publish'),
            rememberedCredentials: any(named: 'rememberedCredentials'),
            onRollbackUncertain: any(named: 'onRollbackUncertain'),
          ),
        ).thenAnswer((_) async => false);

        final api = _SuccessfulAuthApi();
        final container = ProviderContainer(
          overrides: [
            optimizedStorageServiceProvider.overrideWithValue(storage),
            apiServiceProvider.overrideWithValue(api),
            defaultModelProvider.overrideWith((ref) async => null),
          ],
        );
        try {
          await container.read(authStateManagerProvider.future);
          await _waitForAuthStatus(container, AuthStatus.unauthenticated);
          final notifier = container.read(authStateManagerProvider.notifier);
          final committed = switch (mode) {
            _MixedAuthMode.password => notifier.login('user', 'password'),
            _MixedAuthMode.token => notifier.loginWithApiKey(token),
            _MixedAuthMode.ldap => notifier.ldapLogin('user', 'password'),
          };

          check(await committed).isFalse();
          final settled = container.read(authStateManagerProvider).requireValue;
          check(settled.status).equals(AuthStatus.unauthenticated);
          check(settled.token).isNull();
          check(settled.user).isNull();
          check(settled.isLoading).isFalse();
        } finally {
          container.dispose();
          api.dispose();
        }
      }
    },
  );

  test('logout supersedes a login before its first network request', () async {
    final storage = _Storage();
    when(() => storage.getAuthTokenStrict()).thenAnswer((_) async => '');
    when(
      () => storage.getSavedCredentialsStrict(),
    ).thenAnswer((_) async => null);
    when(() => storage.saveLocalUser(null)).thenAnswer((_) async {});
    when(() => storage.clearAuthData()).thenAnswer((_) async {});
    _routeConditionalAuthClearToLegacyMock(storage);
    final captureEntered = Completer<void>();
    final releaseCapture = Completer<void>();
    when(
      () => storage.captureServerSessionOwnership(
        validatedConfig: any(named: 'validatedConfig'),
        requireActive: true,
      ),
    ).thenAnswer((_) async {
      captureEntered.complete();
      await releaseCapture.future;
      return (revision: 1, serverConfig: previousConfig, requireActive: true);
    });

    final api = _SuccessfulAuthApi();
    final container = ProviderContainer(
      overrides: [
        optimizedStorageServiceProvider.overrideWithValue(storage),
        apiServiceProvider.overrideWithValue(api),
        defaultModelProvider.overrideWith((ref) async => null),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(api.dispose);
    await container.read(authStateManagerProvider.future);
    await _waitForAuthStatus(container, AuthStatus.unauthenticated);
    final notifier = container.read(authStateManagerProvider.notifier);

    final login = notifier.login('user', 'password');
    await captureEntered.future;
    await notifier.logout();
    releaseCapture.complete();

    check(await login).isFalse();
    check(api.loginCalls).equals(0);
    final settled = container.read(authStateManagerProvider).requireValue;
    check(settled.status).equals(AuthStatus.unauthenticated);
    check(settled.token).isNull();
    check(settled.isLoading).isFalse();
  });

  test(
    'logout started by an auth publication listener wins the commit',
    () async {
      SharedPreferences.setMockInitialValues({});
      PreferencesStore.debugOverride(await SharedPreferences.getInstance());
      addTearDown(PreferencesStore.debugReset);
      final storage = _Storage();
      when(() => storage.getAuthTokenStrict()).thenAnswer((_) async => '');
      when(
        () => storage.getSavedCredentialsStrict(),
      ).thenAnswer((_) async => null);
      when(() => storage.saveLocalUser(null)).thenAnswer((_) async {});
      when(
        () => storage.saveLocalUserWithAvatar(user, avatarUrl: null),
      ).thenAnswer((_) async {});
      when(() => storage.clearAuthData()).thenAnswer((_) async {});
      _routeConditionalAuthClearToLegacyMock(storage);
      when(
        () => storage.captureServerSessionOwnership(
          validatedConfig: any(named: 'validatedConfig'),
          requireActive: true,
        ),
      ).thenAnswer(
        (_) async =>
            (revision: 1, serverConfig: previousConfig, requireActive: true),
      );
      when(
        () => storage.commitExistingServerSession(
          ownership: any(named: 'ownership'),
          token: any(named: 'token'),
          canCommit: any(named: 'canCommit'),
          publish: any(named: 'publish'),
          rememberedCredentials: any(named: 'rememberedCredentials'),
          onRollbackUncertain: any(named: 'onRollbackUncertain'),
        ),
      ).thenAnswer((invocation) async {
        final publish =
            invocation.namedArguments[#publish] as FutureOr<void> Function();
        await publish();
        return true;
      });

      final api = _SuccessfulAuthApi();
      final container = ProviderContainer(
        overrides: [
          optimizedStorageServiceProvider.overrideWithValue(storage),
          apiServiceProvider.overrideWithValue(api),
          defaultModelProvider.overrideWith((ref) async => null),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(api.dispose);
      await container.read(authStateManagerProvider.future);
      await _waitForAuthStatus(container, AuthStatus.unauthenticated);
      final notifier = container.read(authStateManagerProvider.notifier);
      Future<void>? listenerLogout;
      var startedLogout = false;
      final subscription = container.listen<AsyncValue<AuthState>>(
        authStateManagerProvider,
        (previous, next) {
          final auth = next.asData?.value;
          if (!startedLogout && auth?.status == AuthStatus.authenticated) {
            startedLogout = true;
            listenerLogout = notifier.logout();
          }
        },
      );
      addTearDown(subscription.close);

      await expectLater(
        notifier.login('user', 'password'),
        throwsA(isA<Exception>()),
      );
      check(startedLogout).isTrue();
      await listenerLogout!;

      verify(() => storage.clearAuthData()).called(1);
      final settled = container.read(authStateManagerProvider).requireValue;
      check(settled.status).equals(AuthStatus.unauthenticated);
      check(settled.token).isNull();
      check(settled.user).isNull();
      check(settled.isLoading).isFalse();
      check(api.authToken).isNull();
    },
  );

  test('newer login wins while remote logout is delayed', () async {
    SharedPreferences.setMockInitialValues({});
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());
    addTearDown(PreferencesStore.debugReset);
    final storage = _Storage();
    when(() => storage.getAuthTokenStrict()).thenAnswer((_) async => '');
    when(
      () => storage.getSavedCredentialsStrict(),
    ).thenAnswer((_) async => null);
    when(() => storage.saveLocalUser(null)).thenAnswer((_) async {});
    when(
      () => storage.saveLocalUserWithAvatar(user, avatarUrl: null),
    ).thenAnswer((_) async {});
    _routeConditionalAuthClearToLegacyMock(storage);
    when(
      () => storage.captureServerSessionOwnership(
        validatedConfig: any(named: 'validatedConfig'),
        requireActive: true,
      ),
    ).thenAnswer(
      (_) async =>
          (revision: 1, serverConfig: previousConfig, requireActive: true),
    );
    when(
      () => storage.commitExistingServerSession(
        ownership: any(named: 'ownership'),
        token: any(named: 'token'),
        canCommit: any(named: 'canCommit'),
        publish: any(named: 'publish'),
        rememberedCredentials: any(named: 'rememberedCredentials'),
        onRollbackUncertain: any(named: 'onRollbackUncertain'),
      ),
    ).thenAnswer((invocation) async {
      final publish =
          invocation.namedArguments[#publish] as FutureOr<void> Function();
      await publish();
      return true;
    });
    final logoutEntered = Completer<void>();
    final releaseLogout = Completer<void>();
    final api = _SuccessfulAuthApi(
      logoutEntered: logoutEntered,
      releaseLogout: releaseLogout,
    );
    final container = ProviderContainer(
      overrides: [
        optimizedStorageServiceProvider.overrideWithValue(storage),
        apiServiceProvider.overrideWithValue(api),
        defaultModelProvider.overrideWith((ref) async => null),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(api.dispose);
    await container.read(authStateManagerProvider.future);
    await _waitForAuthStatus(container, AuthStatus.unauthenticated);
    final notifier = container.read(authStateManagerProvider.notifier);
    check(await notifier.login('first-user', 'password')).isTrue();
    api.loginToken = 'rotated-session-token';

    final logout = notifier.logout();
    await logoutEntered.future;
    check(await notifier.login('user', 'password')).isTrue();
    releaseLogout.complete();
    await logout;

    verifyNever(() => storage.clearAuthData());
    final settled = container.read(authStateManagerProvider).requireValue;
    check(settled.status).equals(AuthStatus.authenticated);
    check(settled.token).equals('rotated-session-token');
    check(settled.user).equals(user);
    check(api.authToken).equals('rotated-session-token');
  });

  test(
    'newer committed session still owns auth data in connection error state',
    () async {
      SharedPreferences.setMockInitialValues({});
      PreferencesStore.debugOverride(await SharedPreferences.getInstance());
      addTearDown(PreferencesStore.debugReset);
      final storage = _Storage();
      when(() => storage.getAuthTokenStrict()).thenAnswer((_) async => '');
      when(
        () => storage.getSavedCredentialsStrict(),
      ).thenAnswer((_) async => null);
      when(() => storage.saveLocalUser(null)).thenAnswer((_) async {});
      when(
        () => storage.saveLocalUserWithAvatar(user, avatarUrl: null),
      ).thenAnswer((_) async {});
      when(() => storage.clearAuthData()).thenAnswer((_) async {});
      _routeConditionalAuthClearToLegacyMock(storage);
      when(
        () => storage.captureServerSessionOwnership(
          validatedConfig: any(named: 'validatedConfig'),
          requireActive: true,
        ),
      ).thenAnswer(
        (_) async =>
            (revision: 1, serverConfig: previousConfig, requireActive: true),
      );
      when(
        () => storage.commitExistingServerSession(
          ownership: any(named: 'ownership'),
          token: any(named: 'token'),
          canCommit: any(named: 'canCommit'),
          publish: any(named: 'publish'),
          rememberedCredentials: any(named: 'rememberedCredentials'),
          onRollbackUncertain: any(named: 'onRollbackUncertain'),
        ),
      ).thenAnswer((invocation) async {
        final publish =
            invocation.namedArguments[#publish] as FutureOr<void> Function();
        await publish();
        return true;
      });
      final logoutEntered = Completer<void>();
      final releaseLogout = Completer<void>();
      final api = _SuccessfulAuthApi(
        logoutEntered: logoutEntered,
        releaseLogout: releaseLogout,
      );
      final container = ProviderContainer(
        overrides: [
          optimizedStorageServiceProvider.overrideWithValue(storage),
          apiServiceProvider.overrideWithValue(api),
          defaultModelProvider.overrideWith((ref) async => null),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(api.dispose);
      await container.read(authStateManagerProvider.future);
      await _waitForAuthStatus(container, AuthStatus.unauthenticated);
      final notifier = container.read(authStateManagerProvider.notifier);
      check(await notifier.login('first-user', 'password')).isTrue();
      api.loginToken = 'rotated-session-token';

      final logout = notifier.logout();
      await logoutEntered.future;
      check(await notifier.login('new-user', 'password')).isTrue();
      notifier.onAuthIssue();
      final errorState = container.read(authStateManagerProvider).requireValue;
      check(errorState.status).equals(AuthStatus.error);
      check(errorState.token).equals('rotated-session-token');

      releaseLogout.complete();
      await logout;

      verifyNever(() => storage.clearAuthData());
      final settled = container.read(authStateManagerProvider).requireValue;
      check(settled.status).equals(AuthStatus.error);
      check(settled.token).equals('rotated-session-token');
      check(settled.user).equals(user);
      check(settled.isLoading).isFalse();
      check(api.authToken).equals('rotated-session-token');
    },
  );

  test(
    'successful refresh carries newer session ownership past delayed logout',
    () async {
      SharedPreferences.setMockInitialValues({});
      PreferencesStore.debugOverride(await SharedPreferences.getInstance());
      addTearDown(PreferencesStore.debugReset);
      final storage = _Storage();
      String? storedToken;
      when(
        () => storage.getAuthTokenStrict(),
      ).thenAnswer((_) async => storedToken ?? '');
      when(
        () => storage.getSavedCredentialsStrict(),
      ).thenAnswer((_) async => null);
      when(
        () => storage.getLocalUserWithAvatar(),
      ).thenAnswer((_) async => user);
      when(() => storage.saveLocalUser(null)).thenAnswer((_) async {});
      when(
        () => storage.saveLocalUserWithAvatar(user, avatarUrl: null),
      ).thenAnswer((_) async {});
      when(() => storage.clearAuthData()).thenAnswer((_) async {});
      _routeConditionalAuthClearToLegacyMock(storage);
      when(
        () => storage.captureServerSessionOwnership(
          validatedConfig: any(named: 'validatedConfig'),
          requireActive: true,
        ),
      ).thenAnswer(
        (_) async =>
            (revision: 1, serverConfig: previousConfig, requireActive: true),
      );
      when(
        () => storage.commitExistingServerSession(
          ownership: any(named: 'ownership'),
          token: any(named: 'token'),
          canCommit: any(named: 'canCommit'),
          publish: any(named: 'publish'),
          rememberedCredentials: any(named: 'rememberedCredentials'),
          onRollbackUncertain: any(named: 'onRollbackUncertain'),
        ),
      ).thenAnswer((invocation) async {
        storedToken = invocation.namedArguments[#token] as String;
        final publish =
            invocation.namedArguments[#publish] as FutureOr<void> Function();
        await publish();
        return true;
      });
      final logoutEntered = Completer<void>();
      final releaseLogout = Completer<void>();
      final api = _SuccessfulAuthApi(
        logoutEntered: logoutEntered,
        releaseLogout: releaseLogout,
      );
      final container = ProviderContainer(
        overrides: [
          optimizedStorageServiceProvider.overrideWithValue(storage),
          apiServiceProvider.overrideWithValue(api),
          defaultModelProvider.overrideWith((ref) async => null),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(api.dispose);
      await container.read(authStateManagerProvider.future);
      await _waitForAuthStatus(container, AuthStatus.unauthenticated);
      final notifier = container.read(authStateManagerProvider.notifier);
      check(await notifier.login('first-user', 'password')).isTrue();
      api.loginToken = 'rotated-session-token';

      final logout = notifier.logout();
      await logoutEntered.future;
      check(await notifier.login('new-user', 'password')).isTrue();
      await notifier.refresh();
      final refreshed = container.read(authStateManagerProvider).requireValue;
      check(refreshed.status).equals(AuthStatus.authenticated);
      check(refreshed.token).equals('rotated-session-token');

      releaseLogout.complete();
      await logout;

      verifyNever(() => storage.clearAuthData());
      final settled = container.read(authStateManagerProvider).requireValue;
      check(settled.status).equals(AuthStatus.authenticated);
      check(settled.token).equals('rotated-session-token');
      check(settled.user).equals(user);
      check(api.authToken).equals('rotated-session-token');
    },
  );

  test(
    'remote logout rejects a newer commit that reuses the revoked token',
    () async {
      SharedPreferences.setMockInitialValues({});
      PreferencesStore.debugOverride(await SharedPreferences.getInstance());
      addTearDown(PreferencesStore.debugReset);
      final storage = _Storage();
      when(() => storage.getAuthTokenStrict()).thenAnswer((_) async => '');
      when(
        () => storage.getSavedCredentialsStrict(),
      ).thenAnswer((_) async => null);
      when(() => storage.saveLocalUser(null)).thenAnswer((_) async {});
      when(
        () => storage.saveLocalUserWithAvatar(user, avatarUrl: null),
      ).thenAnswer((_) async {});
      when(() => storage.clearAuthData()).thenAnswer((_) async {});
      _routeConditionalAuthClearToLegacyMock(storage);
      when(
        () => storage.captureServerSessionOwnership(
          validatedConfig: any(named: 'validatedConfig'),
          requireActive: true,
        ),
      ).thenAnswer(
        (_) async =>
            (revision: 1, serverConfig: previousConfig, requireActive: true),
      );
      when(
        () => storage.commitExistingServerSession(
          ownership: any(named: 'ownership'),
          token: any(named: 'token'),
          canCommit: any(named: 'canCommit'),
          publish: any(named: 'publish'),
          rememberedCredentials: any(named: 'rememberedCredentials'),
          onRollbackUncertain: any(named: 'onRollbackUncertain'),
        ),
      ).thenAnswer((invocation) async {
        final publish =
            invocation.namedArguments[#publish] as FutureOr<void> Function();
        await publish();
        return true;
      });
      final logoutEntered = Completer<void>();
      final releaseLogout = Completer<void>();
      final api = _SuccessfulAuthApi(
        logoutEntered: logoutEntered,
        releaseLogout: releaseLogout,
      );
      final container = ProviderContainer(
        overrides: [
          optimizedStorageServiceProvider.overrideWithValue(storage),
          apiServiceProvider.overrideWithValue(api),
          defaultModelProvider.overrideWith((ref) async => null),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(api.dispose);
      await container.read(authStateManagerProvider.future);
      await _waitForAuthStatus(container, AuthStatus.unauthenticated);
      final notifier = container.read(authStateManagerProvider.notifier);
      check(await notifier.login('first-user', 'password')).isTrue();

      final logout = notifier.logout();
      await logoutEntered.future;
      await check(
        notifier.login('same-token-user', 'password'),
      ).throws<Exception>();
      releaseLogout.complete();
      await logout;

      verify(() => storage.clearAuthData()).called(1);
      final settled = container.read(authStateManagerProvider).requireValue;
      check(settled.status).equals(AuthStatus.unauthenticated);
      check(settled.token).isNull();
      check(settled.user).isNull();
      check(settled.isLoading).isFalse();
      check(api.authToken).isNull();
    },
  );

  test(
    'dispatched logout with a lost response rejects same-token resurrection',
    () async {
      SharedPreferences.setMockInitialValues({});
      PreferencesStore.debugOverride(await SharedPreferences.getInstance());
      addTearDown(PreferencesStore.debugReset);
      final storage = _Storage();
      when(() => storage.getAuthTokenStrict()).thenAnswer((_) async => '');
      when(
        () => storage.getSavedCredentialsStrict(),
      ).thenAnswer((_) async => null);
      when(() => storage.saveLocalUser(null)).thenAnswer((_) async {});
      when(
        () => storage.saveLocalUserWithAvatar(user, avatarUrl: null),
      ).thenAnswer((_) async {});
      when(() => storage.clearAuthData()).thenAnswer((_) async {});
      _routeConditionalAuthClearToLegacyMock(storage);
      when(
        () => storage.captureServerSessionOwnership(
          validatedConfig: any(named: 'validatedConfig'),
          requireActive: true,
        ),
      ).thenAnswer(
        (_) async =>
            (revision: 1, serverConfig: previousConfig, requireActive: true),
      );
      when(
        () => storage.commitExistingServerSession(
          ownership: any(named: 'ownership'),
          token: any(named: 'token'),
          canCommit: any(named: 'canCommit'),
          publish: any(named: 'publish'),
          rememberedCredentials: any(named: 'rememberedCredentials'),
          onRollbackUncertain: any(named: 'onRollbackUncertain'),
        ),
      ).thenAnswer((invocation) async {
        final publish =
            invocation.namedArguments[#publish] as FutureOr<void> Function();
        await publish();
        return true;
      });
      final logoutEntered = Completer<void>();
      final releaseLogout = Completer<void>();
      final api = _SuccessfulAuthApi(
        logoutEntered: logoutEntered,
        releaseLogout: releaseLogout,
        logoutFailure: StateError('logout response was lost'),
      );
      final container = ProviderContainer(
        overrides: [
          optimizedStorageServiceProvider.overrideWithValue(storage),
          apiServiceProvider.overrideWithValue(api),
          defaultModelProvider.overrideWith((ref) async => null),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(api.dispose);
      await container.read(authStateManagerProvider.future);
      await _waitForAuthStatus(container, AuthStatus.unauthenticated);
      final notifier = container.read(authStateManagerProvider.notifier);
      check(await notifier.login('first-user', 'password')).isTrue();

      final logout = notifier.logout();
      await logoutEntered.future;
      await check(
        notifier.login('same-token-user', 'password'),
      ).throws<Exception>();
      releaseLogout.complete();
      await logout;

      verify(() => storage.clearAuthData()).called(1);
      final settled = container.read(authStateManagerProvider).requireValue;
      check(settled.status).equals(AuthStatus.unauthenticated);
      check(settled.token).isNull();
      check(settled.user).isNull();
      check(settled.isLoading).isFalse();
      check(api.authToken).isNull();
    },
  );

  test(
    'interactive login accepts a byte-identical reissued token after logout',
    () async {
      SharedPreferences.setMockInitialValues({});
      PreferencesStore.debugOverride(await SharedPreferences.getInstance());
      addTearDown(PreferencesStore.debugReset);
      final storage = _Storage();
      when(() => storage.getAuthTokenStrict()).thenAnswer((_) async => '');
      when(
        () => storage.getSavedCredentialsStrict(),
      ).thenAnswer((_) async => null);
      when(() => storage.saveLocalUser(null)).thenAnswer((_) async {});
      when(
        () => storage.saveLocalUserWithAvatar(user, avatarUrl: null),
      ).thenAnswer((_) async {});
      when(() => storage.clearAuthData()).thenAnswer((_) async {});
      _routeConditionalAuthClearToLegacyMock(storage);
      when(
        () => storage.captureServerSessionOwnership(
          validatedConfig: any(named: 'validatedConfig'),
          requireActive: true,
        ),
      ).thenAnswer(
        (_) async =>
            (revision: 1, serverConfig: previousConfig, requireActive: true),
      );
      when(
        () => storage.commitExistingServerSession(
          ownership: any(named: 'ownership'),
          token: any(named: 'token'),
          canCommit: any(named: 'canCommit'),
          publish: any(named: 'publish'),
          rememberedCredentials: any(named: 'rememberedCredentials'),
          onRollbackUncertain: any(named: 'onRollbackUncertain'),
        ),
      ).thenAnswer((invocation) async {
        final publish =
            invocation.namedArguments[#publish] as FutureOr<void> Function();
        await publish();
        return true;
      });
      final api = _SuccessfulAuthApi();
      final container = ProviderContainer(
        overrides: [
          optimizedStorageServiceProvider.overrideWithValue(storage),
          apiServiceProvider.overrideWithValue(api),
          defaultModelProvider.overrideWith((ref) async => null),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(api.dispose);
      await container.read(authStateManagerProvider.future);
      await _waitForAuthStatus(container, AuthStatus.unauthenticated);
      final notifier = container.read(authStateManagerProvider.notifier);

      check(await notifier.login('user', 'password')).isTrue();
      await notifier.logout();

      // Older Open WebUI servers (no jti, JWT_EXPIRES_IN=-1) deterministically
      // reissue the exact same bearer. A fresh interactive sign-in after the
      // logout has fully completed must accept it instead of throwing until
      // the app restarts.
      check(await notifier.login('user', 'password')).isTrue();

      final settled = container.read(authStateManagerProvider).requireValue;
      check(settled.status).equals(AuthStatus.authenticated);
      check(settled.token).equals('validated-proxy-token');
      check(settled.user).equals(user);
      check(api.authToken).equals('validated-proxy-token');
    },
  );

  test(
    'prevalidated proxy commit accepts a reissued token after logout',
    () async {
      SharedPreferences.setMockInitialValues({});
      PreferencesStore.debugOverride(await SharedPreferences.getInstance());
      addTearDown(PreferencesStore.debugReset);
      final storage = _Storage();
      when(() => storage.getAuthTokenStrict()).thenAnswer((_) async => '');
      when(
        () => storage.getSavedCredentialsStrict(),
      ).thenAnswer((_) async => null);
      when(() => storage.saveLocalUser(null)).thenAnswer((_) async {});
      when(
        () => storage.saveLocalUserWithAvatar(user, avatarUrl: null),
      ).thenAnswer((_) async {});
      when(() => storage.clearAuthData()).thenAnswer((_) async {});
      _routeConditionalAuthClearToLegacyMock(storage);
      when(
        () => storage.captureServerSessionOwnership(
          validatedConfig: any(named: 'validatedConfig'),
          requireActive: true,
        ),
      ).thenAnswer(
        (_) async =>
            (revision: 1, serverConfig: previousConfig, requireActive: true),
      );
      when(
        () => storage.commitExistingServerSession(
          ownership: any(named: 'ownership'),
          token: any(named: 'token'),
          canCommit: any(named: 'canCommit'),
          publish: any(named: 'publish'),
          rememberedCredentials: any(named: 'rememberedCredentials'),
          onRollbackUncertain: any(named: 'onRollbackUncertain'),
        ),
      ).thenAnswer((invocation) async {
        final publish =
            invocation.namedArguments[#publish] as FutureOr<void> Function();
        await publish();
        return true;
      });
      when(() => storage.stageServerConfigCandidate(candidate)).thenAnswer(
        (_) async => (
          configs: const [previousConfig],
          activeServerId: previousConfig.id,
          transactionId: 21,
        ),
      );
      when(
        () => storage.commitServerConfigCandidateSession(
          candidate: candidate,
          transactionId: 21,
          token: token,
          canCommit: any(named: 'canCommit'),
          publish: any(named: 'publish'),
          onRollbackUncertain: any(named: 'onRollbackUncertain'),
        ),
      ).thenAnswer((invocation) async {
        final canCommit =
            invocation.namedArguments[#canCommit] as bool Function();
        final publish =
            invocation.namedArguments[#publish] as FutureOr<void> Function();
        if (!canCommit()) return false;
        await publish();
        return true;
      });
      final api = _SuccessfulAuthApi();
      final container = ProviderContainer(
        overrides: [
          optimizedStorageServiceProvider.overrideWithValue(storage),
          apiServiceProvider.overrideWithValue(api),
          defaultModelProvider.overrideWith((ref) async => null),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(api.dispose);
      await container.read(authStateManagerProvider.future);
      await _waitForAuthStatus(container, AuthStatus.unauthenticated);
      final notifier = container.read(authStateManagerProvider.notifier);

      // The interactive login and the later proxy discovery hand back the
      // same deterministic bearer on pre-jti servers.
      check(await notifier.login('user', 'password')).isTrue();
      await notifier.logout();

      check(
        await notifier.commitPrevalidatedProxySession(
          serverConfig: candidate,
          token: token,
          user: user,
        ),
      ).isTrue();

      final settled = container.read(authStateManagerProvider).requireValue;
      check(settled.status).equals(AuthStatus.authenticated);
      check(settled.token).equals(token);
    },
  );

  test('delayed logout completes cleanup after a newer login fails', () async {
    SharedPreferences.setMockInitialValues({});
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());
    addTearDown(PreferencesStore.debugReset);

    final storage = _Storage();
    when(() => storage.getAuthTokenStrict()).thenAnswer((_) async => '');
    when(
      () => storage.getSavedCredentialsStrict(),
    ).thenAnswer((_) async => null);
    when(() => storage.saveLocalUser(null)).thenAnswer((_) async {});
    when(() => storage.clearAuthData()).thenAnswer((_) async {});
    _routeConditionalAuthClearToLegacyMock(storage);
    when(
      () => storage.captureServerSessionOwnership(
        validatedConfig: any(named: 'validatedConfig'),
        requireActive: true,
      ),
    ).thenAnswer(
      (_) async =>
          (revision: 1, serverConfig: previousConfig, requireActive: true),
    );
    when(
      () => storage.commitExistingServerSession(
        ownership: any(named: 'ownership'),
        token: any(named: 'token'),
        canCommit: any(named: 'canCommit'),
        publish: any(named: 'publish'),
        rememberedCredentials: any(named: 'rememberedCredentials'),
        onRollbackUncertain: any(named: 'onRollbackUncertain'),
      ),
    ).thenAnswer((invocation) async {
      final publish =
          invocation.namedArguments[#publish] as FutureOr<void> Function();
      await publish();
      return true;
    });

    final logoutEntered = Completer<void>();
    final releaseLogout = Completer<void>();
    final api = _SuccessfulAuthApi(
      serverConfig: const ServerConfig(
        id: 'previous',
        name: 'Previous',
        url: 'https://previous.example',
        customHeaders: {'Cookie': 'proxy_session=old'},
        isActive: true,
      ),
      logoutEntered: logoutEntered,
      releaseLogout: releaseLogout,
    );
    final container = ProviderContainer(
      overrides: [
        optimizedStorageServiceProvider.overrideWithValue(storage),
        apiServiceProvider.overrideWithValue(api),
        defaultModelProvider.overrideWith((ref) async => null),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(api.dispose);
    await container.read(authStateManagerProvider.future);
    await _waitForAuthStatus(container, AuthStatus.unauthenticated);
    final notifier = container.read(authStateManagerProvider.notifier);
    check(await notifier.login('account-a', 'password')).isTrue();
    check(
      container.read(authStateManagerProvider).requireValue.user,
    ).equals(user);
    api.loginFailure = StateError('new login rejected');

    final logout = notifier.logout();
    await logoutEntered.future;
    await expectLater(
      notifier.login('user', 'password'),
      throwsA(isA<Exception>()),
    );
    releaseLogout.complete();
    await logout;

    verify(() => storage.clearAuthData()).called(1);
    final settled = container.read(authStateManagerProvider).requireValue;
    check(settled.status).equals(AuthStatus.error);
    check(settled.token).isNull();
    check(settled.user).isNull();
    check(settled.isLoading).isFalse();
    check(container.read(incompleteLogoutFenceProvider)).isTrue();
    final adapter = _RecordingAdapter();
    api.dio.httpClientAdapter = adapter;
    await api.dio.get<void>('/health');
    check(_hasCookieHeader(adapter.requests.single)).isFalse();
  });

  test(
    'logout settles when a newer authentication attempt stays loading',
    () async {
      SharedPreferences.setMockInitialValues({});
      PreferencesStore.debugOverride(await SharedPreferences.getInstance());
      addTearDown(PreferencesStore.debugReset);
      final storage = _Storage();
      when(() => storage.getAuthTokenStrict()).thenAnswer((_) async => '');
      when(
        () => storage.getSavedCredentialsStrict(),
      ).thenAnswer((_) async => null);
      when(() => storage.saveLocalUser(null)).thenAnswer((_) async {});
      when(
        () => storage.saveLocalUserWithAvatar(user, avatarUrl: null),
      ).thenAnswer((_) async {});
      when(() => storage.clearAuthData()).thenAnswer((_) async {});
      _routeConditionalAuthClearToLegacyMock(storage);
      when(
        () => storage.captureServerSessionOwnership(
          validatedConfig: any(named: 'validatedConfig'),
          requireActive: true,
        ),
      ).thenAnswer(
        (_) async =>
            (revision: 1, serverConfig: previousConfig, requireActive: true),
      );
      when(
        () => storage.commitExistingServerSession(
          ownership: any(named: 'ownership'),
          token: any(named: 'token'),
          canCommit: any(named: 'canCommit'),
          publish: any(named: 'publish'),
          rememberedCredentials: any(named: 'rememberedCredentials'),
          onRollbackUncertain: any(named: 'onRollbackUncertain'),
        ),
      ).thenAnswer((invocation) async {
        final publish =
            invocation.namedArguments[#publish] as FutureOr<void> Function();
        await publish();
        return true;
      });

      final logoutEntered = Completer<void>();
      final releaseLogout = Completer<void>();
      final api = _SuccessfulAuthApi(
        logoutEntered: logoutEntered,
        releaseLogout: releaseLogout,
      );
      final container = ProviderContainer(
        overrides: [
          optimizedStorageServiceProvider.overrideWithValue(storage),
          apiServiceProvider.overrideWithValue(api),
          defaultModelProvider.overrideWith((ref) async => null),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(api.dispose);
      await container.read(authStateManagerProvider.future);
      await _waitForAuthStatus(container, AuthStatus.unauthenticated);
      final notifier = container.read(authStateManagerProvider.notifier);
      check(await notifier.login('first-user', 'password')).isTrue();

      final newerCaptureEntered = Completer<void>();
      final releaseNewerCapture = Completer<void>();
      when(
        () => storage.captureServerSessionOwnership(
          validatedConfig: any(named: 'validatedConfig'),
          requireActive: true,
        ),
      ).thenAnswer((_) async {
        newerCaptureEntered.complete();
        await releaseNewerCapture.future;
        return null;
      });

      final logout = notifier.logout();
      await logoutEntered.future;
      final newerLogin = notifier
          .login('new-user', 'password')
          .then<Object?>((value) => value, onError: (Object error) => error);
      await newerCaptureEntered.future;

      releaseLogout.complete();
      await logout.timeout(const Duration(seconds: 3));

      final settled = container.read(authStateManagerProvider).requireValue;
      check(settled.isLoading).isFalse();
      check(settled.token).isNull();
      check(settled.user).isNull();
      verify(() => storage.clearAuthData()).called(1);

      releaseNewerCapture.complete();
      await newerLogin;
    },
  );

  test(
    'failed logout keeps proxy cookies suppressed live and after restart',
    () async {
      SharedPreferences.setMockInitialValues({});
      PreferencesStore.debugOverride(await SharedPreferences.getInstance());
      addTearDown(PreferencesStore.debugReset);

      final storage = _Storage();
      when(() => storage.getAuthTokenStrict()).thenAnswer((_) async => '');
      when(
        () => storage.getSavedCredentialsStrict(),
      ).thenAnswer((_) async => null);
      when(() => storage.saveLocalUser(null)).thenAnswer((_) async {});
      when(
        () => storage.clearAuthData(),
      ).thenThrow(StateError('secure config rewrite failed'));
      _routeConditionalAuthClearToLegacyMock(storage);
      const cookieConfig = ServerConfig(
        id: 'proxy',
        name: 'Proxy',
        url: 'https://proxy.example',
        customHeaders: {'Cookie': 'proxy_session=secret'},
        isActive: true,
      );
      final api = _SuccessfulAuthApi(serverConfig: cookieConfig);
      final container = ProviderContainer(
        overrides: [
          optimizedStorageServiceProvider.overrideWithValue(storage),
          apiServiceProvider.overrideWithValue(api),
          defaultModelProvider.overrideWith((ref) async => null),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(api.dispose);
      await container.read(authStateManagerProvider.future);
      await _waitForAuthStatus(container, AuthStatus.unauthenticated);

      await container.read(authStateManagerProvider.notifier).logout();

      check(
        PreferencesStore.getBool(PreferenceKeys.incompleteLogoutFence),
      ).equals(true);
      check(container.read(incompleteLogoutFenceProvider)).isTrue();
      final liveAdapter = _RecordingAdapter();
      api.dio.httpClientAdapter = liveAdapter;
      await api.dio.get<void>('/health');
      check(_hasCookieHeader(liveAdapter.requests.single)).isFalse();

      final rebuiltWorkerManager = WorkerManager();
      final rebuilt = ApiService(
        serverConfig: cookieConfig,
        workerManager: rebuiltWorkerManager,
        suppressCookieCustomHeader:
            PreferencesStore.getBool(PreferenceKeys.incompleteLogoutFence) ??
            false,
      );
      final rebuiltAdapter = _RecordingAdapter();
      rebuilt.dio.httpClientAdapter = rebuiltAdapter;
      addTearDown(() {
        rebuilt.dispose();
        rebuiltWorkerManager.dispose();
      });
      await rebuilt.dio.get<void>('/health');
      check(_hasCookieHeader(rebuiltAdapter.requests.single)).isFalse();

      final settled = container.read(authStateManagerProvider).requireValue;
      check(settled.status).equals(AuthStatus.unauthenticated);
      check(settled.token).isNull();
      check(settled.error).isNotNull();
      verify(() => storage.clearAuthData()).called(2);
    },
  );

  test(
    'saved-credential validation suppresses Cookie behind logout fence',
    () async {
      SharedPreferences.setMockInitialValues({
        PreferenceKeys.incompleteLogoutFence: true,
      });
      PreferencesStore.debugOverride(await SharedPreferences.getInstance());
      addTearDown(PreferencesStore.debugReset);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      const cookieConfig = ServerConfig(
        id: 'saved-cookie-proxy',
        name: 'Saved Cookie proxy',
        url: 'https://proxy.example',
        customHeaders: {'cOoKiE': 'proxy_session=secret'},
      );
      final workerManager = WorkerManager();
      final api = container.read(savedCredentialAuthApiFactoryProvider)(
        serverConfig: cookieConfig,
        workerManager: workerManager,
      );
      addTearDown(() {
        api.dispose();
        workerManager.dispose();
      });
      final adapter = _RecordingAdapter();
      api.dio.httpClientAdapter = adapter;

      await api.dio.get<void>('/health');

      check(container.read(incompleteLogoutFenceProvider)).isTrue();
      check(_hasCookieHeader(adapter.requests.single)).isFalse();
    },
  );

  test(
    'saved-credential client observes a logout fence raised after creation',
    () async {
      SharedPreferences.setMockInitialValues({});
      PreferencesStore.debugOverride(await SharedPreferences.getInstance());
      addTearDown(PreferencesStore.debugReset);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const cookieConfig = ServerConfig(
        id: 'racing-saved-cookie-proxy',
        name: 'Racing saved Cookie proxy',
        url: 'https://proxy.example',
        customHeaders: {'Cookie': 'proxy_session=secret'},
      );
      final workerManager = WorkerManager();
      final api = container.read(savedCredentialAuthApiFactoryProvider)(
        serverConfig: cookieConfig,
        workerManager: workerManager,
      );
      addTearDown(() {
        api.dispose();
        workerManager.dispose();
      });
      final adapter = _RecordingAdapter();
      api.dio.httpClientAdapter = adapter;

      await api.dio.get<void>('/health');
      container
          .read(incompleteLogoutFenceProvider.notifier)
          .setSuppressed(true);
      await api.dio.get<void>('/health');

      check(adapter.requests).length.equals(2);
      check(_hasCookieHeader(adapter.requests.first)).isTrue();
      check(_hasCookieHeader(adapter.requests.last)).isFalse();
    },
  );

  test(
    'restart fence blocks surviving bearer and credential restoration',
    () async {
      SharedPreferences.setMockInitialValues({
        PreferenceKeys.incompleteLogoutFence: true,
      });
      PreferencesStore.debugOverride(await SharedPreferences.getInstance());
      addTearDown(PreferencesStore.debugReset);

      final storage = _Storage();
      when(() => storage.saveLocalUser(null)).thenAnswer((_) async {});
      when(
        () => storage.clearAuthData(),
      ).thenThrow(StateError('Keychain still unavailable'));
      final container = ProviderContainer(
        overrides: [
          optimizedStorageServiceProvider.overrideWithValue(storage),
          apiServiceProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);

      final state = await container.read(authStateManagerProvider.future);

      check(state.status).equals(AuthStatus.unauthenticated);
      check(state.token).isNull();
      check(state.user).isNull();
      check(state.error).isNotNull();
      check(container.read(incompleteLogoutFenceProvider)).isTrue();
      verify(() => storage.clearAuthData()).called(1);
      verifyNever(() => storage.getAuthTokenStrict());
      verifyNever(() => storage.getSavedCredentials());
      verifyNever(() => storage.getSavedCredentialsStrict());
    },
  );

  test(
    'bootstrap surfaces exhausted credential Keychain failure as an error',
    () async {
      final storage = _Storage();
      when(() => storage.getAuthTokenStrict()).thenAnswer((_) async => null);
      when(
        () => storage.getSavedCredentialsStrict(),
      ).thenThrow(PlatformException(code: 'keychain-unavailable'));
      when(() => storage.saveLocalUser(null)).thenAnswer((_) async {});
      final container = ProviderContainer(
        overrides: [
          optimizedStorageServiceProvider.overrideWithValue(storage),
          apiServiceProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);

      await container.read(authStateManagerProvider.future);
      await _waitForAuthStatus(container, AuthStatus.error);
      final state = container.read(authStateManagerProvider).requireValue;

      check(state.status).equals(AuthStatus.error);
      check(state.token).isNull();
      check(state.error).equals('Failed to initialize authentication');
      verify(() => storage.getSavedCredentialsStrict()).called(1);
      verifyNever(() => storage.getSavedCredentials());
    },
  );

  test(
    'stored-token validation cannot publish over a newer committed login',
    () async {
      const storedToken = 'persisted-old-session-token';
      const storedUser = User(
        id: 'stored-user',
        username: 'stored',
        email: 'stored@example.test',
        role: 'user',
      );
      final storage = _Storage();
      when(
        () => storage.getAuthTokenStrict(),
      ).thenAnswer((_) async => storedToken);
      when(
        () => storage.getLocalUserWithAvatar(),
      ).thenAnswer((_) async => null);
      when(() => storage.saveLocalUser(null)).thenAnswer((_) async {});
      when(
        () => storage.saveLocalUserWithAvatar(user, avatarUrl: null),
      ).thenAnswer((_) async {});
      when(() => storage.stageServerConfigCandidate(candidate)).thenAnswer(
        (_) async => (
          configs: const [previousConfig],
          activeServerId: previousConfig.id,
          transactionId: 81,
        ),
      );
      when(
        () => storage.commitServerConfigCandidateSession(
          candidate: candidate,
          transactionId: 81,
          token: token,
          canCommit: any(named: 'canCommit'),
          publish: any(named: 'publish'),
          onRollbackUncertain: any(named: 'onRollbackUncertain'),
        ),
      ).thenAnswer((invocation) async {
        final canCommit =
            invocation.namedArguments[#canCommit] as bool Function();
        final publish =
            invocation.namedArguments[#publish] as FutureOr<void> Function();
        if (!canCommit()) return false;
        await publish();
        return true;
      });

      final backgroundUser = Completer<User>();
      final api = _GatedStoredTokenApi(backgroundUser);
      final container = ProviderContainer(
        overrides: [
          optimizedStorageServiceProvider.overrideWithValue(storage),
          apiServiceProvider.overrideWithValue(api),
          defaultModelProvider.overrideWith((ref) async => null),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(api.dispose);

      await container.read(authStateManagerProvider.future);
      await api.requestStarted.future;
      final notifier = container.read(authStateManagerProvider.notifier);
      check(
        await notifier.commitPrevalidatedProxySession(
          serverConfig: candidate,
          token: token,
          user: user,
        ),
      ).isTrue();

      backgroundUser.complete(storedUser);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final settled = container.read(authStateManagerProvider).requireValue;
      check(settled.status).equals(AuthStatus.authenticated);
      check(settled.token).equals(token);
      check(settled.user).equals(user);
      check(api.authToken).equals(token);
    },
  );

  test('slow auth refresh cannot overwrite a newer login', () async {
    final storage = _Storage();
    final refreshReadEntered = Completer<void>();
    final releaseRefreshRead = Completer<void>();
    var tokenReads = 0;
    when(() => storage.getAuthTokenStrict()).thenAnswer((_) async {
      tokenReads++;
      if (tokenReads == 1) return '';
      refreshReadEntered.complete();
      await releaseRefreshRead.future;
      return null;
    });
    when(
      () => storage.getSavedCredentialsStrict(),
    ).thenAnswer((_) async => null);
    when(() => storage.saveLocalUser(null)).thenAnswer((_) async {});
    when(
      () => storage.saveLocalUserWithAvatar(user, avatarUrl: null),
    ).thenAnswer((_) async {});
    when(
      () => storage.captureServerSessionOwnership(
        validatedConfig: any(named: 'validatedConfig'),
        requireActive: true,
      ),
    ).thenAnswer(
      (_) async =>
          (revision: 1, serverConfig: previousConfig, requireActive: true),
    );
    when(
      () => storage.commitExistingServerSession(
        ownership: any(named: 'ownership'),
        token: any(named: 'token'),
        canCommit: any(named: 'canCommit'),
        publish: any(named: 'publish'),
        rememberedCredentials: any(named: 'rememberedCredentials'),
        onRollbackUncertain: any(named: 'onRollbackUncertain'),
      ),
    ).thenAnswer((invocation) async {
      final publish =
          invocation.namedArguments[#publish] as FutureOr<void> Function();
      await publish();
      return true;
    });

    final api = _SuccessfulAuthApi();
    final container = ProviderContainer(
      overrides: [
        optimizedStorageServiceProvider.overrideWithValue(storage),
        apiServiceProvider.overrideWithValue(api),
        defaultModelProvider.overrideWith((ref) async => null),
      ],
    );
    addTearDown(() {
      if (!releaseRefreshRead.isCompleted) releaseRefreshRead.complete();
      container.dispose();
      api.dispose();
    });
    await container.read(authStateManagerProvider.future);
    await _waitForAuthStatus(container, AuthStatus.unauthenticated);
    final notifier = container.read(authStateManagerProvider.notifier);

    final refresh = notifier.refresh();
    await refreshReadEntered.future;
    check(await notifier.login('user', 'password')).isTrue();
    releaseRefreshRead.complete();
    await refresh;

    final settled = container.read(authStateManagerProvider).requireValue;
    check(settled.status).equals(AuthStatus.authenticated);
    check(settled.token).equals(token);
    check(settled.user).equals(user);
    check(api.authToken).equals(token);
  });

  test(
    'refresh clears a rejected API key live before secure cleanup settles',
    () async {
      const rejectedApiKey = 'sk-rejected-stored-credential';
      final storage = _Storage();
      var tokenReads = 0;
      when(() => storage.getAuthTokenStrict()).thenAnswer((_) async {
        tokenReads++;
        return tokenReads == 1 ? token : rejectedApiKey;
      });
      when(
        () => storage.getLocalUserWithAvatar(),
      ).thenAnswer((_) async => user);
      when(() => storage.saveLocalUser(null)).thenAnswer((_) async {});
      when(
        () => storage.saveLocalUserWithAvatar(user, avatarUrl: null),
      ).thenAnswer((_) async {});
      final cleanupEntered = Completer<void>();
      final releaseCleanup = Completer<void>();
      when(
        () => storage.clearAuthDataIf(canClear: any(named: 'canClear')),
      ).thenAnswer((invocation) async {
        cleanupEntered.complete();
        await releaseCleanup.future;
        final canClear =
            invocation.namedArguments[#canClear] as bool Function();
        return canClear();
      });

      final api = _SuccessfulAuthApi();
      final container = ProviderContainer(
        overrides: [
          optimizedStorageServiceProvider.overrideWithValue(storage),
          apiServiceProvider.overrideWithValue(api),
          defaultModelProvider.overrideWith((ref) async => null),
        ],
      );
      addTearDown(() {
        if (!releaseCleanup.isCompleted) releaseCleanup.complete();
        container.dispose();
        api.dispose();
      });

      await container.read(authStateManagerProvider.future);
      await _waitForAuthStatus(container, AuthStatus.authenticated);
      check(api.authToken).equals(token);

      final refresh = container
          .read(authStateManagerProvider.notifier)
          .refresh();
      await cleanupEntered.future;

      final rejected = container.read(authStateManagerProvider).requireValue;
      check(rejected.status).equals(AuthStatus.credentialError);
      check(rejected.token).isNull();
      check(rejected.user).isNull();
      check(api.authToken).isNull();

      releaseCleanup.complete();
      await refresh;
    },
  );

  test(
    'bootstrap silent login reuses its one strict credential snapshot',
    () async {
      const savedCredentials = {
        'serverId': 'previous',
        'username': 'jwt_user',
        'password': token,
        'authType': 'token',
        'savedAt': '2026-01-01T00:00:00.000Z',
      };
      final storage = _Storage();
      when(() => storage.getAuthTokenStrict()).thenAnswer((_) async => null);
      when(
        () => storage.getSavedCredentialsStrict(),
      ).thenAnswer((_) async => savedCredentials);
      when(
        () => storage.captureSavedServerSessionOwnership(previousConfig.id),
      ).thenAnswer(
        (_) async =>
            (revision: 1, serverConfig: previousConfig, requireActive: false),
      );
      when(
        () => storage.commitExistingServerSession(
          ownership: any(named: 'ownership'),
          token: token,
          canCommit: any(named: 'canCommit'),
          publish: any(named: 'publish'),
          expectedSavedCredentials: savedCredentials,
          onRollbackUncertain: any(named: 'onRollbackUncertain'),
        ),
      ).thenAnswer((invocation) async {
        final publish =
            invocation.namedArguments[#publish] as FutureOr<void> Function();
        await publish();
        return true;
      });
      when(
        () => storage.saveLocalUserWithAvatar(user, avatarUrl: null),
      ).thenAnswer((_) async {});
      final tempApis = <_SuccessfulAuthApi>[];
      final container = ProviderContainer(
        overrides: [
          optimizedStorageServiceProvider.overrideWithValue(storage),
          apiServiceProvider.overrideWithValue(null),
          savedCredentialAuthApiFactoryProvider.overrideWithValue(({
            required serverConfig,
            required workerManager,
          }) {
            final api = _SuccessfulAuthApi(serverConfig: serverConfig);
            tempApis.add(api);
            return api;
          }),
          defaultModelProvider.overrideWith((ref) async => null),
        ],
      );
      addTearDown(() {
        container.dispose();
        for (final api in tempApis) {
          api.dispose();
        }
      });

      await container.read(authStateManagerProvider.future);
      await _waitForAuthStatus(container, AuthStatus.authenticated);

      final state = container.read(authStateManagerProvider).requireValue;
      check(state.token).equals(token);
      check(state.user).equals(user);
      verify(() => storage.getSavedCredentialsStrict()).called(1);
      verifyNever(() => storage.getSavedCredentials());
    },
  );

  test(
    'foreground silent login preserves its terminal failure state',
    () async {
      const savedCredentials = <String, String>{
        'serverId': 'previous',
        'username': 'user',
        'password': 'password',
        'authType': 'credentials',
      };
      final request = RequestOptions(path: '/api/v1/auths/signin');
      final cases = <({Object error, AuthStatus status})>[
        (
          error: DioException(
            requestOptions: request,
            type: DioExceptionType.badResponse,
            response: Response<void>(requestOptions: request, statusCode: 401),
          ),
          status: AuthStatus.credentialError,
        ),
        (
          error: DioException(
            requestOptions: request,
            type: DioExceptionType.connectionError,
            error: const SocketException('offline'),
          ),
          status: AuthStatus.error,
        ),
      ];

      for (final testCase in cases) {
        SharedPreferences.setMockInitialValues({});
        PreferencesStore.debugOverride(await SharedPreferences.getInstance());
        final storage = _Storage();
        when(() => storage.getAuthTokenStrict()).thenAnswer((_) async => '');
        var strictCredentialReads = 0;
        when(() => storage.getSavedCredentialsStrict()).thenAnswer((_) async {
          strictCredentialReads += 1;
          return strictCredentialReads == 1 ? null : savedCredentials;
        });
        when(() => storage.saveLocalUser(null)).thenAnswer((_) async {});
        when(
          () => storage.captureSavedServerSessionOwnership(previousConfig.id),
        ).thenAnswer(
          (_) async =>
              (revision: 1, serverConfig: previousConfig, requireActive: false),
        );
        when(
          () => storage.deleteSavedCredentialsIfMatches(savedCredentials),
        ).thenAnswer((_) async => true);

        final tempApis = <_SuccessfulAuthApi>[];
        final container = ProviderContainer(
          overrides: [
            optimizedStorageServiceProvider.overrideWithValue(storage),
            apiServiceProvider.overrideWithValue(null),
            savedCredentialAuthApiFactoryProvider.overrideWithValue(({
              required serverConfig,
              required workerManager,
            }) {
              final api = _SuccessfulAuthApi(serverConfig: serverConfig)
                ..loginFailure = testCase.error;
              tempApis.add(api);
              return api;
            }),
            defaultModelProvider.overrideWith((ref) async => null),
          ],
        );
        try {
          await container.read(authStateManagerProvider.future);
          await _waitForAuthStatus(container, AuthStatus.unauthenticated);

          check(
            await container
                .read(authStateManagerProvider.notifier)
                .silentLogin(),
          ).isFalse();
          final settled = container.read(authStateManagerProvider).requireValue;
          check(settled.status).equals(testCase.status);
          check(settled.isLoading).isFalse();
          check(settled.error).isNotNull();
          verifyNever(() => storage.getSavedCredentials());
        } finally {
          container.dispose();
          for (final api in tempApis) {
            api.dispose();
          }
          PreferencesStore.debugReset();
        }
      }
    },
  );

  test(
    'foreground silent login settles when saved-credential storage throws',
    () async {
      SharedPreferences.setMockInitialValues({});
      PreferencesStore.debugOverride(await SharedPreferences.getInstance());
      addTearDown(PreferencesStore.debugReset);
      final storage = _Storage();
      when(() => storage.getAuthTokenStrict()).thenAnswer((_) async => '');
      var strictCredentialReads = 0;
      when(() => storage.getSavedCredentialsStrict()).thenAnswer((_) async {
        strictCredentialReads += 1;
        if (strictCredentialReads == 1) return null;
        throw PlatformException(code: 'keychain-unavailable');
      });
      when(() => storage.saveLocalUser(null)).thenAnswer((_) async {});

      final container = ProviderContainer(
        overrides: [
          optimizedStorageServiceProvider.overrideWithValue(storage),
          apiServiceProvider.overrideWithValue(null),
          defaultModelProvider.overrideWith((ref) async => null),
        ],
      );
      addTearDown(container.dispose);
      await container.read(authStateManagerProvider.future);
      await _waitForAuthStatus(container, AuthStatus.unauthenticated);

      check(
        await container.read(authStateManagerProvider.notifier).silentLogin(),
      ).isFalse();

      final settled = container.read(authStateManagerProvider).requireValue;
      check(settled.status).equals(AuthStatus.error);
      check(settled.isLoading).isFalse();
      check(settled.error).isNotNull();
      verifyNever(() => storage.getSavedCredentials());
    },
  );

  test(
    'authenticated publish rolls back when logout fence clearing is uncertain',
    () async {
      for (final failFenceRestore in [false, true]) {
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        PreferencesStore.debugOverride(preferences);

        final storage = _Storage();
        when(() => storage.getAuthTokenStrict()).thenAnswer((_) async => '');
        when(
          () => storage.getSavedCredentialsStrict(),
        ).thenAnswer((_) async => null);
        when(() => storage.saveLocalUser(null)).thenAnswer((_) async {});
        when(
          () => storage.captureServerSessionOwnership(
            validatedConfig: any(named: 'validatedConfig'),
            requireActive: true,
          ),
        ).thenAnswer(
          (_) async =>
              (revision: 1, serverConfig: previousConfig, requireActive: true),
        );
        when(
          () => storage.commitExistingServerSession(
            ownership: any(named: 'ownership'),
            token: any(named: 'token'),
            canCommit: any(named: 'canCommit'),
            publish: any(named: 'publish'),
            rememberedCredentials: any(named: 'rememberedCredentials'),
            onRollbackUncertain: any(named: 'onRollbackUncertain'),
          ),
        ).thenAnswer((invocation) async {
          final publish =
              invocation.namedArguments[#publish] as FutureOr<void> Function();
          await publish();
          return true;
        });
        final api = _SuccessfulAuthApi();
        final container = ProviderContainer(
          overrides: [
            optimizedStorageServiceProvider.overrideWithValue(storage),
            apiServiceProvider.overrideWithValue(api),
            defaultModelProvider.overrideWith((ref) async => null),
          ],
        );
        try {
          await container.read(authStateManagerProvider.future);
          await _waitForAuthStatus(container, AuthStatus.unauthenticated);
          check(
            await container
                .read(incompleteLogoutFenceProvider.notifier)
                .persist(true),
          ).isTrue();
          PreferencesStore.debugOverride(
            preferences,
            writeInterceptor: (prefs, key, value) async {
              if (key == PreferenceKeys.incompleteLogoutFence &&
                  (value == null || failFenceRestore)) {
                return false;
              }
              return null;
            },
          );

          await expectLater(
            container
                .read(authStateManagerProvider.notifier)
                .login('user', 'password'),
            throwsA(isA<Exception>()),
          );

          final settled = container.read(authStateManagerProvider).requireValue;
          check(settled.token).isNull();
          check(settled.user).isNull();
          check(settled.isLoading).isFalse();
          check(container.read(incompleteLogoutFenceProvider)).isTrue();
          check(
            PreferencesStore.getBool(PreferenceKeys.incompleteLogoutFence),
          ).equals(true);
        } finally {
          container.dispose();
          api.dispose();
          PreferencesStore.debugReset();
        }
      }
    },
  );

  test(
    'newer logout wins while an older login fence clear is delayed',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      PreferencesStore.debugOverride(preferences);

      final storage = _Storage();
      when(() => storage.getAuthTokenStrict()).thenAnswer((_) async => '');
      when(
        () => storage.getSavedCredentialsStrict(),
      ).thenAnswer((_) async => null);
      when(() => storage.saveLocalUser(null)).thenAnswer((_) async {});
      when(
        () => storage.saveLocalUserWithAvatar(user, avatarUrl: null),
      ).thenAnswer((_) async {});
      when(() => storage.clearAuthData()).thenAnswer((_) async {});
      _routeConditionalAuthClearToLegacyMock(storage);
      when(
        () => storage.captureServerSessionOwnership(
          validatedConfig: any(named: 'validatedConfig'),
          requireActive: true,
        ),
      ).thenAnswer(
        (_) async =>
            (revision: 1, serverConfig: previousConfig, requireActive: true),
      );
      when(
        () => storage.commitExistingServerSession(
          ownership: any(named: 'ownership'),
          token: any(named: 'token'),
          canCommit: any(named: 'canCommit'),
          publish: any(named: 'publish'),
          rememberedCredentials: any(named: 'rememberedCredentials'),
          onRollbackUncertain: any(named: 'onRollbackUncertain'),
        ),
      ).thenAnswer((invocation) async {
        final publish =
            invocation.namedArguments[#publish] as FutureOr<void> Function();
        await publish();
        return true;
      });

      final logoutEntered = Completer<void>();
      final releaseLogout = Completer<void>();
      final api = _SuccessfulAuthApi(
        logoutEntered: logoutEntered,
        releaseLogout: releaseLogout,
      );
      final container = ProviderContainer(
        overrides: [
          optimizedStorageServiceProvider.overrideWithValue(storage),
          apiServiceProvider.overrideWithValue(api),
          defaultModelProvider.overrideWith((ref) async => null),
        ],
      );
      final clearEntered = Completer<void>();
      final releaseClear = Completer<void>();
      try {
        await container.read(authStateManagerProvider.future);
        await _waitForAuthStatus(container, AuthStatus.unauthenticated);
        check(
          await container
              .read(incompleteLogoutFenceProvider.notifier)
              .persist(true),
        ).isTrue();

        PreferencesStore.debugOverride(
          preferences,
          writeInterceptor: (prefs, key, value) async {
            if (key == PreferenceKeys.incompleteLogoutFence &&
                value == null &&
                !clearEntered.isCompleted) {
              clearEntered.complete();
              await releaseClear.future;
            }
            return null;
          },
        );

        final notifier = container.read(authStateManagerProvider.notifier);
        final login = notifier.login('user', 'password');
        // Attach the error handler before releasing the gated preference write;
        // the superseding logout can now reject the login before its own
        // remote request reaches the test gate.
        final loginExpectation = expectLater(login, throwsA(isA<Exception>()));
        await clearEntered.future;
        final logout = notifier.logout();
        releaseClear.complete();

        await logoutEntered.future;
        await loginExpectation;
        check(
          container.read(authStateManagerProvider).requireValue.isAuthenticated,
        ).isFalse();
        check(
          PreferencesStore.getBool(PreferenceKeys.incompleteLogoutFence),
        ).equals(true);

        releaseLogout.complete();
        await logout;
      } finally {
        if (!releaseClear.isCompleted) releaseClear.complete();
        if (!releaseLogout.isCompleted) releaseLogout.complete();
        container.dispose();
        api.dispose();
        PreferencesStore.debugReset();
      }
    },
  );

  test(
    'newer login clears a pending logout fence before publication',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      PreferencesStore.debugOverride(preferences);

      final storage = _Storage();
      when(() => storage.getAuthTokenStrict()).thenAnswer((_) async => '');
      when(
        () => storage.getSavedCredentialsStrict(),
      ).thenAnswer((_) async => null);
      when(() => storage.saveLocalUser(null)).thenAnswer((_) async {});
      when(
        () => storage.saveLocalUserWithAvatar(user, avatarUrl: null),
      ).thenAnswer((_) async {});
      when(() => storage.clearAuthData()).thenAnswer((_) async {});
      _routeConditionalAuthClearToLegacyMock(storage);
      when(
        () => storage.captureServerSessionOwnership(
          validatedConfig: any(named: 'validatedConfig'),
          requireActive: true,
        ),
      ).thenAnswer(
        (_) async =>
            (revision: 1, serverConfig: previousConfig, requireActive: true),
      );
      when(
        () => storage.commitExistingServerSession(
          ownership: any(named: 'ownership'),
          token: any(named: 'token'),
          canCommit: any(named: 'canCommit'),
          publish: any(named: 'publish'),
          rememberedCredentials: any(named: 'rememberedCredentials'),
          onRollbackUncertain: any(named: 'onRollbackUncertain'),
        ),
      ).thenAnswer((invocation) async {
        final publish =
            invocation.namedArguments[#publish] as FutureOr<void> Function();
        await publish();
        return true;
      });

      final logoutEntered = Completer<void>();
      final releaseLogout = Completer<void>();
      final api = _SuccessfulAuthApi(
        logoutEntered: logoutEntered,
        releaseLogout: releaseLogout,
      );
      final container = ProviderContainer(
        overrides: [
          optimizedStorageServiceProvider.overrideWithValue(storage),
          apiServiceProvider.overrideWithValue(api),
          defaultModelProvider.overrideWith((ref) async => null),
        ],
      );
      final trueWriteEntered = Completer<void>();
      final releaseTrueWrite = Completer<void>();
      try {
        await container.read(authStateManagerProvider.future);
        await _waitForAuthStatus(container, AuthStatus.unauthenticated);
        PreferencesStore.debugOverride(
          preferences,
          writeInterceptor: (prefs, key, value) async {
            if (key == PreferenceKeys.incompleteLogoutFence &&
                value == true &&
                !trueWriteEntered.isCompleted) {
              trueWriteEntered.complete();
              await releaseTrueWrite.future;
            }
            return null;
          },
        );

        final notifier = container.read(authStateManagerProvider.notifier);
        final logout = notifier.logout();
        await trueWriteEntered.future;
        final login = notifier.login('user', 'password');
        releaseTrueWrite.complete();

        check(await login).isTrue();
        await logoutEntered.future;
        check(
          PreferencesStore.getBool(PreferenceKeys.incompleteLogoutFence),
        ).isNull();
        releaseLogout.complete();
        await logout;

        final settled = container.read(authStateManagerProvider).requireValue;
        check(settled.status).equals(AuthStatus.authenticated);
        check(settled.token).equals(token);
        check(settled.user).equals(user);
        check(
          PreferencesStore.getBool(PreferenceKeys.incompleteLogoutFence),
        ).isNull();
      } finally {
        if (!releaseTrueWrite.isCompleted) releaseTrueWrite.complete();
        if (!releaseLogout.isCompleted) releaseLogout.complete();
        container.dispose();
        api.dispose();
        PreferencesStore.debugReset();
      }
    },
  );

  test('stale token invalidation cannot overwrite a newer login', () async {
    final storage = _Storage();
    when(() => storage.getAuthTokenStrict()).thenAnswer((_) async => '');
    when(
      () => storage.getSavedCredentialsStrict(),
    ).thenAnswer((_) async => null);
    when(() => storage.saveLocalUser(null)).thenAnswer((_) async {});
    when(
      () => storage.saveLocalUserWithAvatar(user, avatarUrl: null),
    ).thenAnswer((_) async {});
    when(() => storage.stageServerConfigCandidate(candidate)).thenAnswer(
      (_) async => (
        configs: const [previousConfig],
        activeServerId: previousConfig.id,
        transactionId: 71,
      ),
    );
    when(
      () => storage.commitServerConfigCandidateSession(
        candidate: candidate,
        transactionId: 71,
        token: token,
        canCommit: any(named: 'canCommit'),
        publish: any(named: 'publish'),
        onRollbackUncertain: any(named: 'onRollbackUncertain'),
      ),
    ).thenAnswer((invocation) async {
      final publish =
          invocation.namedArguments[#publish] as FutureOr<void> Function();
      await publish();
      return true;
    });
    when(
      () => storage.captureServerSessionOwnership(
        validatedConfig: any(named: 'validatedConfig'),
        requireActive: true,
      ),
    ).thenAnswer(
      (_) async =>
          (revision: 2, serverConfig: previousConfig, requireActive: true),
    );
    when(
      () => storage.commitExistingServerSession(
        ownership: any(named: 'ownership'),
        token: any(named: 'token'),
        canCommit: any(named: 'canCommit'),
        publish: any(named: 'publish'),
        rememberedCredentials: any(named: 'rememberedCredentials'),
        onRollbackUncertain: any(named: 'onRollbackUncertain'),
      ),
    ).thenAnswer((invocation) async {
      final publish =
          invocation.namedArguments[#publish] as FutureOr<void> Function();
      await publish();
      return true;
    });
    final invalidationDeleteEntered = Completer<void>();
    final releaseInvalidationDelete = Completer<void>();
    when(() => storage.deleteAuthTokenIfMatches(token)).thenAnswer((_) async {
      invalidationDeleteEntered.complete();
      await releaseInvalidationDelete.future;
      return true;
    });
    when(() => storage.clearUserScopedAuthData()).thenAnswer((_) async {});

    final api = _SuccessfulAuthApi();
    final container = ProviderContainer(
      overrides: [
        optimizedStorageServiceProvider.overrideWithValue(storage),
        apiServiceProvider.overrideWithValue(api),
        defaultModelProvider.overrideWith((ref) async => null),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(api.dispose);
    await container.read(authStateManagerProvider.future);
    await _waitForAuthStatus(container, AuthStatus.unauthenticated);
    final notifier = container.read(authStateManagerProvider.notifier);
    check(
      await notifier.commitPrevalidatedProxySession(
        serverConfig: candidate,
        token: token,
        user: user,
      ),
    ).isTrue();

    final invalidation = notifier.onTokenInvalidated();
    await invalidationDeleteEntered.future;
    final rejected = container.read(authStateManagerProvider).requireValue;
    check(rejected.status).equals(AuthStatus.tokenExpired);
    check(rejected.token).isNull();
    check(rejected.user).isNull();
    check(api.authToken).isNull();
    check(await notifier.login('user', 'password')).isTrue();
    releaseInvalidationDelete.complete();
    await invalidation;

    verifyNever(() => storage.clearUserScopedAuthData());
    final settled = container.read(authStateManagerProvider).requireValue;
    check(settled.status).equals(AuthStatus.authenticated);
    check(settled.token).equals(token);
    check(settled.user).equals(user);
    check(settled.isLoading).isFalse();
  });

  test(
    'max-retry token invalidation still clears the rejected bearer',
    () async {
      final storage = _Storage();
      when(() => storage.getAuthTokenStrict()).thenAnswer((_) async => '');
      when(
        () => storage.getSavedCredentialsStrict(),
      ).thenAnswer((_) async => null);
      when(() => storage.getSavedCredentials()).thenAnswer((_) async => null);
      when(
        () => storage.deleteAuthTokenIfMatches(token),
      ).thenAnswer((_) async => true);
      when(() => storage.clearUserScopedAuthData()).thenAnswer((_) async {});
      when(() => storage.saveLocalUser(null)).thenAnswer((_) async {});
      when(
        () => storage.saveLocalUserWithAvatar(user, avatarUrl: null),
      ).thenAnswer((_) async {});
      when(
        () => storage.captureServerSessionOwnership(
          validatedConfig: any(named: 'validatedConfig'),
          requireActive: true,
        ),
      ).thenAnswer(
        (_) async =>
            (revision: 1, serverConfig: previousConfig, requireActive: true),
      );
      when(
        () => storage.commitExistingServerSession(
          ownership: any(named: 'ownership'),
          token: any(named: 'token'),
          canCommit: any(named: 'canCommit'),
          publish: any(named: 'publish'),
          rememberedCredentials: any(named: 'rememberedCredentials'),
          onRollbackUncertain: any(named: 'onRollbackUncertain'),
        ),
      ).thenAnswer((invocation) async {
        final publish =
            invocation.namedArguments[#publish] as FutureOr<void> Function();
        await publish();
        return true;
      });

      final api = _SuccessfulAuthApi();
      final container = ProviderContainer(
        overrides: [
          optimizedStorageServiceProvider.overrideWithValue(storage),
          apiServiceProvider.overrideWithValue(api),
          defaultModelProvider.overrideWith((ref) async => null),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(api.dispose);
      await container.read(authStateManagerProvider.future);
      await _waitForAuthStatus(container, AuthStatus.unauthenticated);
      final notifier = container.read(authStateManagerProvider.notifier);

      for (var attempt = 0; attempt < 4; attempt++) {
        check(await notifier.login('user', 'password')).isTrue();
        await notifier.onTokenInvalidated();
      }

      verify(() => storage.deleteAuthTokenIfMatches(token)).called(4);
      final settled = container.read(authStateManagerProvider).requireValue;
      check(settled.status).equals(AuthStatus.error);
      check(settled.token).isNull();
      check(settled.user).isNull();
      check(settled.isLoading).isFalse();
      check(api.authToken).isNull();
    },
  );

  test(
    'proxy rollback uncertainty fences every foreground auth producer',
    () async {
      for (final mode in _MixedAuthMode.values) {
        final storage = _Storage();
        when(() => storage.getAuthTokenStrict()).thenAnswer((_) async => '');
        when(
          () => storage.getSavedCredentialsStrict(),
        ).thenAnswer((_) async => null);
        when(() => storage.saveLocalUser(null)).thenAnswer((_) async {});
        when(
          () => storage.saveLocalUserWithAvatar(user, avatarUrl: null),
        ).thenAnswer((_) async {});
        var stageCall = 39;
        when(() => storage.stageServerConfigCandidate(candidate)).thenAnswer(
          (_) async => (
            configs: const [previousConfig],
            activeServerId: previousConfig.id,
            transactionId: ++stageCall,
          ),
        );
        when(
          () => storage.discardServerConfigCandidate(
            candidate: candidate,
            transactionId: any(named: 'transactionId'),
          ),
        ).thenAnswer((_) async => false);

        final proxyCommitEntered = Completer<void>();
        final releaseProxyCommit = Completer<void>();
        var proxyCommitCall = 0;
        when(
          () => storage.commitServerConfigCandidateSession(
            candidate: candidate,
            transactionId: any(named: 'transactionId'),
            token: token,
            canCommit: any(named: 'canCommit'),
            publish: any(named: 'publish'),
            onRollbackUncertain: any(named: 'onRollbackUncertain'),
          ),
        ).thenAnswer((invocation) async {
          if (++proxyCommitCall == 1) {
            final publish =
                invocation.namedArguments[#publish]
                    as FutureOr<void> Function();
            await publish();
            return true;
          }
          proxyCommitEntered.complete();
          await releaseProxyCommit.future;
          final poison =
              invocation.namedArguments[#onRollbackUncertain]
                  as void Function();
          poison();
          throw const ServerConfigSessionRollbackException(
            commitError: 'candidate write failed',
            rollbackError: 'baseline restore failed',
          );
        });

        when(
          () => storage.captureServerSessionOwnership(
            validatedConfig: any(named: 'validatedConfig'),
            requireActive: true,
          ),
        ).thenAnswer(
          (_) async =>
              (revision: 1, serverConfig: previousConfig, requireActive: true),
        );

        final normalCommitEntered = Completer<void>();
        final releaseNormalCommit = Completer<void>();
        when(
          () => storage.commitExistingServerSession(
            ownership: any(named: 'ownership'),
            token: any(named: 'token'),
            canCommit: any(named: 'canCommit'),
            publish: any(named: 'publish'),
            rememberedCredentials: any(named: 'rememberedCredentials'),
            onRollbackUncertain: any(named: 'onRollbackUncertain'),
          ),
        ).thenAnswer((invocation) async {
          normalCommitEntered.complete();
          await releaseNormalCommit.future;
          final canCommit =
              invocation.namedArguments[#canCommit] as bool Function();
          if (!canCommit()) return false;
          final publish =
              invocation.namedArguments[#publish] as FutureOr<void> Function();
          await publish();
          return true;
        });

        final api = _SuccessfulAuthApi();
        final container = ProviderContainer(
          overrides: [
            optimizedStorageServiceProvider.overrideWithValue(storage),
            apiServiceProvider.overrideWithValue(api),
            defaultModelProvider.overrideWith((ref) async => null),
          ],
        );
        try {
          await container.read(authStateManagerProvider.future);
          await _waitForAuthStatus(container, AuthStatus.unauthenticated);
          final notifier = container.read(authStateManagerProvider.notifier);
          check(
            await notifier.commitPrevalidatedProxySession(
              serverConfig: candidate,
              token: token,
              user: user,
            ),
          ).isTrue();

          final proxyFailure = notifier.commitPrevalidatedProxySession(
            serverConfig: candidate,
            token: token,
            user: user,
          );
          await proxyCommitEntered.future;
          final normalLogin = switch (mode) {
            _MixedAuthMode.password => notifier.login('user', 'password'),
            _MixedAuthMode.token => notifier.loginWithApiKey(token),
            _MixedAuthMode.ldap => notifier.ldapLogin('user', 'password'),
          };
          await normalCommitEntered.future;

          releaseProxyCommit.complete();
          await expectLater(proxyFailure, throwsA(isA<Exception>()));
          releaseNormalCommit.complete();
          check(await normalLogin).isFalse();

          final settled = container.read(authStateManagerProvider).requireValue;
          check(settled.status).equals(AuthStatus.unauthenticated);
          check(settled.token).isNull();
          check(settled.user).isNull();
          check(settled.isLoading).isFalse();
        } finally {
          container.dispose();
          api.dispose();
        }
      }
    },
  );

  test('proxy rollback uncertainty fences saved-credential login', () async {
    const savedCredentials = <String, String>{
      'serverId': 'previous',
      'username': 'jwt_user',
      'password': token,
      'authType': 'token',
    };
    final storage = _Storage();
    when(() => storage.getAuthTokenStrict()).thenAnswer((_) async => '');
    var strictCredentialReads = 0;
    when(() => storage.getSavedCredentialsStrict()).thenAnswer((_) async {
      strictCredentialReads += 1;
      return strictCredentialReads == 1 ? null : savedCredentials;
    });
    when(() => storage.saveLocalUser(null)).thenAnswer((_) async {});
    when(
      () => storage.saveLocalUserWithAvatar(user, avatarUrl: null),
    ).thenAnswer((_) async {});
    when(
      () => storage.captureSavedServerSessionOwnership(previousConfig.id),
    ).thenAnswer(
      (_) async =>
          (revision: 1, serverConfig: previousConfig, requireActive: false),
    );
    var stageCall = 49;
    when(() => storage.stageServerConfigCandidate(candidate)).thenAnswer(
      (_) async => (
        configs: const [previousConfig],
        activeServerId: previousConfig.id,
        transactionId: ++stageCall,
      ),
    );
    when(
      () => storage.discardServerConfigCandidate(
        candidate: candidate,
        transactionId: any(named: 'transactionId'),
      ),
    ).thenAnswer((_) async => false);

    final proxyCommitEntered = Completer<void>();
    final releaseProxyCommit = Completer<void>();
    var proxyCommitCall = 0;
    when(
      () => storage.commitServerConfigCandidateSession(
        candidate: candidate,
        transactionId: any(named: 'transactionId'),
        token: token,
        canCommit: any(named: 'canCommit'),
        publish: any(named: 'publish'),
        onRollbackUncertain: any(named: 'onRollbackUncertain'),
      ),
    ).thenAnswer((invocation) async {
      if (++proxyCommitCall == 1) {
        final publish =
            invocation.namedArguments[#publish] as FutureOr<void> Function();
        await publish();
        return true;
      }
      proxyCommitEntered.complete();
      await releaseProxyCommit.future;
      final poison =
          invocation.namedArguments[#onRollbackUncertain] as void Function();
      poison();
      throw const ServerConfigSessionRollbackException(
        commitError: 'candidate write failed',
        rollbackError: 'baseline restore failed',
      );
    });

    final silentCommitEntered = Completer<void>();
    final releaseSilentCommit = Completer<void>();
    when(
      () => storage.commitExistingServerSession(
        ownership: any(named: 'ownership'),
        token: any(named: 'token'),
        canCommit: any(named: 'canCommit'),
        publish: any(named: 'publish'),
        expectedSavedCredentials: any(named: 'expectedSavedCredentials'),
        onRollbackUncertain: any(named: 'onRollbackUncertain'),
      ),
    ).thenAnswer((invocation) async {
      silentCommitEntered.complete();
      await releaseSilentCommit.future;
      final canCommit =
          invocation.namedArguments[#canCommit] as bool Function();
      if (!canCommit()) return false;
      final publish =
          invocation.namedArguments[#publish] as FutureOr<void> Function();
      await publish();
      return true;
    });

    final api = _SuccessfulAuthApi();
    final savedCredentialApis = <_SuccessfulAuthApi>[];
    final container = ProviderContainer(
      overrides: [
        optimizedStorageServiceProvider.overrideWithValue(storage),
        apiServiceProvider.overrideWithValue(api),
        serverConfigsProvider.overrideWith((ref) async => [previousConfig]),
        savedCredentialAuthApiFactoryProvider.overrideWithValue(({
          required serverConfig,
          required workerManager,
        }) {
          final created = _SuccessfulAuthApi(serverConfig: serverConfig);
          savedCredentialApis.add(created);
          return created;
        }),
        defaultModelProvider.overrideWith((ref) async => null),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(api.dispose);
    addTearDown(() {
      for (final created in savedCredentialApis) {
        created.dispose();
      }
    });
    await container.read(authStateManagerProvider.future);
    await _waitForAuthStatus(container, AuthStatus.unauthenticated);
    final notifier = container.read(authStateManagerProvider.notifier);
    check(
      await notifier.commitPrevalidatedProxySession(
        serverConfig: candidate,
        token: token,
        user: user,
      ),
    ).isTrue();

    final proxyFailure = notifier.commitPrevalidatedProxySession(
      serverConfig: candidate,
      token: token,
      user: user,
    );
    await proxyCommitEntered.future;
    final silentLogin = notifier.silentLogin();
    await silentCommitEntered.future;

    releaseProxyCommit.complete();
    await expectLater(proxyFailure, throwsA(isA<Exception>()));
    releaseSilentCommit.complete();
    check(await silentLogin).isFalse();
    verify(
      () => storage.commitExistingServerSession(
        ownership: any(named: 'ownership'),
        token: any(named: 'token'),
        canCommit: any(named: 'canCommit'),
        publish: any(named: 'publish'),
        expectedSavedCredentials: any(named: 'expectedSavedCredentials'),
        onRollbackUncertain: any(named: 'onRollbackUncertain'),
      ),
    ).called(1);

    final settled = container.read(authStateManagerProvider).requireValue;
    check(settled.status).equals(AuthStatus.unauthenticated);
    check(settled.token).isNull();
    check(settled.user).isNull();
    check(settled.isLoading).isFalse();
  });
}

enum _MixedAuthMode { password, token, ldap }

final class _GatedStoredTokenApi extends ApiService {
  _GatedStoredTokenApi(Completer<User> response)
    : this._withWorker(response, WorkerManager());

  _GatedStoredTokenApi._withWorker(this.response, this._ownedWorkerManager)
    : super(
        serverConfig: const ServerConfig(
          id: 'previous',
          name: 'Previous',
          url: 'https://previous.example',
          isActive: true,
        ),
        workerManager: _ownedWorkerManager,
      );

  final Completer<User> response;
  final WorkerManager _ownedWorkerManager;
  final Completer<void> requestStarted = Completer<void>();

  @override
  void dispose() {
    super.dispose();
    _ownedWorkerManager.dispose();
  }

  @override
  Future<User> getCurrentUser({
    bool suppressAuthFailureNotification = false,
    String? candidateAuthToken,
    ApiAuthSnapshot? authSnapshot,
  }) {
    if (!requestStarted.isCompleted) requestStarted.complete();
    return response.future;
  }
}

final class _SuccessfulAuthApi extends ApiService {
  _SuccessfulAuthApi({
    ServerConfig? serverConfig,
    Completer<void>? logoutEntered,
    Completer<void>? releaseLogout,
    Object? logoutFailure,
  }) : this._withWorker(
         serverConfig: serverConfig,
         logoutEntered: logoutEntered,
         releaseLogout: releaseLogout,
         logoutFailure: logoutFailure,
         workerManager: WorkerManager(),
       );

  // The explicit parameter is also retained for deterministic test teardown.
  // ignore: use_super_parameters
  _SuccessfulAuthApi._withWorker({
    ServerConfig? serverConfig,
    this.logoutEntered,
    this.releaseLogout,
    this.logoutFailure,
    required WorkerManager workerManager,
  }) : _ownedWorkerManager = workerManager,
       super(
         serverConfig:
             serverConfig ??
             const ServerConfig(
               id: 'previous',
               name: 'Previous',
               url: 'https://previous.example',
               isActive: true,
             ),
         workerManager: workerManager,
       );

  int loginCalls = 0;
  final WorkerManager _ownedWorkerManager;
  final Completer<void>? logoutEntered;
  final Completer<void>? releaseLogout;
  final Object? logoutFailure;
  Object? loginFailure;
  String loginToken = 'validated-proxy-token';

  @override
  void dispose() {
    super.dispose();
    _ownedWorkerManager.dispose();
  }

  @override
  Future<Map<String, dynamic>> login(String username, String password) async {
    loginCalls++;
    if (loginFailure case final failure?) throw failure;
    return {'token': loginToken};
  }

  @override
  Future<Map<String, dynamic>> ldapLogin(
    String username,
    String password,
  ) async => const {'token': 'validated-proxy-token'};

  @override
  Future<User> getCurrentUser({
    bool suppressAuthFailureNotification = false,
    String? candidateAuthToken,
    ApiAuthSnapshot? authSnapshot,
  }) async => const User(
    id: 'user',
    username: 'user',
    email: 'user@example.test',
    role: 'user',
  );

  @override
  Future<bool> checkHealth() async => true;

  @override
  Future<void> logout({ApiAuthSnapshot? authSnapshot}) async {
    logoutEntered?.complete();
    await releaseLogout?.future;
    if (logoutFailure case final failure?) throw failure;
  }
}

final class _Storage extends Mock implements OptimizedStorageService {}

void _routeConditionalAuthClearToLegacyMock(_Storage storage) {
  when(
    () => storage.clearAuthDataIf(canClear: any(named: 'canClear')),
  ).thenAnswer((invocation) async {
    final canClear = invocation.namedArguments[#canClear] as bool Function();
    if (!canClear()) return false;
    await storage.clearAuthData();
    return true;
  });
}

final class _RecordingAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString('{}', 200);
  }

  @override
  void close({bool force = false}) {}
}

bool _hasCookieHeader(RequestOptions request) =>
    request.headers.keys.any((header) => header.toLowerCase() == 'cookie');

Future<void> _waitForAuthStatus(
  ProviderContainer container,
  AuthStatus expected,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    final state = container.read(authStateManagerProvider).asData?.value;
    if (state?.status == expected) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  check(
    container.read(authStateManagerProvider).requireValue.status,
  ).equals(expected);
}
