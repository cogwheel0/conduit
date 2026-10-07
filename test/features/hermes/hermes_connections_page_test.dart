import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/features/hermes/views/hermes_connections_page.dart';
import 'package:conduit/features/hermes/views/hermes_settings_page.dart';
import 'package:conduit/features/hermes/widgets/hermes_connection_switcher.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit_core/conduit_core.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_contract.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_profile.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_connection_service.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/providers/host_ports.dart';
import 'package:conduit_core/providers/storage_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

const _home = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _work = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

void main() {
  late InMemorySecureKeyValueStore secrets;

  setUp(() {
    secrets = InMemorySecureKeyValueStore({
      'hermes_api_key_v1:$_home': 'home-key',
      'hermes_api_key_v1:$_work': 'work-key',
    });
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
  });
  tearDown(PreferencesStore.debugReset);


  testWidgets('lists connections, switches on tap, and opens the editor', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: Routes.hermesSettings,
      routes: [
        GoRoute(
          path: Routes.hermesSettings,
          name: RouteNames.hermesSettings,
          builder: (_, _) => const HermesConnectionsPage(),
        ),
        GoRoute(
          path: Routes.hermesConnectionEditor,
          name: RouteNames.hermesConnectionEditor,
          builder: (_, state) => Text('editor:${state.pathParameters['id']}'),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [secureStorageProvider.overrideWithValue(secrets)],
        child: MaterialApp.router(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(HermesConnectionsPage)),
    );

    expect(find.text('Home agent'), findsOneWidget);
    expect(find.text('Work agent'), findsOneWidget);
    expect(find.textContaining('Active ·'), findsOneWidget);

    await tester.tap(find.text('Work agent'));
    await tester.pumpAndSettle();
    check(container.read(hermesConfigProvider).connectionId).equals(_work);
    check(container.read(hermesConfigProvider).apiKey).equals('work-key');

    await tester.tap(
      find.byKey(const ValueKey<String>('hermes-edit-connection-$_home')),
    );
    await tester.pumpAndSettle();
    expect(find.text('editor:$_home'), findsOneWidget);
  });

  testWidgets('sidebar switcher names the active connection and switches', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [secureStorageProvider.overrideWithValue(secrets)],
        child: const MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: HermesConnectionSwitcherTile()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(HermesConnectionSwitcherTile)),
    );

    expect(find.text('Home agent'), findsOneWidget);
    expect(find.text('HA'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('hermes-connection-switcher')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('hermes-connection-option-$_work')),
    );
    await tester.pumpAndSettle();

    check(container.read(hermesConfigProvider).connectionId).equals(_work);
    expect(find.text('Work agent'), findsOneWidget);
    expect(find.text('WA'), findsOneWidget);
  });

  testWidgets('edits an inactive connection without switching to it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [secureStorageProvider.overrideWithValue(secrets)],
        child: const MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: HermesSettingsPage(connectionId: _work),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(HermesSettingsPage)),
    );
    final nameField = find.descendant(
      of: find.byKey(const ValueKey<String>('hermes-connection-name-field')),
      matching: find.byType(EditableText),
    );
    check(tester.widget<EditableText>(nameField).controller.text)
        .equals('Work agent');

    await tester.enterText(nameField, 'Office');
    await tester.tap(find.byKey(const ValueKey<String>('hermes-save-button')));
    await tester.pumpAndSettle();
    final saved = container
        .read(hermesConnectionsProvider)
        .singleWhere((profile) => profile.id == _work);
    check(saved.name).equals('Office');
    check(saved.nameSource).equals(HermesConnectionNameSource.user);
    // Saving another connection leaves the runtime on the active one.
    check(container.read(hermesConfigProvider).connectionId).equals(_home);
    check(
      await secrets.read(key: 'hermes_api_key_v1:$_work'),
    ).equals('work-key');

    await tester.tap(find.byKey(const ValueKey<String>('hermes-use-connection')));
    await tester.pumpAndSettle();
    check(container.read(hermesConfigProvider).connectionId).equals(_work);
    expect(
      find.byKey(const ValueKey<String>('hermes-use-connection')),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('hermes-delete-connection')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    check(
      container.read(hermesConnectionsProvider).map((profile) => profile.id),
    ).deepEquals([_home]);
    check(container.read(hermesConfigProvider).connectionId).equals(_home);
    check(await secrets.read(key: 'hermes_api_key_v1:$_work')).isNull();
  });

  testWidgets('tests an inactive connection with its rotated tokens', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
              mode: HermesBackendMode.desktopGateway,
              desktopAuthKind: HermesDesktopAuthKind.nativePkce,
              documentTrustPrincipalId: 'bbbbbbbb-0000-4000-8000-000000000000',
            ),
          ],
        ).encode(),
        PreferenceKeys.hermesActiveConnectionId: _home,
      }),
    );
    await secrets.write(
      key: 'hermes_desktop_credentials_v1:$_work',
      value: jsonEncode(_nativeCredentials('refresh-0').toJson()),
    );
    final gateway = _RecordingGateway();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          secureStorageProvider.overrideWithValue(secrets),
          hermesConnectionGatewayProvider.overrideWithValue(gateway),
        ],
        child: const MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: HermesSettingsPage(connectionId: _work),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final notifier = ProviderScope.containerOf(
      tester.element(find.byType(HermesSettingsPage)),
    ).read(hermesConfigProvider.notifier);

    // Listing profiles or probing from another client rotates the stored
    // tokens after the editor loaded them.
    final loaded = await notifier.savedConnectionConfig(_work);
    await notifier.credentialsWriterFor(loaded)(
      _nativeCredentials('refresh-1'),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Test connection'));
    await tester.pumpAndSettle();
    check(
      gateway.probed.single.desktopCredentials?.nativeTokens?.refreshToken,
    ).equals('refresh-1');
  });

  testWidgets('a save that finishes after the editor closes is harmless', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final persisted = Completer<void>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          secureStorageProvider.overrideWithValue(secrets),
          hermesConnectionGatewayProvider.overrideWithValue(
            _RecordingGateway(persistGate: persisted.future),
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: HermesSettingsPage(connectionId: _work),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('hermes-save-button')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    persisted.complete();
    await tester.pumpAndSettle();

    check(tester.takeException()).isNull();
  });

  // The inactive connection's own read failing, and the active connection's
  // failing, which blocks every read until secure storage is retried.
  for (final (failure, failingKey) in [
    ('its secrets', 'hermes_api_key_v1:$_work'),
    ('secure storage', 'hermes_api_key_v1:$_home'),
  ]) {
    testWidgets('retries an inactive connection after $failure failed', (
      tester,
    ) async {
      // Reads of Hermes secrets retry once, so two failures fail one load.
      final flaky = _FailingSecrets(
        {
          'hermes_api_key_v1:$_home': 'home-key',
          'hermes_api_key_v1:$_work': 'work-key',
        },
        failingKey: failingKey,
        failures: 2,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [secureStorageProvider.overrideWithValue(flaky)],
          child: const MaterialApp(
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: HermesSettingsPage(connectionId: _work),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final nameField = find.byKey(
        const ValueKey<String>('hermes-connection-name-field'),
      );
      final retry = find.byKey(
        const ValueKey<String>('hermes-retry-load-connection'),
      );
      expect(nameField, findsNothing);
      expect(retry, findsOneWidget);

      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(nameField, findsOneWidget);
      expect(retry, findsNothing);
    });
  }

  testWidgets('an editor whose baseline cannot be read says so and retries', (
    tester,
  ) async {
    final flaky = _FailingSecrets(
      {
        'hermes_api_key_v1:$_home': 'home-key',
        'hermes_api_key_v1:$_work': 'work-key',
      },
      failingKey: 'hermes_api_key_v1:$_home',
      failures: 0,
    );
    // Tall enough to build the whole editor, Save included.
    await tester.binding.setSurfaceSize(const Size(800, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [secureStorageProvider.overrideWithValue(flaky)],
        child: const MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: HermesSettingsPage(connectionId: _home),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(HermesSettingsPage)),
    );
    final retry = find.byKey(
      const ValueKey<String>('hermes-retry-load-connection'),
    );
    ConduitButton save() => tester.widget<ConduitButton>(
      find.byKey(const ValueKey<String>('hermes-save-button')),
    );
    check(save().onPressed).isNotNull();

    // The edited connection stops being active, and reading its stored
    // baseline fails (reads of Hermes secrets retry once).
    flaky.failures = 2;
    await container.read(hermesConfigProvider.notifier).setActiveConnection(
      _work,
    );
    await tester.pumpAndSettle();
    expect(retry, findsOneWidget);
    check(save().onPressed).isNull();

    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(retry, findsNothing);
    check(save().onPressed).isNotNull();
  });

  testWidgets('a delete that ends after its page closed still finishes', (
    tester,
  ) async {
    PreferencesStore.debugOverride(
      InMemoryKeyValueStore(<String, Object?>{
        PreferenceKeys.hermesEnabled: true,
        PreferenceKeys.preferredBackend: PreferredBackend.hermes.name,
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
    await tester.binding.setSurfaceSize(const Size(800, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final cookies = _BlockingCookieJar();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          secureStorageProvider.overrideWithValue(secrets),
          cookieJarProvider.overrideWithValue(cookies),
        ],
        child: MaterialApp(
          navigatorKey: navigator,
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const SizedBox(),
        ),
      ),
    );
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const HermesSettingsPage(connectionId: _home),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(HermesSettingsPage)),
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('hermes-delete-connection')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pump();
    // The user leaves while the deletion signs out of the dashboard.
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byType(HermesSettingsPage), findsNothing);
    cookies.release.complete(true);
    await tester.pumpAndSettle();

    check(container.read(hermesConnectionsProvider)).isEmpty();
    // With nothing left, a Hermes-only install goes back to the chooser.
    check(
      container.read(preferredBackendProvider),
    ).equals(PreferredBackend.unset);
    check(tester.takeException()).isNull();
  });

  testWidgets('the enable row announces whether Hermes is on', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [secureStorageProvider.overrideWithValue(secrets)],
        child: const MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: HermesConnectionsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getSemantics(
        find.byKey(const ValueKey<String>('hermes-enable-row')),
      ),
      isSemantics(hasToggledState: true, isToggled: true),
    );
    semantics.dispose();
  });

  test('initials come from the first two words of a name', () {
    check(hermesConnectionInitials('Home Lab')).equals('HL');
    check(hermesConnectionInitials('research')).equals('RE');
    check(hermesConnectionInitials('hermes.example.com')).equals('HE');
    check(hermesConnectionInitials(null)).equals('HA');
    check(hermesConnectionInitials('  ')).equals('HA');
  });
}

