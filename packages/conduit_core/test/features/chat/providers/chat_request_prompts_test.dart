import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/models/model.dart';
import 'package:test/test.dart';

void main() {
  group('the texts a request fills {{USER_LOCATION}} into', () {
    test('are its system messages and each model\'s own prompt', () {
      final prompts = openWebUiRequestPromptsForTest(
        const <Map<String, dynamic>>[
          <String, dynamic>{
            'role': 'system',
            'content': 'Answer for someone near {{USER_LOCATION}}.',
          },
          <String, dynamic>{'role': 'user', 'content': 'Where am I?'},
          <String, dynamic>{
            'role': 'system',
            'content': <Map<String, dynamic>>[
              <String, dynamic>{'type': 'text', 'text': 'Be brief.'},
            ],
          },
        ],
        models: const <Model?>[
          Model(
            id: 'guide',
            name: 'Harbour Guide',
            metadata: <String, dynamic>{
              'info': <String, dynamic>{
                'params': <String, dynamic>{
                  'system': 'Tides near {{USER_LOCATION}}.',
                },
              },
            },
          ),
          Model(id: 'plain', name: 'Plain'),
          null,
        ],
      );

      check(prompts).deepEquals(<String?>[
        'Answer for someone near {{USER_LOCATION}}.',
        'Be brief.',
        'Tides near {{USER_LOCATION}}.',
        null,
        null,
      ]);
    });

    test('leave the user\'s own words out', () {
      final prompts = openWebUiRequestPromptsForTest(
        const <Map<String, dynamic>>[
          <String, dynamic>{
            'role': 'user',
            'content': 'What is {{USER_LOCATION}}?',
          },
        ],
      );

      check(prompts).isEmpty();
    });
  });
}
