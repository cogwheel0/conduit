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

  test(
    'Notes visibility defaults on and participates in settings equality',
    () {
      const settings = AppSettings();
      expect(settings.showComposerNotesButton, isTrue);
      final hidden = settings.copyWith(showComposerNotesButton: false);
      expect(hidden, isNot(settings));
      expect(hidden.copyWith(showComposerNotesButton: true), settings);
    },
  );

  test('Notes visibility survives a new settings container', () async {
    final first = ProviderContainer();
    addTearDown(first.dispose);
    await first
        .read(appSettingsProvider.notifier)
        .setShowComposerNotesButton(false);
    expect(first.read(appSettingsProvider).showComposerNotesButton, isFalse);
    final restored = ProviderContainer();
    addTearDown(restored.dispose);
    expect(restored.read(appSettingsProvider).showComposerNotesButton, isFalse);
  });

  test('a stale bulk save preserves visibility; reset restores it', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final settings = container.read(appSettingsProvider.notifier);
    await settings.setShowComposerNotesButton(false);
    await SettingsService.saveSettings(const AppSettings());
    expect(
      (await SettingsService.loadSettings()).showComposerNotesButton,
      isFalse,
    );
    await settings.resetToDefaults();
    expect(
      (await SettingsService.loadSettings()).showComposerNotesButton,
      isTrue,
    );
    expect(
      PreferencesStore.containsKey(PreferenceKeys.showComposerNotesButton),
      isFalse,
    );
  });
}