HermesDesktopCredentials _nativeCredentials(String refreshToken) =>
    HermesDesktopCredentials(
      nativeTokens: HermesDesktopTokenSet(
        accessToken: 'access-$refreshToken',
        refreshToken: refreshToken,
        expiresAt: DateTime.utc(2100),
      ),
    );

final class _RecordingGateway implements HermesConnectionGateway {
  _RecordingGateway({this.persistGate});

  /// When set, saves wait for it.
  final Future<void>? persistGate;
  final List<HermesConfig> probed = <HermesConfig>[];

  @override
  Future<bool> probe(HermesConfig draft) async {
    probed.add(draft);
    return false;
  }

  @override
  Future<String?> persist(HermesConnectionDraft draft) async {
    await persistGate;
    return draft.config.connectionId;
  }

  @override
  Future<void> commitOnboarding(
    HermesConnectionDraft draft, {
    required bool Function() isCurrent,
  }) async {}

  @override
  Future<String?> suggestDisplayName(HermesConfig draft) async => null;
}

/// Secure storage whose first [failures] reads of [failingKey] throw.
final class _FailingSecrets extends InMemorySecureKeyValueStore {
  _FailingSecrets(
    super.seed, {
    required this.failingKey,
    required this.failures,
  });

  final String failingKey;
  int failures;

  @override
  Future<String?> read({required String key}) {
    if (key == failingKey && failures > 0) {
      failures--;
      throw StateError('secure storage unavailable');
    }
    return super.read(key: key);
  }
}

final class _BlockingCookieJar extends NullCookieJarPort {
  final Completer<bool> release = Completer<bool>();

  @override
  Future<bool> clearForOrigin(String origin) => release.future;
}
