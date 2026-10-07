import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/persistence/account_scoped_preferences.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/providers/app_providers.dart'
    show SettledActiveAccountId, settledActiveAccountIdProvider;
import 'package:conduit_core/services/settings_service.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// The settled account stays on A, so settings do not reload mid-test.
final class _SettledOnA extends SettledActiveAccountId {
  @override
  String? build() => 'a';
}

/// Settles where the test says.
final class _Settled extends SettledActiveAccountId {
  @override
  String? build() => 'a';

  void settle(String? accountId) => state = accountId;
}

/// Model and chat defaults that belong to one Open WebUI account.
void main() {
  setUp(() async {
    PreferencesStore.installLoader(() async => InMemoryKeyValueStore());
    await PreferencesStore.ensureInitialized();
  });

  tearDown(PreferencesStore.debugReset);

  Future<void> activate(String? accountId) =>
      PreferencesStore.put(PreferenceKeys.activeServerId, accountId);

  test('each account keeps its own default model', () async {
    await PreferencesStore.put(
      PreferenceKeys.accountScopedSettingsMigrated,
      true,
    );
    await activate('a');
    await SettingsService.setDefaultModel('model-on-a');
    await activate('b');
    await SettingsService.setDefaultModel('model-on-b');

    check(await SettingsService.getDefaultModel()).equals('model-on-b');
    await activate('a');
    check(await SettingsService.getDefaultModel()).equals('model-on-a');
    check((await SettingsService.loadSettings()).defaultModel)
        .equals('model-on-a');
  });

  test('look-and-feel settings stay device-wide', () async {
    await activate('a');
    await SettingsService.setReduceMotion(true);
    await activate('b');

    check(await SettingsService.getReduceMotion()).isTrue();
  });

  test('without an account the device-wide value is used', () async {
    await activate(null);
    await SettingsService.setPinnedModels(['direct:model']);

    check(PreferencesStore.getStringList(PreferenceKeys.pinnedModels))
        .isNotNull()
        .deepEquals(['direct:model']);
    check(await SettingsService.getPinnedModels()).deepEquals(['direct:model']);
  });

  test(
    'before its one-time copy an account reads the old device value',
    () async {
      await PreferencesStore.put(PreferenceKeys.defaultModel, 'pre-upgrade');
      await activate('a');

      check(await SettingsService.getDefaultModel()).equals('pre-upgrade');

      await migrateDeviceSettingsIntoAccount('a');
      await activate('b');
      // A later account starts from the defaults, not from someone else's.
      check(await SettingsService.getDefaultModel()).isNull();
      await activate('a');
      check(await SettingsService.getDefaultModel()).equals('pre-upgrade');
    },
  );

  test('a write lands under the account active when it started', () async {
    await PreferencesStore.put(
      PreferenceKeys.accountScopedSettingsMigrated,
      true,
    );
    await activate('a');
    final save = SettingsService.saveSettings(
      (await SettingsService.loadSettings()).copyWith(defaultModel: 'on-a'),
    );
    await activate('b');
    await save;

    check(await SettingsService.getDefaultModel()).isNull();
    await activate('a');
    check(await SettingsService.getDefaultModel()).equals('on-a');
  });

  test(
    'server notification prefs land under the account they came from',
    () async {
      await PreferencesStore.put(
        PreferenceKeys.accountScopedSettingsMigrated,
        true,
      );
      await activate('a');
      final container = ProviderContainer(
        overrides: [
          settledActiveAccountIdProvider.overrideWith(_SettledOnA.new),
        ],
      );
      addTearDown(container.dispose);
      final settings = container.read(appSettingsProvider.notifier);
      bool? stored(String key, String accountId) =>
          PreferencesStore.getBool(accountScopedPreferenceKey(key, accountId));
      void checkNothingOnB() {
        for (final key in const [
          PreferenceKeys.notificationsEnabled,
          PreferenceKeys.notificationSound,
          PreferenceKeys.notificationSoundAlways,
        ]) {
          check(stored(key, 'b')).isNull();
        }
      }

      final apply = settings.applyServerNotificationPrefs(
        accountId: 'a',
        enabled: true,
        sound: false,
        soundAlways: true,
      );
      await activate('b');
      await apply;

      checkNothingOnB();
      check(stored(PreferenceKeys.notificationsEnabled, 'a')).equals(true);
      check(stored(PreferenceKeys.notificationSound, 'a')).equals(false);
      check(stored(PreferenceKeys.notificationSoundAlways, 'a')).equals(true);

      // Prefs fetched for A that arrive once B is active still go to A, and
      // leave the settings on screen alone.
      final shown = container.read(appSettingsProvider);
      await settings.applyServerNotificationPrefs(
        accountId: 'a',
        enabled: false,
        sound: true,
        soundAlways: false,
      );

      checkNothingOnB();
      check(stored(PreferenceKeys.notificationsEnabled, 'a')).equals(false);
      check(container.read(appSettingsProvider)).identicalTo(shown);
    },
  );

  test('server notification prefs show once written, after a switch away '
      'and back', () async {
    final paused = Completer<void>();
    final resume = Completer<void>();
    final soundKey = accountScopedPreferenceKey(
      PreferenceKeys.notificationSound,
      'a',
    );
    PreferencesStore.debugOverride(
      InMemoryKeyValueStore(),
      writeInterceptor: (_, key, _) async {
        if (key == soundKey && !paused.isCompleted) {
          paused.complete();
          await resume.future;
        }
        return null;
      },
    );
    await PreferencesStore.put(
      PreferenceKeys.accountScopedSettingsMigrated,
      true,
    );
    await activate('a');
    final container = ProviderContainer(
      overrides: [settledActiveAccountIdProvider.overrideWith(_Settled.new)],
    );
    addTearDown(container.dispose);
    final settled = container.read(settledActiveAccountIdProvider.notifier)
        as _Settled;
    container.read(appSettingsProvider);

    final apply = container
        .read(appSettingsProvider.notifier)
        .applyServerNotificationPrefs(
          accountId: 'a',
          enabled: true,
          sound: false,
          soundAlways: true,
        );
    // Only the first of the three is written when the user switches to B
    // and back, and the settings reload from what is there.
    await paused.future;
    await activate('b');
    settled.settle('b');
    container.read(appSettingsProvider);
    await activate('a');
    settled.settle('a');
    check(container.read(appSettingsProvider).notificationSound).isTrue();
    resume.complete();
    await apply;

    final shown = container.read(appSettingsProvider);
    check(shown.notificationsEnabled).isTrue();
    check(shown.notificationSound).isFalse();
    check(shown.notificationSoundAlways).isTrue();
  });

  test('a saved server voice is read back for its account', () async {
    await PreferencesStore.put(
      PreferenceKeys.accountScopedSettingsMigrated,
      true,
    );
    await activate('a');
    await SettingsService.saveSettings(
      (await SettingsService.loadSettings()).copyWith(
        ttsServerVoiceId: 'v1',
        ttsServerVoiceName: 'Voice',
      ),
    );

    final onA = await SettingsService.loadSettings();
    check(onA.ttsServerVoiceId).equals('v1');
    check(onA.ttsServerVoiceName).equals('Voice');
    check(PreferencesStore.containsKey(PreferenceKeys.ttsServerVoiceId))
        .isFalse();
    await activate('b');
    check((await SettingsService.loadSettings()).ttsServerVoiceId).isNull();
  });

  test('clearing an account removes everything it kept', () async {
    await activate('a');
    await SettingsService.setDefaultModel('model-on-a');
    await PreferencesStore.put(
      '${PreferenceKeys.transportOptionsPrefix}:${base64Url.encode(utf8.encode('a'))}',
      '{}',
    );
    await PreferencesStore.put(
      PreferenceKeys.serverFeatureAvailability,
      jsonEncode({
        'a::user': {'notes': true},
        'b::user': {'notes': false},
      }),
    );
    await PreferencesStore.put(
      PreferenceKeys.openWebUiAccountSummaries,
      jsonEncode({
        'a': {'name': 'A'},
        'b': {'name': 'B'},
      }),
    );

    await clearOpenWebUiAccountPreferences('a');

    check(PreferencesStore.keys().where((key) => key.contains('@acct:')))
        .isEmpty();
    check(
      jsonDecode(
        PreferencesStore.getString(PreferenceKeys.serverFeatureAvailability)!,
      ) as Map,
    ).keys.deepEquals(['b::user']);
    check(
      jsonDecode(
        PreferencesStore.getString(PreferenceKeys.openWebUiAccountSummaries)!,
      ) as Map,
    ).keys.deepEquals(['b']);
  });
}
