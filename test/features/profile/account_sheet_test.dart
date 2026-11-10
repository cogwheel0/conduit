import 'dart:async';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/features/auth/views/server_connection_page.dart';
import 'package:conduit/features/auth/widgets/auth_grouped_form.dart';
import 'package:conduit/features/profile/widgets/account_sheet.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/connection_components.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/auth/openwebui_account_summaries.dart';
import 'package:conduit_core/conduit_core.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_contract.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_profile.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_connection_service.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/providers/openwebui_accounts_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../direct_connections/direct_connections_ui_test_support.dart';

const _home = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _work = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

final _homeServer = OpenWebUiServer(
  id: 'home',
  name: 'Home Lab',
  endpoints: [OpenWebUiEndpoint(id: 'home-lan', url: 'http://10.0.0.2:3000')],
);

/// An HTTP client whose requests never connect: a load through it stays in
/// flight.
final class _SilentHttpClient implements HttpClient {
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      Completer<HttpClientRequest>().future;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

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
          plainHttpConsentOrigin: config.plainHttpConsentOrigin,
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

/// Hermes that cannot be turned on: its secure storage is locked, say.
final class _EnableFails extends HermesConfigController {
  @override
  Future<void> setEnabled(bool enabled) async =>
      throw StateError('secure storage unavailable');
}

final class _OpenWebUiPrimary extends PreferredBackendController {
  @override
  PreferredBackend build() => PreferredBackend.owui;
}

final class _SettledOnAlex extends SettledActiveAccountId {
  @override
  String? build() => 'alex-home';
}

void main() {
  late GoRouter router;

  setUp(() {
    // Other tests share this isolate when CI runs them in shards.
    addTearDown(PreferencesStore.debugReset);
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
    TargetPlatform? platform,
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
          builder: (_, state) => Text(
            'add on ${(state.extra! as ServerConnectionHandoff).serverId}',
          ),
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
          reviewerModeProvider.overrideWithValue(false),
          ...overrides,
        ],
        child: MaterialApp.router(
          theme: platform == null ? null : ThemeData(platform: platform),
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
    expect(find.text('Add Account'), findsOne);
    for (final label in ['Open WebUI', 'Hermes', 'Direct']) {
      expect(
        find.descendant(
          of: find.byKey(const Key('account-sheet-kind')),
          matching: find.text(label),
        ),
        findsOne,
      );
    }
    expect(find.byKey(const Key('account-sheet-openwebui')), findsOne);
  });

  testWidgets('LibreChat has no tab while it is off', (
    tester,
  ) async {
    await pumpSheet(
      tester,
      const AddAccountRequest(),
      overrides: [libreChatBackendEnabledProvider.overrideWithValue(false)],
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('account-sheet-kind')),
        matching: find.text('LibreChat'),
      ),
      findsNothing,
    );
  });

  testWidgets('the LibreChat tab adds a LibreChat account', (tester) async {
    await pumpSheet(
      tester,
      const AddAccountRequest(),
      overrides: [libreChatBackendEnabledProvider.overrideWithValue(true)],
    );
    await chooseKind(tester, 'LibreChat');
    expect(find.byKey(const Key('account-sheet-librechat')), findsOne);
    expect(find.byKey(const Key('librechat-server-field')), findsOne);
    // Choosing it leaves the other tabs where they were.
    await chooseKind(tester, 'Direct');
    expect(find.byKey(const Key('account-sheet-direct')), findsOne);
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

  // HTTP fails in tests: the check reaches no server.
  testWidgets('a new server is checked in the sheet, which says there when '
      'it does not answer', (tester) async {
    await pumpSheet(tester, const AddAccountRequest());
    expect(find.byKey(const Key('account-sheet-openwebui')), findsOne);

    await tester.enterText(
      find.byKey(const ValueKey<String>('server-url-field')),
      'https://unreachable.example',
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('server-connection-continue')),
    );
    await tester.pump();
    expect(find.text('Connecting...'), findsWidgets);
    // The check's requests run on the real clock, its waits on the test's.
    for (var i = 0; i < 60; i++) {
      if (find.text('Connecting...').evaluate().isEmpty) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(seconds: 1));
    }

    expect(find.byType(AccountSheet), findsOne);
    expect(find.text('Connecting...'), findsNothing);
    expect(find.byType(ConnectionAttemptBanner), findsOne);
  });

  group('on iOS', () {
    setUp(() {
      // The Flutter fallbacks of the native iOS 26 controls render in tests.
      PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
      PlatformUiCapabilities.debugIOSMajorVersionOverride = 18;
    });
    tearDown(PlatformUiCapabilities.resetDebugOverrides);

    final homeAccount = OpenWebUiAccountEntry(
      account: OpenWebUiAccount(id: 'alex-home', serverId: 'home'),
      server: _homeServer,
      summary: const OpenWebUiAccountSummary(name: 'Alex'),
      isActive: true,
      hasSession: true,
    );

    Finder urlField() => find.byKey(const ValueKey<String>('server-url-field'));

    testWidgets('Open WebUI is the first-run form: saved servers as rows, '
        'then the new server grouped with Advanced Settings', (tester) async {
      await pumpSheet(
        tester,
        const AddAccountRequest(),
        accounts: [homeAccount],
        platform: TargetPlatform.iOS,
      );

      // No web-form label, asterisk or banner of the old embedded form.
      expect(find.text('Server Address'), findsNothing);
      expect(find.text('*'), findsNothing);
      expect(find.byType(AccessibleFormField), findsNothing);
      expect(find.text('or'), findsNothing);

      // A saved server is a row with its mark, name and address, and a
      // chevron to its sign-in.
      final saved = tester.widget<AuthGroupedSection>(
        find.byKey(const Key('account-sheet-saved-servers')),
      );
      check(saved.header).equals('Saved Servers');
      final row = tester.widget<AuthGroupedRow>(
        find.byKey(const Key('account-sheet-server-home')),
      );
      check(row.title).equals('Home Lab');
      check(row.subtitle).equals('10.0.0.2:3000');
      check(row.showChevron).isTrue();
      check(row.leading).isA<AuthIconTile>();

      // The new server: the address named by its leading label, Advanced
      // Settings in the same group, and the footer under both.
      final address = tester.widget<AuthGroupedSection>(
        find.byKey(const ValueKey<String>('server-address-section')),
      );
      check(address.header).equals('New Server');
      check(address.footer)
          .equals('Use the address you open in a web browser.');
      final card = find.descendant(
        of: find.byKey(const ValueKey<String>('server-address-section')),
        matching: find.byType(AuthGroupedCard),
      );
      expect(
        find.descendant(
          of: card,
          matching: find.byKey(
            const ValueKey<String>('advanced-settings-toggle'),
          ),
        ),
        findsOne,
      );
      expect(find.descendant(of: card, matching: urlField()), findsOne);
      final url = tester.widget<AuthGroupedTextField>(urlField());
      check(url.label).equals('Server');
      // The keyboard stays down until a field is chosen: it would cover the
      // saved servers.
      check(url.autofocus).isFalse();

      final connect = tester.widget<AuthPrimaryButton>(
        find.byKey(const ValueKey<String>('server-connection-continue')),
      );
      check(connect.label).equals('Connect');
      check(connect.onPressed).isNull();
      await tester.enterText(
        find.descendant(of: urlField(), matching: find.byType(EditableText)),
        'chat.example.com',
      );
      await tester.pump();
      check(
        tester
            .widget<AuthPrimaryButton>(
              find.byKey(const ValueKey<String>('server-connection-continue')),
            )
            .onPressed,
      ).isNotNull();
    });

    testWidgets('a saved server row adds an account to it', (tester) async {
      final container = await pumpSheet(
        tester,
        const AddAccountRequest(),
        accounts: [homeAccount],
        platform: TargetPlatform.iOS,
      );

      await tester.tap(find.byKey(const Key('account-sheet-server-home')));
      await tester.pumpAndSettle();

      expect(find.byType(AccountSheet), findsNothing);
      expect(find.text('add on home'), findsOne);
      check(container.read(accountAdditionOriginProvider)).equals('alex-home');
    });

    testWidgets('a server known only by its address shows it once', (
      tester,
    ) async {
      await pumpSheet(
        tester,
        const AddAccountRequest(),
        accounts: [
          OpenWebUiAccountEntry(
            account: OpenWebUiAccount(id: 'alex-lab', serverId: 'lab'),
            server: OpenWebUiServer(
              id: 'lab',
              name: '10.0.0.9',
              endpoints: [
                OpenWebUiEndpoint(id: 'lab-lan', url: 'http://10.0.0.9:8080'),
              ],
            ),
            summary: const OpenWebUiAccountSummary(name: 'Alex'),
            isActive: true,
            hasSession: true,
          ),
        ],
        platform: TargetPlatform.iOS,
      );

      final row = tester.widget<AuthGroupedRow>(
        find.byKey(const Key('account-sheet-server-lab')),
      );
      check(row.title).equals('10.0.0.9:8080');
      check(row.subtitle).equals('Open WebUI');
    });

    testWidgets('with no saved server the form has no headers', (tester) async {
      await pumpSheet(
        tester,
        const AddAccountRequest(),
        platform: TargetPlatform.iOS,
      );

      expect(
        find.byKey(const Key('account-sheet-saved-servers')),
        findsNothing,
      );
      check(
        tester
            .widget<AuthGroupedSection>(
              find.byKey(const ValueKey<String>('server-address-section')),
            )
            .header,
      ).isNull();
    });

    // HTTP fails in tests: the check reaches no server.
    testWidgets('a server that does not answer says so in the group\'s '
        'footer, and the sheet stays', (tester) async {
      await pumpSheet(
        tester,
        const AddAccountRequest(),
        platform: TargetPlatform.iOS,
      );
      await tester.enterText(
        find.descendant(of: urlField(), matching: find.byType(EditableText)),
        'https://unreachable.example',
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey<String>('server-connection-continue')),
      );
      await tester.pump();
      bool busy() => tester
          .widget<AuthPrimaryButton>(
            find.byKey(const ValueKey<String>('server-connection-continue')),
          )
          .busy;
      check(busy()).isTrue();
      // The check's requests run on the real clock, its waits on the test's.
      for (var i = 0; i < 60 && busy(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(seconds: 1));
      }

      check(busy()).isFalse();
      expect(find.byType(AccountSheet), findsOne);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('server-address-section')),
          matching: find.byKey(const ValueKey('auth-footer-error')),
        ),
        findsOne,
      );
      expect(find.byType(ConnectionAttemptBanner), findsNothing);
    });
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

  // Hermes-only mode hid a provider added next to Hermes alone (#862).
  testWidgets('Direct added where Hermes-only mode would hide it becomes the '
      'primary backend', (tester) async {
    final profiles = DirectTestOnboardingDirectProfiles(
      const DirectConnectionProbe(reachable: true),
    );
    final container = await pumpSheet(
      tester,
      const AddAccountRequest(AccountKind.direct),
      overrides: [
        directConnectionProfilesProvider.overrideWith(() => profiles),
        hermesOnlyModeProvider.overrideWithValue(true),
      ],
    );

    await directTestSubmitOnboarding(tester);

    check(profiles.upsertCalls).equals(1);
    check(
      container.read(preferredBackendProvider),
    ).equals(PreferredBackend.direct);
  });

  testWidgets('Direct added next to Open WebUI leaves it primary', (
    tester,
  ) async {
    final profiles = DirectTestOnboardingDirectProfiles(
      const DirectConnectionProbe(reachable: true),
    );
    final container = await pumpSheet(
      tester,
      const AddAccountRequest(AccountKind.direct),
      overrides: [
        directConnectionProfilesProvider.overrideWith(() => profiles),
        hermesOnlyModeProvider.overrideWithValue(false),
        preferredBackendProvider.overrideWith(_OpenWebUiPrimary.new),
      ],
    );

    await directTestSubmitOnboarding(tester);

    check(profiles.upsertCalls).equals(1);
    check(
      container.read(preferredBackendProvider),
    ).equals(PreferredBackend.owui);
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

  // Plain HTTP to another machine carries the key unencrypted: Connect
  // asks first, and nothing is sent or saved until the user agrees.
  testWidgets('Hermes asks before sending credentials over plain HTTP', (
    tester,
  ) async {
    final gateway = _ReachableGateway();
    final container = await pumpSheet(
      tester,
      const AddAccountRequest(AccountKind.hermes),
      overrides: [hermesConnectionGatewayProvider.overrideWithValue(gateway)],
    );
    gateway.container = container;
    await tester.enterText(
      find.byKey(const ValueKey<String>('hermes-server-url-field')),
      'http://192.0.2.10:8642/v1',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('hermes-api-key-field')),
      'lab-key',
    );
    await tester.pump();
    final submit = find.byKey(const ValueKey<String>('hermes-sheet-submit'));

    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(find.text('Send credentials without encryption?'), findsOne);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    check(gateway.probes).equals(0);
    check(container.read(hermesConnectionsProvider)).length.equals(1);

    await tester.tap(submit);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send Without Encryption'));
    await tester.pumpAndSettle();

    check(gateway.probes).equals(1);
    final added = container
        .read(hermesConnectionsProvider)
        .singleWhere((connection) => connection.id != _home);
    check(added.plainHttpConsentOrigin).equals('http://192.0.2.10:8642');
    expect(find.byType(AccountSheet), findsNothing);
  });

  // The Desktop Gateway section lists the server's profiles as a URL is
  // typed, sending the draft's token and access headers: over plain HTTP
  // it waits until Test, Save or sign-in has asked.
  testWidgets('Desktop Gateway lists no profiles over plain HTTP unasked', (
    tester,
  ) async {
    await pumpSheet(tester, const AddAccountRequest(AccountKind.hermes));
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('hermes-backend-mode-selector')),
        matching: find.text('Desktop Gateway'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('hermes-server-url-field')),
      'http://192.0.2.10:8642',
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Test the connection, then refresh the profile list.'),
      findsOne,
    );
  });

  // A load still in flight when the URL turned plain HTTP never reset its
  // spinner, and the refresh the note asks for stayed disabled.
  testWidgets('Desktop Gateway can refresh after a load the URL cut short', (
    tester,
  ) async {
    await pumpSheet(tester, const AddAccountRequest(AccountKind.hermes));
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('hermes-backend-mode-selector')),
        matching: find.text('Desktop Gateway'),
      ),
    );
    await tester.pumpAndSettle();
    final url = find.byKey(const ValueKey<String>('hermes-server-url-field'));
    // Found by its label, which a loading button does not show.
    ConduitButton refresh() => tester.widget<ConduitButton>(
      find.byWidgetPredicate(
        (widget) => widget is ConduitButton && widget.text == 'Refresh Profiles',
      ),
    );

    // A load starts for this device's address, its server never answering,
    // and a plain HTTP address elsewhere cuts it short.
    await HttpOverrides.runZoned(() async {
      await tester.enterText(url, 'http://127.0.0.1:9');
      await tester.pump();
      expect(refresh().isLoading, isTrue);
      await tester.enterText(url, 'http://192.0.2.10:8642');
      await tester.pump();
    }, createHttpClient: (_) => _SilentHttpClient());

    expect(refresh().isLoading, isFalse);
    expect(refresh().onPressed, isNotNull);
    // The unanswered load's own timeout ends it.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  });

  // Connect saved the connection and then failed to turn Hermes on; the
  // button became Save, which only saved again and never turned it on.
  testWidgets('Connect stays Connect after it saved but could not finish', (
    tester,
  ) async {
    final gateway = _ReachableGateway();
    final container = await pumpSheet(
      tester,
      const AddAccountRequest(AccountKind.hermes),
      overrides: [
        hermesConnectionGatewayProvider.overrideWithValue(gateway),
        hermesConfigProvider.overrideWith(_EnableFails.new),
      ],
    );
    gateway.container = container;
    await tester.enterText(
      find.byKey(const ValueKey<String>('hermes-server-url-field')),
      'https://lab.example',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('hermes-api-key-field')),
      'lab-key',
    );
    await tester.pump();
    final submit = find.byKey(const ValueKey<String>('hermes-sheet-submit'));

    await tester.tap(submit);
    await tester.pumpAndSettle();

    expect(find.byType(AccountSheet), findsOne);
    expect(
      find.descendant(of: submit, matching: find.text('Connect Hermes')),
      findsOne,
    );
    await tester.tap(submit);
    await tester.pumpAndSettle();
    // Connect again, from its test, not a bare save.
    check(gateway.probes).equals(2);
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

  group('dragging the form', () {
    double sheetHeight(WidgetTester tester) => tester
        .getSize(
          find
              .descendant(
                of: find.byType(DraggableScrollableSheet),
                matching: find.byType(ClipRRect),
              )
              .first,
        )
        .height;

    Future<void> slowDrag(WidgetTester tester, double dy) async {
      final form = find
          .descendant(
            of: find.byType(DraggableScrollableSheet),
            matching: find.byType(Scrollable),
          )
          .first;
      final gesture = await tester.startGesture(tester.getCenter(form));
      for (var moved = 0.0; moved.abs() < dy.abs(); moved += dy.sign * 10) {
        await gesture.moveBy(Offset(0, dy.sign * 10));
        await tester.pump(const Duration(milliseconds: 16));
      }
      // Held still before letting go: no fling to carry it.
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.up();
      await tester.pumpAndSettle();
    }

    // Let go short of the top, the sheet settled back where it opened and
    // the form had not moved: a short scroll did nothing.
    testWidgets('a short upward drag opens the sheet the rest of the way', (
      tester,
    ) async {
      await pumpSheet(tester, const AddAccountRequest(AccountKind.hermes));
      final opened = sheetHeight(tester);

      await slowDrag(tester, -100);

      check(sheetHeight(tester)).isGreaterThan(opened);
      // 95% of the 2400-pixel-high test screen.
      check(sheetHeight(tester)).equals(2280);
    });

    testWidgets('a downward drag does not open it', (tester) async {
      await pumpSheet(tester, const AddAccountRequest(AccountKind.hermes));
      final opened = sheetHeight(tester);

      await slowDrag(tester, 40);

      check(sheetHeight(tester)).isLessOrEqual(opened);
    });

    testWidgets('the keyboard coming up opens the sheet the rest of the way, '
        'as a UIKit sheet goes to its large detent', (tester) async {
      await pumpSheet(tester, const AddAccountRequest(AccountKind.hermes));
      final opened = sheetHeight(tester);

      tester.view.viewInsets = const FakeViewPadding(bottom: 600);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();

      // The full share of what the keyboard leaves of the 2400 high view.
      check(sheetHeight(tester)).isGreaterThan(opened * (1800 / 2400));
      check(sheetHeight(tester)).equals(1800 * 0.95);
    });

    testWidgets('opened all the way, the sheet stops under the status bar', (
      tester,
    ) async {
      tester.view.padding = const FakeViewPadding(top: 300);
      addTearDown(tester.view.resetPadding);
      await pumpSheet(tester, const AddAccountRequest(AccountKind.hermes));

      tester.view.viewInsets = const FakeViewPadding(bottom: 600);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();

      // 1800 points above the keyboard, less the 300 point status bar and
      // the sheet's gap under it.
      check(sheetHeight(tester)).equals(1800 - 300 - 8);
    });
  });

  // The sheet lifts itself above the keyboard, and a page opened inside it
  // took the keyboard's height off a second time: a web sign-in page there
  // had no room left and showed nothing while the keyboard was up.
  testWidgets('a page opened in the sheet keeps its room over the keyboard', (
    tester,
  ) async {
    await pumpSheet(tester, const AddAccountRequest(AccountKind.hermes));
    var body = 0.0;
    unawaited(
      Navigator.of(
        tester.element(find.byKey(const Key('account-sheet-hermes'))),
      ).push(
        PageRouteBuilder<void>(
          pageBuilder: (_, _, _) => ConnectionWebAuthScaffold(
            title: 'Sign in',
            body: LayoutBuilder(
              builder: (_, constraints) {
                body = constraints.maxHeight;
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    double sheet() => tester
        .getSize(
          find
              .descendant(
                of: find.byType(DraggableScrollableSheet),
                matching: find.byType(ClipRRect),
              )
              .first,
        )
        .height;
    // The page's bar and edges.
    final chrome = sheet() - body;

    tester.view.viewInsets = const FakeViewPadding(bottom: 1000);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();

    // The sheet stands on the keyboard: 95% of the 1,400 pixels above it.
    check(sheet()).equals(1330);
    check(body).equals(sheet() - chrome);
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
    expect(find.text('Edit Connection'), findsOne);
    expect(find.byKey(const Key('account-sheet-direct')), findsOne);
    // The form's own Save; the sheet adds one only for iOS's toolbar Save.
    expect(
      find.descendant(
        of: find.byType(AccountSheet),
        matching: find.text('Save'),
      ),
      findsOne,
    );
  });

  // An inactive connection loads before its form shows, and that wait was
  // a page of its own, which the sheet's list could not lay out.
  testWidgets('an inactive Hermes connection is edited in the sheet', (
    tester,
  ) async {
    PreferencesStore.debugOverride(
      InMemoryKeyValueStore(<String, Object?>{
        PreferenceKeys.hermesEnabled: true,
        PreferenceKeys.hermesConnections: HermesConnectionsDocument(
          connections: const [
            HermesConnectionProfile(
              id: _home,
              name: 'Home agent',
              baseUrl: 'https://home.example',
              documentTrustPrincipalId: 'aaaaaaaa-0000-4000-8000-000000000000',
            ),
            HermesConnectionProfile(
              id: _work,
              name: 'Work agent',
              baseUrl: 'https://work.example',
              documentTrustPrincipalId: 'bbbbbbbb-0000-4000-8000-000000000000',
            ),
          ],
        ).encode(),
        PreferenceKeys.hermesActiveConnectionId: _home,
      }),
    );

    await pumpSheet(tester, const EditHermesConnectionRequest(_work));

    expect(tester.takeException(), isNull);
    expect(find.text('Work agent'), findsWidgets);
    expect(
      find.byKey(const ValueKey<String>('hermes-server-url-field')),
      findsOne,
    );
  });
}
