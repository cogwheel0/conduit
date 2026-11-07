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
    });

    // A choice is a literal answer, such as a path or a command: one cut
    // to fit the card sent Hermes a different answer.
    test('keep a long choice whole and shorten only its label', () {
      final path = '/srv/synthetic/${'nested/' * 60}report.md';
      final question = hermesClarifyQuestions([
        {
          'qid': 'q0',
          'question': 'Which file?',
          'choices': [path, 'z' * (kMaxHermesClarifyChoiceCharacters + 1)],
        },
      ]).single;

      check(question.choices).deepEquals([path]);
      check(
        HermesClarifyDraft(choices: [path]).answerFor(question),
      ).equals(path);
      final label = hermesClarifyChoiceLabel(path);
      check(label.runes.length)
          .equals(kMaxHermesClarifyChoiceLabelCharacters);
      check(label).endsWith('…');
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

    test('send a live choice as it reads, or leave it out', () {
      final longPath = '/srv/${'deep/' * 120}notes.txt';
      final message = applyHermesRunEventForTest(
        ChatMessage(
          id: 'assistant-1',
          role: 'assistant',
          content: '',
          timestamp: DateTime.utc(2030),
        ),
        HermesDecisionRequested(
          kind: HermesDecisionKind.clarification,
          requestId: 'prm_c1a3',
          prompt: 'Which command?',
          raw: {
            'prompt_id': 'prm_c1a3',
            'execution_generation': 3,
            'question': 'Which command?',
            'choices': ['ls  -la', longPath, 'pwd'],
          },
        ),
        runId: 'run_5be1c0de',
      );

      final decision = message.metadata![kHermesDecisionMeta] as Map;
      final question = hermesClarifyQuestionsFromPayload(decision).single;
      // Folding `ls  -la` or cutting the path would send another answer.
      check(question.choices).deepEquals(['pwd']);
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

    // Credentials a locked answer can carry, each with a token that is not
    // a configured connection secret.
    const credentialAnswers = {
      'Authorization: Bearer tok-alpha-1': 'tok-alpha-1',
      'Proxy-Authorization: Basic dG9rLWJldGEtMg==': 'dG9rLWJldGEtMg',
      'Bearer tok-gamma-3': 'tok-gamma-3',
      'password=tok-delta-4': 'tok-delta-4',
      'api_key: "tok epsilon 5"': 'epsilon',
      '{"secret": "tok-zeta-6"}': 'tok-zeta-6',
      "access_token='tok eta 7'": 'eta',
      'password="a\\"tok-theta-8"': 'tok-theta-8',
      'Cookie: sid=tok-iota-9; theme=dark': 'tok-iota-9',
    };

    test('redact every credential form from a locked answer', () async {
      for (final MapEntry(key: answer, value: token)
          in credentialAnswers.entries) {
        await HermesPendingDecisionStore.upsert(
          origin: 'https://hermes.example',
          storedSessionId: 'stored-1',
          runtimeId: 'runtime-1',
          requestId: 'srq-cred',
          kind: HermesPendingDesktopDecisionKind.clarification,
          prompt: 'Which header?',
          questions: hermesClarifyQuestions(
            [
              {'qid': 'q0', 'question': 'Which header?'},
            ],
            answers: {'q0': answer},
          ),
        );

        final stored = PreferencesStore.getStringList(
          PreferenceKeys.hermesPendingDesktopDecisions,
        )!.join();
        check(because: answer, stored).not((it) => it.contains(token));
        final record = (await HermesPendingDecisionStore.forSession(
          origin: 'https://hermes.example',
          storedSessionId: 'stored-1',
        )).single;
        check(
          because: answer,
          record.questions.single.lockedAnswer,
        ).isNotNull().not((it) => it.contains(token));
      }
    });

    test('redact a locked answer saved by an earlier build', () async {
      final expires = DateTime.now()
          .toUtc()
          .add(const Duration(hours: 1))
          .toIso8601String();
      await PreferencesStore.putChecked(
        PreferenceKeys.hermesPendingDesktopDecisions,
        [
          jsonEncode({
            'origin': 'https://hermes.example',
            'stored_session_id': 'stored-1',
            'runtime_id': 'runtime-1',
            'request_id': 'srq-old',
            'kind': 'clarification',
            'expires_at': expires,
            'questions': [
              {
                'qid': 'q0',
                'question': 'Which header?',
                'locked': true,
                'answer': 'Authorization: Bearer tok-kappa-10',
              },
            ],
          }),
        ],
      );

      final record = (await HermesPendingDecisionStore.forSession(
        origin: 'https://hermes.example',
        storedSessionId: 'stored-1',
      )).single;

      check(
        record.questions.single.lockedAnswer,
      ).isNotNull().not((it) => it.contains('tok-kappa-10'));
    });

    test('a live card shows no credential from a locked answer', () {
      for (final MapEntry(key: answer, value: token)
          in credentialAnswers.entries) {
        final message = applyHermesRunEventForTest(
          ChatMessage(
            id: 'assistant-1',
            role: 'assistant',
            content: '',
            timestamp: DateTime.utc(2030),
          ),
          HermesDecisionRequested(
            kind: HermesDecisionKind.clarification,
            requestId: 'prm_c1a4',
            prompt: 'Which header?',
            raw: {
              'prompt_id': 'prm_c1a4',
              'execution_generation': 3,
              'questions': [
                {'qid': 'q0', 'question': 'Which header?'},
              ],
              'answers': {'q0': answer},
            },
          ),
          runId: 'run_5be1c0de',
        );

        final decision = message.metadata![kHermesDecisionMeta] as Map;
        final question = hermesClarifyQuestionsFromPayload(decision).single;
        check(
          because: answer,
          question.lockedAnswer,
        ).isNotNull().not((it) => it.contains(token));
      }
    });

    test('a lone surrogate is kept within the field budget', () async {
      await HermesPendingDecisionStore.upsert(
        origin: 'https://hermes.example',
        storedSessionId: 'stored-1',
        runtimeId: 'runtime-1',
        requestId: 'srq-sur',
        kind: HermesPendingDesktopDecisionKind.clarification,
        prompt: '${'\uD800' * 400}?',
      );

      final stored = PreferencesStore.getStringList(
        PreferenceKeys.hermesPendingDesktopDecisions,
      )!.single;
      check(stored).not((it) => it.contains(r'\ud800'));
      final record = (await HermesPendingDecisionStore.forSession(
        origin: 'https://hermes.example',
        storedSessionId: 'stored-1',
      )).single;
      check(record.prompt).isNotNull().startsWith('\uFFFD');
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

    // The store keeps each field to 512 scalars; one of two UTF-16 units
    // each made a full form longer than the store would read back.
    test('a form of the longest fields survives a restart', () async {
      const wide = '😀';
      final questions = hermesClarifyQuestions(
        [
          for (var q = 0; q < kMaxHermesClarifyQuestions; q++)
            {
              'qid': 'q$q',
              'question': wide * 600,
              'choices': [
                for (var c = 0; c < kMaxHermesClarifyChoices; c++)
                  '${String.fromCharCode(0x41 + c)}${wide * 511}',
              ],
            },
        ],
        answers: {'q0': wide * 600},
      );
      await HermesPendingDecisionStore.upsert(
        origin: 'https://hermes.example',
        storedSessionId: 'stored-1',
        runtimeId: 'runtime-1',
        requestId: 'srq-f3',
        kind: HermesPendingDesktopDecisionKind.clarification,
        questions: questions,
      );

      final record = (await HermesPendingDecisionStore.forSession(
        origin: 'https://hermes.example',
        storedSessionId: 'stored-1',
      )).single;
      check(record.questions).length.equals(kMaxHermesClarifyQuestions);
      check(record.questions.last.choices)
          .length
          .equals(kMaxHermesClarifyChoices);
      check(record.questions.last.choices.first.runes.length).equals(512);
    });

    // Earlier builds saved each question of a form as its own card. Only
    // the whole form is answered now, and a resume shows it again.
    test('question-by-question records are dropped', () async {
      for (final (id, kind) in [
        ('srq-old/q1', HermesPendingDesktopDecisionKind.clarification),
        ('srq-new', HermesPendingDesktopDecisionKind.clarification),
        ('op-1/docs', HermesPendingDesktopDecisionKind.mcpSetup),
      ]) {
        await HermesPendingDecisionStore.upsert(
          origin: 'https://hermes.example',
          storedSessionId: 'stored-1',
          runtimeId: 'runtime-1',
          requestId: id,
          kind: kind,
          prompt: 'Pick one',
        );
      }

      final ids = [
        for (final record in await HermesPendingDecisionStore.forSession(
          origin: 'https://hermes.example',
          storedSessionId: 'stored-1',
        ))
          record.requestId,
      ]..sort();
      check(ids).deepEquals(['op-1/docs', 'srq-new']);
    });

    test('a choice the store would change is left out', () async {
      await HermesPendingDecisionStore.upsert(
        origin: 'https://hermes.example',
        storedSessionId: 'stored-1',
        runtimeId: 'runtime-1',
        requestId: 'srq-f4',
        kind: HermesPendingDesktopDecisionKind.clarification,
        questions: hermesClarifyQuestions([
          {
            'qid': 'q0',
            'question': 'Which command?',
            'choices': ['ls  -la', 'pwd', 'x' * 600],
          },
        ]),
      );

      final record = (await HermesPendingDecisionStore.forSession(
        origin: 'https://hermes.example',
        storedSessionId: 'stored-1',
      )).single;
      // Restored, the form answers with what it stored: never an altered
      // command or a cut one.
      check(record.questions.single.choices).deepEquals(['pwd']);
    });
  });
}
