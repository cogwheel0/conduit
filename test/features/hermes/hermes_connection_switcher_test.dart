import 'package:checks/checks.dart';
import 'package:conduit/features/hermes/widgets/hermes_connection_switcher.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/conduit_core.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_profile.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/storage_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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

  testWidgets('header switcher names the active connection and switches', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [secureStorageProvider.overrideWithValue(secrets)],
        child: const MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: HermesConnectionHeaderSwitcher()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(HermesConnectionHeaderSwitcher)),
    );

    expect(find.text('Home agent'), findsOneWidget);

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
  });

  testWidgets('header shows no switcher with one connection saved', (
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
          ],
        ).encode(),
        PreferenceKeys.hermesActiveConnectionId: _home,
      }),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [secureStorageProvider.overrideWithValue(secrets)],
        child: const MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: HermesConnectionHeaderSwitcher()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Home agent'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('hermes-connection-switcher')),
      findsNothing,
    );
  });

  test('initials come from the first two words of a name', () {
    check(hermesConnectionInitials('Home Lab')).equals('HL');
    check(hermesConnectionInitials('research')).equals('RE');
    check(hermesConnectionInitials('hermes.example.com')).equals('HE');
    check(hermesConnectionInitials(null)).equals('HA');
    check(hermesConnectionInitials('  ')).equals('HA');
  });
}
