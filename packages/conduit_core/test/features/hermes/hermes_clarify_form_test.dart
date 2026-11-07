import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/hermes/models/hermes_clarify_form.dart';
import 'package:conduit_core/features/hermes/models/hermes_run_event.dart';
import 'package:conduit_core/features/hermes/services/hermes_decision_projection.dart';
import 'package:conduit_core/features/hermes/services/hermes_pending_decision_store.dart';
import 'package:conduit_core/features/hermes/services/hermes_run_transport.dart';
import 'package:conduit_core/features/hermes/services/hermes_stream_parser.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:test/test.dart';

Stream<List<int>> _sse(List<String> chunks) =>
    Stream<List<int>>.fromIterable(chunks.map(utf8.encode));

const _questions = [
  {
    'qid': 'q0',
    'question': 'Which colour?',
    'choices': ['Teal (Recommended)', 'Amber'],
  },
  {
    'qid': 'q1',
    'question': 'Which sizes?',
    'choices': ['Small', 'Large'],
    'multi_select': true,
  },
  {'qid': 'q2', 'question': 'Anything else?'},
];

void main() {
  group('clarify questions', () {
    test('parse every question, with locked answers read-only', () {
      final questions = hermesClarifyQuestions(
        _questions,
        answers: {'q2': null},
      );

      check(questions.map((q) => q.id)).deepEquals(['q0', 'q1', 'q2']);
      check(questions[0].choices).deepEquals(['Teal (Recommended)', 'Amber']);
      check(questions[0].multiSelect).isFalse();
      check(questions[1].multiSelect).isTrue();
      check(questions[2].locked).isTrue();
      check(questions[2].lockedAnswer).isNull();
    });

    test('bound questions, choices and text', () {
      final questions = hermesClarifyQuestions([
        for (var i = 0; i < 10; i++)
          {
            'qid': 'q$i',
            'question': 'x' * 2000,
            'choices': [for (var c = 0; c < 10; c++) 'choice $c ${'y' * 500}'],
          },
        {'qid': 'q0', 'question': 'A repeated id'},
      ]);

      check(questions).length.equals(kMaxHermesClarifyQuestions);
      check(questions.first.text.runes.length)
          .equals(kMaxHermesClarifyQuestionCharacters);
      check(questions.first.text).endsWith('…');
      check(questions.first.choices).length.equals(kMaxHermesClarifyChoices);
      check(questions.first.choices.first.runes.length)
          .equals(kMaxHermesClarifyChoiceCharacters);
    });

    test('drop malformed questions and choices', () {
      final questions = hermesClarifyQuestions([
        'not a question',
        {'qid': 'q0'},
        {'qid': 'q1', 'question': 'Pick one', 'choices': [1, ' ', 'Fine']},
        {'question': 'No id'},
      ]);

      check(questions.single.id).equals('q1');
      check(questions.single.choices).deepEquals(['Fine']);
    });

    test('a lone question has the single question id', () {
      final questions = hermesClarifyQuestionsFromPayload({
        'question': 'Which folder?',
        'choices': ['src', 'docs'],
        'multi_select': true,
      });

      check(questions.single.id).equals(kHermesSingleClarifyQuestionId);
      check(questions.single.multiSelect).isTrue();
    });

    test('a multi-select flag without choices is open-ended', () {
      final question = hermesClarifyQuestions([
        {'qid': 'q0', 'question': 'Notes?', 'multi_select': true},
      ]).single;

      check(question.multiSelect).isFalse();
    });

    test('round-trip through their stored form', () {
      final questions = hermesClarifyQuestions(
        _questions,
        answers: {'q0': 'Teal'},
      );
      final restored = hermesClarifyQuestions(
        jsonDecode(jsonEncode([for (final q in questions) q.toJson()])),
      );

      check(restored.map((q) => q.toJson()).toList())
          .deepEquals(questions.map((q) => q.toJson()).toList());
      check(restored.first.lockedAnswer).equals('Teal');
    });
  });

  group('clarify answers', () {
    final questions = hermesClarifyQuestions(
      _questions,
      answers: {'q2': 'already said'},
    );

    test('send bare choices, arrays for multi-select, and skip locks', () {
      final answers = hermesClarifyAnswers(questions, {
        'q0': const HermesClarifyDraft(choices: ['Teal (Recommended)']),
        'q1': const HermesClarifyDraft(
          choices: ['Small', 'Large'],
          text: 'Huge',
        ),
        'q2': const HermesClarifyDraft(text: 'ignored: it is locked'),
      });

      check(answers).deepEquals({
        'q0': 'Teal',
        'q1': '["Small","Large","Huge"]',
      });
      check(hermesClarifySubmission(answers)).deepEquals({
        'answers': answers,
        'outcome': 'submitted',
      });
    });

    test('a skipped or empty question is null', () {
      final answers = hermesClarifyAnswers(questions, {
        'q0': const HermesClarifyDraft(choices: ['Amber'], skipped: true),
      });

      check(answers).deepEquals({'q0': null, 'q1': null});
    });

    test('typed words answer a single-select question', () {
      const draft = HermesClarifyDraft(text: '  Violet  ');

      check(draft.answerFor(questions[0])).equals('Violet');
      check(draft.settles(questions[0])).isTrue();
      check(const HermesClarifyDraft().settles(questions[0])).isFalse();
      check(const HermesClarifyDraft(skipped: true).settles(questions[0]))
          .isTrue();
    });

    test('the recommended label is presentation only', () {
      check(hermesClarifyBareChoice('Teal (Recommended)')).equals('Teal');
      check(hermesClarifyBareChoice('Teal (recommended)')).equals('Teal');
      check(hermesClarifyChoiceIsRecommended('Teal (Recommended)')).isTrue();
      check(hermesClarifyChoiceIsRecommended('Amber')).isFalse();
    });
  });

  group('REST run questions', () {
    test('show as a decision answered by prompt id and generation', () async {
      final events = await parseHermesRunStream(
        _sse([
          'data: {"event":"clarify.request","run_id":"run_5be1c0de",'
              '"kind":"clarify","prompt_id":"prm_c1a2",'
              '"execution_generation":3,"question":"Which folder?",'
              '"choices":["src","docs"],"multi_select":false,"seq":3}\n\n',
          'data: {"event":"clarify.settled","run_id":"run_5be1c0de",'
              '"prompt_id":"prm_c1a2","execution_generation":3,'
              '"seq":4}\n\n',
        ]),
      ).toList();

      final asked = events.whereType<HermesDecisionRequested>().single;
      check(asked.kind).equals(HermesDecisionKind.clarification);
      check(asked.requestId).equals('prm_c1a2');
      check(asked.prompt).equals('Which folder?');
      check(asked.raw['execution_generation']).equals(3);
      check(events.whereType<HermesApprovalRequested>()).isEmpty();
      check(events.whereType<HermesPromptSettled>().single.kind)
          .equals('clarify');
    });

    test('without a prompt identity are not shown', () async {
      final events = await parseHermesRunStream(
        _sse([
          'data: {"event":"clarify.request","run_id":"run_5be1c0de",'
              '"question":"Which folder?"}\n\n',
        ]),
      ).toList();

      check(events.whereType<HermesDecisionRequested>()).isEmpty();
      check(events.whereType<HermesApprovalRequested>()).isEmpty();
    });

    test('still open after a dropped stream come from pending controls', () {
      final events = hermesPendingControlEvents([
        {
          'kind': 'clarify',
          'prompt_id': 'prm_c9',
          'execution_generation': 2,
          'question': 'Which folder?',
          'choices': <String>[],
          'multi_select': false,
        },
        {
          'kind': 'approval',
          'prompt_id': 'prm_a9',
          'execution_generation': 2,
          'command': 'rm -rf build',
          'description': 'remove a build folder',
          'choices': ['once', 'deny'],
        },
        {'kind': 'unknown', 'prompt_id': 'prm_x'},
        'not a control',
      ]);

      check(events).length.equals(2);
      check(events.first).isA<HermesDecisionRequested>()
          .has((e) => e.requestId, 'requestId')
          .equals('prm_c9');
      check(events.last).isA<HermesApprovalRequested>()
        ..has((e) => e.approvalId, 'approvalId').equals('prm_a9')
        ..has((e) => e.executionGeneration, 'generation').equals(2);
    });

    test('keep their questions and generation on the card', () {
      final message = applyHermesRunEventForTest(
        ChatMessage(
          id: 'assistant-1',
          role: 'assistant',
          content: '',
          timestamp: DateTime.utc(2030),
        ),
        const HermesDecisionRequested(
          kind: HermesDecisionKind.clarification,
          requestId: 'prm_c1a2',
          prompt: 'Which folder? synthetic-secret-123',
          raw: {
            'prompt_id': 'prm_c1a2',
            'execution_generation': 3,
            'question': 'Which folder? synthetic-secret-123',
            'choices': ['src', 'docs'],
          },
        ),
        runId: 'run_5be1c0de',
        sensitiveValues: const ['synthetic-secret-123'],
      );

      final decision = message.metadata![kHermesDecisionMeta] as Map;
      check(decision['state']).equals('pending');
      check(decision['requestId']).equals('prm_c1a2');
      check(decision['runtimeId']).equals('run_5be1c0de');
      check(decision['executionGeneration']).equals(3);
      final question = hermesClarifyQuestionsFromPayload(decision).single;
      check(question.choices).deepEquals(['src', 'docs']);
      check(question.text).not((it) => it.contains('synthetic-secret-123'));
    });
  });

  group('pending clarify forms', () {
    setUp(() => PreferencesStore.debugOverride(InMemoryKeyValueStore()));

    test('survive a restart with every question and lock', () async {
      final questions = hermesClarifyQuestions(
        _questions,
        answers: {'q2': 'nothing'},
      );
      await HermesPendingDecisionStore.upsert(
        origin: 'https://hermes.example',
        storedSessionId: 'stored-1',
        runtimeId: 'runtime-1',
        requestId: 'srq-f1',
        kind: HermesPendingDesktopDecisionKind.clarification,
        prompt: 'Which colour?',
        questions: questions,
      );

      final record = (await HermesPendingDecisionStore.forSession(
        origin: 'https://hermes.example',
        storedSessionId: 'stored-1',
      )).single;
      check(record.questions.map((q) => q.toJson()).toList())
          .deepEquals(questions.map((q) => q.toJson()).toList());

      final restored = hermesPendingDesktopDecisionMessages(
        [record],
        modelId: 'hermes',
      ).single;
      final decision = restored.metadata![kHermesDecisionMeta] as Map;
      check(decision['requestId']).equals('srq-f1');
      check(
        hermesClarifyQuestionsFromPayload(decision).map((q) => q.id),
      ).deepEquals(['q0', 'q1', 'q2']);
    });

    test('redact connection secrets from stored questions', () async {
      await HermesPendingDecisionStore.upsert(
        origin: 'https://hermes.example',
        storedSessionId: 'stored-1',
        runtimeId: 'runtime-1',
        requestId: 'srq-f2',
        kind: HermesPendingDesktopDecisionKind.clarification,
        questions: hermesClarifyQuestions([
          {
            'qid': 'q0',
            'question': 'Use key synthetic-secret-123?',
            'choices': ['synthetic-secret-123', 'Other'],
          },
        ]),
        sensitiveValues: const ['synthetic-secret-123'],
      );

      final stored = PreferencesStore.getStringList(
        PreferenceKeys.hermesPendingDesktopDecisions,
      );
      check(stored).isNotNull();
      check(stored!.join()).not((it) => it.contains('synthetic-secret-123'));
    });
  });
}
