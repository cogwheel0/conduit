import 'package:checks/checks.dart';
import 'package:conduit/features/profile/widgets/account_sheet.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/auth/openwebui_account_summaries.dart';
import 'package:conduit_core/conduit_core.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_contract.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_profile.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_connection_service.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/openwebui_accounts_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../direct_connections/direct_connections_ui_test_support.dart';

const _home = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

final _homeServer = OpenWebUiServer(
  id: 'home',
  name: 'Home Lab',
  endpoints: [OpenWebUiEndpoint(id: 'home-lan', url: 'http://10.0.0.2:3000')],
);

/// Tests every draft as reachable, and saves through the real connections,
/// as the app's gateway does.
final class _ReachableGateway implements HermesConnectionGateway {
  late ProviderContainer container;
  int probes = 0;

  @override
  Future<bool> probe(HermesConfig draft) async {
    probes++;
    return true;
  }

  @override
  Future<String?> persist(HermesConnectionDraft draft) async {
    final config = draft.config;
    return container
        .read(hermesConfigProvider.notifier)
        .createConnection(
          baseUrl: config.baseUrl,
          name: config.name,
          nameSource: draft.nameSource,
          mode: config.mode,
          apiKey: config.apiKey,
        );
  }

  @override
  Future<void> commitOnboarding(
    HermesConnectionDraft draft, {
    required bool Function() isCurrent,
  }) async {}

  @override
  Future<String?> suggestDisplayName(HermesConfig draft) async => null;
}

final class _SettledOnAlex extends SettledActiveAccountId {
  @override
  String? build() => 'alex-home';
}

