import 'package:checks/checks.dart';
import 'package:conduit/features/profile/views/manage_accounts_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/auth/openwebui_account_summaries.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/openwebui_accounts_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

final _home = OpenWebUiServer(
  id: 'home',
  name: 'Home',
  endpoints: [OpenWebUiEndpoint(id: 'home-lan', url: 'http://10.0.0.2:3000')],
);

OpenWebUiAccountEntry _entry(
  String id, {
  required String name,
  bool isActive = false,
  bool hasSession = true,
}) => OpenWebUiAccountEntry(
  account: OpenWebUiAccount(id: id, serverId: _home.id, userId: 'u-$id'),
  server: _home,
  summary: OpenWebUiAccountSummary(name: name),
  isActive: isActive,
  hasSession: hasSession,
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

void main() {
  late GoRouter router;

  Future<_SignInNeeded> pumpAccounts(
    WidgetTester tester,
    List<OpenWebUiAccountEntry> accounts,
  ) async {
    final controller = _SignInNeeded();
    router = GoRouter(
      initialLocation: Routes.accounts,
      routes: [
        GoRoute(
          path: Routes.accounts,
          builder: (_, _) => const ManageAccountsPage(),
        ),
        GoRoute(
          path: Routes.authentication,
          builder: (_, _) => const Text('sign in'),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
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

  String location() => router.routerDelegate.currentConfiguration.uri.path;

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
    expect(find.text('Signed out · Home'), findsOneWidget);

    await tester.tap(find.byKey(const Key('accounts-row-alex-home')));
    await tester.pumpAndSettle();

    check(controller.switched).deepEquals(['alex-home']);
    check(location()).equals(Routes.authentication);
    expect(find.text('sign in'), findsOneWidget);
  });
}
