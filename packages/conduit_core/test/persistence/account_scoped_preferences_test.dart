import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/openwebui_account_summaries.dart';
import 'package:conduit_core/database/account_storage_isolation.dart';
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
    debugResetDeviceSettingsCopy();
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

  test('only the first account active after the upgrade inherits the '
      'device settings', () async {
    final paused = Completer<void>();
    final resume = Completer<void>();
    final onA = accountScopedPreferenceKey(PreferenceKeys.defaultModel, 'a');
    PreferencesStore.debugOverride(
      InMemoryKeyValueStore(),
      writeInterceptor: (_, key, _) async {
        if (key == onA && !paused.isCompleted) {
          paused.complete();
          await resume.future;
        }
        return null;
      },
    );
    await PreferencesStore.put(PreferenceKeys.defaultModel, 'pre-upgrade');

    final copyingToA = migrateDeviceSettingsIntoAccount('a');
    await paused.future;
    // B is certified while A's copy is still being written.
    await migrateDeviceSettingsIntoAccount('b');
    resume.complete();
    await copyingToA;

    check(PreferencesStore.getRaw(onA)).equals('pre-upgrade');
    check(
      PreferencesStore.containsKey(
        accountScopedPreferenceKey(PreferenceKeys.defaultModel, 'b'),
      ),
    ).isFalse();
  });

  test('a device setting that fails to copy is copied again', () async {
    final onA = accountScopedPreferenceKey(PreferenceKeys.defaultModel, 'a');
    var refuse = true;
    PreferencesStore.debugOverride(
      InMemoryKeyValueStore(),
      writeInterceptor: (_, key, _) async =>
          key == onA && refuse ? false : null,
    );
    await PreferencesStore.put(PreferenceKeys.defaultModel, 'pre-upgrade');

    await check(migrateDeviceSettingsIntoAccount('a')).throws<StateError>();
    check(
      PreferencesStore.getBool(PreferenceKeys.accountScopedSettingsMigrated),
    ).not((it) => it.equals(true));

    refuse = false;
    await migrateDeviceSettingsIntoAccount('a');
    check(PreferencesStore.getRaw(onA)).equals('pre-upgrade');
  });

  test("a removal the store refuses is reported, after the account's other "
      'data has gone', () async {
    final pinnedOnA = accountScopedPreferenceKey(
      PreferenceKeys.pinnedModels,
      'a',
    );
    final modelOnA = accountScopedPreferenceKey(PreferenceKeys.defaultModel, 'a');
    final transport =
        '${PreferenceKeys.transportOptionsPrefix}:'
        '${base64Url.encode(utf8.encode('a'))}';
    final store = InMemoryKeyValueStore();
    PreferencesStore.debugOverride(
      store,
      writeInterceptor: (_, key, value) async =>
          key == pinnedOnA && value == null ? false : null,
    );
    await PreferencesStore.put(pinnedOnA, ['model']);
    await PreferencesStore.put(modelOnA, 'model');
    await PreferencesStore.put(transport, 'polling');

    await check(clearOpenWebUiAccountPreferences('a')).throws<StateError>();

    check(PreferencesStore.containsKey(modelOnA)).isFalse();
    check(PreferencesStore.containsKey(transport)).isFalse();
    // Still there, and said so.
    check(PreferencesStore.containsKey(pinnedOnA)).isTrue();
  });

  test('device settings whose copy failed go with the account they were for',
      () async {
    final onA = accountScopedPreferenceKey(PreferenceKeys.defaultModel, 'a');
    PreferencesStore.debugOverride(
      InMemoryKeyValueStore(),
      writeInterceptor: (_, key, _) async => key == onA ? false : null,
    );
    await PreferencesStore.put(PreferenceKeys.defaultModel, 'pre-upgrade');
    await check(migrateDeviceSettingsIntoAccount('a')).throws<StateError>();

    await clearOpenWebUiAccountPreferences('a');
    await migrateDeviceSettingsIntoAccount('b');
    await activate('b');

    check(await SettingsService.getDefaultModel()).isNull();
  });

  test('a settings copy overtaken by its account\'s removal leaves nothing',
      () async {
    final paused = Completer<void>();
    final resume = Completer<void>();
    final onA = accountScopedPreferenceKey(PreferenceKeys.defaultModel, 'a');
    PreferencesStore.debugOverride(
      InMemoryKeyValueStore(),
      writeInterceptor: (_, key, _) async {
        if (key == onA && !paused.isCompleted) {
          paused.complete();
          await resume.future;
        }
        return null;
      },
    );
    await PreferencesStore.put(PreferenceKeys.defaultModel, 'pre-upgrade');

    final copying = migrateDeviceSettingsIntoAccount('a');
    await paused.future;
    // A is signed out of while its copy is being written.
    await clearOpenWebUiAccountPreferences('a');
    resume.complete();
    await copying;

    check(PreferencesStore.containsKey(onA)).isFalse();
  });

  test('an account whose settings copy cannot be marked done is still cleared',
      () async {
    final onA = accountScopedPreferenceKey(PreferenceKeys.defaultModel, 'a');
    final pinnedOnA = accountScopedPreferenceKey(
      PreferenceKeys.pinnedModels,
      'a',
    );
    var refuseMark = false;
    PreferencesStore.debugOverride(
      InMemoryKeyValueStore(),
      writeInterceptor: (_, key, _) async {
        if (key == onA) return false;
        if (key == PreferenceKeys.accountScopedSettingsMigrated && refuseMark) {
          return false;
        }
        return null;
      },
    );
    await PreferencesStore.put(PreferenceKeys.defaultModel, 'pre-upgrade');
    await PreferencesStore.put(pinnedOnA, <String>['model']);
    await check(migrateDeviceSettingsIntoAccount('a')).throws<StateError>();

    refuseMark = true;
    await check(clearOpenWebUiAccountPreferences('a')).throws<StateError>();

    // A's own settings went regardless, and B does not take A's over.
    check(PreferencesStore.containsKey(pinnedOnA)).isFalse();
    await migrateDeviceSettingsIntoAccount('b');
    check(
      PreferencesStore.containsKey(
        accountScopedPreferenceKey(PreferenceKeys.defaultModel, 'b'),
      ),
    ).isFalse();
  });

  test('a setting cleared before the device settings were copied stays '
      'cleared', () async {
    final onA = accountScopedPreferenceKey(PreferenceKeys.defaultModel, 'a');
    var refuse = true;
    PreferencesStore.debugOverride(
      InMemoryKeyValueStore(),
      writeInterceptor: (_, key, _) async =>
          key == onA && refuse ? false : null,
    );
    await PreferencesStore.put(PreferenceKeys.defaultModel, 'pre-upgrade');
    await activate('a');
    // A's copy failed, so A still reads the device value.
    await check(migrateDeviceSettingsIntoAccount('a')).throws<StateError>();
    check(await SettingsService.getDefaultModel()).equals('pre-upgrade');
    refuse = false;

    await SettingsService.setDefaultModel(null);

    check(await SettingsService.getDefaultModel()).isNull();
  });

  test('a settings copy asked for again while it runs keeps what it copied',
      () async {
    final paused = Completer<void>();
    final resume = Completer<void>();
    final onA = accountScopedPreferenceKey(PreferenceKeys.defaultModel, 'a');
    PreferencesStore.debugOverride(
      InMemoryKeyValueStore(),
      writeInterceptor: (_, key, _) async {
        if (key == onA && !paused.isCompleted) {
          paused.complete();
          await resume.future;
        }
        return null;
      },
    );
    await PreferencesStore.put(PreferenceKeys.defaultModel, 'pre-upgrade');

    final first = migrateDeviceSettingsIntoAccount('a');
    await paused.future;
    // Switching to B and back to A certifies A again mid-copy; a copy of its
    // own would finish while the first one still waits on a write.
    final second = migrateDeviceSettingsIntoAccount('a');
    await pumpEventQueue();
    resume.complete();
    await first;
    await second;

    check(PreferencesStore.getRaw(onA)).equals('pre-upgrade');
  });

  test('a setting cleared while the device settings cannot be copied says '
      'so', () async {
    final onA = accountScopedPreferenceKey(PreferenceKeys.defaultModel, 'a');
    PreferencesStore.debugOverride(
      InMemoryKeyValueStore(),
      writeInterceptor: (_, key, _) async => key == onA ? false : null,
    );
    await PreferencesStore.put(PreferenceKeys.defaultModel, 'pre-upgrade');
    await activate('a');

    // The device value would come back with the copy; the clear fails
    // rather than seem to work.
    await check(SettingsService.setDefaultModel(null)).throws<StateError>();
    check(await SettingsService.getDefaultModel()).equals('pre-upgrade');
  });

  test('a setting with no device value clears while the copy cannot run',
      () async {
    final onA = accountScopedPreferenceKey(PreferenceKeys.defaultModel, 'a');
    PreferencesStore.debugOverride(
      InMemoryKeyValueStore(),
      writeInterceptor: (_, key, _) async => key == onA ? false : null,
    );
    await PreferencesStore.put(PreferenceKeys.defaultModel, 'pre-upgrade');
    await activate('a');

    await SettingsService.setOpenRouterImageGenerationModel('image-model');

    // Nothing for the image model to fall back to or be copied back from.
    await SettingsService.setOpenRouterImageGenerationModel(null);
    check(
      (await SettingsService.loadSettings()).openRouterImageGenerationModel,
    ).isNull();
  });

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

  test('a notification choice made while server prefs are saved stays',
      () async {
    final paused = Completer<void>();
    final resume = Completer<void>();
    final lastKey = accountScopedPreferenceKey(
      PreferenceKeys.notificationSoundAlways,
      'a',
    );
    PreferencesStore.debugOverride(
      InMemoryKeyValueStore(),
      writeInterceptor: (_, key, _) async {
        if (key == lastKey && !paused.isCompleted) {
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
      overrides: [settledActiveAccountIdProvider.overrideWith(_SettledOnA.new)],
    );
    addTearDown(container.dispose);
    final settings = container.read(appSettingsProvider.notifier);

    final apply = settings.applyServerNotificationPrefs(
      accountId: 'a',
      enabled: true,
      sound: true,
      soundAlways: true,
    );
    // The server's sound setting is saved; the user turns sound off.
    await paused.future;
    await settings.setNotificationSound(false);
    resume.complete();
    await apply;

    check(container.read(appSettingsProvider).notificationSound).isFalse();
  });

  test('a signed-out account\'s summary stays gone when another account '
      'is used', () async {
    final container = ProviderContainer(
      overrides: [
        settledActiveAccountIdProvider.overrideWith(_SettledOnA.new),
      ],
    );
    addTearDown(container.dispose);
    final summaries = container.read(
      openWebUiAccountSummariesProvider.notifier,
    );
    await summaries.touch('a');
    await summaries.touch('b');

    await container.read(openWebUiAccountPrivateDataClearProvider)('a');
    // B is used again before anything reloads the summaries.
    await summaries.touch('b');

    final stored = PreferencesStore.getString(
      PreferenceKeys.openWebUiAccountSummaries,
    );
    check((jsonDecode(stored!) as Map).keys).deepEquals(['b']);
  });

  test("a signed-out account's summary that cannot be removed is reported",
      () async {
    // As SharedPreferences fails a write: what it shows changes, and the
    // write to disk reports failure.
    var refuse = false;
    PreferencesStore.debugOverride(
      InMemoryKeyValueStore(),
      writeInterceptor: (preferences, key, value) async {
        if (!refuse || key != PreferenceKeys.openWebUiAccountSummaries) {
          return null;
        }
        await preferences.setString(key, value! as String);
        return false;
      },
    );
    final container = ProviderContainer(
      overrides: [
        settledActiveAccountIdProvider.overrideWith(_SettledOnA.new),
      ],
    );
    addTearDown(container.dispose);
    final summaries = container.read(
      openWebUiAccountSummariesProvider.notifier,
    );
    await summaries.touch('a');
    await summaries.touch('b');
    refuse = true;

    await check(
      container.read(openWebUiAccountPrivateDataClearProvider)('a'),
    ).throws<StateError>();
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
