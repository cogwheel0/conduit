import 'package:checks/checks.dart';
import 'package:conduit_core/persistence/account_scoped_preferences.dart';
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

  // Each setting a host can default: what turns it on, how it reads, how
  // the user sets it, and where it is stored.
  final rows = <({
    String name,
    AppSettingsHostDefaults on,
    bool Function(AppSettings) read,
    Future<void> Function(AppSettingsNotifier, bool) set,
    String key,
    String? account,
  })>[
    (
      name: 'Send with Enter',
      on: const AppSettingsHostDefaults(sendOnEnter: true),
      read: (settings) => settings.sendOnEnter,
      set: (notifier, value) => notifier.setSendOnEnter(value),
      key: PreferenceKeys.sendOnEnterKey,
      account: null,
    ),
    (
      name: 'notifications',
      on: const AppSettingsHostDefaults(notificationsEnabled: true),
      read: (settings) => settings.notificationsEnabled,
      set: (notifier, value) => notifier.setNotificationsEnabled(value),
      key: PreferenceKeys.notificationsEnabled,
      account: null,
    ),
    // Stored for the account in use as well as for the device.
    (
      name: 'notifications, with an account signed in',
      on: const AppSettingsHostDefaults(notificationsEnabled: true),
      read: (settings) => settings.notificationsEnabled,
      set: (notifier, value) => notifier.setNotificationsEnabled(value),
      key: PreferenceKeys.notificationsEnabled,
      account: 'acct-1',
    ),
  ];

  for (final row in rows) {
    test('${row.name}: the host default stands until the user sets it, '
        'and again after a reset', () async {
      final account = row.account;
      if (account != null) {
        await PreferencesStore.put(PreferenceKeys.activeServerId, account);
      }
      bool stored() =>
          PreferencesStore.containsKey(row.key) ||
          (account != null &&
              PreferencesStore.containsKey(
                accountScopedPreferenceKey(row.key, account),
              ));
      check(row.read(launch().read(appSettingsProvider))).isFalse();
      final container = launch(hostDefaults: row.on);
      check(row.read(container.read(appSettingsProvider))).isTrue();

      // A choice is stored and wins, after a relaunch too.
      await row.set(container.read(appSettingsProvider.notifier), false);
      final relaunched = launch(hostDefaults: row.on);
      check(row.read(relaunched.read(appSettingsProvider))).isFalse();
      check(stored()).isTrue();

      // A reset goes back to the host's default, and leaves it unset.
      await relaunched.read(appSettingsProvider.notifier).resetToDefaults();
      check(row.read(relaunched.read(appSettingsProvider))).isTrue();
      check(stored()).isFalse();
      // Saving another setting afterwards keeps it unset.
      await relaunched.read(appSettingsProvider.notifier).setTtsSpeed(1.5);
      check(stored()).isFalse();
      check(
        row.read(launch(hostDefaults: row.on).read(appSettingsProvider)),
      ).isTrue();
    });
  }

  test('mentions only is off until set, and is stored', () async {
    final container = launch();
    check(
      container.read(appSettingsProvider).notificationChannelMentionsOnly,
    ).isFalse();
    await container
        .read(appSettingsProvider.notifier)
        .setNotificationChannelMentionsOnly(true);
    check(
      launch().read(appSettingsProvider).notificationChannelMentionsOnly,
    ).isTrue();

    // A bulk save of an older snapshot (another setting's) leaves it.
    await SettingsService.saveSettings(const AppSettings());
    check(
      launch().read(appSettingsProvider).notificationChannelMentionsOnly,
    ).isTrue();
    // A reset clears it.
    await container.read(appSettingsProvider.notifier).resetToDefaults();
    check(
      launch().read(appSettingsProvider).notificationChannelMentionsOnly,
    ).isFalse();
  });
}
