import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/auth/auth_state_manager.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/providers/backend_mode_providers.dart';
import 'package:conduit/core/router/app_router.dart';
import 'package:conduit/core/services/navigation_service.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit/features/hermes/models/hermes_config.dart';
import 'package:conduit/features/hermes/providers/hermes_providers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

final class _MockBuildContext extends Mock implements BuildContext {}

final class _MockGoRouterState extends Mock implements GoRouterState {}

final class _FixedPreferredBackendController
    extends PreferredBackendController {
  @override
  PreferredBackend build() => PreferredBackend.hermes;
}

final class _DirectPreferredBackendController
    extends PreferredBackendController {
  @override
  PreferredBackend build() => PreferredBackend.direct;
}

final class _UnsetPreferredBackendController
    extends PreferredBackendController {
  @override
  PreferredBackend build() => PreferredBackend.unset;
}

final class _FixedDirectProfiles extends DirectConnectionProfilesController {
  _FixedDirectProfiles(this._profiles);

  final List<DirectConnectionProfile> _profiles;

  @override
  Future<List<DirectConnectionProfile>> build() async => _profiles;
}

final class _PendingDirectProfiles extends DirectConnectionProfilesController {
  _PendingDirectProfiles(this._profiles);

  final Future<List<DirectConnectionProfile>> _profiles;

  @override
  Future<List<DirectConnectionProfile>> build() => _profiles;
}

final class _ReloadableDirectProfiles
    extends DirectConnectionProfilesController {
  _ReloadableDirectProfiles(this._load);

  final Future<List<DirectConnectionProfile>> Function() _load;

  @override
  Future<List<DirectConnectionProfile>> build() => _load();
}

final class _FixedHermesConfigController extends HermesConfigController {
  _FixedHermesConfigController(this._config);

  final HermesConfig _config;

  @override
  HermesConfig build() => _config;

  void publish(HermesConfig config) => state = config;
}

final class _FixedHermesSecretsLoading extends HermesSecretsLoading {
  _FixedHermesSecretsLoading(this._loading);

  final bool _loading;

  @override
  bool build() => _loading;
}

final class _SignedOutAuthStateManager extends AuthStateManager {
  @override
  Future<AuthState> build() async =>
      const AuthState(status: AuthStatus.unauthenticated);
}

final class _SignedOutApiKeyErrorAuthStateManager extends AuthStateManager {
  @override
  Future<AuthState> build() async => const AuthState(
    status: AuthStatus.unauthenticated,
    error: 'apiKeyNoLongerSupported',
  );
}

final class _AuthenticatedAuthStateManager extends AuthStateManager {
  @override
  Future<AuthState> build() async => const AuthState(
    status: AuthStatus.authenticated,
    token: 'openwebui-token',
  );
}

final class _ErrorAuthStateManager extends AuthStateManager {
  @override
  Future<AuthState> build() async =>
      const AuthState(status: AuthStatus.error, error: 'SSO failed');
}

const _retainedOpenWebUiServer = ServerConfig(
  id: 'openwebui',
  name: 'Open WebUI',
  url: 'https://openwebui.example',
  isActive: true,
);

const _usableHermes = HermesConfig(
  enabled: true,
  baseUrl: 'https://hermes.example/v1',
  apiKey: 'hermes-key',
);

const _incompleteHermes = HermesConfig(
  enabled: true,
  baseUrl: 'https://hermes.example/v1',
);

final _usableDirectProfile = DirectConnectionProfile(
  id: 'direct-profile',
  name: 'Local Ollama',
  adapterKey: 'ollama',
  baseUrl: 'http://localhost:11434',
  manualModelIds: const ['llama3'],
);

