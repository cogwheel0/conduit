import 'package:checks/checks.dart';
import 'package:conduit/features/profile/widgets/account_actions.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/auth/openwebui_account_summaries.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/navigation/route_redirect.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/providers/chat_entry_readiness_providers.dart';
import 'package:conduit_core/providers/openwebui_accounts_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _home = ServerConfig(
  id: 'home',
  name: 'Home',
  url: 'https://home.example',
);

const _work = ServerConfig(
  id: 'work',
  name: 'Work',
  url: 'https://work.example',
);

final _homeEntry = OpenWebUiAccountEntry(
  account: OpenWebUiAccount(id: _home.id, serverId: 'home-server', userId: 'u'),
  server: OpenWebUiServer(
    id: 'home-server',
    name: 'Home',
    endpoints: [OpenWebUiEndpoint(id: 'lan', url: _home.url)],
  ),
  summary: const OpenWebUiAccountSummary(name: 'Ada'),
  isActive: true,
  hasSession: true,
);

final _ollama = DirectConnectionProfile(
  id: 'direct-profile',
  name: 'Local Ollama',
  adapterKey: 'ollama',
  baseUrl: 'http://localhost:11434',
  manualModelIds: const ['llama3'],
);

/// Next to a usable Direct backend the router lets a user stay on the
/// profile with an Open WebUI account that is not signed in, so switching to
/// one, or signing out into one, has to open its sign-in itself.
void main() {
  // What the router sees of the active account; the accounts controller
  // moves these as a switch or a sign-out does.
  late ServerConfig? active;
  late AuthNavigationState auth;
  late GoRouter router;

  /// Shows a profile whose actions leave [next] active and signed out, after
  /// stopping a reply first when [replyInProgress].
  Future<void> pumpProfile(
    WidgetTester tester, {
    required ServerConfig? next,
    bool replyInProgress = false,
  }) async {
    active = _home;
    auth = AuthNavigationState.authenticated;
    late final ProviderContainer container;
    final accounts = _SignedOutHandover(
      replyInProgress: replyInProgress,
      leave: () {
        active = next;
        auth = AuthNavigationState.needsLogin;
        container.invalidate(activeServerProvider);
      },
    );
    container = ProviderContainer(
      overrides: [
        activeServerProvider.overrideWith((ref) async => active),
        openWebUiAccountsControllerProvider.overrideWithValue(accounts),
      ],
    );
    addTearDown(container.dispose);
    T read<T>(ProviderListenable<T> provider) {
      final seen = <ProviderListenable<Object?>, Object?>{
        reviewerModeProvider: false,
        activeServerProvider: AsyncData<ServerConfig?>(active),
        authNavigationStateProvider: auth,
        preferredBackendProvider: PreferredBackend.direct,
        hermesConfigProvider: const HermesConfig(),
        hermesSecretsLoadingProvider: false,
        effectiveDirectConnectionProfilesProvider:
            AsyncData<List<DirectConnectionProfile>>([_ollama]),
        accountlessPrimaryBackendUsableProvider: true,
        authStateManagerProvider: const AsyncData<AuthState>(
          AuthState(status: AuthStatus.unauthenticated),
        ),
      };
      return seen.containsKey(provider)
          ? seen[provider] as T
          : container.read(provider);
    }

    router = GoRouter(
      initialLocation: Routes.profile,
      redirect: (context, state) => resolveRouteRedirect(state.uri.path, read),
      routes: [
        GoRoute(
          path: Routes.profile,
          builder: (context, state) => Consumer(
            builder: (context, ref, _) => Column(
              children: [
                TextButton(
                  onPressed: () => switchToSavedAccount(context, ref, _work.id),
                  child: const Text('switch'),
                ),
                TextButton(
                  onPressed: () =>
                      signOutOfSavedAccount(context, ref, _homeEntry),
                  child: const Text('sign out'),
                ),
              ],
            ),
          ),
        ),
        GoRoute(
          path: Routes.authentication,
          builder: (context, state) => const Text('sign in'),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  String location() => router.routerDelegate.currentConfiguration.uri.path;

  testWidgets('switching to an account that needs sign-in opens it', (
    tester,
  ) async {
    await pumpProfile(tester, next: _work);

    await tester.tap(find.text('switch'));
    await tester.pumpAndSettle();

    check(location()).equals(Routes.authentication);
    expect(find.text('sign in'), findsOneWidget);
  });

  testWidgets('switching anyway past a reply opens sign-in too', (
    tester,
  ) async {
    await pumpProfile(tester, next: _work, replyInProgress: true);

    await tester.tap(find.text('switch'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Switch anyway'));
    await tester.pumpAndSettle();

    check(location()).equals(Routes.authentication);
  });

  testWidgets('signing out into an account that needs sign-in opens it', (
    tester,
  ) async {
    await pumpProfile(tester, next: _work);

    await tester.tap(find.text('sign out'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();

    check(location()).equals(Routes.authentication);
  });

  testWidgets('signing out of the last account carries on without it', (
    tester,
  ) async {
    await pumpProfile(tester, next: null);

    await tester.tap(find.text('sign out'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();

    check(location()).equals(Routes.profile);
    expect(find.text('sign in'), findsNothing);
  });
}

/// Leaves another account active and signed out, as the accounts controller
/// reports for one without a session.
class _SignedOutHandover extends Fake implements OpenWebUiAccountsController {
  _SignedOutHandover({required this.replyInProgress, required this.leave});

  final bool replyInProgress;
  final void Function() leave;

  Future<OpenWebUiAccountChangeResult> _change(bool force) async {
    if (replyInProgress && !force) {
      return OpenWebUiAccountChangeResult.blockedByActiveReply;
    }
    leave();
    return OpenWebUiAccountChangeResult.needsSignIn;
  }

  @override
  Future<OpenWebUiAccountChangeResult> switchTo(
    String accountId, {
    bool force = false,
  }) => _change(force);

  @override
  Future<OpenWebUiAccountChangeResult> signOut(
    String accountId, {
    bool force = false,
  }) => _change(force);
}
