import 'package:checks/checks.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/services/settings_service.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolveChatFeatureDefaultsForTest', () {
    test('prefers local app overrides over server and model defaults', () {
      final defaults = resolveChatFeatureDefaultsForTest(
        appSettings: const AppSettings(
          chatWebSearchEnabled: false,
          chatImageGenerationEnabled: true,
        ),
        userSettings: const {
          'ui': {'webSearch': 'always', 'imageGeneration': 'always'},
        },
        model: const Model(
          id: 'default-tools',
          name: 'Default Tools',
          metadata: {
            'meta': {
              'defaultFeatureIds': ['web_search', 'image_generation'],
            },
          },
        ),
      );

      check(defaults.webSearchEnabled).isFalse();
      check(defaults.imageGenerationEnabled).isTrue();
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
