import 'package:checks/checks.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/services/direct_replay_output.dart';
import 'package:conduit_core/utils/persisted_message_content.dart';
import 'package:test/test.dart';

void main() {
  const rendered =
      '<details type="reasoning" done="true" duration="1">\n'
      '<summary>Thought for 1 second</summary>\n> plan\n</details>\n'
      '<details type="tool_calls" done="true" id="c1" name="lookup" '
      'arguments="{}" result="&quot;42&quot;">\n'
      '<summary>Tool Executed</summary>\n</details>\n'
      'The answer is 42.';

  Map<String, dynamic> messageItem(List<Map<String, dynamic>> parts) =>
      <String, dynamic>{
        'type': 'message',
        'id': 'm',
        'role': 'assistant',
        'status': 'completed',
        'content': parts,
      };

  const toolItems = <Map<String, dynamic>>[
    <String, dynamic>{
      'type': 'reasoning',
      'id': 'r1',
      'summary': <Map<String, dynamic>>[
        <String, dynamic>{'type': 'summary_text', 'text': 'plan'},
      ],
    },
    <String, dynamic>{
      'type': 'function_call',
      'id': 'c1',
      'call_id': 'c1',
      'name': 'lookup',
      'arguments': '{}',
      'status': 'completed',
    },
    <String, dynamic>{
      'type': 'function_call_output',
      'call_id': 'c1',
      'output': '"42"',
    },
  ];

  ChatMessage assistant(String content, {List<Map<String, dynamic>>? output}) =>
      ChatMessage(
        id: 'a',
        role: 'assistant',
        content: content,
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
        output: output,
      );

  group('outputItemsMessageText', () {
    test('mirrors getOutputText: message items only, parts concatenated, '
        'items joined by newline, blank items skipped', () {
      final text = outputItemsMessageText(<Map<String, dynamic>>[
        ...toolItems,
        messageItem([
          {'type': 'output_text', 'text': 'Hello '},
          {'type': 'output_text', 'text': 'world'},
        ]),
        messageItem([
          {'type': 'output_text', 'text': '   '},
        ]),
        messageItem([
          {'type': 'output_text', 'text': 'Again'},
          {'type': 'refusal', 'refusal': 'no text key'},
        ]),
      ]);

      check(text).equals('Hello world\nAgain');
    });

    test('stringifies non-string text parts and ignores null text', () {
      final text = outputItemsMessageText(<Map<String, dynamic>>[
        messageItem([
          {'type': 'output_text', 'text': 12},
          {'type': 'output_text', 'text': null},
        ]),
      ]);

      check(text).equals('12');
    });

    test('returns an empty string for string content or no message items', () {
      check(outputItemsMessageText(const <Map<String, dynamic>>[])).equals('');
      check(outputItemsMessageText(toolItems)).equals('');
      check(
        outputItemsMessageText(<Map<String, dynamic>>[
          <String, dynamic>{'type': 'message', 'content': 'plain'},
        ]),
      ).equals('');
    });
  });

  group('persistedMessageContent', () {
    test('returns the output message text when output carries the turn', () {
      final message = assistant(
        rendered,
        output: [
          ...toolItems,
          messageItem([
            {'type': 'output_text', 'text': 'The answer is 42.'},
          ]),
        ],
      );

      check(persistedMessageContent(message)).equals('The answer is 42.');
    });

    test('keeps content untouched without output', () {
      check(persistedMessageContent(assistant(rendered))).equals(rendered);
      check(persistedMessageContent(assistant(rendered, output: const [])))
          .equals(rendered);
    });

    test('keeps non-assistant content untouched', () {
      final user = ChatMessage(
        id: 'u',
        role: 'user',
        content: rendered,
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
        output: [
          messageItem([
            {'type': 'output_text', 'text': 'other'},
          ]),
        ],
      );

      check(persistedMessageContent(user)).equals(rendered);
    });

    test('falls back to stripped prose when output has no message text', () {
      final message = assistant(rendered, output: toolItems);

      check(persistedMessageContent(message)).equals('The answer is 42.');
    });

    test('keeps content when neither output nor prose is available', () {
      const detailsOnly =
          '<details type="tool_calls" done="true" id="c1" name="lookup" '
          'arguments="{}" result="1">\n<summary>Tool Executed</summary>\n'
          '</details>';
      final message = assistant(detailsOnly, output: toolItems);

      check(persistedMessageContent(message)).equals(detailsOnly);
    });

    test('keeps rendered content for a direct replay mirror', () {
      final message = assistant(
        rendered,
        output: buildConduitDirectReplayOutput(
          assistantMessageId: 'a',
          rawContent: 'The answer is 42.',
        ),
      );

      check(persistedMessageContent(message)).equals(rendered);
    });
  });
}