void main() {
  test('native-sheet destinations suppress the second page transition', () {
    check(
      usesNoTransitionForNativeSheet(const NativeSheetNavigationOrigin()),
    ).isTrue();
    check(usesNoTransitionForNativeSheet(null)).isFalse();
    check(usesNoTransitionForNativeSheet(true)).isFalse();
  });

  group('Hermes-only route policy', () {
    test('allows app-local profile and Hermes settings surfaces', () {
      for (final location in <String>[
        Routes.chat,
        Routes.profile,
        Routes.audioSettings,
        Routes.appearanceSettings,
        Routes.chatSettings,
        Routes.dataConnectionSettings,
        Routes.personalization,
        Routes.directConnections,
        Routes.directConnectionEditorPath('new'),
        Routes.hermesSettings,
        Routes.hermesJobs,
        Routes.about,
      ]) {
        check(isHermesOnlyAppLocation(location)).isTrue();
      }
    });

    test('does not expose OpenWebUI-only surfaces', () {
      for (final location in <String>[
        Routes.accountSettings,
        Routes.notificationSettings,
        Routes.notes,
        Routes.channel,
      ]) {
        check(isHermesOnlyAppLocation(location)).isFalse();
      }
    });

    test('settled incomplete Hermes config opens settings, not splash', () {
      check(
        incompleteHermesDestination(secretsLoading: false),
      ).equals(Routes.hermesSettings);
      check(
        incompleteHermesDestination(secretsLoading: true),
      ).equals(Routes.splash);
    });

    test('incomplete Hermes waits while the active server is loading', () {
      check(
        incompleteHermesDestination(
          secretsLoading: false,
          activeServerLoading: true,
        ),
      ).equals(Routes.splash);
    });

    test(
      'signed-out retained OpenWebUI server does not block preferred Hermes',
      () async {
        final container = ProviderContainer(
          overrides: [
            reviewerModeProvider.overrideWithValue(false),
            activeServerProvider.overrideWith(
              (_) async => _retainedOpenWebUiServer,
            ),
            preferredBackendProvider.overrideWith(
              _FixedPreferredBackendController.new,
            ),
            hermesConfigProvider.overrideWith(
              () => _FixedHermesConfigController(_usableHermes),
            ),
            authStateManagerProvider.overrideWith(
              _SignedOutApiKeyErrorAuthStateManager.new,
            ),
          ],
        );
        addTearDown(container.dispose);
        await container.read(activeServerProvider.future);
        await container.read(authStateManagerProvider.future);

        final state = _MockGoRouterState();
        when(() => state.uri).thenReturn(Uri.parse(Routes.chat));

        final redirect = container
            .read(routerNotifierProvider)
            .redirect(_MockBuildContext(), state);

        check(redirect).isNull();

        when(() => state.uri).thenReturn(Uri.parse(Routes.authentication));
        check(
          container
              .read(routerNotifierProvider)
              .redirect(_MockBuildContext(), state),
        ).isNull();
      },
    );

    test(
      'authenticated retained OpenWebUI server keeps mixed-mode routes',
      () async {
        final container = ProviderContainer(
          overrides: [
            reviewerModeProvider.overrideWithValue(false),
            activeServerProvider.overrideWith(
              (_) async => _retainedOpenWebUiServer,
            ),
            preferredBackendProvider.overrideWith(
              _FixedPreferredBackendController.new,
            ),
            hermesConfigProvider.overrideWith(
              () => _FixedHermesConfigController(_usableHermes),
            ),
            authStateManagerProvider.overrideWith(
              _AuthenticatedAuthStateManager.new,
            ),
          ],
        );
        addTearDown(container.dispose);
        await container.read(activeServerProvider.future);
        await container.read(authStateManagerProvider.future);

        final state = _MockGoRouterState();
        when(() => state.uri).thenReturn(Uri.parse(Routes.notes));

        final redirect = container
            .read(routerNotifierProvider)
            .redirect(_MockBuildContext(), state);

        check(redirect).isNull();
      },
    );

    test(
      'stale OWUI API-key error waits for preferred Hermes secrets',
      () async {
        final container = ProviderContainer(
          overrides: [
            reviewerModeProvider.overrideWithValue(false),
            activeServerProvider.overrideWith(
              (_) async => _retainedOpenWebUiServer,
            ),
            preferredBackendProvider.overrideWith(
              _FixedPreferredBackendController.new,
            ),
            hermesConfigProvider.overrideWith(
              () => _FixedHermesConfigController(_incompleteHermes),
            ),
            hermesSecretsLoadingProvider.overrideWith(
              () => _FixedHermesSecretsLoading(true),
            ),
            authStateManagerProvider.overrideWith(
              _SignedOutApiKeyErrorAuthStateManager.new,
            ),
          ],
        );
        addTearDown(container.dispose);
        await container.read(activeServerProvider.future);
        await container.read(authStateManagerProvider.future);

        final state = _MockGoRouterState();
        when(() => state.uri).thenReturn(Uri.parse(Routes.splash));
        final notifier = container.read(routerNotifierProvider);

        check(notifier.redirect(_MockBuildContext(), state)).isNull();

        (container.read(hermesConfigProvider.notifier)
                as _FixedHermesConfigController)
            .publish(_usableHermes);
        container.read(hermesSecretsLoadingProvider.notifier).set(false);

        check(
          notifier.redirect(_MockBuildContext(), state),
        ).equals(Routes.chat);
      },
    );

    test(
      'retained signed-out server repairs missing preferred Hermes secret',
      () async {
        final container = ProviderContainer(
          overrides: [
            reviewerModeProvider.overrideWithValue(false),
            activeServerProvider.overrideWith(
              (_) async => _retainedOpenWebUiServer,
            ),
            preferredBackendProvider.overrideWith(
              _FixedPreferredBackendController.new,
            ),
            hermesConfigProvider.overrideWith(
              () => _FixedHermesConfigController(_incompleteHermes),
            ),
            hermesSecretsLoadingProvider.overrideWith(
              () => _FixedHermesSecretsLoading(false),
            ),
            authStateManagerProvider.overrideWith(
              _SignedOutAuthStateManager.new,
            ),
          ],
        );
        addTearDown(container.dispose);
        await container.read(activeServerProvider.future);
        await container.read(authStateManagerProvider.future);

        final state = _MockGoRouterState();
        when(() => state.uri).thenReturn(Uri.parse(Routes.splash));

        final redirect = container
            .read(routerNotifierProvider)
            .redirect(_MockBuildContext(), state);

        check(redirect).equals(Routes.hermesSettings);
      },
    );

    test(
      'stale OWUI API-key errors do not block local backend setup',
      () async {
        final container = ProviderContainer(
          overrides: [
            reviewerModeProvider.overrideWithValue(false),
            activeServerProvider.overrideWith(
              (_) async => _retainedOpenWebUiServer,
            ),
            preferredBackendProvider.overrideWith(
              _FixedPreferredBackendController.new,
            ),
            hermesConfigProvider.overrideWith(
              () => _FixedHermesConfigController(_incompleteHermes),
            ),
            hermesSecretsLoadingProvider.overrideWith(
              () => _FixedHermesSecretsLoading(false),
            ),
            authStateManagerProvider.overrideWith(
              _SignedOutApiKeyErrorAuthStateManager.new,
            ),
          ],
        );
        addTearDown(container.dispose);
        await container.read(activeServerProvider.future);
        await container.read(authStateManagerProvider.future);

        final state = _MockGoRouterState();
        final notifier = container.read(routerNotifierProvider);
        for (final location in <String>[
          Routes.backendChooser,
          Routes.hermesSettings,
          Routes.serverConnection,
          Routes.ssoAuth,
          Routes.proxyAuth,
        ]) {
          when(() => state.uri).thenReturn(Uri.parse(location));
          check(notifier.redirect(_MockBuildContext(), state)).isNull();
        }

        when(() => state.uri).thenReturn(Uri.parse(Routes.splash));
        check(
          notifier.redirect(_MockBuildContext(), state),
        ).equals(Routes.hermesSettings);
      },
    );

    test('reviewer mode outranks stale OpenWebUI credential errors', () async {
      final container = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWithValue(true),
          activeServerProvider.overrideWith(
            (_) async => _retainedOpenWebUiServer,
          ),
          preferredBackendProvider.overrideWith(
            _UnsetPreferredBackendController.new,
          ),
          hermesConfigProvider.overrideWith(
            () => _FixedHermesConfigController(_incompleteHermes),
          ),
          authStateManagerProvider.overrideWith(
            _SignedOutApiKeyErrorAuthStateManager.new,
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(activeServerProvider.future);
      await container.read(authStateManagerProvider.future);

      final state = _MockGoRouterState();
      when(() => state.uri).thenReturn(Uri.parse(Routes.authentication));

      check(
        container
            .read(routerNotifierProvider)
            .redirect(_MockBuildContext(), state),
      ).equals(Routes.chat);
    });

    test('OpenWebUI auth errors stay on explicit SSO recovery', () async {
      final container = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          activeServerProvider.overrideWith(
            (_) async => _retainedOpenWebUiServer,
          ),
          preferredBackendProvider.overrideWith(
            _UnsetPreferredBackendController.new,
          ),
          hermesConfigProvider.overrideWith(
            () => _FixedHermesConfigController(const HermesConfig()),
          ),
          authStateManagerProvider.overrideWith(_ErrorAuthStateManager.new),
        ],
      );
      addTearDown(container.dispose);
      await container.read(activeServerProvider.future);
      await container.read(authStateManagerProvider.future);

      final state = _MockGoRouterState();
      when(() => state.uri).thenReturn(Uri.parse(Routes.ssoAuth));

      check(
        container
            .read(routerNotifierProvider)
            .redirect(_MockBuildContext(), state),
      ).isNull();
    });

    test('preferred Hermes ignores a loading optional OWUI server', () async {
      final pendingServer = Completer<ServerConfig?>();
      final container = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          activeServerProvider.overrideWith((_) => pendingServer.future),
          preferredBackendProvider.overrideWith(
            _FixedPreferredBackendController.new,
          ),
          hermesConfigProvider.overrideWith(
            () => _FixedHermesConfigController(_usableHermes),
          ),
          authStateManagerProvider.overrideWith(
            _AuthenticatedAuthStateManager.new,
          ),
        ],
      );
      addTearDown(() {
        pendingServer.complete(_retainedOpenWebUiServer);
        container.dispose();
      });
      await container.read(authStateManagerProvider.future);

      final state = _MockGoRouterState();
      final notifier = container.read(routerNotifierProvider);
      when(() => state.uri).thenReturn(Uri.parse(Routes.notes));
      check(notifier.redirect(_MockBuildContext(), state)).equals(Routes.chat);

      when(() => state.uri).thenReturn(Uri.parse(Routes.authentication));
      check(notifier.redirect(_MockBuildContext(), state)).isNull();
    });

    test('preferred Hermes ignores a failed optional OWUI server', () async {
      final container = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          activeServerProvider.overrideWith(
            (_) => Future<ServerConfig?>.error(StateError('storage failed')),
          ),
          preferredBackendProvider.overrideWith(
            _FixedPreferredBackendController.new,
          ),
          hermesConfigProvider.overrideWith(
            () => _FixedHermesConfigController(_usableHermes),
          ),
          authStateManagerProvider.overrideWith(
            _AuthenticatedAuthStateManager.new,
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(authStateManagerProvider.future);
      await expectLater(
        container.read(activeServerProvider.future),
        throwsStateError,
      );

      final state = _MockGoRouterState();
      final notifier = container.read(routerNotifierProvider);
      when(() => state.uri).thenReturn(Uri.parse(Routes.notes));
      check(notifier.redirect(_MockBuildContext(), state)).equals(Routes.chat);

      when(() => state.uri).thenReturn(Uri.parse(Routes.authentication));
      check(notifier.redirect(_MockBuildContext(), state)).isNull();
    });
  });

  group('Direct-primary route policy', () {
    test(
      'usable Direct stays primary with a retained signed-out OWUI server',
      () async {
        final container = ProviderContainer(
          overrides: [
            reviewerModeProvider.overrideWithValue(false),
            activeServerProvider.overrideWith(
              (_) async => _retainedOpenWebUiServer,
            ),
            preferredBackendProvider.overrideWith(
              _DirectPreferredBackendController.new,
            ),
            directConnectionProfilesProvider.overrideWith(
              () => _FixedDirectProfiles([_usableDirectProfile]),
            ),
            hermesConfigProvider.overrideWith(
              () => _FixedHermesConfigController(const HermesConfig()),
            ),
            authStateManagerProvider.overrideWith(
              _SignedOutAuthStateManager.new,
            ),
          ],
        );
        addTearDown(container.dispose);
        await container.read(activeServerProvider.future);
        await container.read(directConnectionProfilesProvider.future);
        await container.read(authStateManagerProvider.future);

        final state = _MockGoRouterState();
        final notifier = container.read(routerNotifierProvider);
        when(() => state.uri).thenReturn(Uri.parse(Routes.chat));
        check(notifier.redirect(_MockBuildContext(), state)).isNull();

        when(() => state.uri).thenReturn(Uri.parse(Routes.notes));
        check(
          notifier.redirect(_MockBuildContext(), state),
        ).equals(Routes.chat);

        when(() => state.uri).thenReturn(Uri.parse(Routes.authentication));
        check(notifier.redirect(_MockBuildContext(), state)).isNull();
      },
    );

    test('usable Direct ignores a loading optional OWUI server', () async {
      final pendingServer = Completer<ServerConfig?>();
      final container = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          activeServerProvider.overrideWith((_) => pendingServer.future),
          preferredBackendProvider.overrideWith(
            _DirectPreferredBackendController.new,
          ),
          directConnectionProfilesProvider.overrideWith(
            () => _FixedDirectProfiles([_usableDirectProfile]),
          ),
          hermesConfigProvider.overrideWith(
            () => _FixedHermesConfigController(const HermesConfig()),
          ),
          authStateManagerProvider.overrideWith(
            _AuthenticatedAuthStateManager.new,
          ),
        ],
      );
      addTearDown(() {
        pendingServer.complete(_retainedOpenWebUiServer);
        container.dispose();
      });
      await container.read(directConnectionProfilesProvider.future);
      await container.read(authStateManagerProvider.future);

      final state = _MockGoRouterState();
      final notifier = container.read(routerNotifierProvider);
      when(() => state.uri).thenReturn(Uri.parse(Routes.notes));
      check(notifier.redirect(_MockBuildContext(), state)).equals(Routes.chat);

      when(() => state.uri).thenReturn(Uri.parse(Routes.authentication));
      check(notifier.redirect(_MockBuildContext(), state)).isNull();
    });

    test('usable Direct ignores a failed optional OWUI server', () async {
      final container = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          activeServerProvider.overrideWith(
            (_) => Future<ServerConfig?>.error(StateError('storage failed')),
          ),
          preferredBackendProvider.overrideWith(
            _DirectPreferredBackendController.new,
          ),
          directConnectionProfilesProvider.overrideWith(
            () => _FixedDirectProfiles([_usableDirectProfile]),
          ),
          hermesConfigProvider.overrideWith(
            () => _FixedHermesConfigController(const HermesConfig()),
          ),
          authStateManagerProvider.overrideWith(
            _AuthenticatedAuthStateManager.new,
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(directConnectionProfilesProvider.future);
      await container.read(authStateManagerProvider.future);
      await expectLater(
        container.read(activeServerProvider.future),
        throwsStateError,
      );

      final state = _MockGoRouterState();
      final notifier = container.read(routerNotifierProvider);
      when(() => state.uri).thenReturn(Uri.parse(Routes.notes));
      check(notifier.redirect(_MockBuildContext(), state)).equals(Routes.chat);

      when(() => state.uri).thenReturn(Uri.parse(Routes.authentication));
      check(notifier.redirect(_MockBuildContext(), state)).isNull();
    });

    test('recovers setup when no usable Direct profile remains', () async {
      final container = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          activeServerProvider.overrideWith(
            (_) async => _retainedOpenWebUiServer,
          ),
          preferredBackendProvider.overrideWith(
            _DirectPreferredBackendController.new,
          ),
          directConnectionProfilesProvider.overrideWith(
            () => _FixedDirectProfiles(const []),
          ),
          hermesConfigProvider.overrideWith(
            () => _FixedHermesConfigController(const HermesConfig()),
          ),
          authStateManagerProvider.overrideWith(_SignedOutAuthStateManager.new),
        ],
      );
      addTearDown(container.dispose);
      await container.read(activeServerProvider.future);
      await container.read(directConnectionProfilesProvider.future);
      await container.read(authStateManagerProvider.future);

      final state = _MockGoRouterState();
      when(() => state.uri).thenReturn(Uri.parse(Routes.chat));

      check(
        container
            .read(routerNotifierProvider)
            .redirect(_MockBuildContext(), state),
      ).equals('${Routes.directConnections}?onboarding=true');
    });

    test('waits for Direct profiles, then enters local chat', () async {
      final profiles = Completer<List<DirectConnectionProfile>>();
      final container = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          activeServerProvider.overrideWith((_) async => null),
          preferredBackendProvider.overrideWith(
            _DirectPreferredBackendController.new,
          ),
          directConnectionProfilesProvider.overrideWith(
            () => _PendingDirectProfiles(profiles.future),
          ),
          hermesConfigProvider.overrideWith(
            () => _FixedHermesConfigController(const HermesConfig()),
          ),
          authStateManagerProvider.overrideWith(_SignedOutAuthStateManager.new),
        ],
      );
      addTearDown(() {
        if (!profiles.isCompleted) profiles.complete([_usableDirectProfile]);
        container.dispose();
      });
      await container.read(activeServerProvider.future);
      await container.read(authStateManagerProvider.future);

      final state = _MockGoRouterState();
      final notifier = container.read(routerNotifierProvider);
      when(() => state.uri).thenReturn(Uri.parse(Routes.chat));
      check(
        notifier.redirect(_MockBuildContext(), state),
      ).equals(Routes.splash);

      profiles.complete([_usableDirectProfile]);
      await container.read(directConnectionProfilesProvider.future);
      when(() => state.uri).thenReturn(Uri.parse(Routes.splash));
      check(notifier.redirect(_MockBuildContext(), state)).equals(Routes.chat);
    });

    test('uses authenticated OpenWebUI when Direct is unavailable', () async {
      final container = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          activeServerProvider.overrideWith(
            (_) async => _retainedOpenWebUiServer,
          ),
          preferredBackendProvider.overrideWith(
            _DirectPreferredBackendController.new,
          ),
          directConnectionProfilesProvider.overrideWith(
            () => _FixedDirectProfiles(const []),
          ),
          hermesConfigProvider.overrideWith(
            () => _FixedHermesConfigController(const HermesConfig()),
          ),
          authStateManagerProvider.overrideWith(
            _AuthenticatedAuthStateManager.new,
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(activeServerProvider.future);
      await container.read(directConnectionProfilesProvider.future);
      await container.read(authStateManagerProvider.future);

      final state = _MockGoRouterState();
      when(() => state.uri).thenReturn(Uri.parse(Routes.notes));

      check(
        container
            .read(routerNotifierProvider)
            .redirect(_MockBuildContext(), state),
      ).isNull();
    });

    test(
      'profile refresh loading and error with previous data fail closed',
      () async {
        Future<List<DirectConnectionProfile>> attempt = Future.value([
          _usableDirectProfile,
        ]);
        final container = ProviderContainer(
          overrides: [
            reviewerModeProvider.overrideWithValue(false),
            activeServerProvider.overrideWith(
              (_) async => _retainedOpenWebUiServer,
            ),
            preferredBackendProvider.overrideWith(
              _DirectPreferredBackendController.new,
            ),
            directConnectionProfilesProvider.overrideWith(
              () => _ReloadableDirectProfiles(() => attempt),
            ),
            hermesConfigProvider.overrideWith(
              () => _FixedHermesConfigController(const HermesConfig()),
            ),
            authStateManagerProvider.overrideWith(
              _SignedOutAuthStateManager.new,
            ),
          ],
        );
        addTearDown(container.dispose);
        await container.read(activeServerProvider.future);
        await container.read(directConnectionProfilesProvider.future);
        await container.read(authStateManagerProvider.future);

        final state = _MockGoRouterState();
        final notifier = container.read(routerNotifierProvider);
        final pending = Completer<List<DirectConnectionProfile>>();
        attempt = pending.future;
        container.invalidate(directConnectionProfilesProvider);
        await Future<void>.delayed(Duration.zero);

        final refreshing = container.read(directConnectionProfilesProvider);
        check(refreshing.isLoading).isTrue();
        check(refreshing.hasValue).isTrue();
        when(() => state.uri).thenReturn(Uri.parse(Routes.chat));
        check(
          notifier.redirect(_MockBuildContext(), state),
        ).equals(Routes.splash);

        pending.complete([_usableDirectProfile]);
        await container.read(directConnectionProfilesProvider.future);
        attempt = Future.error(StateError('secure storage unavailable'));
        container.invalidate(directConnectionProfilesProvider);
        await expectLater(
          container.read(directConnectionProfilesProvider.future),
          throwsStateError,
        );

        final failed = container.read(directConnectionProfilesProvider);
        check(failed.hasError).isTrue();
        check(failed.hasValue).isTrue();
        check(
          notifier.redirect(_MockBuildContext(), state),
        ).equals('${Routes.directConnections}?onboarding=true');
      },
    );
  });
}
