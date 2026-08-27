import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/models/openwebui_chat_prompt.dart';
import 'package:flutter_test/flutter_test.dart';

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
