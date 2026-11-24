import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/librechat/models/librechat_tools.dart';
import 'package:conduit_core/features/librechat/services/librechat_pause_controller.dart';
import 'package:test/test.dart';

typedef _Sent = ({
  Map<String, LibreChatToolDecisionInput>? decisions,
  Map<String, String>? answers,
});

const _tools = LibreChatPendingAction({
  'actionId': 'act-1',
  'payload': {
    'type': 'tool_approval',
    'action_requests': [
      {
        'tool_call_id': 'call-a',
        'name': 'echo',
        'arguments': '{"text": "hi"}',
      },
      {'tool_call_id': 'call-b', 'name': 'lookup', 'arguments': <String, Object>{}},
    ],
    'review_configs': [
      {
        'tool_call_id': 'call-a',
        'allowed_decisions': ['approve', 'reject', 'edit'],
      },
      {
        'tool_call_id': 'call-b',
        'allowed_decisions': ['respond', 'reject'],
      },
    ],
  },
});

const _questions = LibreChatPendingAction({
  'actionId': 'act-2',
  'payload': {
    'type': 'ask_user_question',
    'questions': [
      {
        'id': 'q1',
        'question': 'Which city?',
        'description': '  ',
        'options': [
          {'label': 'Paris', 'value': 'paris'},
          'Rome',
        ],
      },
      {
        'id': 'q2',
        'question': 'Which days?',
        'multiSelect': true,
        'options': [
          {'label': 'Mon', 'value': 'monday'},
          'Tue',
        ],
      },
    ],
  },
});

/// A controller whose sends are recorded, and fail with [failWith] while it
/// is set, or wait for [hold] while it is set.
({LibreChatPauseController pause, List<_Sent> sent}) _pause(
  LibreChatPendingAction action, {
  Object? Function()? failWith,
  Completer<void>? hold,
}) {
  final sent = <_Sent>[];
  final pause = LibreChatPauseController(
    action,
    resolve: ({decisions, answers}) async {
      sent.add((decisions: decisions, answers: answers));
      await hold?.future;
      final failure = failWith?.call();
      if (failure != null) throw failure;
    },
  );
  return (pause: pause, sent: sent);
}

