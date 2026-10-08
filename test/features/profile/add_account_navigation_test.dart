import 'dart:async';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/features/auth/views/server_connection_page.dart';
import 'package:conduit/features/profile/widgets/account_actions.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/navigation/route_redirect.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/providers/chat_entry_readiness_providers.dart';
import 'package:conduit_core/providers/openwebui_accounts_controller.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
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

const _added = ServerConfig(
  id: 'account-b',
  name: 'Home',
  url: 'https://owui.example',
);

/// Adding an account goes through sign-in pages the router keeps a signed-in
/// user away from, and the router decides from its location.
void main() {
  late ProviderContainer container;
  late GoRouter router;
  late _RecordingAccountsController accounts;
  // What the router sees of the active account; a test moves these as the
  // added account's sign-in goes.
  late ServerConfig active;
  late AuthNavigationState auth;
  late bool abandonable;
  // Holds the answer back while set, as a reload of it does.
  Completer<bool>? abandonableAnswer;
  late _MergingAuth signIns;
  late _RegistryStorage storage;
  // What the connection page handed sign-in, when it got that far.
  late Object? authFlow;

  setUp(() {
    active = _active;
    auth = AuthNavigationState.authenticated;
    abandonable = false;
    abandonableAnswer = null;
    storage = _RegistryStorage();
    authFlow = null;
    accounts = _RecordingAccountsController();
    // Folding the added account into the one it was added from leaves that
    // one active.
    signIns = _MergingAuth(onMerge: () => active = _active);
    container = ProviderContainer(
      overrides: [
        activeServerProvider.overrideWithValue(const AsyncData(_active)),
        reviewerModeProvider.overrideWithValue(false),
        pendingSignInAbandonableProvider.overrideWith(
          (ref) async => await abandonableAnswer?.future ?? abandonable,
        ),
        openWebUiAccountsControllerProvider.overrideWithValue(accounts),
        authStateManagerProvider.overrideWith(() => signIns),
        optimizedStorageServiceProvider.overrideWithValue(storage),
      ],
    );
    // The state the real policy sees; besides the addition, only the active
    // account and its sign-in change.
    T read<T>(ProviderListenable<T> provider) {
      final seen = <ProviderListenable<Object?>, Object?>{
        reviewerModeProvider: false,
        activeServerProvider: AsyncData<ServerConfig?>(active),
        authNavigationStateProvider: auth,
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
      return seen.containsKey(provider)
          ? seen[provider] as T
          : container.read(provider);
    }

    router = GoRouter(
      initialLocation: Routes.chat,
      redirect: (context, state) => resolveRouteRedirect(state.uri.path, read),
      routes: [
        GoRoute(
          path: Routes.chat,
          builder: (context, state) => Consumer(
            builder: (context, ref, _) => Column(
              children: [
                TextButton(
                  onPressed: () => openAddAccount(context, ref),
                  child: const Text('add account'),
                ),
                TextButton(
                  onPressed: () =>
                      openAddAccount(context, ref, serverId: 'home'),
                  child: const Text('add account on Home'),
                ),
              ],
            ),
          ),
        ),
        GoRoute(
          path: Routes.addServer,
          name: RouteNames.addServer,
          builder: (context, state) => ServerConnectionPage(
            addingAccount: true,
            serverId: state.extra as String?,
          ),
        ),
        GoRoute(
          path: Routes.authentication,
          name: RouteNames.authentication,
          builder: (context, state) {
            authFlow = state.extra;
            return const Text('sign in');
          },
        ),
      ],
    );
  });

  tearDown(() {
    router.dispose();
    container.dispose();
  });

  Future<void> openAddAccountFromChat(
    WidgetTester tester, {
    String button = 'add account',
  }) async {
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
    await tester.tap(find.text(button));
    await tester.pumpAndSettle();
  }

  final connectionPage = find.byType(
    ServerConnectionPage,
    skipOffstage: false,
  );

  testWidgets('opens the connection page while signed in, and ends the '
      'addition when it closes', (tester) async {
    await openAddAccountFromChat(tester);

    expect(connectionPage, findsOneWidget);
    check(container.read(accountAdditionOriginProvider)).equals(_active.id);

    await tester.tap(
      find.byKey(const ValueKey<String>('server-connection-back-button')),
    );
    await tester.pumpAndSettle();

    check(find.text('add account').evaluate()).isNotEmpty();
    check(container.read(accountAdditionOriginProvider)).isNull();
  });

  // Pushed over chat, the router kept redirecting from chat, so the pages
  // stayed on screen over the account that had just signed in.
  testWidgets('leaves the sign-in pages for chat once the added account '
      'signs in', (tester) async {
    await openAddAccountFromChat(tester);
    unawaited(router.pushNamed<void>(RouteNames.authentication));
    await tester.pumpAndSettle();

    active = _added;
    router.refresh();
    await tester.pumpAndSettle();

    check(find.text('add account').evaluate()).isNotEmpty();
    expect(connectionPage, findsNothing);
    expect(find.text('sign in', skipOffstage: false), findsNothing);
    check(container.read(accountAdditionOriginProvider)).isNull();
  });

  // Signing in as the user the addition began from folds the new account
  // back into that one. With it active again, the router took the addition
  // for still running and kept the finished sign-in on screen.
  testWidgets('leaves the sign-in pages for chat when the sign-in lands '
      'back in the account it was added from', (tester) async {
    PreferencesStore.debugOverride(
      InMemoryKeyValueStore({PreferenceKeys.activeServerId: _added.id}),
    );
    addTearDown(PreferencesStore.debugReset);
    container.read(openWebUiDuplicateAccountReconcilerProvider);
    await openAddAccountFromChat(tester);
    unawaited(router.pushNamed<void>(RouteNames.authentication));
    await tester.pumpAndSettle();
    // The first attempt makes the new account active, signed out.
    active = _added;
    auth = AuthNavigationState.needsLogin;
    router.refresh();
    await tester.pumpAndSettle();

    auth = AuthNavigationState.authenticated;
    signIns.signIn(_activeUser);
    await tester.pumpAndSettle();
    check(active).equals(_active);
    router.refresh();
    await tester.pumpAndSettle();

    check(find.text('add account').evaluate()).isNotEmpty();
    expect(connectionPage, findsNothing);
    expect(find.text('sign in', skipOffstage: false), findsNothing);
    check(container.read(accountAdditionOriginProvider)).isNull();
  });

  // The first attempt makes the new account active before it signs in.
  // Redirecting from chat sent that to a fresh sign-in page instead, and
  // threw away the page the attempt was running on.
  testWidgets('keeps the sign-in pages while the added account is not yet '
      'signed in', (tester) async {
    await openAddAccountFromChat(tester);
    unawaited(router.pushNamed<void>(RouteNames.authentication));
    await tester.pumpAndSettle();

    active = _added;
    auth = AuthNavigationState.needsLogin;
    router.refresh();
    await tester.pumpAndSettle();

    check(find.text('sign in').evaluate()).isNotEmpty();
    expect(connectionPage, findsOneWidget);
    check(router.canPop()).isTrue();
  });

  testWidgets('system back on the connection page returns to chat', (
    tester,
  ) async {
    await openAddAccountFromChat(tester);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    check(find.text('add account').evaluate()).isNotEmpty();
    check(container.read(accountAdditionOriginProvider)).isNull();
    check(accounts.abandons).equals(0);
  });

  testWidgets('system back drops an added account that never signed in', (
    tester,
  ) async {
    abandonable = true;
    await openAddAccountFromChat(tester);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    check(accounts.abandons).equals(1);
    check(find.text('add account').evaluate()).isNotEmpty();
  });

  // Back from the sign-in page, the added account has just become active and
  // whether it can be dropped is still being worked out. Taking the answer
  // shown before left that account active, signed out.
  testWidgets('Back waits to know whether the added account can be dropped', (
    tester,
  ) async {
    await openAddAccountFromChat(tester);
    final answer = abandonableAnswer = Completer<bool>();
    container.invalidate(pendingSignInAbandonableProvider);
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey<String>('server-connection-back-button')),
    );
    await tester.pump();
    answer.complete(true);
    await tester.pumpAndSettle();

    check(accounts.abandons).equals(1);
    check(find.text('add account').evaluate()).isNotEmpty();
  });

  // The connection page fills in a saved server's route but named the new
  // account's connection after the host, and saving it renamed the server
  // to that for every account on it.
  testWidgets('adding an account on a saved server keeps its name', (
    tester,
  ) async {
    // The binding blocks real HTTP; the server answers on loopback.
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = _RealHttpOverrides();
    addTearDown(() => HttpOverrides.global = previousOverrides);
    final server = (await tester.runAsync(
      () => HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    ))!;
    addTearDown(() => tester.runAsync(() => server.close(force: true)));
    server.listen((request) {
      final body = switch (request.uri.path) {
        '/health' => '{"status":true}',
        '/api/config' =>
          '{"status":true,"version":"0.6.0","name":"Open WebUI",'
              '"features":{}}',
        _ => null,
      };
      request.response
        ..statusCode = body == null ? HttpStatus.notFound : HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(body ?? '{}');
      unawaited(request.response.close());
    });
    storage.url = 'http://127.0.0.1:${server.port}';

    await openAddAccountFromChat(tester, button: 'add account on Home');
    expect(find.text(storage.url), findsOneWidget);
    await tester.tap(find.text('Connect'));
    for (var i = 0; i < 100 && authFlow == null; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();

    final saved = (authFlow! as AuthFlowConfig).serverConfig;
    check(saved.name).equals('Home');
    // Saving it next to the accounts already on the server leaves the
    // server's name as it was.
    final registry = await storage.getOpenWebUiRegistryStrict();
    final merged = registry.mergeServerConfigs([
      ...registry.projectAll(),
      saved,
    ]);
    check(merged.servers.map((server) => server.name)).deepEquals(['Home']);
  });
}

