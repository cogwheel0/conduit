import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

const _guide = Model(
  id: 'guide',
  name: 'Harbour Guide',
  metadata: <String, dynamic>{
    'info': <String, dynamic>{
      'params': <String, dynamic>{'system': 'Tides near {{USER_LOCATION}}.'},
    },
  },
);

const _plain = Model(id: 'plain', name: 'Plain');

final class _Listed extends Models {
  @override
  Future<List<Model>> build() async => const <Model>[_guide, _plain];
}

void main() {
  group('the texts a request fills {{USER_LOCATION}} into', () {
    test('are its system messages and each model\'s own prompt, never the '
        'user\'s words', () {
      final prompts = openWebUiRequestPromptsForTest(
        const <Map<String, dynamic>>[
          <String, dynamic>{
            'role': 'system',
            'content': 'Answer for someone near {{USER_LOCATION}}.',
          },
          <String, dynamic>{
            'role': 'user',
            'content': 'What is {{USER_LOCATION}}?',
          },
          <String, dynamic>{
            'role': 'system',
            'content': <Map<String, dynamic>>[
              <String, dynamic>{'type': 'text', 'text': 'Be brief.'},
            ],
          },
        ],
        models: const <Model?>[_guide, _plain, null],
      );

      check(prompts).deepEquals(<String?>[
        'Answer for someone near {{USER_LOCATION}}.',
        'Be brief.',
        'Tides near {{USER_LOCATION}}.',
        null,
        null,
      ]);
    });

    test('come from the model the request goes to, not the one picked',
        () async {
      final container = ProviderContainer(
        overrides: [modelsProvider.overrideWith(_Listed.new)],
      );
      addTearDown(container.dispose);
      await container.read(modelsProvider.future);

      check(
        openWebUiRequestModelForTest(container, 'guide', selected: _plain),
      ).identicalTo(_guide);
      check(
        openWebUiRequestModelForTest(container, 'plain', selected: _plain),
      ).identicalTo(_plain);
      check(
        openWebUiRequestModelForTest(container, 'gone', selected: _plain),
      ).isNull();
    });
  });
}
