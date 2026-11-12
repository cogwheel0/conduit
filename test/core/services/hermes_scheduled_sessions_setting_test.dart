import 'package:conduit/platform/flutter_key_value_store.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
  });
  tearDown(PreferencesStore.debugReset);

  test('scheduled runs show by default and take part in equality', () {
    const settings = AppSettings();
    expect(settings.hermesShowScheduledSessions, isTrue);
    final hidden = settings.copyWith(hermesShowScheduledSessions: false);
    expect(hidden, isNot(settings));
    expect(hidden.hashCode, isNot(settings.hashCode));
    expect(hidden.copyWith(hermesShowScheduledSessions: true), settings);
  });

  test('the choice survives a new settings container', () async {
    final first = ProviderContainer();
    addTearDown(first.dispose);
    await first
        .read(appSettingsProvider.notifier)
        .setHermesShowScheduledSessions(false);
    expect(first.read(appSettingsProvider).hermesShowScheduledSessions, false);

    final restored = ProviderContainer();
    addTearDown(restored.dispose);
    expect(
      restored.read(appSettingsProvider).hermesShowScheduledSessions,
      isFalse,
    );
  });

  test('a stale bulk save keeps the choice; reset restores it', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final settings = container.read(appSettingsProvider.notifier);
    await settings.setHermesShowScheduledSessions(false);
    await SettingsService.saveSettings(const AppSettings());
    expect(
      (await SettingsService.loadSettings()).hermesShowScheduledSessions,
      isFalse,
    );

    await settings.resetToDefaults();
    expect(
      (await SettingsService.loadSettings()).hermesShowScheduledSessions,
      isTrue,
    );
    expect(
      PreferencesStore.containsKey(PreferenceKeys.hermesShowScheduledSessions),
      isFalse,
    );
  });
}
