import 'package:checks/checks.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/utils/native_sheet_utils.dart';
import 'package:conduit/core/services/settings_service.dart';
import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final l10n = AppLocalizationsEn();

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

  test('native speech-rate slider shows its value only once', () {
    final parts = buildNativeAudioSheetParts(l10n, const AppSettings());
    final speechRate = parts.mainItems.singleWhere(
      (item) => item.id == 'tts-speech-rate',
    );

    check(speechRate.subtitle).isNull();
  });
}
