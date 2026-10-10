import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/server_speech/direct_voice_provider_settings.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/core/utils/native_sheet_utils.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit/l10n/app_localizations_de.dart';
import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:conduit/l10n/app_localizations_ja.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final l10n = AppLocalizationsEn();

  test('the native About page links the open source licenses', () {
    final items = buildNativeAboutItems(
      l10n,
      appVersion: '4.1.8 (149)',
      serverName: 'Open WebUI',
      serverVersion: '0.11.4',
    );

    final licenses = items.singleWhere(
      (item) => item.id == NativeSheetRoutes.openSourceLicenses,
    );
    check(licenses.title).equals('Open source licenses');
    check(items.map((item) => item.id)).contains('server-version');
  });

  test('the Hermes-only About page has no server rows', () {
    final ids = buildNativeAboutItems(
      l10n,
      appVersion: '4.1.8',
    ).map((item) => item.id);

    check(ids).not((it) => it.contains('server-name'));
    check(ids).contains(NativeSheetRoutes.openSourceLicenses);
  });

  test('native Settings titles follow the app language', () {
    final de = AppLocalizationsDe();
    check(nativeSettingsTitle(de)).equals('Einstellungen');
    check(nativeProfileTitle(de)).equals('Profil');
    check(nativeAiMemoryTitle(de)).equals('KI und Erinnerung');

    final ja = AppLocalizationsJa();
    check(nativeSettingsTitle(ja)).equals('設定');
    check(nativeChatsTitle(ja)).equals('チャット');
    check(nativeAiMemoryTitle(ja)).equals('AIとメモリ');

    check(nativeSettingsTitle(l10n)).equals('Settings');
  });

  test('OpenRouter image model item is exposed for the native Chats sheet', () {
    final item = buildNativeOpenRouterImageGenerationModelItem(
      l10n,
      models: const [
        Model(
          id: 'direct:openrouter:model',
          name: 'OpenRouter model',
          capabilities: {'openrouter': true, 'image_generation': true},
        ),
      ],
      selectedModelId: 'openai/gpt-5-image-mini',
    );

    check(item).isNotNull();
    check(item!.id).equals('default-image-generation-model');
    check(item.subtitle).equals('openai/gpt-5-image-mini');
  });

  test('native image model item stays hidden without the OpenRouter tool', () {
    final item = buildNativeOpenRouterImageGenerationModelItem(
      l10n,
      models: const [
        Model(
          id: 'openwebui:model',
          name: 'OpenWebUI model',
          capabilities: {'openrouter': false, 'image_generation': true},
        ),
      ],
      selectedModelId: null,
    );

    check(item).isNull();
  });

  test('native barge-in toggle is off by default', () {
    final parts = buildNativeAudioSheetParts(l10n, const AppSettings());
    final bargeIn = parts.mainSections.first.items.singleWhere(
      (item) => item.id == 'voice-barge-in',
    );

    check(bargeIn.kind).equals(NativeSheetItemKind.toggle);
    check(bargeIn.title).equals(l10n.voiceBargeIn);
    check(bargeIn.subtitle).equals(l10n.voiceBargeInDescription);
    check(bargeIn.value).equals(false);
  });

  for (final stt in SttPreference.values) {
    for (final tts in TtsEngine.values) {
      for (final enabled in [false, true]) {
        test('native barge-in reflects $enabled with $stt and $tts', () {
          final parts = buildNativeAudioSheetParts(
            l10n,
            AppSettings(
              sttPreference: stt,
              ttsEngine: tts,
              voiceBargeInEnabled: enabled,
            ),
          );
          final bargeIn = parts.mainSections
              .expand((section) => section.items)
              .singleWhere((item) => item.id == 'voice-barge-in');

          check(bargeIn.kind).equals(NativeSheetItemKind.toggle);
          check(bargeIn.value).equals(enabled);
        });
      }
    }
  }

  group('native Voice provider', () {
    final openAi = DirectConnectionProfile(
      id: 'voice',
      name: 'OpenAI',
      adapterKey: kOpenAiCompatibleAdapterKey,
      baseUrl: 'https://api.openai.com/v1',
    );

    Iterable<NativeSheetItemConfig> items(NativeSheetDetailConfig detail) =>
        detail.sections.expand((section) => section.items);

    test('shows its model fields only once a connection is chosen', () {
      final none = buildNativeAudioSheetParts(
        l10n,
        const AppSettings(),
        voiceProviderCandidates: [openAi],
      );
      check(
        items(none.voiceProviderDetail).map((item) => item.id),
      ).deepEquals(['voice-provider-connection']);

      final chosen = buildNativeAudioSheetParts(
        l10n,
        AppSettings(
          directVoiceProvider: DirectVoiceProviderSettings.forConnection(
            openAi,
          ),
        ),
        voiceProviderCandidates: [openAi],
      );
      final fields = {
        for (final item in items(chosen.voiceProviderDetail))
          item.id: item.value,
      };
      check(fields).deepEquals({
        'voice-provider-connection': 'voice',
        'voice-provider-transcription-model': 'whisper-1',
        'voice-provider-speech-model': 'tts-1',
        'voice-provider-speech-voice': 'alloy',
      });
      check(
        nativeVoiceProviderFieldIds.keys.toSet(),
      ).deepEquals(fields.keys.toSet()..remove('voice-provider-connection'));
    });

    test('a removed connection reads as none', () {
      final parts = buildNativeAudioSheetParts(
        l10n,
        const AppSettings(
          directVoiceProvider: DirectVoiceProviderSettings(profileId: 'gone'),
        ),
        voiceProviderCandidates: [openAi],
      );

      final row = parts.mainSections
          .expand((section) => section.items)
          .singleWhere((item) => item.id == NativeSheetRoutes.voiceProvider);
      check(row.subtitle).equals(l10n.voiceProviderNone);
      check(
        items(parts.voiceProviderDetail).map((item) => item.id),
      ).deepEquals(['voice-provider-connection']);
    });

    test('server voices are offered only where the backend lists them', () {
      bool offersPicker({required bool serverOffersVoiceChoice}) =>
          buildNativeAudioSheetParts(
                l10n,
                const AppSettings(ttsEngine: TtsEngine.server),
                serverOffersVoiceChoice: serverOffersVoiceChoice,
              ).mainSections
              .expand((section) => section.items)
              .any((item) => item.id == 'tts-voice-picker');

      check(offersPicker(serverOffersVoiceChoice: true)).isTrue();
      check(offersPicker(serverOffersVoiceChoice: false)).isFalse();
    });
  });

  test('native speech-rate slider shows its value only once', () {
    final parts = buildNativeAudioSheetParts(l10n, const AppSettings());
    final speechRate = parts.mainSections
        .expand((section) => section.items)
        .singleWhere((item) => item.id == 'tts-speech-rate');

    check(speechRate.subtitle).isNull();
  });
}
