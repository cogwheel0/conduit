import 'package:checks/checks.dart';
import 'package:conduit/features/profile/views/profile_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/auth/openwebui_account_summaries.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/automations/providers/automation_providers.dart';
import 'package:conduit_core/features/calendar/providers/calendar_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/integrations/providers/personal_connections_providers.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/providers/openwebui_accounts_controller.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _alex = User(
  id: 'user-a',
  username: 'alex',
  email: 'alex@home.example',
  name: 'Alex',
  role: 'user',
);

final _home = OpenWebUiServer(
  id: 'home',
  name: 'Home',
  endpoints: [OpenWebUiEndpoint(id: 'home-lan', url: 'http://10.0.0.2:3000')],
);

final _work = OpenWebUiServer(
  id: 'work',
  name: 'Work',
  endpoints: [OpenWebUiEndpoint(id: 'work-proxy', url: 'https://chat.work')],
);

OpenWebUiAccountEntry _entry(
  String id,
  OpenWebUiServer server, {
  required String name,
  String? email,
  bool isActive = false,
  bool hasSession = true,
}) => OpenWebUiAccountEntry(
  account: OpenWebUiAccount(id: id, serverId: server.id, userId: 'u-$id'),
  server: server,
  summary: OpenWebUiAccountSummary(name: name, email: email),
  isActive: isActive,
  hasSession: hasSession,
);

final class _RecordingController implements OpenWebUiAccountsController {
  final switched = <String>[];

