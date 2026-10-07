import 'package:conduit/features/profile/views/profile_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/auth/openwebui_account_summaries.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/automations/providers/automation_providers.dart';
import 'package:conduit_core/features/calendar/providers/calendar_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/integrations/providers/personal_connections_providers.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
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

void main() {
  Future<_RecordingController> pumpProfile(
    WidgetTester tester,
    List<OpenWebUiAccountEntry> accounts,
  ) async {
    final controller = _RecordingController();
    final workerManager = WorkerManager();
    addTearDown(workerManager.dispose);
    // Account actions navigate through the app's router.
    final router = GoRouter(
      routes: [GoRoute(path: '/', builder: (_, _) => const ProfilePage())],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserProvider2.overrideWithValue(_alex),
          currentUserProvider.overrideWith((ref) async => _alex),
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
          openWebUiAccountsProvider.overrideWith((ref) async => accounts),
          openWebUiAccountsControllerProvider.overrideWithValue(controller),
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

  testWidgets('lists the other saved accounts and switches on tap', (
    tester,
  ) async {
    final controller = await pumpProfile(tester, [
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

    expect(find.text('Accounts'), findsOneWidget);
    expect(find.text('Alex (work)'), findsOneWidget);
    expect(find.text('alex@work · Work'), findsOneWidget);
    expect(find.text('Sam'), findsOneWidget);
    expect(find.text('Signed out · Home'), findsOneWidget);
    expect(find.text('Add account'), findsOneWidget);
    expect(find.text('Manage accounts'), findsOneWidget);

    await tester.tap(find.text('Alex (work)'));
    await tester.pumpAndSettle();
    expect(controller.switched, ['alex-work']);
  });

  testWidgets('with several accounts, sign out of one or of all', (
    tester,
  ) async {
    await pumpProfile(tester, [
      _entry('alex-home', _home, name: 'Alex', isActive: true),
      _entry('alex-work', _work, name: 'Alex (work)'),
    ]);

    await tester.fling(find.byType(ListView), const Offset(0, -2000), 3000);
    await tester.pumpAndSettle();
    expect(find.text('Sign out of Alex'), findsOneWidget);
    expect(find.text('Sign out of all accounts'), findsOneWidget);
  });

  testWidgets('with one account, sign out is unchanged', (tester) async {
    await pumpProfile(tester, [
      _entry('alex-home', _home, name: 'Alex', isActive: true),
    ]);

    expect(find.text('Add account'), findsOneWidget);
    expect(find.text('Manage accounts'), findsNothing);
    await tester.fling(find.byType(ListView), const Offset(0, -2000), 3000);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-sign-out')), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
    expect(find.byKey(const Key('settings-sign-out-account')), findsNothing);
  });
}
