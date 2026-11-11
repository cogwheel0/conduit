import 'package:checks/checks.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:test/test.dart';

void main() {
  group('resolveChatFeatureDefaultsForTest', () {
    test('a choice stored for every chat by earlier builds no longer '
        'overrides the account\'s and the model\'s defaults', () {
      final defaults = resolveChatFeatureDefaultsForTest(
        appSettings: const AppSettings(
          chatWebSearchEnabled: false,
          chatImageGenerationEnabled: true,
        ),
        userSettings: const {
          'ui': {'webSearch': 'always'},
        },
        model: const Model(id: 'plain', name: 'Plain'),
      );

      check(defaults.webSearchEnabled).isTrue();
      check(defaults.imageGenerationEnabled).isFalse();
    });

    test('uses OpenWebUI always-on defaults when no local override exists', () {
      final defaults = resolveChatFeatureDefaultsForTest(
        appSettings: const AppSettings(),
        userSettings: const {
          'ui': {'webSearch': 'always', 'imageGeneration': 'always'},
        },
      );

      check(defaults.webSearchEnabled).isTrue();
      check(defaults.imageGenerationEnabled).isTrue();
    });

    test('falls back to model default features when available', () {
      final defaults = resolveChatFeatureDefaultsForTest(
        appSettings: const AppSettings(),
        model: const Model(
          id: 'model-defaults',
          name: 'Model Defaults',
          metadata: {
            'info': {
              'meta': {
                'defaultFeatureIds': ['web_search', 'image_generation'],
              },
            },
          },
        ),
      );

      check(defaults.webSearchEnabled).isTrue();
      check(defaults.imageGenerationEnabled).isTrue();
    });

    test('supports legacy root-level feature flags', () {
      final defaults = resolveChatFeatureDefaultsForTest(
        appSettings: const AppSettings(),
        userSettings: const {
          'webSearchEnabled': true,
          'imageGenerationEnabled': true,
        },
      );

      check(defaults.webSearchEnabled).isTrue();
      check(defaults.imageGenerationEnabled).isTrue();
    });
  });
}
