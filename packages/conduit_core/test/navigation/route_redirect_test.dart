import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/navigation/route_redirect.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/providers/chat_entry_readiness_providers.dart';
import 'package:conduit_core/providers/openwebui_accounts_controller.dart';
import 'package:conduit_core/providers/openwebui_route_resolver.dart';
import 'package:conduit_core/providers/primary_account_providers.dart';
import 'package:conduit_core/providers/primary_account_switcher.dart';
import 'package:riverpod/misc.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

const _server = ServerConfig(
  id: 'server',
  name: 'Server',
  url: 'https://owui.example',
);

/// A [ProviderRead] over fixed values, so the policy runs with no container
/// and no Flutter binding. A provider the case did not set throws, which
/// shows up as a failing test when the policy starts reading something new.
ProviderRead _reader({
  bool reviewerMode = false,
  AsyncValue<ServerConfig?> activeServer = const AsyncData(_server),
  AuthNavigationState auth = AuthNavigationState.authenticated,
  PreferredBackend preferred = PreferredBackend.owui,
  HermesConfig hermes = const HermesConfig(),
  bool hermesSecretsLoading = false,
  bool accountless = false,
  List<DirectConnectionProfile> directProfiles = const [],
  String? addingAccountFrom,
  AuthState authSnapshot = const AuthState(status: AuthStatus.unauthenticated),
  String? settledAccount,
  bool proxySignInForRouteEditing = false,
  AuthNavigationState? primaryAuth,
  bool bootRecovering = false,
}) {
  final values = <ProviderListenable<Object?>, Object?>{
    // Read only with LibreChat in charge; an Open WebUI case leaves it unset,
    // so reading it there fails the case.
    primaryAuthNavigationStateProvider: ?primaryAuth,
    accountAdditionOriginProvider: addingAccountFrom,
    settledActiveAccountIdProvider: settledAccount,
    proxySignInForRouteEditingProvider: proxySignInForRouteEditing,
    reviewerModeProvider: reviewerMode,
    primaryBootRecoveryPendingProvider: bootRecovering,
    activeServerProvider: activeServer,
    authNavigationStateProvider: auth,
    preferredBackendProvider: preferred,
    hermesConfigProvider: hermes,
    hermesSecretsLoadingProvider: hermesSecretsLoading,
    effectiveDirectConnectionProfilesProvider:
        AsyncData<List<DirectConnectionProfile>>(directProfiles),
    accountlessPrimaryBackendUsableProvider: accountless,
    authStateManagerProvider: AsyncData<AuthState>(authSnapshot),
  };
  return <T>(ProviderListenable<T> provider) {
    if (!values.containsKey(provider)) {
      throw StateError('Unexpected provider read: $provider');
    }
    return values[provider] as T;
  };
}

/// A usable accountless install preferring [preferred], with [hermes] set up
/// beside it.
ProviderRead _accountless(PreferredBackend preferred, HermesConfig hermes) =>
    _reader(
      activeServer: const AsyncData(null),
      auth: AuthNavigationState.needsLogin,
      preferred: preferred,
      hermes: hermes,
      accountless: true,
      directProfiles: preferred == PreferredBackend.direct
          ? [
              DirectConnectionProfile(
                id: 'direct',
                name: 'Direct',
                adapterKey: kOpenAiCompatibleAdapterKey,
                baseUrl: 'https://api.example/v1',
                apiKey: 'key',
              ),
            ]
          : const [],
    );

/// The active server as it reads while it is fetched again: still the one
/// already known, and loading.
Future<AsyncValue<ServerConfig?>> _refreshing(ServerConfig server) async {
  final refetch = Completer<ServerConfig?>();
  var builds = 0;
  final provider = FutureProvider<ServerConfig?>(
    (ref) => builds++ == 0 ? Future.value(server) : refetch.future,
  );
  final container = ProviderContainer();
  addTearDown(container.dispose);
  await container.read(provider.future);
  container.invalidate(provider);
  final refreshing = container.read(provider);
  check(refreshing.isLoading).isTrue();
  check(refreshing.value).equals(server);
  return refreshing;
}

