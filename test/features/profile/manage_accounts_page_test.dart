import 'package:checks/checks.dart';
import 'package:conduit/features/profile/views/manage_accounts_page.dart';
import 'package:conduit/features/profile/widgets/account_sheet.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/auth/openwebui_account_summaries.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_profile.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/librechat/models/librechat_account.dart';
import 'package:conduit_core/features/librechat/models/librechat_server.dart';
import 'package:conduit_core/features/librechat/models/librechat_session.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/providers/openwebui_accounts_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

final _home = OpenWebUiServer(
  id: 'home',
  name: 'Home Lab',
  endpoints: [OpenWebUiEndpoint(id: 'home-lan', url: 'http://10.0.0.2:3000')],
);

final _work = OpenWebUiServer(
  id: 'work',
  name: '',
  endpoints: [OpenWebUiEndpoint(id: 'work-1', url: 'https://chat.corp.com')],
);

OpenWebUiAccountEntry _entry(
  String id, {
  required String name,
  OpenWebUiServer? server,
  String? email,
  bool isActive = false,
  bool hasSession = true,
}) => OpenWebUiAccountEntry(
  account: OpenWebUiAccount(
    id: id,
    serverId: (server ?? _home).id,
    userId: 'u-$id',
  ),
  server: server ?? _home,
  summary: OpenWebUiAccountSummary(name: name, email: email),
  isActive: isActive,
  hasSession: hasSession,
);

const _hermesHome = HermesConnectionProfile(
  id: 'hermes-home',
  name: 'Home agent',
  documentTrustPrincipalId: 'p-home',
  baseUrl: 'http://10.0.0.5:8642',
);

const _hermesLaptop = HermesConnectionProfile(
  id: 'hermes-laptop',
  name: 'Laptop',
  documentTrustPrincipalId: 'p-laptop',
  baseUrl: 'http://10.0.0.6:9119',
  mode: HermesBackendMode.desktopGateway,
);

/// Reports every switch as one that needs a sign-in, as the accounts
/// controller does for an account without a session.
final class _SignInNeeded implements OpenWebUiAccountsController {
  final switched = <String>[];

