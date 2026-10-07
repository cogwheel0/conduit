import 'package:checks/checks.dart';
import 'package:conduit/features/profile/widgets/account_actions.dart';
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
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _active = ServerConfig(
  id: 'account-a',
  name: 'Home',
  url: 'https://owui.example',
);

/// Adding an account goes through sign-in pages the router keeps a signed-in
/// user away from, and the router decides as the page is pushed.
void main() {
  late ProviderContainer container;
  late GoRouter router;

  setUp(() {
    container = ProviderContainer(
      overrides: [
        activeServerProvider.overrideWithValue(const AsyncData(_active)),
      ],
    );
    // The signed-in state the real policy sees; only the addition is live.
    final fixed = <ProviderListenable<Object?>, Object?>{
      reviewerModeProvider: false,
      activeServerProvider: const AsyncData<ServerConfig?>(_active),
      authNavigationStateProvider: AuthNavigationState.authenticated,
      preferredBackendProvider: PreferredBackend.owui,
      hermesConfigProvider: const HermesConfig(),
      hermesSecretsLoadingProvider: false,
      effectiveDirectConnectionProfilesProvider:
          const AsyncData<List<DirectConnectionProfile>>([]),
      accountlessPrimaryBackendUsableProvider: false,
      authStateManagerProvider: const AsyncData<AuthState>(
        AuthState(status: AuthStatus.authenticated),
      ),
    };
    T read<T>(ProviderListenable<T> provider) => fixed.containsKey(provider)
        ? fixed[provider] as T
        : container.read(provider);

    router = GoRouter(
      initialLocation: Routes.chat,
      redirect: (context, state) => resolveRouteRedirect(state.uri.path, read),
      routes: [
        GoRoute(
          path: Routes.chat,
          builder: (context, state) => Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => openAddAccount(context, ref),
              child: const Text('add account'),
            ),
          ),
        ),
        GoRoute(
          path: Routes.addServer,
          name: RouteNames.addServer,
          builder: (context, state) => const Text('add server'),
        ),
      ],
    );
  });

  tearDown(() {
    router.dispose();
    container.dispose();
  });

  testWidgets('opens the connection page while signed in, and ends the '
      'addition when it closes', (tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );

    await tester.tap(find.text('add account'));
    await tester.pumpAndSettle();

    check(find.text('add server').evaluate()).isNotEmpty();
    check(container.read(accountAdditionOriginProvider)).equals(_active.id);

    router.pop();
    await tester.pumpAndSettle();

    check(find.text('add account').evaluate()).isNotEmpty();
    check(container.read(accountAdditionOriginProvider)).isNull();
  });
}