void main() {
  test('a change of the primary account cut short holds the splash until '
      'startup settles it', () {
    // Open WebUI parked by a switch to LibreChat that never finished.
    final read = _reader(
      activeServer: const AsyncData(null),
      auth: AuthNavigationState.needsLogin,
      bootRecovering: true,
    );
    for (final location in [
      Routes.chat,
      Routes.backendChooser,
      Routes.authentication,
    ]) {
      check(
        because: location,
        resolveRouteRedirect(location, read),
      ).equals(Routes.splash);
    }
    check(resolveRouteRedirect(Routes.splash, read)).isNull();
  });

  group('with a LibreChat account in charge', () {
    // Open WebUI is parked: no active server, signed out. None of its rules
    // may decide where a LibreChat user goes.
    ProviderRead libreChat(AuthNavigationState auth) => _reader(
      preferred: PreferredBackend.libreChat,
      activeServer: const AsyncData(null),
      auth: AuthNavigationState.needsLogin,
      primaryAuth: auth,
    );

    const owuiOnly = [
      Routes.workspace,
      '${Routes.workspace}/models',
      Routes.notes,
      '/notes/n1',
      '/channel/c1',
      Routes.scheduledTasks,
      Routes.calendar,
    ];
    const allowed = [Routes.chat, Routes.profile, Routes.accounts];
    const setup = [
      Routes.backendChooser,
      Routes.libreChatSignIn,
      Routes.hermesSettings,
      Routes.directConnections,
    ];
    // Open WebUI's sign-in stays reachable: an Open WebUI account can be
    // added while LibreChat is in charge.
    const openWebUiSignIn = [
      Routes.serverConnection,
      Routes.addServer,
      Routes.authentication,
      Routes.ssoAuth,
    ];

    final table = <AuthNavigationState, Map<String, String?>>{
      AuthNavigationState.loading: {
        Routes.splash: null,
        Routes.chat: Routes.splash,
        Routes.workspace: Routes.splash,
      },
      // Its own sign-in, for the account's server; choosing another
      // backend stays open.
      AuthNavigationState.needsLogin: {
        Routes.libreChatSignIn: null,
        Routes.backendChooser: null,
        Routes.chat: Routes.libreChatSignIn,
        Routes.splash: Routes.libreChatSignIn,
        Routes.notes: Routes.libreChatSignIn,
      },
      AuthNavigationState.authenticated: {
        Routes.splash: Routes.chat,
        for (final location in allowed) location: null,
        for (final location in owuiOnly) location: Routes.chat,
      },
      AuthNavigationState.error: {
        Routes.splash: Routes.chat,
        for (final location in allowed) location: null,
        for (final location in owuiOnly) location: Routes.chat,
      },
    };

    for (final MapEntry(key: auth, value: expectations) in table.entries) {
      test('${auth.name}: routes on the LibreChat sign-in', () {
        final read = libreChat(auth);
        for (final MapEntry(key: location, value: expected)
            in expectations.entries) {
          check(
            because: '$location while ${auth.name}',
            resolveRouteRedirect(location, read),
          ).equals(expected);
        }
        for (final location in [...setup, ...openWebUiSignIn]) {
          check(
            because: '$location while ${auth.name}',
            resolveRouteRedirect(location, read),
          ).isNull();
        }
      });
    }

    test('needsLogin: the saved accounts stay in reach', () {
      // Another saved account may still be signed in; switching to it needs
      // no session for the one in charge.
      final read = libreChat(AuthNavigationState.needsLogin);
      // As are a saved server's addresses, which Accounts opens.
      for (final location in [
        Routes.accounts,
        Routes.serverAddresses,
        Routes.serverAddressEditor,
      ]) {
        check(
          because: location,
          resolveRouteRedirect(location, read),
        ).isNull();
      }
      // Chat still waits for the sign-in.
      check(resolveRouteRedirect(Routes.chat, read)).isNotNull();
    });

    test('the Hermes pages follow the Hermes connection beside it', () {
      ProviderRead signedIn(HermesConfig hermes) => _reader(
        preferred: PreferredBackend.libreChat,
        activeServer: const AsyncData(null),
        auth: AuthNavigationState.needsLogin,
        primaryAuth: AuthNavigationState.authenticated,
        hermes: hermes,
      );
      const gateway = HermesConfig(
        enabled: true,
        baseUrl: 'https://hermes.example',
        mode: HermesBackendMode.desktopGateway,
      );
      const responses = HermesConfig(
        enabled: true,
        baseUrl: 'https://hermes.example',
        apiKey: 'key',
      );

      check(resolveRouteRedirect(Routes.hermesMcp, signedIn(gateway))).isNull();
      check(
        resolveRouteRedirect(Routes.hermesMcp, signedIn(responses)),
      ).equals(Routes.chat);
      check(
        resolveRouteRedirect(Routes.hermesSessions, signedIn(responses)),
      ).isNull();
      check(
        resolveRouteRedirect(
          Routes.hermesSessions,
          signedIn(const HermesConfig()),
        ),
      ).equals(Routes.chat);
    });
  });

  group('resolveRouteRedirect', () {
    test('reviewer mode pins the app to chat', () {
      final read = _reader(reviewerMode: true);

      check(resolveRouteRedirect(Routes.profile, read)).equals(Routes.chat);
      check(resolveRouteRedirect(Routes.chat, read)).isNull();
    });

    test('an authenticated session leaves auth pages for chat', () {
      final read = _reader();

      check(resolveRouteRedirect(Routes.authentication, read))
          .equals(Routes.chat);
      check(resolveRouteRedirect(Routes.splash, read)).equals(Routes.chat);
      check(resolveRouteRedirect(Routes.chat, read)).isNull();
    });

    group('adding another account', () {
      test('stays in the sign-in flow while the first account is active', () {
        final read = _reader(addingAccountFrom: _server.id);

        check(resolveRouteRedirect(Routes.addServer, read)).isNull();
        check(resolveRouteRedirect(Routes.authentication, read)).isNull();
        check(resolveRouteRedirect(Routes.proxyAuth, read)).isNull();
        check(resolveRouteRedirect(Routes.ssoAuth, read)).isNull();
      });

      test('lands in chat once the new account is the active one', () {
        final read = _reader(addingAccountFrom: 'the-account-it-began-from');

        check(resolveRouteRedirect(Routes.authentication, read))
            .equals(Routes.chat);
        check(resolveRouteRedirect(Routes.addServer, read)).equals(Routes.chat);
      });

      test('outside the flow an add-server visit goes to chat', () {
        final read = _reader();

        check(resolveRouteRedirect(Routes.addServer, read)).equals(Routes.chat);
      });

      // A profile refresh for the account it began from was refused: that
      // account's error, its token kept.
      test('stays in the sign-in flow through an error of the first '
          'account', () {
        final read = _reader(
          auth: AuthNavigationState.error,
          authSnapshot: const AuthState(
            status: AuthStatus.error,
            token: 'token-a',
            error: 'refused',
          ),
          addingAccountFrom: _server.id,
        );

        check(resolveRouteRedirect(Routes.addServer, read)).isNull();
        check(resolveRouteRedirect(Routes.authentication, read)).isNull();
        // Outside the addition's pages, the error shows as before.
        check(resolveRouteRedirect(Routes.chat, read))
            .equals(Routes.connectionIssue);
      });

      // The Keychain can refuse a read for a moment.
      test('stays in the sign-in flow when the active server cannot be '
          'read', () {
        final read = _reader(
          activeServer: AsyncError<ServerConfig?>('locked', StackTrace.empty),
          addingAccountFrom: _server.id,
          settledAccount: _server.id,
        );

        check(resolveRouteRedirect(Routes.addServer, read)).isNull();
        check(resolveRouteRedirect(Routes.authentication, read)).isNull();
        check(resolveRouteRedirect(Routes.chat, read))
            .equals(Routes.connectionIssue);
      });

      test('the new account, signed out, stays on its sign-in', () {
        final read = _reader(
          auth: AuthNavigationState.needsLogin,
          addingAccountFrom: 'the-account-it-began-from',
        );

        check(resolveRouteRedirect(Routes.addServer, read)).isNull();
        check(resolveRouteRedirect(Routes.authentication, read)).isNull();
      });
    });

    group('checking a proxy-protected address', () {
      test('opens the proxy sign-in while the address editor waits on it', () {
        final read = _reader(proxySignInForRouteEditing: true);

        check(resolveRouteRedirect(Routes.proxyAuth, read)).isNull();
        // Only that screen.
        check(resolveRouteRedirect(Routes.authentication, read))
            .equals(Routes.chat);
        check(routeRedirectDependencies)
            .contains(proxySignInForRouteEditingProvider);
      });

      test('a signed-in visit to the proxy sign-in otherwise goes to chat', () {
        final read = _reader();

        check(resolveRouteRedirect(Routes.proxyAuth, read)).equals(Routes.chat);
      });
    });

    test('a signed-out session is sent to authentication', () {
      final read = _reader(auth: AuthNavigationState.needsLogin);

      check(resolveRouteRedirect(Routes.chat, read))
          .equals(Routes.authentication);
      check(resolveRouteRedirect(Routes.authentication, read)).isNull();
    });

    test('a loading session holds the splash', () {
      final read = _reader(auth: AuthNavigationState.loading);

      check(resolveRouteRedirect(Routes.chat, read)).equals(Routes.splash);
      check(resolveRouteRedirect(Routes.splash, read)).isNull();
    });

    test('a recoverable auth error shows the connection issue page', () {
      final read = _reader(auth: AuthNavigationState.error);

      check(resolveRouteRedirect(Routes.chat, read))
          .equals(Routes.connectionIssue);
      check(resolveRouteRedirect(Routes.connectionIssue, read)).isNull();
    });

    test(
      'a refresh of the active server keeps the user where they are',
      () async {
        // Saving one of its addresses, or moving to another, fetches it again.
        final read = _reader(activeServer: await _refreshing(_server));

        check(resolveRouteRedirect(Routes.profile, read)).isNull();
        check(resolveRouteRedirect(Routes.chat, read)).isNull();
      },
    );

    test('a failed or loading server lookup does not strand the user', () {
      final failed = _reader(
        activeServer: AsyncError<ServerConfig?>('boom', StackTrace.empty),
        auth: AuthNavigationState.needsLogin,
      );
      final loading = _reader(
        activeServer: const AsyncLoading(),
        auth: AuthNavigationState.needsLogin,
      );

      check(resolveRouteRedirect(Routes.chat, failed))
          .equals(Routes.connectionIssue);
      check(resolveRouteRedirect(Routes.chat, loading)).equals(Routes.splash);
      check(resolveRouteRedirect(Routes.authentication, loading)).isNull();
    });

    test('no server sends onboarding to the backend chooser', () {
      final read = _reader(
        activeServer: const AsyncData(null),
        auth: AuthNavigationState.needsLogin,
      );

      check(resolveRouteRedirect(Routes.chat, read))
          .equals(Routes.backendChooser);
      check(resolveRouteRedirect(Routes.serverConnection, read)).isNull();
    });

    test('Hermes-only setup waits on secrets, then recovers in settings', () {
      const hermes = HermesConfig(enabled: true);
      final loading = _reader(
        activeServer: const AsyncData(null),
        auth: AuthNavigationState.needsLogin,
        preferred: PreferredBackend.hermes,
        hermes: hermes,
        hermesSecretsLoading: true,
      );
      final settled = _reader(
        activeServer: const AsyncData(null),
        auth: AuthNavigationState.needsLogin,
        preferred: PreferredBackend.hermes,
        hermes: hermes,
      );

      check(resolveRouteRedirect(Routes.chat, loading)).isNull();
      check(resolveRouteRedirect(Routes.notes, loading)).equals(Routes.splash);
      check(resolveRouteRedirect(Routes.notes, settled))
          .equals(Routes.hermesSettings);
      check(resolveRouteRedirect(Routes.hermesSettings, settled)).isNull();
      // Adding or editing a saved connection is part of recovering.
      for (final editor in [
        Routes.hermesConnectionEditorPath(Routes.hermesNewConnectionId),
        Routes.hermesConnectionEditorPath(
          'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        ),
      ]) {
        check(resolveRouteRedirect(editor, settled)).isNull();
        check(isHermesOnlyAppLocation(editor)).isTrue();
      }
    });

    test('an open Hermes room is a Hermes page', () {
      check(isHermesOnlyAppLocation(Routes.hermesRoomPath('standup')))
          .isTrue();
      check(Routes.hermesRoomPath('a b')).equals('/hermes-room/a%20b');
      check(isHermesOnlyAppLocation('/hermes-roomless')).isFalse();
    });

    test('an open Hermes room needs a usable Desktop Gateway', () {
      final room = Routes.hermesRoomPath('standup');
      const gateway = HermesConfig(
        enabled: true,
        baseUrl: 'https://hermes.example',
        mode: HermesBackendMode.desktopGateway,
      );
      const responses = HermesConfig(
        enabled: true,
        baseUrl: 'https://hermes.example',
        apiKey: 'key',
      );

      check(
        resolveRouteRedirect(
          room,
          _accountless(PreferredBackend.hermes, gateway),
        ),
      ).isNull();
      // Switching to the Responses API leaves no room to show.
      check(
        resolveRouteRedirect(
          room,
          _accountless(PreferredBackend.hermes, responses),
        ),
      ).equals(Routes.chat);
    });

    test('a usable accountless backend never needs an account', () {
      final read = _reader(
        activeServer: const AsyncData(null),
        auth: AuthNavigationState.needsLogin,
        preferred: PreferredBackend.unset,
        accountless: true,
      );

      check(resolveRouteRedirect(Routes.chat, read)).isNull();
      check(resolveRouteRedirect(Routes.authentication, read)).isNull();
    });

    // An expired session leaves the saved accounts on the device, and the
    // profile offers Manage accounts next to a usable Hermes or Direct
    // backend. The router sent that to chat.
    test('Manage accounts opens with the active account signed out next to '
        'a usable accountless backend', () {
      final hermes = _reader(
        auth: AuthNavigationState.needsLogin,
        preferred: PreferredBackend.hermes,
        hermes: const HermesConfig(
          enabled: true,
          baseUrl: 'https://hermes.example',
          apiKey: 'key',
        ),
        accountless: true,
      );
      final direct = _reader(
        auth: AuthNavigationState.needsLogin,
        preferred: PreferredBackend.direct,
        accountless: true,
        directProfiles: [
          DirectConnectionProfile(
            id: 'direct',
            name: 'Direct',
            adapterKey: kOpenAiCompatibleAdapterKey,
            baseUrl: 'https://api.example/v1',
            apiKey: 'key',
          ),
        ],
      );

      check(resolveRouteRedirect(Routes.accounts, hermes)).isNull();
      check(resolveRouteRedirect(Routes.accounts, direct)).isNull();
      // Manage accounts opens a server's addresses.
      for (final location in [
        Routes.serverAddresses,
        Routes.serverAddressEditor,
      ]) {
        check(resolveRouteRedirect(location, hermes)).isNull();
        check(resolveRouteRedirect(location, direct)).isNull();
      }
    });

    group('the Hermes MCP page', () {
      const gateway = HermesConfig(
        enabled: true,
        baseUrl: 'https://hermes.example',
        mode: HermesBackendMode.desktopGateway,
      );
      const responses = HermesConfig(
        enabled: true,
        baseUrl: 'https://hermes.example',
        apiKey: 'key',
      );

      test('opens where the Desktop Gateway is configured', () {
        for (final preferred in [
          PreferredBackend.hermes,
          PreferredBackend.direct,
        ]) {
          check(
            because: '$preferred',
            resolveRouteRedirect(
              Routes.hermesMcp,
              _accountless(preferred, gateway),
            ),
          ).isNull();
        }
      });

      test('is not offered in Responses API mode', () {
        check(
          resolveRouteRedirect(
            Routes.hermesMcp,
            _accountless(PreferredBackend.hermes, responses),
          ),
        ).equals(Routes.chat);
      });

      test('is not offered to a Direct-primary install without Hermes', () {
        check(
          resolveRouteRedirect(
            Routes.hermesMcp,
            _accountless(PreferredBackend.direct, const HermesConfig()),
          ),
        ).equals(Routes.chat);
      });

      test('is in no location-only allowlist', () {
        // Such a list answers for every Hermes configuration, including the
        // loading branches that run before the mode is known to be usable.
        check(isHermesOnlyAppLocation(Routes.hermesMcp)).isFalse();
        check(isDirectOnlyAppLocation(Routes.hermesMcp)).isFalse();
      });

      test('is not offered while the gateway configuration is unusable', () {
        // Desktop Gateway mode with no valid endpoint is not a usable
        // backend, so the user is sent to finish setting it up instead.
        const incomplete = HermesConfig(
          enabled: true,
          mode: HermesBackendMode.desktopGateway,
        );
        final read = _reader(
          activeServer: const AsyncData(null),
          auth: AuthNavigationState.needsLogin,
          preferred: PreferredBackend.hermes,
          hermes: incomplete,
        );

        check(resolveRouteRedirect(Routes.hermesMcp, read))
            .equals(Routes.hermesSettings);
      });

      test('is not offered while Hermes secrets are still loading', () {
        final read = _reader(
          activeServer: const AsyncData(null),
          auth: AuthNavigationState.needsLogin,
          preferred: PreferredBackend.hermes,
          hermes: const HermesConfig(enabled: true),
          hermesSecretsLoading: true,
        );

        check(resolveRouteRedirect(Routes.hermesMcp, read))
            .equals(Routes.splash);
      });
    });

    group('the Hermes sessions page', () {
      test('opens wherever a Hermes connection is set up', () {
        const hermes = HermesConfig(
          enabled: true,
          baseUrl: 'https://hermes.example',
          apiKey: 'key',
        );
        for (final preferred in [
          PreferredBackend.hermes,
          PreferredBackend.direct,
        ]) {
          check(
            because: '$preferred',
            resolveRouteRedirect(
              Routes.hermesSessions,
              _accountless(preferred, hermes),
            ),
          ).isNull();
        }
      });

      test('is not offered to a Direct-primary install without Hermes', () {
        check(
          resolveRouteRedirect(
            Routes.hermesSessions,
            _accountless(PreferredBackend.direct, const HermesConfig()),
          ),
        ).equals(Routes.chat);
      });
    });
  });
}
