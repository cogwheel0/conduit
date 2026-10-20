import 'package:checks/checks.dart';
import 'package:conduit/features/profile/widgets/account_actions.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/conduit_core.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_profile.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _home = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _work = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

/// Secure storage that cannot read the work connection's secrets: a locked
/// Keychain item, say.
final class _WorkUnreadable extends InMemorySecureKeyValueStore {
  _WorkUnreadable(super.seed);

  @override
  Future<String?> read({required String key}) {
    if (key.endsWith(':$_work')) {
      throw StateError('secure storage unavailable');
    }
    return super.read(key: key);
  }
}

void main() {
  setUp(() {
    addTearDown(PreferencesStore.debugReset);
    // Two saved connections, Hermes off.
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

  // Hermes was turned on first, with the connection it was meant to leave;
  // the switch then failed, and that one stayed on and in use.
  testWidgets('a connection that cannot be switched to leaves Hermes off', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          secureStorageProvider.overrideWithValue(
            _WorkUnreadable({'hermes_api_key_v1:$_home': 'home-key'}),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () => useHermesConnection(context, ref, _work),
                child: const Text('use work'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.text('use work')),
    );

    await tester.tap(find.text('use work'));
    await tester.pumpAndSettle();

    check(container.read(hermesEnabledProvider)).isFalse();
    check(container.read(hermesActiveConnectionIdProvider)).equals(_home);
  });
}