  @override
  Future<OpenWebUiAccountChangeResult> switchTo(
    String accountId, {
    bool force = false,
  }) async {
    switched.add(accountId);
    return OpenWebUiAccountChangeResult.done;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _DirectPrimary extends PreferredBackendController {
  @override
  PreferredBackend build() => PreferredBackend.direct;
}

void main() {
  Future<_RecordingController> pumpProfile(
    WidgetTester tester,
    List<OpenWebUiAccountEntry> accounts, {
    Object? accountsError,
    User? user = _alex,
    bool directPrimary = false,
  }) async {
    final controller = _RecordingController();
    final workerManager = WorkerManager();
    addTearDown(workerManager.dispose);
    // Account actions navigate through the app's router.
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const ProfilePage()),
        GoRoute(
          path: Routes.accounts,
          name: RouteNames.accounts,
          builder: (_, _) => const Text('accounts page'),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        retry: (_, _) => null,
        overrides: [
          currentUserProvider2.overrideWithValue(user),
          currentUserProvider.overrideWith((ref) async => user),
          if (directPrimary)
            preferredBackendProvider.overrideWith(_DirectPrimary.new),
          isAuthLoadingProvider2.overrideWithValue(false),
          apiServiceProvider.overrideWithValue(
            ApiService(
              serverConfig: const ServerConfig(
                id: 'alex-home',
                name: 'Home',
                url: 'http://10.0.0.2:3000',
              ),
              workerManager: workerManager,
            ),
          ),
          appSettingsProvider.overrideWithValue(const AppSettings()),
          calendarAvailableProvider.overrideWithValue(false),
          personalConnectionsEntryVisibleProvider.overrideWithValue(false),
          scheduledTasksEntryVisibleProvider.overrideWithValue(false),
          chatDataControlsEntryVisibleProvider.overrideWithValue(false),
          openWebUiAccountsProvider.overrideWith((ref) async {
            if (accountsError != null) throw accountsError;
            return accounts;
          }),
          openWebUiAccountsControllerProvider.overrideWithValue(controller),
          // No Hermes connections, whatever another test left saved: the
          // card counts them.
          hermesConnectionsProvider.overrideWithValue(const []),
          hermesEnabledProvider.overrideWithValue(false),
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

  Finder inCard(Finder finder) => find.descendant(
    of: find.byKey(const Key('settings-account-card')),
    matching: finder,
  );

  testWidgets('the card says who is signed in, where, and how many others, '
      'and leads to them all', (tester) async {
    await pumpProfile(tester, [
      _entry(
        'alex-home',
        _home,
        name: 'Alex',
        email: 'alex@home.example',
        isActive: true,
      ),
      _entry('alex-work', _work, name: 'Alex (work)', email: 'alex@work'),
      _entry('sam-home', _home, name: 'Sam', hasSession: false),
    ]);

    check(inCard(find.text('Alex')).evaluate()).isNotEmpty();
    check(inCard(find.text('Home +2')).evaluate()).isNotEmpty();
    check(inCard(find.text('Add account')).evaluate()).isNotEmpty();
    // The other accounts are on the Accounts page, not listed here.
    check(find.text('Alex (work)').evaluate()).isEmpty();
    check(find.text('Manage accounts').evaluate()).isEmpty();

    await tester.tap(find.byKey(const Key('settings-accounts')));
    await tester.pumpAndSettle();
    check(find.text('accounts page').evaluate()).isNotEmpty();
  });

  testWidgets('the account signed in has its own group, and connections are '
      'left to Accounts', (tester) async {
    await pumpProfile(tester, [
      _entry('alex-home', _home, name: 'Alex', isActive: true),
    ]);

    final group = find.byKey(const Key('settings-account-group'));
    check(find.descendant(of: group, matching: find.text('Account')).evaluate())
        .isNotEmpty();
    check(
      find.descendant(of: group, matching: find.text('Profile')).evaluate(),
    ).isNotEmpty();
    await tester.fling(find.byType(ListView), const Offset(0, -2000), 3000);
    await tester.pumpAndSettle();
    check(find.text('Direct Connections').evaluate()).isEmpty();
    check(find.text('Hermes Agent').evaluate()).isEmpty();
  });

  testWidgets('with several accounts, Sign out leaves only the active one', (
    tester,
  ) async {
    await pumpProfile(tester, [
      _entry('alex-home', _home, name: 'Alex', isActive: true),
      _entry('alex-work', _work, name: 'Alex (work)'),
    ]);

    await tester.fling(find.byType(ListView), const Offset(0, -2000), 3000);
    await tester.pumpAndSettle();
    final signOut = find.byKey(const Key('settings-sign-out-account'));
    check(signOut.evaluate()).isNotEmpty();
    check(
      find.descendant(of: signOut, matching: find.text('Sign out')).evaluate(),
    ).isNotEmpty();
    check(find.text('Sign out of all accounts').evaluate()).isEmpty();
  });

  testWidgets('with one account, sign out is unchanged', (tester) async {
    await pumpProfile(tester, [
      _entry('alex-home', _home, name: 'Alex', isActive: true),
    ]);

    check(inCard(find.text('Home')).evaluate()).isNotEmpty();
    await tester.fling(find.byType(ListView), const Offset(0, -2000), 3000);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-sign-out')), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
    expect(find.byKey(const Key('settings-sign-out-account')), findsNothing);
  });

  // Signing out signs out of every saved account. With the list unread, the
  // row said "Sign out" as though there were only this one.
  testWidgets('with the saved accounts unreadable, sign out says it signs '
      'out of all of them', (tester) async {
    await pumpProfile(tester, const [], accountsError: StateError('locked'));

    check(inCard(find.text('Alex')).evaluate()).isNotEmpty();
    await tester.fling(find.byType(ListView), const Offset(0, -2000), 3000);
    await tester.pumpAndSettle();
    check(find.text('Sign out of all accounts').evaluate()).isNotEmpty();
    check(find.text('Sign out').evaluate()).isEmpty();
    check(
      find.byKey(const Key('settings-sign-out-account')).evaluate(),
    ).isEmpty();
  });

  // An expired session clears the current user. Next to a usable Direct or
  // Hermes backend this page stays open, and the other accounts went with
  // the profile header.
  testWidgets('with the active account signed out, the other accounts are '
      'still a tap away', (tester) async {
    await pumpProfile(
      tester,
      [
        _entry(
          'alex-home',
          _home,
          name: 'Alex',
          isActive: true,
          hasSession: false,
        ),
        _entry('alex-work', _work, name: 'Alex (work)', email: 'alex@work'),
      ],
      user: null,
      directPrimary: true,
    );

    // Direct is what is in use; both accounts are elsewhere.
    check(inCard(find.text('Direct Connections')).evaluate()).isNotEmpty();
    check(inCard(find.text('+2')).evaluate()).isNotEmpty();
    await tester.tap(find.byKey(const Key('settings-accounts')));
    await tester.pumpAndSettle();
    check(find.text('accounts page').evaluate()).isNotEmpty();
  });
}
