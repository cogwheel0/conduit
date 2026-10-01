import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/composer/openwebui_prompt_answers.dart';
import 'package:conduit_core/features/chat/providers/openwebui_prompt_resolution.dart';
import 'package:conduit_core/models/openwebui_chat_prompt.dart';
import 'package:test/test.dart';

const _pick = OpenWebUiPromptQuestion(
  id: 'q1',
  header: 'Pick',
  question: 'Which?',
  options: [
    OpenWebUiPromptOption(label: 'A', description: 'first'),
    OpenWebUiPromptOption(label: 'B', description: 'second'),
  ],
  allowOther: false,
);

const _free = OpenWebUiPromptQuestion(
  id: 'q2',
  header: 'Why',
  question: 'Explain',
  options: [],
  allowOther: true,
);

const _ask = OpenWebUiComposerPrompt(
  identity: 'p1',
  kind: OpenWebUiComposerPromptKind.askUser,
  questions: [_pick, _free],
);

void main() {
  group('OpenWebUiPromptAnswers', () {
    test('walks the questions and completes with every answer', () {
      final answers = OpenWebUiPromptAnswers(_ask);
      check(answers.question).equals(_pick);
      check(answers.progressLabel).equals('1/2');
      check(answers.canGoNext).isFalse();
      check(answers.complete).isFalse();

      answers.selectOption(_pick, _pick.options[1], 1);
      check(answers.isOptionSelected('q1', 1)).isTrue();
      check(answers.isOptionSelected('q1', 0)).isFalse();
      check(answers.canGoNext).isTrue();

      answers.next();
      check(answers.question).equals(_free);
      check(answers.canGoPrevious).isTrue();
      check(answers.hasNext).isFalse();

      answers.selectOther(_free, '  ');
      check(answers.complete).isFalse();
      answers.updateOther(_free, '  because ');
      check(answers.complete).isTrue();

      answers.previous();
      check(answers.questionIndex).equals(0);
    });

    test('submission trims other text and drops text on options', () {
      final answers = OpenWebUiPromptAnswers(_ask)
        ..selectOption(_pick, _pick.options[0], 0)
        ..updateOther(_free, ' why not ');
      check(answers.submission()).deepEquals({
        'q1': {
          'type': 'option',
          'option_index': 0,
          'label': 'A',
          'description': 'first',
        },
        'q2': {'type': 'other', 'text': 'why not'},
      });
    });

    test('a decision prompt has no question or progress', () {
      final answers = OpenWebUiPromptAnswers(
        const OpenWebUiComposerPrompt(
          identity: 'p2',
          kind: OpenWebUiComposerPromptKind.toolApproval,
        ),
      );
      check(answers.question).isNull();
      check(answers.progressLabel).isNull();
      check(answers.complete).isFalse();
    });

    test('run is single-flight and marks a failure', () async {
      final answers = OpenWebUiPromptAnswers(_ask);
      var changes = 0;
      var calls = 0;
      final first = answers.run(() async {
        calls++;
        await Future<void>.delayed(Duration.zero);
        throw StateError('offline');
      }, onChanged: () => changes++);
      check(answers.busy).isTrue();
      await answers.run(() => calls++);
      await first;
      check(calls).equals(1);
      check(answers.busy).isFalse();
      check(answers.failed).isTrue();
      check(changes).equals(2);

      await answers.run(() {});
      check(answers.busy).isTrue();
      check(answers.failed).isFalse();
    });
  });

  test('canUsePersistedOpenWebUiPrompt needs the loaded owning chat', () {
    check(
      canUsePersistedOpenWebUiPrompt(
        isLoadingConversation: false,
        ownerConversationId: 'c1',
        activeConversationId: 'c1',
      ),
    ).isTrue();
    check(
      canUsePersistedOpenWebUiPrompt(
        isLoadingConversation: true,
        ownerConversationId: 'c1',
        activeConversationId: 'c1',
      ),
    ).isFalse();
    check(
      canUsePersistedOpenWebUiPrompt(
        isLoadingConversation: false,
        ownerConversationId: 'c1',
        activeConversationId: 'c2',
      ),
    ).isFalse();
  });

  test('openWebUiDecisionAction: ask-user cancel rejects', () {
    check(openWebUiDecisionAction(_ask, true))
        .equals(OpenWebUiToolCallAction.reject);
    const approval = OpenWebUiComposerPrompt(
      identity: 'p3',
      kind: OpenWebUiComposerPromptKind.toolApproval,
    );
    check(openWebUiDecisionAction(approval, true))
        .equals(OpenWebUiToolCallAction.approve);
    check(openWebUiDecisionAction(approval, false))
        .equals(OpenWebUiToolCallAction.reject);
  });
}
