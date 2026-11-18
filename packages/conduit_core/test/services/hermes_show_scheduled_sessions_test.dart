import 'package:checks/checks.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// Show Scheduled Runs is saved before it is shown: the Hermes list follows
/// the value at once, so one that could not be saved never shows.
void main() {
  var refuse = false;

  setUp(() {
    refuse = false;
    PreferencesStore.debugOverride(
      InMemoryKeyValueStore(),
      writeInterceptor: (prefs, key, value) async {
        if (refuse &&
            key.endsWith(PreferenceKeys.hermesShowScheduledSessions)) {
          throw StateError('Preference changes are unavailable.');
        }
        return null;
      },
    );
  });
  tearDown(PreferencesStore.debugReset);

  test('a change that cannot be saved leaves the shown value', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final settings = container.read(appSettingsProvider.notifier);
    check(
      container.read(appSettingsProvider).hermesShowScheduledSessions,
    ).isTrue();

    refuse = true;
    await check(
      settings.setHermesShowScheduledSessions(false),
    ).throws<StateError>();
    check(
      container.read(appSettingsProvider).hermesShowScheduledSessions,
    ).isTrue();

    refuse = false;
    await settings.setHermesShowScheduledSessions(false);
    check(
      container.read(appSettingsProvider).hermesShowScheduledSessions,
    ).isFalse();
  });

  test('a write the store does not keep leaves the shown value', () async {
    final store = _Unkept();
    PreferencesStore.debugOverride(store);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final settings = container.read(appSettingsProvider.notifier);

    store.unkept = true;
    await check(
      settings.setHermesShowScheduledSessions(false),
    ).throws<StateError>();
    check(
      container.read(appSettingsProvider).hermesShowScheduledSessions,
    ).isTrue();
  });
}

/// Preferences whose writes report they were not kept while [unkept].
final class _Unkept extends InMemoryKeyValueStore {
  bool unkept = false;

  @override
  Future<bool> setBool(String key, bool value) async =>
      !unkept && await super.setBool(key, value);
}