  @override
  Future<OpenWebUiAccountChangeResult> switchTo(
    String accountId, {
    bool force = false,
  }) async {
    switched.add(accountId);
    return OpenWebUiAccountChangeResult.needsSignIn;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Registry extends LibreChatRegistryController {
  _Registry(this.registry);

  final LibreChatRegistry registry;

  @override
  Future<LibreChatRegistry> build() async => registry;
}

final class _DirectProfiles extends DirectConnectionProfilesController {
  _DirectProfiles(this.profiles);

  final List<DirectConnectionProfile> profiles;

  @override
  Future<List<DirectConnectionProfile>> build() async => profiles;
}

void main() {
  late GoRouter router;

  Future<_SignInNeeded> pumpAccounts(
    WidgetTester tester,
    List<OpenWebUiAccountEntry> accounts, {
    List<HermesConnectionProfile> hermes = const [],
    String? hermesActiveId,
    bool hermesEnabled = false,
    List<DirectConnectionProfile> direct = const [],
    List<Override> overrides = const [],
  }) async {
    final controller = _SignInNeeded();
    Widget target(String name) => Text(name);
    router = GoRouter(
      initialLocation: Routes.accounts,
      routes: [
        GoRoute(
          path: Routes.accounts,
          name: RouteNames.accounts,
          builder: (_, _) => const ManageAccountsPage(),
        ),
        GoRoute(
          path: Routes.authentication,
          builder: (_, _) => target('sign in'),
        ),
        GoRoute(
          path: Routes.serverAddresses,
          name: RouteNames.serverAddresses,
          builder: (_, state) => target('server ${state.extra}'),
        ),
        GoRoute(
          path: Routes.hermesSettings,
          name: RouteNames.hermesSettings,
          builder: (_, _) => target('hermes page'),
        ),
        GoRoute(
          path: Routes.hermesConnectionEditor,
          name: RouteNames.hermesConnectionEditor,
          builder: (_, state) =>
              target('hermes editor ${state.pathParameters['id']}'),
        ),
        GoRoute(
          path: Routes.directConnections,
          name: RouteNames.directConnections,
          builder: (_, _) => target('direct page'),
        ),
        GoRoute(
          path: Routes.directConnectionEditor,
          name: RouteNames.directConnectionEditor,
          builder: (_, state) =>
              target('direct editor ${state.pathParameters['id']}'),
        ),
        GoRoute(
          path: Routes.serverConnection,
          name: RouteNames.serverConnection,
          builder: (_, _) => target('connect'),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          openWebUiAccountsProvider.overrideWith((ref) async => accounts),
          openWebUiAccountsControllerProvider.overrideWithValue(controller),
          hermesConnectionsProvider.overrideWithValue(hermes),
          hermesActiveConnectionIdProvider.overrideWithValue(hermesActiveId),
          hermesEnabledProvider.overrideWithValue(hermesEnabled),
          directConnectionProfilesProvider.overrideWith(
            () => _DirectProfiles(direct),
          ),
          applePccPlatformSupportedProvider.overrideWithValue(false),
          reviewerModeProvider.overrideWithValue(false),
          ...overrides,
        ],
        child: MaterialApp.router(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  String location() => router.routerDelegate.currentConfiguration.uri.path;

  Finder inCard(String card, Finder finder) =>
      find.descendant(of: find.byKey(Key(card)), matching: finder);

  testWidgets('each server is a card of its accounts, the active one checked', (
    tester,
  ) async {
    await pumpAccounts(tester, [
      _entry('alex-home', name: 'Alex', email: 'alex@home.lan', isActive: true),
      _entry('sam-home', name: 'Sam', hasSession: false),
      _entry('alex-work', name: 'Alex L.', server: _work),
    ]);

    // The server leads its card, under its initials; its accounts follow.
    expect(inCard('accounts-server-home', find.text('Home Lab')), findsOne);
    expect(inCard('accounts-server-home', find.text('HL')), findsOne);
    expect(inCard('accounts-server-home', find.text('Alex')), findsOne);
    expect(
      inCard('accounts-server-home', find.text('alex@home.lan')),
      findsOne,
    );
    expect(inCard('accounts-server-home', find.text('Signed out')), findsOne);
    // Without a name, a server goes by its host.
    expect(
      inCard('accounts-server-work', find.text('chat.corp.com')),
      findsOne,
    );
    expect(inCard('accounts-server-work', find.text('C')), findsOne);

    expect(
      find.descendant(
        of: find.byKey(const Key('accounts-row-alex-home')),
        matching: find.bySemanticsLabel('Active'),
      ),
      findsOne,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('accounts-row-sam-home')),
        matching: find.bySemanticsLabel('Active'),
      ),
      findsNothing,
    );
  });

  testWidgets('the active account, signed in, is not switched to', (
    tester,
  ) async {
    final controller = await pumpAccounts(tester, [
      _entry('alex-home', name: 'Alex', isActive: true),
      _entry('sam-home', name: 'Sam'),
    ]);

    await tester.tap(find.byKey(const Key('accounts-row-alex-home')));
    await tester.pumpAndSettle();

    check(controller.switched).isEmpty();
    check(location()).equals(Routes.accounts);
  });

  // Next to a usable Direct or Hermes backend this page stays open once the
  // active account's session expires, and its row, marked signed out, did
  // nothing when tapped.
  testWidgets('the active account, signed out, opens its sign-in', (
    tester,
  ) async {
    final controller = await pumpAccounts(tester, [
      _entry('alex-home', name: 'Alex', isActive: true, hasSession: false),
      _entry('sam-home', name: 'Sam'),
    ]);
    expect(
      find.descendant(
        of: find.byKey(const Key('accounts-row-alex-home')),
        matching: find.text('Signed out'),
      ),
      findsOne,
    );

    await tester.tap(find.byKey(const Key('accounts-row-alex-home')));
    await tester.pumpAndSettle();

    check(controller.switched).deepEquals(['alex-home']);
    check(location()).equals(Routes.authentication);
    expect(find.text('sign in'), findsOneWidget);
  });

  testWidgets('a server card opens its page from the top row', (tester) async {
    await pumpAccounts(tester, [
      _entry('alex-home', name: 'Alex', isActive: true),
    ]);

    await tester.tap(find.byKey(const Key('accounts-server-open-home')));
    await tester.pumpAndSettle();

    expect(find.text('server home'), findsOne);
  });

  testWidgets('Hermes lists its connections, the one in use checked', (
    tester,
  ) async {
    await pumpAccounts(
      tester,
      const [],
      hermes: const [_hermesHome, _hermesLaptop],
      hermesActiveId: 'hermes-home',
      hermesEnabled: true,
    );

    expect(inCard('accounts-hermes', find.text('Hermes Agent')), findsOne);
    expect(inCard('accounts-hermes', find.text('Home agent')), findsOne);
    // Plain HTTP to another machine: its credentials travel unencrypted.
    expect(
      inCard(
        'accounts-hermes',
        find.text('Desktop Gateway · 10.0.0.6 · Not encrypted'),
      ),
      findsOne,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('accounts-hermes-hermes-home')),
        matching: find.bySemanticsLabel('Active'),
      ),
      findsOne,
    );

    await tester.tap(find.byKey(const Key('accounts-hermes-open')));
    await tester.pumpAndSettle();
    expect(find.text('hermes page'), findsOne);
  });

  testWidgets('with Hermes off, no connection is checked', (tester) async {
    await pumpAccounts(
      tester,
      const [],
      hermes: const [_hermesHome],
      hermesActiveId: 'hermes-home',
    );

    expect(find.bySemanticsLabel('Active'), findsNothing);
  });

  testWidgets('Direct lists its providers, none checked, each opening it', (
    tester,
  ) async {
    await pumpAccounts(
      tester,
      const [],
      direct: [
        DirectConnectionProfile(
          id: 'router',
          name: 'OpenRouter',
          adapterKey: kOpenAiCompatibleAdapterKey,
          baseUrl: 'https://openrouter.ai/api/v1',
        ),
        DirectConnectionProfile(
          id: 'desk',
          name: 'Desk',
          adapterKey: kOllamaAdapterKey,
          baseUrl: 'http://10.0.0.7:11434',
          enabled: false,
        ),
      ],
    );

    expect(
      inCard('accounts-direct', find.text('Direct Connections')),
      findsOne,
    );
    expect(inCard('accounts-direct', find.text('Ollama · Disabled')), findsOne);
    expect(find.bySemanticsLabel('Active'), findsNothing);
    expect(find.byKey(const Key('accounts-direct-add')), findsNothing);

    // Edited in the account sheet, not on a page of its own.
    await tester.tap(find.byKey(const Key('accounts-direct-desk')));
    await tester.pumpAndSettle();
    expect(find.byType(AccountSheet), findsOne);
    expect(find.byKey(const Key('account-sheet-direct')), findsOne);
  });

  testWidgets('LibreChat lists its accounts once it is on, the one in '
      'charge checked', (tester) async {
    final dev = LibreChatAccount.forUser(
      const LibreChatServer(baseUrl: 'https://chat.example.com'),
      const LibreChatUser(id: 'u1', name: 'Dev'),
      serverTitle: 'Team Chat',
    );
    final ops = LibreChatAccount.forUser(
      const LibreChatServer(baseUrl: 'https://ops.example.com'),
      const LibreChatUser(id: 'u2', name: 'Ops'),
    );
    await pumpAccounts(
      tester,
      const [],
      overrides: [
        libreChatBackendEnabledProvider.overrideWithValue(true),
        libreChatRegistryProvider.overrideWith(
          () => _Registry(
            LibreChatRegistry(accounts: [dev, ops], activeId: dev.id),
          ),
        ),
        primaryAccountKindProvider.overrideWithValue(
          PrimaryAccountKind.libreChat,
        ),
      ],
    );

    expect(inCard('accounts-librechat', find.text('Dev')), findsOne);
    expect(inCard('accounts-librechat', find.text('Ops')), findsOne);
    // Neither has a saved session here: both read signed out, with where
    // they are.
    expect(
      inCard('accounts-librechat', find.text('Signed out · ops.example.com')),
      findsOne,
    );
    expect(
      inCard('accounts-librechat', find.text('Signed out · Team Chat')),
      findsOne,
    );
    expect(
      find.descendant(
        of: find.byKey(Key('accounts-librechat-${dev.id}')),
        matching: find.bySemanticsLabel('Active'),
      ),
      findsOne,
    );
    expect(find.byKey(const Key('accounts-librechat-add')), findsOne);
    // Several accounts, counting LibreChat's: signing out of all is offered.
    await tester.scrollUntilVisible(
      find.byKey(const Key('accounts-sign-out-all')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const Key('accounts-sign-out-all')), findsOne);
  });

  testWidgets('LibreChat stays out of the list while it is off and unused', (
    tester,
  ) async {
    await pumpAccounts(
      tester,
      const [],
      overrides: [libreChatBackendEnabledProvider.overrideWithValue(false)],
    );
    expect(find.byKey(const Key('accounts-librechat')), findsNothing);
  });

  testWidgets('every card shows when empty, offering to add its first', (
    tester,
  ) async {
    await pumpAccounts(tester, const []);

    expect(find.byKey(const Key('accounts-openwebui-add')), findsOne);
    expect(find.byKey(const Key('accounts-hermes-add')), findsOne);
    expect(find.byKey(const Key('accounts-direct-add')), findsOne);
    expect(find.byKey(const Key('accounts-sign-out-all')), findsNothing);

    // Its server is entered in the account sheet.
    await tester.tap(find.byKey(const Key('accounts-openwebui-add')));
    await tester.pumpAndSettle();
    expect(find.byType(AccountSheet), findsOne);
    expect(find.byKey(const Key('account-sheet-openwebui')), findsOne);
  });

  testWidgets('the page ends on Add Account, which opens the account sheet', (
    tester,
  ) async {
    await pumpAccounts(tester, [
      _entry('alex-home', name: 'Alex', isActive: true),
    ]);
    final add = find.byKey(const Key('accounts-add'));
    await tester.scrollUntilVisible(
      add,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.descendant(of: add, matching: find.text('Add Account')),
      findsOne,
    );
    // Below every card: nothing but Sign Out of All Accounts follows it.
    final direct = find.byKey(const Key('accounts-direct'));
    expect(
      tester.getTopLeft(add).dy,
      greaterThan(tester.getBottomLeft(direct).dy),
    );

    await tester.tap(add);
    await tester.pumpAndSettle();
    expect(find.byType(AccountSheet), findsOne);
    expect(find.byKey(const Key('account-sheet-openwebui')), findsOne);
  });

  testWidgets('with one account, Settings signs out of it, not this page', (
    tester,
  ) async {
    await pumpAccounts(tester, [
      _entry('alex-home', name: 'Alex', isActive: true),
    ]);
    expect(find.byKey(const Key('accounts-sign-out-all')), findsNothing);
  });

  testWidgets('signing out of every account is offered with several', (
    tester,
  ) async {
    await pumpAccounts(tester, [
      _entry('alex-home', name: 'Alex', isActive: true),
      _entry('sam-home', name: 'Sam'),
    ]);
    await tester.scrollUntilVisible(
      find.byKey(const Key('accounts-sign-out-all')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const Key('accounts-sign-out-all')), findsOne);
  });
}