void main() {
  late GoRouter router;

  setUp(() {
    // One saved Hermes connection, with Hermes off.
    PreferencesStore.debugOverride(
      InMemoryKeyValueStore(<String, Object?>{
        PreferenceKeys.hermesEnabled: false,
        PreferenceKeys.hermesConnections: HermesConnectionsDocument(
          connections: const [
            HermesConnectionProfile(
              id: _home,
              name: 'Home agent',
              baseUrl: 'https://home.example',
              documentTrustPrincipalId: 'aaaaaaaa-0000-4000-8000-000000000000',
            ),
          ],
        ).encode(),
        PreferenceKeys.hermesActiveConnectionId: _home,
      }),
    );
  });

  Future<ProviderContainer> pumpSheet(
    WidgetTester tester,
    AccountSheetRequest request, {
    List<Override> overrides = const [],
    List<OpenWebUiAccountEntry> accounts = const [],
  }) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, _) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showAccountSheet(context, request),
                child: const Text('open'),
              ),
            ),
          ),
        ),
        GoRoute(
          path: Routes.addServer,
          name: RouteNames.addServer,
          builder: (_, state) => Text('add on ${state.extra}'),
        ),
        GoRoute(
          path: Routes.serverConnection,
          name: RouteNames.serverConnection,
          builder: (_, _) => const Text('connect'),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          secureStorageProvider.overrideWithValue(
            InMemorySecureKeyValueStore({'hermes_api_key_v1:$_home': 'key'}),
          ),
          openWebUiAccountsProvider.overrideWith((ref) async => accounts),
          settledActiveAccountIdProvider.overrideWith(_SettledOnAlex.new),
          ...overrides,
        ],
        child: MaterialApp.router(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(tester.element(find.text('open')));
  }

  Future<void> chooseKind(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('account-sheet-kind')),
        matching: find.text(label),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('an addition has a tab for each kind, Open WebUI first', (
    tester,
  ) async {
    await pumpSheet(tester, const AddAccountRequest());

    expect(find.byType(AccountSheet), findsOne);
    expect(find.text('Add account'), findsOne);
    for (final label in ['Open WebUI', 'Hermes', 'Direct']) {
      expect(
        find.descendant(
          of: find.byKey(const Key('account-sheet-kind')),
          matching: find.text(label),
        ),
        findsOne,
      );
    }
    expect(find.byKey(const Key('account-sheet-new-server')), findsOne);
  });

  testWidgets('continuing on a saved server adds an account to it', (
    tester,
  ) async {
    final container = await pumpSheet(
      tester,
      const AddAccountRequest(),
      accounts: [
        OpenWebUiAccountEntry(
          account: OpenWebUiAccount(id: 'alex-home', serverId: 'home'),
          server: _homeServer,
          summary: const OpenWebUiAccountSummary(name: 'Alex'),
          isActive: true,
          hasSession: true,
        ),
      ],
    );
    expect(find.text('Continue with Home Lab'), findsOne);

    await tester.tap(find.byKey(const Key('account-sheet-server-home')));
    await tester.pumpAndSettle();

    expect(find.byType(AccountSheet), findsNothing);
    expect(find.text('add on home'), findsOne);
    // The addition began from the account in use, for the router to leave
    // its sign-in alone.
    check(container.read(accountAdditionOriginProvider)).equals('alex-home');
  });

  testWidgets('with no Open WebUI account, a new server is a first one', (
    tester,
  ) async {
    await pumpSheet(tester, const AddAccountRequest());

    await tester.tap(find.byKey(const Key('account-sheet-new-server')));
    await tester.pumpAndSettle();

    expect(find.text('connect'), findsOne);
  });

  testWidgets('Direct tests a provider, saves it, and closes', (tester) async {
    final profiles = DirectTestOnboardingDirectProfiles(
      const DirectConnectionProbe(reachable: true),
    );
    await pumpSheet(
      tester,
      const AddAccountRequest(AccountKind.direct),
      overrides: [
        directConnectionProfilesProvider.overrideWith(() => profiles),
      ],
    );
    expect(find.byKey(const Key('account-sheet-direct')), findsOne);

    await directTestSubmitOnboarding(tester);

    check(profiles.probeCalls).equals(1);
    check(profiles.upsertCalls).equals(1);
    check(profiles.lastUpsert?.apiKey).equals('test-secret');
    expect(find.byType(AccountSheet), findsNothing);
  });

  testWidgets('Hermes tests a connection, saves it, and puts it in use, '
      'turning Hermes on', (tester) async {
    final gateway = _ReachableGateway();
    final container = await pumpSheet(
      tester,
      const AddAccountRequest(AccountKind.hermes),
      overrides: [hermesConnectionGatewayProvider.overrideWithValue(gateway)],
    );
    gateway.container = container;
    expect(find.byKey(const Key('account-sheet-hermes')), findsOne);

    await tester.enterText(
      find.byKey(const ValueKey<String>('hermes-server-url-field')),
      'https://lab.example',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('hermes-api-key-field')),
      'lab-key',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('hermes-sheet-submit')));
    await tester.pumpAndSettle();

    check(gateway.probes).equals(1);
    final connections = container.read(hermesConnectionsProvider);
    check(connections).length.equals(2);
    final added = connections.singleWhere((c) => c.id != _home);
    check(container.read(hermesActiveConnectionIdProvider)).equals(added.id);
    check(container.read(hermesEnabledProvider)).isTrue();
    expect(find.byType(AccountSheet), findsNothing);
  });

  testWidgets('switching tabs keeps what was typed in each', (tester) async {
    await pumpSheet(tester, const AddAccountRequest(AccountKind.hermes));
    await tester.enterText(
      find.byKey(const ValueKey<String>('hermes-server-url-field')),
      'https://lab.example',
    );

    await chooseKind(tester, 'Direct');
    expect(find.byKey(const Key('account-sheet-direct')), findsOne);
    expect(find.text('https://lab.example'), findsNothing);
    await chooseKind(tester, 'Hermes');

    expect(find.text('https://lab.example'), findsOne);
  });

  testWidgets('a Direct provider is edited in the sheet, without tabs', (
    tester,
  ) async {
    await pumpSheet(
      tester,
      const EditDirectConnectionRequest('desk'),
      overrides: [
        directConnectionProfilesProvider.overrideWith(
          () => DirectTestStaticDirectProfiles([
            DirectConnectionProfile(
              id: 'desk',
              name: 'Desk',
              adapterKey: kOllamaAdapterKey,
              baseUrl: 'http://10.0.0.7:11434',
            ),
          ]),
        ),
      ],
    );

    expect(find.byKey(const Key('account-sheet-kind')), findsNothing);
    expect(find.text('Edit connection'), findsOne);
    expect(find.byKey(const Key('account-sheet-direct')), findsOne);
    expect(find.byKey(const Key('direct-editor-save-button')), findsOne);
  });
}