void main() {
  group('tool calls', () {
    test('are put one at a time, each with the decisions the server allows, '
        'and sent together once all are decided; an answer for a card not '
        'up decides nothing', () async {
      final (:pause, :sent) = _pause(_tools);
      const approve = LibreChatToolDecisionInput(LibreChatToolDecision.approve);
      // A card not shown yet.
      check(await pause.decide('call-b', approve))
          .equals(LibreChatPauseStep.stale);

      final first = pause.current! as LibreChatToolCard;
      check(first.id).equals('call-a');
      check(first.allowed).deepEquals([
        LibreChatToolDecision.approve,
        LibreChatToolDecision.reject,
        LibreChatToolDecision.edit,
      ]);
      check(first.argumentsText).equals('{"text": "hi"}');
      check(first.editableArguments).equals('{\n  "text": "hi"\n}');
      check(
        await pause.decide(
          'call-a',
          const LibreChatToolDecisionInput(LibreChatToolDecision.approve),
        ),
      ).equals(LibreChatPauseStep.next);
      // The first card answered again, as a second tap on it would.
      check(await pause.decide('call-a', approve))
          .equals(LibreChatPauseStep.stale);
      check(sent).isEmpty();

      final second = pause.current! as LibreChatToolCard;
      check(second.id).equals('call-b');
      check((second.index, second.count)).equals((1, 2));
      // No arguments to show, and an empty object to edit from.
      check(second.argumentsText).isNull();
      check(second.editableArguments).equals('{}');
      check(
        await pause.decide(
          'call-b',
          const LibreChatToolDecisionInput(
            LibreChatToolDecision.respond,
            responseText: 'Sample result',
          ),
        ),
      ).equals(LibreChatPauseStep.sent);

      final decisions = sent.single.decisions!;
      check(decisions.keys).deepEquals(['call-a', 'call-b']);
      check(decisions['call-a']!.decision)
          .equals(LibreChatToolDecision.approve);
      check(decisions['call-b']!.responseText).equals('Sample result');
      check(sent.single.answers).isNull();
      check(pause.sent).isTrue();
    });

    test('refuse what the server would refuse, taking nothing', () async {
      final (:pause, :sent) = _pause(_tools);

      // Not in this call's list.
      check(
        await pause.decide(
          'call-a',
          const LibreChatToolDecisionInput(LibreChatToolDecision.respond),
        ),
      ).equals(LibreChatPauseStep.notAllowed);
      // An edit runs the tool with a JSON object only.
      check(
        await pause.decide(
          'call-a',
          const LibreChatToolDecisionInput(LibreChatToolDecision.edit),
        ),
      ).equals(LibreChatPauseStep.invalidArguments);
      check(pause.current!.id).equals('call-a');

      await pause.decide(
          'call-a',
        const LibreChatToolDecisionInput(LibreChatToolDecision.approve),
      );
      // A response needs words.
      check(
        await pause.decide(
          'call-b',
          const LibreChatToolDecisionInput(
            LibreChatToolDecision.respond,
            responseText: '   ',
          ),
        ),
      ).equals(LibreChatPauseStep.empty);
      check(pause.current!.id).equals('call-b');
      check(sent).isEmpty();
    });

    test('an edit is a JSON object, never a list, a string or broken JSON', () {
      check(
        LibreChatPauseController.editedArguments('{"path": "notes.txt"}'),
      ).isNotNull().deepEquals({'path': 'notes.txt'});
      for (final text in ['[1, 2]', '"notes.txt"', '{"path":', '']) {
        check(
          because: text,
          LibreChatPauseController.editedArguments(text),
        ).isNull();
      }
    });

    test('a failed send puts the last card back, its decision cleared, and '
        'the next decision sends them all again; only that card takes an '
        'answer', () async {
      var failing = true;
      final (:pause, :sent) = _pause(
        _tools,
        failWith: () => failing ? StateError('offline') : null,
      );
      await pause.decide(
          'call-a',
        const LibreChatToolDecisionInput(LibreChatToolDecision.approve),
      );
      check(
        await pause.decide(
          'call-b',
          const LibreChatToolDecisionInput(LibreChatToolDecision.reject),
        ),
      ).equals(LibreChatPauseStep.failed);
      check(pause.failed).isTrue();
      check(pause.current!.id).equals('call-b');

      failing = false;
      // The first call keeps its decision: only the card put back is up.
      check(
        await pause.decide(
          'call-a',
          const LibreChatToolDecisionInput(LibreChatToolDecision.approve),
        ),
      ).equals(LibreChatPauseStep.stale);
      check(sent).length.equals(1);
      check(
        await pause.decide(
          'call-b',
          const LibreChatToolDecisionInput(LibreChatToolDecision.reject),
        ),
      ).equals(LibreChatPauseStep.sent);
      check(pause.failed).isFalse();
      check(sent).length.equals(2);
      check(sent.last.decisions!.keys).deepEquals(['call-a', 'call-b']);
    });

    test('nothing more is taken while the answer goes out, or once it has',
        () async {
      final hold = Completer<void>();
      final (:pause, :sent) = _pause(_tools, hold: hold);
      await pause.decide(
          'call-a',
        const LibreChatToolDecisionInput(LibreChatToolDecision.approve),
      );
      final sending = pause.decide(
          'call-b',
        const LibreChatToolDecisionInput(LibreChatToolDecision.reject),
      );
      check(pause.sending).isTrue();
      check(
        await pause.decide(
          'call-b',
          const LibreChatToolDecisionInput(LibreChatToolDecision.reject),
        ),
      ).equals(LibreChatPauseStep.busy);

      hold.complete();
      check(await sending).equals(LibreChatPauseStep.sent);
      check(pause.sending).isFalse();
      check(
        await pause.decide(
          'call-b',
          const LibreChatToolDecisionInput(LibreChatToolDecision.reject),
        ),
      ).equals(LibreChatPauseStep.busy);
      check(sent).length.equals(1);
    });
  });

  group('questions', () {
    test('are put one at a time and answered with their choices\' values, '
        'several joined, typed text as it is; an answer for a question not '
        'up is refused', () async {
      final (:pause, :sent) = _pause(_questions);
      // A question not shown yet.
      check(await pause.answer('q2', 'mon')).equals(LibreChatPauseStep.stale);

      final first = pause.current! as LibreChatQuestionCard;
      check(first.id).equals('q1');
      check(first.question).equals('Which city?');
      check(first.description).isNull();
      check(first.choices.map((c) => c.label)).deepEquals(['Paris', 'Rome']);
      check(first.answerFor('Paris')).equals('paris');
      check(first.answerFor('Rome')).equals('Rome');
      check(first.answerFor('Lyon, I think')).equals('Lyon, I think');
      check(
        await pause.answer('q1', first.answerFor('Paris')),
      ).equals(LibreChatPauseStep.next);
      // The first answered again.
      check(await pause.answer('q1', 'rome')).equals(LibreChatPauseStep.stale);

      final second = pause.current! as LibreChatQuestionCard;
      check(second.multiSelect).isTrue();
      check(second.answerFor('["Mon","Tue"]')).equals('monday, Tue');
      check(second.answerFor('weekends')).equals('weekends');
      check(
        await pause.answer('q2', second.answerFor('["Mon","Tue"]')),
      ).equals(LibreChatPauseStep.sent);

      check(sent.single.answers).isNotNull().deepEquals({
        'q1': 'paris',
        'q2': 'monday, Tue',
      });
      check(sent.single.decisions).isNull();
    });

    test('an empty answer is not taken', () async {
      final (:pause, :sent) = _pause(_questions);
      check(await pause.answer('q1', '  ')).equals(LibreChatPauseStep.empty);
      check(pause.current!.id).equals('q1');
      check(sent).isEmpty();
    });

    test('a single question is answered under its tool call\'s id', () async {
      final (:pause, :sent) = _pause(
        const LibreChatPendingAction({
          'actionId': 'act-3',
          'payload': {
            'type': 'ask_user_question',
            'tool_call_id': 'call-q',
            'question': {'question': 'Ready?'},
          },
        }),
      );
      check(pause.current!.id).equals('call-q');
      check(await pause.answer('call-q', 'yes')).equals(LibreChatPauseStep.sent);
      check(sent.single.answers).isNotNull().deepEquals({'call-q': 'yes'});
    });
  });

  test('a pause of neither kind puts no card and takes nothing', () async {
    final (:pause, :sent) = _pause(
      const LibreChatPendingAction({
        'actionId': 'act-4',
        'payload': {'type': 'something_new'},
      }),
    );
    check(pause.current).isNull();
    check(
      await pause.decide(
          'call-a',
        const LibreChatToolDecisionInput(LibreChatToolDecision.approve),
      ),
    ).equals(LibreChatPauseStep.busy);
    check(await pause.answer('q1', 'yes')).equals(LibreChatPauseStep.busy);
    check(sent).isEmpty();
  });
}
