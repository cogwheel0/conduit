import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/openwebui_chat_prompt.dart';
import 'package:test/test.dart';

void main() {
  test('ask-user parser enforces the upstream shape and bounds text', () {
    final prompt = parseOpenWebUiAskUserPrompt(<String, dynamic>{
      'questions': [
        {
          'id': 'choice',
          'header': List.filled(80, 'H').join(),
          'question': 'Pick one',
          'options': [
            {'label': 'First', 'description': 'The first option'},
            {'label': 'Second', 'description': 'The second option'},
          ],
        },
      ],
      'timeout_ms': 300000,
    }, identity: 'live:1');

    check(prompt).isNotNull();
    check(prompt!.questions.single.header.length).equals(48);
    check(boundedOpenWebUiString('${List.filled(47, 'H').join()}😀', 48))
        .equals(List.filled(47, 'H').join());
    check(prompt.questions.single.allowOther).isTrue();
    check(prompt.timeout).equals(const Duration(minutes: 2));
    check(
      parseOpenWebUiAskUserPrompt({
        'questions': [
          {
            'id': 'duplicate',
            'question': 'One',
            'options': [
              {'label': 'A', 'description': 'A'},
              {'label': 'B', 'description': 'B'},
            ],
          },
          {
            'id': 'duplicate',
            'question': 'Two',
            'options': [
              {'label': 'A', 'description': 'A'},
              {'label': 'B', 'description': 'B'},
            ],
          },
        ],
      }, identity: 'invalid'),
    ).isNull();
  });

  test(
    'pending detector skips resolved calls and selects the newest prompt',
    () {
      final messages = [
        _assistant('older', [
          {
            'type': 'function_call',
            'call_id': 'old-call',
            'name': 'old_tool',
            'arguments': '{}',
            'status': 'pending',
          },
        ]),
        _assistant('newer', [
          {
            'type': 'function_call',
            'call_id': 'resolved-call',
            'name': 'resolved_tool',
            'arguments': '{}',
            'status': 'pending',
          },
          {
            'type': 'function_call_output',
            'call_id': ' resolved-call ',
            'output': const [],
          },
          {
            'type': 'function_call',
            'call_id': 'ask-call',
            'name': 'ask_user',
            'arguments': jsonEncode({
              'questions': [
                {
                  'id': 'scope',
                  'header': 'Scope',
                  'question': 'Which scope?',
                  'options': [
                    {'label': 'One', 'description': 'One scope'},
                    {'label': 'All', 'description': 'Every scope'},
                  ],
                },
              ],
            }),
            'status': 'pending',
          },
        ]),
      ];

      final pending = findPendingOpenWebUiToolPrompt(messages);
      check(pending).isNotNull();
      check(pending!.messageId).equals('newer');
      check(pending.callId).equals('ask-call');
      check(pending.prompt.kind).equals(OpenWebUiComposerPromptKind.askUser);
    },
  );

  test('pending detector surfaces unapproved queued calls', () {
    final pending = findPendingOpenWebUiToolPrompt([
      _assistant('assistant', [
        {
          'type': 'function_call',
          'call_id': 'queued-call',
          'name': 'filesystem',
          'arguments': const {'path': '/tmp'},
          'status': 'queued',
        },
      ]),
    ]);

    check(pending).isNotNull();
    check(pending!.callId).equals('queued-call');
  });

  group('coding agent requests (Open WebUI 0.13.1)', () {
    // As `AgentOutput.approve` saves an agent's request: pending, with the
    // agent's own request as `native`.
    Map<String, dynamic> request(
      String name,
      Object arguments, {
      String status = 'pending',
      Map<String, dynamic>? resolution,
    }) => {
      'type': 'function_call',
      'id': 'approval_1',
      'call_id': 'approval_1',
      'name': name,
      'arguments': jsonEncode(arguments),
      'status': status,
      'native': const {'request_id': 'r1'},
      'agent_resolution': ?resolution,
    };

    test('an agent\'s questions show although ask_user would refuse '
        'them', () {
      // Claude Code keys a question by its whole text; ACP and Pi send
      // choices without descriptions, or none for a written answer.
      final longId =
          'Which of the files under src should I refactor first? '
          'Pick the one that matters most.';
      final pending = findPendingOpenWebUiToolPrompt([
        _assistant('assistant', [
          request('ask_user', {
            'questions': [
              {
                'id': longId,
                'header': 'Refactor',
                'question': longId,
                'options': [
                  {'label': 'a.dart', 'description': ''},
                  {'label': 'b.dart', 'description': ''},
                  {'label': 'c.dart', 'description': ''},
                  {'label': 'd.dart', 'description': ''},
                ],
              },
              {
                'id': 'value',
                'header': 'Pi',
                'question': 'Enter a response',
                'options': <Object>[],
              },
              {'id': 'q3', 'question': 'Anything else?'},
              {
                'id': 'q4',
                'question': 'Proceed?',
                'options': [
                  {'label': 'Yes', 'description': ''},
                  {'label': 'No', 'description': ''},
                ],
                'allow_other': false,
              },
            ],
          }),
        ]),
      ]);

      check(pending).isNotNull();
      check(pending!.callId).equals('approval_1');
      final questions = pending.prompt.questions;
      check(pending.prompt.kind).equals(OpenWebUiComposerPromptKind.askUser);
      check(questions.map((q) => q.id))
          .deepEquals([longId, 'value', 'q3', 'q4']);
      check(questions.first.options.map((o) => o.label))
          .deepEquals(['a.dart', 'b.dart', 'c.dart', 'd.dart']);
      check(questions.first.options.first.description).equals('');
      check(questions[1].options).isEmpty();
      check(questions[1].allowOther).isTrue();
      check(questions[2].header).equals('Question 3');
      check(questions[3].allowOther).isFalse();
    });

    test('the same questions without `native` still meet ask_user\'s '
        'rules', () {
      final pending = findPendingOpenWebUiToolPrompt([
        _assistant('assistant', [
          {
            ...request('ask_user', {
              'questions': [
                {'id': 'value', 'question': 'Enter a response'},
              ],
            }),
          }..remove('native'),
        ]),
      ]);
      check(pending).isNull();
    });

    test('a request the server already handed its answer is not asked '
        'again', () {
      check(
        findPendingOpenWebUiToolPrompt([
          _assistant('assistant', [
            request(
              'agent_tool',
              {'command': 'ls'},
              status: 'queued',
              resolution: {'action': 'approve'},
            ),
          ]),
        ]),
      ).isNull();
    });
  });

  test(
    'resolution projection matches approve, reject, and answer contracts',
    () {
      final output = <Map<String, dynamic>>[
        {
          'type': 'function_call',
          'call_id': ' call-1 ',
          'name': 'ask_user',
          'status': 'pending',
        },
      ];
      final answered = applyOpenWebUiToolCallResolution(
        output: output,
        callId: 'call-1',
        action: 'answer',
        answers: const {
          'scope': {'type': 'other', 'text': 'this chat'},
        },
      );
      check(answered.first['status']).equals('completed');
      final answerText =
          ((answered.last['output'] as List).single as Map)['text'] as String;
      expect(jsonDecode(answerText), {
        'status': 'answered',
        'answers': {
          'scope': {'type': 'other', 'text': 'this chat'},
        },
      });

      final approved = applyOpenWebUiToolCallResolution(
        output: output,
        callId: 'call-1',
        action: 'approve',
      );
      check(approved.single['status']).equals('queued');
      check(approved.single['approved']).equals(true);

      final rejected = applyOpenWebUiToolCallResolution(
        output: output,
        callId: 'call-1',
        action: 'reject',
      );
      check(rejected.first['status']).equals('rejected');
      check(rejected.last['status']).equals('rejected');
    },
  );
}

ChatMessage _assistant(String id, List<Map<String, dynamic>> output) =>
    ChatMessage(
      id: id,
      role: 'assistant',
      content: '',
      timestamp: DateTime(2026),
      output: output,
    );