class _RealHttpOverrides extends HttpOverrides {}

const _activeUser = User(
  id: 'user-a',
  username: 'ada',
  email: 'ada@example.test',
  role: 'user',
);

/// Account A, which the addition began from, and the added account B, both
/// on the same server.
class _RegistryStorage extends Fake implements OptimizedStorageService {
  /// Where the saved server is.
  String url = 'https://owui.example';

  @override
  Future<OpenWebUiRegistry> getOpenWebUiRegistryStrict() async =>
      OpenWebUiRegistry(
        servers: [
          OpenWebUiServer(
            id: 'home',
            name: 'Home',
            endpoints: [OpenWebUiEndpoint(id: 'home-url', url: url)],
          ),
        ],
        accounts: [
          OpenWebUiAccount(
            id: _active.id,
            serverId: 'home',
            userId: _activeUser.id,
          ),
          OpenWebUiAccount(id: _added.id, serverId: 'home', isActive: true),
        ],
      );
}

/// Signs in when told to, and folds the active account into another as the
/// real merge does.
class _MergingAuth extends AuthStateManager {
  _MergingAuth({required this.onMerge});

  final void Function() onMerge;

  @override
  Future<AuthState> build() async =>
      const AuthState(status: AuthStatus.unauthenticated);

  void signIn(User user) => state = AsyncData(
    AuthState(status: AuthStatus.authenticated, token: 'token', user: user),
  );

  @override
  Future<bool> mergeActiveAccountInto(
    String targetAccountId, {
    required String expectedSourceAccountId,
    String? expectedToken,
  }) async {
    onMerge();
    return true;
  }
}

/// Records each request to drop an added account that never signed in.
class _RecordingAccountsController extends Fake
    implements OpenWebUiAccountsController {
  int abandons = 0;

  @override
  Future<bool> abandonPendingSignIn() async {
    abandons++;
    return true;
  }
}
