import 'dart:async';

import 'package:checks/checks.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:conduit_core/features/chat/server_speech/direct_voice_provider_settings.dart';
import 'package:conduit_core/features/web_search/web_search.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit/platform/flutter_key_value_store.dart';

void main() {
  group('Sliding sidebar preference', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
    });
    tearDown(PreferencesStore.debugReset);

    test('defaults off and survives a new settings provider', () async {
      check(const AppSettings().slidingSidebarEnabled).isFalse();
      check(await SettingsService.getSlidingSidebarEnabled()).isFalse();
      final first = ProviderContainer();
      await first
          .read(appSettingsProvider.notifier)
          .setSlidingSidebarEnabled(true);
      first.dispose();
      final reopened = ProviderContainer();
      addTearDown(reopened.dispose);
      check(reopened.read(appSettingsProvider).slidingSidebarEnabled).isTrue();
      await reopened
          .read(appSettingsProvider.notifier)
          .setSlidingSidebarEnabled(false);
      check(await SettingsService.getSlidingSidebarEnabled()).isFalse();
    });

    test('a delayed bulk save cannot undo a newer sidebar toggle', () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      var held = false;
      PreferencesStore.debugOverride(
        PreferencesStore.instance,
        writeInterceptor: (_, key, value) async {
          if (key == PreferenceKeys.reduceMotion && !held) {
            held = true;
            entered.complete();
            await release.future;
          }
          return null;
        },
      );
      final bulk = SettingsService.saveSettings(const AppSettings());
      await entered.future;
      await SettingsService.setSlidingSidebarEnabled(true);
      release.complete();
      await bulk;
      check(await SettingsService.getSlidingSidebarEnabled()).isTrue();
      final reopened = ProviderContainer();
      addTearDown(reopened.dispose);
      check(reopened.read(appSettingsProvider).slidingSidebarEnabled).isTrue();
    });

    test('reset restores the default sidebar after opting in', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container
          .read(appSettingsProvider.notifier)
          .setSlidingSidebarEnabled(true);
      await container.read(appSettingsProvider.notifier).resetToDefaults();
      check(container.read(appSettingsProvider).slidingSidebarEnabled)
          .isFalse();
      check(await SettingsService.getSlidingSidebarEnabled()).isFalse();
    });

    test('copy and equality retain the preference', () {
      final enabled = const AppSettings().copyWith(slidingSidebarEnabled: true);
      check(enabled == const AppSettings()).isFalse();
      check(enabled.copyWith().slidingSidebarEnabled).isTrue();
      check(enabled == enabled.copyWith()).isTrue();
    });
  });

  group('AppSettings', () {
    group('default constructor values', () {
      const settings = AppSettings();

      test('reduceMotion defaults to false', () {
        check(settings.reduceMotion).equals(false);
      });

      test('animationSpeed defaults to 1.0', () {
        check(settings.animationSpeed).equals(1.0);
      });

      test('disableHapticsWhileStreaming defaults to false', () {
        check(settings.disableHapticsWhileStreaming).equals(false);
      });

      test('highContrast defaults to false', () {
        check(settings.highContrast).equals(false);
      });

      test('darkMode defaults to true', () {
        check(settings.darkMode).equals(true);
      });

      test('defaultModel defaults to null', () {
        check(settings.defaultModel).isNull();
      });

      test('OpenRouter image generation model defaults to null', () {
        check(settings.openRouterImageGenerationModel).isNull();
      });

      test('voiceLocaleId defaults to null', () {
        check(settings.voiceLocaleId).isNull();
      });

      test('voiceHoldToTalk defaults to false', () {
        check(settings.voiceHoldToTalk).equals(false);
      });

      test('voiceAutoSendFinal defaults to false', () {
        check(settings.voiceAutoSendFinal).equals(false);
      });

      test('socketTransportMode defaults to ws', () {
        check(settings.socketTransportMode).equals('ws');
      });

      test('quickPills defaults to empty list', () {
        check(settings.quickPills).isEmpty();
      });

      test('pinnedModels defaults to empty list', () {
        check(settings.pinnedModels).isEmpty();
      });

      test('sendOnEnter defaults to false', () {
        check(settings.sendOnEnter).equals(false);
      });

      test('sttPreference defaults to deviceOnly', () {
        check(settings.sttPreference).equals(SttPreference.deviceOnly);
      });

      test('sttLanguageCode defaults to null', () {
        check(settings.sttLanguageCode).isNull();
      });

      test('ttsVoice defaults to null', () {
        check(settings.ttsVoice).isNull();
      });

      test('ttsVoiceName defaults to null', () {
        check(settings.ttsVoiceName).isNull();
      });

      test('ttsSpeed defaults to the voice\'s own pace', () {
        check(settings.ttsSpeed).equals(1.0);
      });

      test('ttsPitch defaults to 1.0', () {
        check(settings.ttsPitch).equals(1.0);
      });

      test('ttsVolume defaults to 1.0', () {
        check(settings.ttsVolume).equals(1.0);
      });

      test('ttsEngine defaults to device', () {
        check(settings.ttsEngine).equals(TtsEngine.device);
      });

      test('ttsServerVoiceId defaults to null', () {
        check(settings.ttsServerVoiceId).isNull();
      });

      test('ttsServerVoiceName defaults to null', () {
        check(settings.ttsServerVoiceName).isNull();
      });

      test('androidAssistantTrigger defaults to overlay', () {
        check(settings.androidAssistantTrigger)
            .equals(AndroidAssistantTrigger.overlay);
      });

      test('voiceSilenceDuration defaults to 2000', () {
        check(settings.voiceSilenceDuration).equals(2000);
      });

      test('temporaryChatByDefault defaults to false', () {
        check(settings.temporaryChatByDefault).equals(false);
      });
    });

    group('copyWith', () {
      test('returns identical settings when no arguments given', () {
        const original = AppSettings();
        final copy = original.copyWith();
        check(copy).equals(original);
      });

      test('copies non-nullable fields correctly', () {
        const original = AppSettings();
        final modified = original.copyWith(
          reduceMotion: true,
          animationSpeed: 1.5,
          disableHapticsWhileStreaming: true,
          highContrast: true,
          darkMode: false,
          voiceHoldToTalk: true,
          voiceAutoSendFinal: true,
          socketTransportMode: 'polling',
          quickPills: ['web', 'image'],
          pinnedModels: ['gpt-4o', 'claude-sonnet'],
          sendOnEnter: true,
          sttPreference: SttPreference.serverOnly,
          ttsSpeed: 1.25,
          ttsPitch: 1.2,
          ttsVolume: 0.9,
          ttsEngine: TtsEngine.server,
          androidAssistantTrigger: AndroidAssistantTrigger.newChat,
          voiceSilenceDuration: 1500,
          temporaryChatByDefault: true,
        );

        check(modified.reduceMotion).equals(true);
        check(modified.animationSpeed).equals(1.5);
        check(modified.disableHapticsWhileStreaming).equals(true);
        check(modified.highContrast).equals(true);
        check(modified.darkMode).equals(false);
        check(modified.voiceHoldToTalk).equals(true);
        check(modified.voiceAutoSendFinal).equals(true);
        check(modified.socketTransportMode).equals('polling');
        check(modified.quickPills).deepEquals(['web', 'image']);
        check(modified.pinnedModels).deepEquals(['gpt-4o', 'claude-sonnet']);
        check(modified.sendOnEnter).equals(true);
        check(modified.sttPreference).equals(SttPreference.serverOnly);
        check(modified.ttsSpeed).equals(1.25);
        check(modified.ttsPitch).equals(1.2);
        check(modified.ttsVolume).equals(0.9);
        check(modified.ttsEngine).equals(TtsEngine.server);
        check(modified.androidAssistantTrigger)
            .equals(AndroidAssistantTrigger.newChat);
        check(modified.voiceSilenceDuration).equals(1500);
        check(modified.temporaryChatByDefault).equals(true);
      });

      test('can set nullable fields to a value', () {
        const original = AppSettings();
        final modified = original.copyWith(
          defaultModel: 'gpt-4',
          openRouterImageGenerationModel: 'openai/gpt-5-image-mini',
          voiceLocaleId: 'en_US',
          sttLanguageCode: 'pl',
          ttsVoice: 'voice1',
          ttsVoiceName: 'Voice One',
          ttsServerVoiceId: 'server-voice-1',
          ttsServerVoiceName: 'Server Voice',
        );

        check(modified.defaultModel).equals('gpt-4');
        check(modified.openRouterImageGenerationModel)
            .equals('openai/gpt-5-image-mini');
        check(modified.voiceLocaleId).equals('en_US');
        check(modified.sttLanguageCode).equals('pl');
        check(modified.ttsVoice).equals('voice1');
        check(modified.ttsVoiceName).equals('Voice One');
        check(modified.ttsServerVoiceId).equals('server-voice-1');
        check(modified.ttsServerVoiceName).equals('Server Voice');
      });

      test('can set nullable fields back to null', () {
        final original = const AppSettings().copyWith(
          defaultModel: 'gpt-4',
          openRouterImageGenerationModel: 'openai/gpt-5-image-mini',
          voiceLocaleId: 'en_US',
          sttLanguageCode: 'pl',
          ttsVoice: 'voice1',
          ttsVoiceName: 'Voice One',
          ttsServerVoiceId: 'server-voice-1',
          ttsServerVoiceName: 'Server Voice',
        );

        final cleared = original.copyWith(
          defaultModel: null,
          openRouterImageGenerationModel: null,
          voiceLocaleId: null,
          sttLanguageCode: null,
          ttsVoice: null,
          ttsVoiceName: null,
          ttsServerVoiceId: null,
          ttsServerVoiceName: null,
        );

        check(cleared.defaultModel).isNull();
        check(cleared.openRouterImageGenerationModel).isNull();
        check(cleared.voiceLocaleId).isNull();
        check(cleared.sttLanguageCode).isNull();
        check(cleared.ttsVoice).isNull();
        check(cleared.ttsVoiceName).isNull();
        check(cleared.ttsServerVoiceId).isNull();
        check(cleared.ttsServerVoiceName).isNull();
      });

      test('preserves nullable values when not specified', () {
        final original = const AppSettings().copyWith(
          defaultModel: 'gpt-4',
          voiceLocaleId: 'en_US',
          sttLanguageCode: 'pl',
        );

        final copy = original.copyWith(darkMode: false);

        check(copy.defaultModel).equals('gpt-4');
        check(copy.voiceLocaleId).equals('en_US');
        check(copy.sttLanguageCode).equals('pl');
        check(copy.darkMode).equals(false);
      });
    });

    group('equality', () {
      test('instances with same non-default values are equal', () {
        final a = const AppSettings().copyWith(
          darkMode: false,
          defaultModel: 'model-1',
          quickPills: ['web'],
        );
        final b = const AppSettings().copyWith(
          darkMode: false,
          defaultModel: 'model-1',
          quickPills: ['web'],
        );
        check(a).equals(b);
      });

      test('different reduceMotion yields inequality', () {
        const a = AppSettings();
        final b = a.copyWith(reduceMotion: true);
        check(a).not((it) => it.equals(b));
      });

      test('different quickPills yields inequality', () {
        final a = const AppSettings().copyWith(quickPills: ['web']);
        final b = const AppSettings().copyWith(quickPills: ['image']);
        check(a).not((it) => it.equals(b));
      });

      test('different sttLanguageCode yields inequality', () {
        final a = const AppSettings().copyWith(sttLanguageCode: 'pl');
        const b = AppSettings();
        check(a).not((it) => it.equals(b));
      });

      test('different ttsVoiceName yields inequality', () {
        final a = const AppSettings().copyWith(ttsVoiceName: 'Voice One');
        const b = AppSettings();
        check(a).not((it) => it.equals(b));
      });

      test('quickPills order matters', () {
        final a = const AppSettings().copyWith(quickPills: ['web', 'image']);
        final b = const AppSettings().copyWith(quickPills: ['image', 'web']);
        check(a).not((it) => it.equals(b));
      });

      test('pinnedModels order matters', () {
        final a = const AppSettings().copyWith(
          pinnedModels: ['gpt-4o', 'claude-sonnet'],
        );
        final b = const AppSettings().copyWith(
          pinnedModels: ['claude-sonnet', 'gpt-4o'],
        );
        check(a).not((it) => it.equals(b));
      });

      test('socketTransportMode is excluded from equality', () {
        final a = const AppSettings().copyWith(socketTransportMode: 'ws');
        final b = const AppSettings().copyWith(socketTransportMode: 'polling');
        // socketTransportMode is intentionally not in ==
        check(a).equals(b);
      });

      test('not equal to a non-AppSettings object', () {
        const a = AppSettings();
        // ignore: unrelated_type_equality_checks
        check(a == 'not an AppSettings').equals(false);
      });
    });

    group('hashCode', () {
      test('copies with same values have same hashCode', () {
        final a = const AppSettings().copyWith(
          darkMode: false,
          defaultModel: 'model-1',
        );
        final b = const AppSettings().copyWith(
          darkMode: false,
          defaultModel: 'model-1',
        );
        check(a.hashCode).equals(b.hashCode);
      });

      test('socketTransportMode is excluded from hashCode', () {
        final a = const AppSettings().copyWith(socketTransportMode: 'ws');
        final b = const AppSettings().copyWith(socketTransportMode: 'polling');
        check(a).equals(b);
        check(a.hashCode).equals(b.hashCode);
      });
    });
  });

  group('SettingsService.normalizeVoiceLocaleId', () {
    test('uses null for native automatic language detection', () {
      check(SettingsService.normalizeVoiceLocaleId(null)).isNull();
      check(SettingsService.normalizeVoiceLocaleId('')).isNull();
      check(SettingsService.normalizeVoiceLocaleId('auto')).isNull();
    });

    test('uses a distinct sentinel for the Android system language', () {
      check(SettingsService.normalizeVoiceLocaleId('system'))
          .equals(SettingsService.voiceLocaleSystemDefault);
      check(SettingsService.normalizeVoiceLocaleId('default'))
          .equals(SettingsService.voiceLocaleSystemDefault);
      check(
        SettingsService.normalizeVoiceLocaleId(
          SettingsService.voiceLocaleSystemDefault,
        ),
      ).equals(SettingsService.voiceLocaleSystemDefault);
    });

    test('preserves and canonicalizes full locale tags', () {
      check(SettingsService.normalizeVoiceLocaleId('PL_pl')).equals('pl-PL');
      check(SettingsService.normalizeVoiceLocaleId('zh_hant_tw'))
          .equals('zh-Hant-TW');
      check(SettingsService.normalizeVoiceLocaleId('es-419')).equals('es-419');
    });

    test('rejects invalid custom locale tags', () {
      check(SettingsService.normalizeVoiceLocaleId('p')).isNull();
      check(SettingsService.normalizeVoiceLocaleId('pl--PL')).isNull();
      check(SettingsService.normalizeVoiceLocaleId('Polish language')).isNull();
    });

    test('is independent from the server STT language normalization', () {
      check(SettingsService.normalizeVoiceLocaleId('pl-PL')).equals('pl-PL');
      check(SettingsService.normalizeSttLanguageCode('pl-PL')).equals('pl');
    });
  });

  group('SettingsService voice locale persistence', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
    });

    tearDown(PreferencesStore.debugReset);

    test(
      'round-trips explicit and system selections and clears auto',
      () async {
        await SettingsService.setVoiceLocaleId('pl_PL');
        check(await SettingsService.getVoiceLocaleId()).equals('pl-PL');
        check(PreferencesStore.getString(PreferenceKeys.voiceLocaleId))
            .equals('pl-PL');

        await SettingsService.setVoiceLocaleId('system');
        check(await SettingsService.getVoiceLocaleId())
            .equals(SettingsService.voiceLocaleSystemDefault);

        await SettingsService.setVoiceLocaleId(null);
        check(await SettingsService.getVoiceLocaleId()).isNull();
        check(PreferencesStore.containsKey(PreferenceKeys.voiceLocaleId))
            .isFalse();
      },
    );
  });

  group('SettingsService speech speed persistence', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
    });

    tearDown(PreferencesStore.debugReset);

    // An older install saved the device engine's rate, where 0.5 was the
    // voice's own pace; it carries over as the nearest speed offered.
    for (final (rate, speed) in [
      (null, 1.0),
      (0.5, 1.0),
      (0.6, 1.25),
      (0.25, 0.75),
      (2.0, 2.0),
    ]) {
      test('a saved rate of $rate loads as ${speed}x', () async {
        if (rate != null) {
          await PreferencesStore.put(PreferenceKeys.ttsSpeechRate, rate);
        }
        check((await SettingsService.loadSettings()).ttsSpeed).equals(speed);
      });
    }

    test('a saved speed wins over an older rate and round-trips', () async {
      await PreferencesStore.put(PreferenceKeys.ttsSpeechRate, 0.9);
      await SettingsService.saveSettings(const AppSettings(ttsSpeed: 0.75));
      check((await SettingsService.loadSettings()).ttsSpeed).equals(0.75);
    });
  });

  group('SettingsService OpenRouter image model persistence', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
    });

    tearDown(PreferencesStore.debugReset);

    test('trims, round-trips, and clears the model id', () async {
      await SettingsService.setOpenRouterImageGenerationModel(
        '  openai/gpt-5-image-mini  ',
      );
      check(
        (await SettingsService.loadSettings()).openRouterImageGenerationModel,
      ).equals('openai/gpt-5-image-mini');

      await SettingsService.setOpenRouterImageGenerationModel('   ');
      check(
        PreferencesStore.containsKey(
          PreferenceKeys.openRouterImageGenerationModel,
        ),
      ).isFalse();
    });
  });

  group('AppSettingsNotifier OpenRouter image model startup writes', () {
    setUp(() {
      PreferencesStore.debugReset();
      SharedPreferences.setMockInitialValues(<String, Object>{
        PreferenceKeys.openRouterImageGenerationModel: 'openai/gpt-5-image',
      });
    });

    tearDown(PreferencesStore.debugReset);

    test('waits for hydration before applying a new model id', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      check(container.read(appSettingsProvider).openRouterImageGenerationModel)
          .isNull();

      await container
          .read(appSettingsProvider.notifier)
          .setOpenRouterImageGenerationModel('openai/gpt-5-image-mini');

      check(container.read(appSettingsProvider).openRouterImageGenerationModel)
          .equals('openai/gpt-5-image-mini');
      check(
        PreferencesStore.getString(
          PreferenceKeys.openRouterImageGenerationModel,
        ),
      ).equals('openai/gpt-5-image-mini');
    });
  });

  group('AppSettingsNotifier web search preferences', () {
    setUp(() {
      PreferencesStore.debugReset();
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    tearDown(PreferencesStore.debugReset);

    test('persist across reloads, and Auto region clears the code', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(appSettingsProvider.notifier);

      await notifier.setWebSearchEngine(WebSearchEngineChoice.brave);
      await notifier.setWebSearchSafeSearch(SafeSearch.strict);
      await notifier.setWebSearchRegion('de-de');

      final reloaded = await SettingsService.loadSettings();
      check(reloaded.webSearchEngine).equals(WebSearchEngineChoice.brave);
      check(reloaded.webSearchSafeSearch).equals(SafeSearch.strict);
      check(reloaded.webSearchRegion).equals('de-de');

      await notifier.setWebSearchRegion(kWebSearchRegionAuto);
      check(PreferencesStore.containsKey(PreferenceKeys.webSearchRegion))
          .isFalse();
      check((await SettingsService.loadSettings()).webSearchRegion).isNull();
    });
  });

  group('AppSettingsNotifier advanced features preference', () {
    setUp(() {
      PreferencesStore.debugReset();
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    tearDown(PreferencesStore.debugReset);

    test('starts off, survives a restart even when enabled before hydration, '
        'and reset turns it off', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      check(container.read(appSettingsProvider).advancedFeaturesEnabled)
          .isFalse();

      await container
          .read(appSettingsProvider.notifier)
          .setAdvancedFeaturesEnabled(true);
      check(container.read(appSettingsProvider).advancedFeaturesEnabled)
          .isTrue();

      final restarted = ProviderContainer();
      addTearDown(restarted.dispose);
      check(restarted.read(appSettingsProvider).advancedFeaturesEnabled)
          .isTrue();

      await restarted.read(appSettingsProvider.notifier).resetToDefaults();
      final afterReset = ProviderContainer();
      addTearDown(afterReset.dispose);
      check(afterReset.read(appSettingsProvider).advancedFeaturesEnabled)
          .isFalse();
    });
  });

  group('Computer preference', () {
    setUp(() {
      PreferencesStore.debugReset();
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });
    tearDown(PreferencesStore.debugReset);

    test(
      'disable survives restart and bulk save; reset restores default',
      () async {
        const defaults = AppSettings();
        check(defaults.computerEnabled).isTrue();
        check(defaults.copyWith(computerEnabled: false))
            .not((it) => it.equals(defaults));
        final container = ProviderContainer();
        addTearDown(container.dispose);
        await container
            .read(appSettingsProvider.notifier)
            .setComputerEnabled(false);
        check(container.read(appSettingsProvider).computerEnabled).isFalse();
        final preferences = await SharedPreferences.getInstance();
        await preferences.reload();
        final saved = <String, Object>{
          for (final key in preferences.getKeys()) key: preferences.get(key)!,
        };
        SharedPreferences.setMockInitialValues(saved);
        PreferencesStore.debugReset();
        PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
        final restarted = ProviderContainer();
        addTearDown(restarted.dispose);
        check(restarted.read(appSettingsProvider).computerEnabled).isFalse();
        await SettingsService.saveSettings(const AppSettings());
        check((await SettingsService.loadSettings()).computerEnabled).isFalse();
        await restarted.read(appSettingsProvider.notifier).resetToDefaults();
        check((await SettingsService.loadSettings()).computerEnabled).isTrue();
      },
    );
  });

  group('Citation background preference', () {
    setUp(() {
      PreferencesStore.debugReset();
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    tearDown(PreferencesStore.debugReset);

    test('defaults to filled and participates in settings equality', () {
      const defaults = AppSettings();
      final transparent = defaults.copyWith(citationBackground: false);
      check(defaults.citationBackground).isTrue();
      check(transparent.citationBackground).isFalse();
      check(transparent).not((it) => it.equals(defaults));
      check(transparent.copyWith()).equals(transparent);
    });

    test(
      'transparent survives restart and bulk save; reset restores filled',
      () async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        await container
            .read(appSettingsProvider.notifier)
            .setCitationBackground(false);
        check(container.read(appSettingsProvider).citationBackground).isFalse();

        // Reload the persisted mock values into a fresh host store.
        final preferences = await SharedPreferences.getInstance();
        await preferences.reload();
        final saved = <String, Object>{
          for (final key in preferences.getKeys()) key: preferences.get(key)!,
        };
        SharedPreferences.setMockInitialValues(saved);
        PreferencesStore.debugReset();
        PreferencesStore.debugOverride(await FlutterKeyValueStore.load());

        final restarted = ProviderContainer();
        addTearDown(restarted.dispose);
        check(restarted.read(appSettingsProvider).citationBackground).isFalse();
        // A stale unrelated settings save must not reset the local appearance.
        await SettingsService.saveSettings(const AppSettings());
        check((await SettingsService.loadSettings()).citationBackground)
            .isFalse();

        await restarted.read(appSettingsProvider.notifier).resetToDefaults();
        final afterReset = ProviderContainer();
        addTearDown(afterReset.dispose);
        check(afterReset.read(appSettingsProvider).citationBackground).isTrue();
      },
    );
  });

  group('AppSettingsNotifier Voice provider', () {
    setUp(() {
      PreferencesStore.debugReset();
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    tearDown(PreferencesStore.debugReset);

    test('survives a restart, and reset clears it for good', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container
          .read(appSettingsProvider.notifier)
          .setDirectVoiceProvider(
            const DirectVoiceProviderSettings(profileId: 'voice'),
          );

      final restarted = ProviderContainer();
      addTearDown(restarted.dispose);
      check(restarted.read(appSettingsProvider).directVoiceProvider?.profileId)
          .equals('voice');

      await restarted.read(appSettingsProvider.notifier).resetToDefaults();
      final afterReset = ProviderContainer();
      addTearDown(afterReset.dispose);
      check(afterReset.read(appSettingsProvider).directVoiceProvider).isNull();
    });
  });

  group('SettingsService.normalizeSttLanguageCode', () {
    test('normalizes two-letter language codes', () {
      check(SettingsService.normalizeSttLanguageCode('PL')).equals('pl');
      check(SettingsService.normalizeSttLanguageCode('pl-PL')).equals('pl');
      check(SettingsService.normalizeSttLanguageCode('en_US')).equals('en');
    });

    test('treats auto-like and blank values as no pinned language', () {
      check(SettingsService.normalizeSttLanguageCode(null)).isNull();
      check(SettingsService.normalizeSttLanguageCode('')).isNull();
      check(SettingsService.normalizeSttLanguageCode('auto')).isNull();
      check(SettingsService.normalizeSttLanguageCode('system')).isNull();
    });

    test('distinguishes auto-like values from invalid language codes', () {
      check(SettingsService.isSttLanguageAutoInput(null)).isTrue();
      check(SettingsService.isSttLanguageAutoInput('auto')).isTrue();
      check(SettingsService.isSttLanguageAutoInput('default')).isTrue();
      check(SettingsService.isSttLanguageAutoInput('eng')).isFalse();
      check(SettingsService.isSttLanguageAutoInput('polish')).isFalse();
    });

    test('rejects non ISO-639-1 values', () {
      check(SettingsService.normalizeSttLanguageCode('polish')).isNull();
      check(SettingsService.normalizeSttLanguageCode('p')).isNull();
      check(SettingsService.normalizeSttLanguageCode('eng')).isNull();
    });
  });

  group('Pinned models', () {
    test(
      'sanitizes blanks and duplicates while preserving first-seen order',
      () {
        final sanitized = SettingsService.sanitizePinnedModels([
          'gpt-4o',
          '',
          'claude-sonnet',
          'gpt-4o',
          ' claude-sonnet ',
          '   ',
        ]);

        check(sanitized).deepEquals(['gpt-4o', 'claude-sonnet']);
      },
    );
  });

  group('AndroidAssistantTriggerStorage', () {
    test('overlay storageValue is "overlay"', () {
      check(AndroidAssistantTrigger.overlay.storageValue).equals('overlay');
    });

    test('newChat storageValue is "new_chat"', () {
      check(AndroidAssistantTrigger.newChat.storageValue).equals('new_chat');
    });

    test('voiceCall storageValue is "voice_call"', () {
      check(AndroidAssistantTrigger.voiceCall.storageValue)
          .equals('voice_call');
    });
  });
  group('message action preferences', () {
    setUp(() {
      PreferencesStore.debugReset();
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });
    tearDown(PreferencesStore.debugReset);

    test('custom actions and empty choices survive restart; reset restores defaults', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(appSettingsProvider.notifier);
      await notifier.setInlineMessageActions(['share', 'usage', 'share']);
      expect((await SettingsService.loadSettings()).inlineMessageActions, [
        'share',
        'usage',
      ]);
      final restarted = ProviderContainer();
      addTearDown(restarted.dispose);
      expect(restarted.read(appSettingsProvider).inlineMessageActions, [
        'share',
        'usage',
      ]);
      await notifier.setInlineMessageActions([]);
      expect(
        (await SettingsService.loadSettings()).inlineMessageActions,
        isEmpty,
      );
      await notifier.setInlineMessageActions(null);
      expect(
        (await SettingsService.loadSettings()).inlineMessageActions,
        isNull,
      );
      expect(
        PreferencesStore.containsKey(PreferenceKeys.inlineMessageActions),
        isFalse,
      );
    });

    test('bulk settings saves preserve independently saved actions', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(appSettingsProvider.notifier);
      final stale = container.read(appSettingsProvider);
      await notifier.setInlineMessageActions(['share']);
      await SettingsService.saveSettings(stale.copyWith(ttsSpeed: 1.5));
      expect((await SettingsService.loadSettings()).inlineMessageActions, [
        'share',
      ]);
      await notifier.resetToDefaults();
      expect(
        (await SettingsService.loadSettings()).inlineMessageActions,
        isNull,
      );
    });

    test('copy and equality distinguish defaults from an empty selection', () {
      const defaults = AppSettings();
      final empty = defaults.copyWith(inlineMessageActions: <String>[]);
      expect(empty, isNot(defaults));
      expect(empty.copyWith(darkMode: false).inlineMessageActions, isEmpty);
      expect(empty.copyWith(inlineMessageActions: null), defaults);
      expect(
        defaults.copyWith(inlineMessageActions: ['share']),
        defaults.copyWith(inlineMessageActions: ['share']),
      );
    });
  });
}
