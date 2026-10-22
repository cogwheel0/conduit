import 'package:conduit_core/models/response_animation.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => PreferencesStore.debugOverride(InMemoryKeyValueStore()));
  tearDown(PreferencesStore.debugReset);

  test('choices persist independently across provider recreation', () async {
    final container = ProviderContainer();
    final notifier = container.read(appSettingsProvider.notifier);
    expect(
      container.read(appSettingsProvider).thinkingIndicatorStyle,
      ResponseIndicatorStyle.facets,
    );
    expect(
      container.read(appSettingsProvider).skillIndicatorStyle,
      ResponseIndicatorStyle.exchange,
    );
    for (final thinking in ResponseIndicatorStyle.thinkingChoices) {
      await notifier.setThinkingIndicatorStyle(thinking);
      expect(
        container.read(appSettingsProvider).thinkingIndicatorStyle,
        thinking,
      );
    }
    await notifier.setSkillIndicatorStyle(ResponseIndicatorStyle.fold);
    await notifier.setResponseFinishStyle(ResponseFinishStyle.shrink);
    container.dispose();
    final reloaded = ProviderContainer();
    addTearDown(reloaded.dispose);
    final settings = reloaded.read(appSettingsProvider);
    expect(settings.thinkingIndicatorStyle, ResponseIndicatorStyle.gather);
    expect(settings.skillIndicatorStyle, ResponseIndicatorStyle.fold);
    expect(settings.responseFinishStyle, ResponseFinishStyle.shrink);
    expect(
      PreferencesStore.getString(PreferenceKeys.thinkingIndicatorStyle),
      'gather',
    );
  });

  test('invalid saved choices safely use approved defaults', () async {
    PreferencesStore.debugOverride(
      InMemoryKeyValueStore({
        PreferenceKeys.thinkingIndicatorStyle: 'exchange',
        PreferenceKeys.skillIndicatorStyle: 'gather',
        PreferenceKeys.responseFinishStyle: 'unknown',
      }),
    );
    final settings = await SettingsService.loadSettings();
    expect(settings.thinkingIndicatorStyle, ResponseIndicatorStyle.facets);
    expect(settings.skillIndicatorStyle, ResponseIndicatorStyle.exchange);
    expect(settings.responseFinishStyle, ResponseFinishStyle.fade);
  });

  test('bulk settings save retains all three animation choices', () async {
    await SettingsService.saveSettings(
      const AppSettings(
        thinkingIndicatorStyle: ResponseIndicatorStyle.scan,
        skillIndicatorStyle: ResponseIndicatorStyle.fold,
        responseFinishStyle: ResponseFinishStyle.clear,
      ),
    );
    final settings = await SettingsService.loadSettings();
    expect(settings.thinkingIndicatorStyle, ResponseIndicatorStyle.scan);
    expect(settings.skillIndicatorStyle, ResponseIndicatorStyle.fold);
    expect(settings.responseFinishStyle, ResponseFinishStyle.clear);
  });
}
