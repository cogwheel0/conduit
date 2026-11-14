import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// A host's defaults stand in only for settings the user never set.
void main() {
  late InMemoryKeyValueStore prefs;

  setUp(() {
    prefs = InMemoryKeyValueStore();
    PreferencesStore.debugOverride(prefs);
  });

  tearDown(PreferencesStore.debugReset);

  ProviderContainer launch({AppSettingsHostDefaults? hostDefaults}) {
    final container = ProviderContainer(
      overrides: [
        if (hostDefaults != null)
          appSettingsHostDefaultsProvider.overrideWithValue(hostDefaults),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test("without host defaults, Send with Enter keeps core's default", () {
    expect(launch().read(appSettingsProvider).sendOnEnter, isFalse);
  });

  test('a host default turns Send with Enter on while it was never set', () {
    final container = launch(
      hostDefaults: const AppSettingsHostDefaults(sendOnEnter: true),
    );
    expect(container.read(appSettingsProvider).sendOnEnter, isTrue);
  });

  test('a stored choice wins over the host default', () async {
    final container = launch(
      hostDefaults: const AppSettingsHostDefaults(sendOnEnter: true),
    );
    await container.read(appSettingsProvider.notifier).setSendOnEnter(false);
    expect(container.read(appSettingsProvider).sendOnEnter, isFalse);

    // Read back from storage, as after a relaunch.
    final relaunched = launch(
      hostDefaults: const AppSettingsHostDefaults(sendOnEnter: true),
    );
    expect(relaunched.read(appSettingsProvider).sendOnEnter, isFalse);
    expect(PreferencesStore.containsKey(PreferenceKeys.sendOnEnterKey), isTrue);
  });

  test('a host default turns notifications on until the user or server sets '
      'them', () async {
    expect(launch().read(appSettingsProvider).notificationsEnabled, isFalse);
    final container = launch(
      hostDefaults: const AppSettingsHostDefaults(notificationsEnabled: true),
    );
    expect(container.read(appSettingsProvider).notificationsEnabled, isTrue);

    await container
        .read(appSettingsProvider.notifier)
        .setNotificationsEnabled(false);
    final relaunched = launch(
      hostDefaults: const AppSettingsHostDefaults(notificationsEnabled: true),
    );
    expect(relaunched.read(appSettingsProvider).notificationsEnabled, isFalse);
  });

  test('mentions only is off until set, and is stored', () async {
    final container = launch();
    expect(
      container.read(appSettingsProvider).notificationChannelMentionsOnly,
      isFalse,
    );
    await container
        .read(appSettingsProvider.notifier)
        .setNotificationChannelMentionsOnly(true);
    expect(
      launch().read(appSettingsProvider).notificationChannelMentionsOnly,
      isTrue,
    );
  });
}
