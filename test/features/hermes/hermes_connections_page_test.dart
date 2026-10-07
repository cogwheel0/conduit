import 'package:checks/checks.dart';
import 'package:conduit/features/hermes/views/hermes_connections_page.dart';
import 'package:conduit/features/hermes/views/hermes_settings_page.dart';
import 'package:conduit/features/hermes/widgets/hermes_connection_switcher.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/conduit_core.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_profile.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
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

  test('initials come from the first two words of a name', () {
    check(hermesConnectionInitials('Home Lab')).equals('HL');
    check(hermesConnectionInitials('research')).equals('RE');
    check(hermesConnectionInitials('hermes.example.com')).equals('HE');
    check(hermesConnectionInitials(null)).equals('HA');
    check(hermesConnectionInitials('  ')).equals('HA');
  });
}
