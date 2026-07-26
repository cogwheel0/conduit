import 'package:checks/checks.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/services/settings_service.dart';
import 'package:conduit/core/sherpa/sherpa_catalog.dart';
import 'package:conduit/core/sherpa/sherpa_model.dart';
import 'package:conduit/core/utils/native_sheet_utils.dart';
import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final l10n = AppLocalizationsEn();

  test('native Sherpa manager row is actionable and shows storage', () {
    final parts = buildNativeAudioSheetParts(
      l10n,
      const AppSettings(),
      installedModelCount: 2,
      installedModelBytes: 1572864,
    );

    final manager = parts.mainItems.firstWhere(
      (item) => item.id == 'sherpa-models',
    );
    check(manager.dismissOnSelect).isTrue();
    check(manager.subtitle).equals('2 installed • 1.5 MB');
  });

  test('native Sherpa manager keeps generic copy when inventory fails', () {
    final parts = buildNativeAudioSheetParts(
      l10n,
      const AppSettings(),
      installedModelCount: null,
    );

    final manager = parts.mainItems.firstWhere(
      (item) => item.id == 'sherpa-models',
    );
    check(manager.subtitle).equals(l10n.sherpaModelsSubtitle);
  });

  test('native Sherpa engines expose the selected model choosers', () {
    final stt = sherpaModelCatalog.firstWhere(
      (model) => model.kind == SherpaModelKind.stt,
    );
    final tts = sherpaModelCatalog.firstWhere(
      (model) => model.kind == SherpaModelKind.tts,
    );
    final parts = buildNativeAudioSheetParts(
      l10n,
      AppSettings(
        sttPreference: SttPreference.sherpa,
        ttsEngine: TtsEngine.sherpa,
        sherpaSttModelId: stt.id,
        sherpaTtsModelId: tts.id,
      ),
    );

    final sttChooser = parts.mainItems.firstWhere(
      (item) => item.id == 'sherpa-stt-model',
    );
    final ttsChooser = parts.mainItems.firstWhere(
      (item) => item.id == 'sherpa-tts-model',
    );
    check(sttChooser.subtitle).equals(stt.displayName);
    check(sttChooser.dismissOnSelect).isTrue();
    check(ttsChooser.subtitle).equals(tts.displayName);
    check(ttsChooser.dismissOnSelect).isTrue();
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
}
