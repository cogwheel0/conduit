@TestOn('vm')
library;

import 'package:conduit_desktop_ui/src/l10n/strings.g.dart';
import 'package:conduit_desktop_ui/src/prompt_trigger.dart';
import 'package:conduit_desktop_ui/src/widgets/prompt_menu.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart' show button;
import 'package:jaspr_test/jaspr_test.dart';

void main() {
  group('slashTriggerIn', () {
    test('a command at the start of the text', () {
      final trigger = slashTriggerIn('/Sum')!;
      expect(trigger.start, 0);
      expect(trigger.query, 'sum');
    });

    test('a command after other words keeps them', () {
      final trigger = slashTriggerIn('Please /sum')!;
      expect(trigger.start, 7);
      expect(trigger.query, 'sum');
    });

    test('a bare slash opens the menu', () {
      expect(slashTriggerIn('/')?.query, '');
    });

    test('a path or a fraction is not a command', () {
      expect(slashTriggerIn('open src/main'), isNull);
      expect(slashTriggerIn('about 1/2'), isNull);
      expect(slashTriggerIn('/usr/bin'), isNull);
    });

    test('only at the end: a finished command is not reopened', () {
      expect(slashTriggerIn('/sum this'), isNull);
    });
  });

  group('mentions', () {
    test('a # at the start of a word, but not a heading', () {
      expect(knowledgeTriggerIn('use #hand')?.query, 'hand');
      // "# " is a markdown heading being typed: the space ends the token.
      expect(knowledgeTriggerIn('# Title'), isNull);
    });

    test('an @ at the start of a word', () {
      expect(mentionTriggerIn('ask @gpt')?.query, 'gpt');
      expect(mentionTriggerIn('mail me@example.com'), isNull);
    });

    test('models by name or id, the ones that start with it first', () {
      const models = <ModelSummary>[
        ModelSummary(id: 'llama3:8b', name: 'Llama 3'),
        ModelSummary(id: 'gemma3:1b', name: 'Gemma 3'),
        ModelSummary(id: 'my-gemma-tune', name: 'Tuned'),
      ];
      expect(matchModels('gem', models).map((m) => m.id), <String>[
        'gemma3:1b',
        'my-gemma-tune',
      ]);
    });
  });

  group('matchPrompts', () {
    const prompts = <PromptSummary>[
      PromptSummary(command: '/review', title: 'Summarize a review'),
      PromptSummary(command: '/summarize', title: 'Summary'),
      PromptSummary(command: '/standup', title: 'Stand-up'),
    ];

    test('commands that start with the query come first', () {
      expect(matchPrompts('sum', prompts).map((p) => p.command), <String>[
        '/summarize',
        '/review',
      ]);
    });

    test('an empty query lists them all', () {
      expect(matchPrompts('', prompts), hasLength(3));
    });
  });

  group('PromptInputsForm', () {
    testComponents('Insert waits for required fields', (tester) async {
      Map<String, String>? submitted;
      tester.pumpComponent(
        PromptInputsForm(
          title: 'Stand-up',
          inputs: const <PromptInput>[
            PromptInput(name: 'team', label: 'Team', required: true),
            PromptInput(name: 'note', label: 'Note', defaultValue: 'none'),
          ],
          onSubmit: (values) => submitted = values,
          onCancel: () {},
        ),
      );
      await pumpEventQueue();
      expect(
        find.text(t.desktop.desktopPromptFill(title: 'Stand-up')),
        findsOneComponent,
      );
      // Disabled: clicking does nothing.
      await tester.click(
        find.componentWithText(button, t.desktop.desktopPromptInsert),
      );
      expect(submitted, isNull);
    });

    testComponents('a select starts on its first option', (tester) async {
      Map<String, String>? submitted;
      tester.pumpComponent(
        PromptInputsForm(
          title: 'Stand-up',
          inputs: const <PromptInput>[
            PromptInput(
              name: 'team',
              label: 'Team',
              type: 'select',
              required: true,
              options: <String>['Platform', 'Mobile'],
            ),
          ],
          onSubmit: (values) => submitted = values,
          onCancel: () {},
        ),
      );
      await pumpEventQueue();
      await tester.click(
        find.componentWithText(button, t.desktop.desktopPromptInsert),
      );
      expect(submitted, <String, String>{'team': 'Platform'});
    });
  });
}
