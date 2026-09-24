import 'package:checks/checks.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/services/direct_replay_output.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('localEchoRowForMessage', () {
    final message = ChatMessage(
      id: 'assistant-1',
      role: 'assistant',
      content: 'Answer',
      timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      model: 'gpt-4o',
      isStreaming: false,
      metadata: const <String, dynamic>{'modelName': 'GPT-4o'},
      output: const <Map<String, dynamic>>[
        <String, dynamic>{'type': 'text', 'text': 'Answer'},
      ],
      files: const <Map<String, dynamic>>[
        <String, dynamic>{'type': 'image', 'url': 'https://x/img.png'},
      ],
      embeds: const <Map<String, dynamic>>[
        <String, dynamic>{'html': '<iframe></iframe>'},
      ],
      usage: const <String, dynamic>{'total_tokens': 42},
      sources: const <ChatSourceReference>[
        ChatSourceReference(
          id: 'src-1',
          title: 'Docs',
          url: 'https://example.com',
          snippet: 'Snippet text',
          type: 'web_search',
        ),
      ],
      statusHistory: const <ChatStatusUpdate>[
        ChatStatusUpdate(description: 'Searching', done: true),
      ],
      codeExecutions: const <ChatCodeExecution>[
        ChatCodeExecution(
          id: 'exec-1',
          name: 'run',
          language: 'python',
          code: 'print(1)',
          result: ChatCodeExecutionResult(output: '1'),
        ),
      ],
      followUps: const <String>['Next?'],
      error: const ChatMessageError(content: 'boom'),
    );

    test('carries every durable field the sync outbox must replay', () {
      // The outbox rebuilds the full chat blob from these rows and the server
      // replaces each message object wholesale — a key missing here is a key
      // wiped from the server copy on the next push.
      final payload = localEchoRowForMessage('chat-1', message).payload;

      const durableKeys = {
        'id',
        'parentId',
        'childrenIds',
        'role',
        'content',
        'timestamp',
        'isStreaming',
        'done',
        'model',
        'metadata',
        'output',
        'files',
        'embeds',
        'usage',
        'sources',
        'statusHistory',
        'code_executions',
        'followUps',
        'error',
      };
      check(durableKeys.difference(payload.keys.toSet())).isEmpty();
    });

    test('persists sources and code executions in the server shape', () {
      // The OWUI web client reads citation-shaped `sources` and snake_case
      // `code_executions`; client-model shapes would break that client for
      // any chat synced from Conduit.
      final payload = localEchoRowForMessage('chat-1', message).payload;

      final source =
          (payload['sources'] as List).single as Map<String, dynamic>;
      check(source['source']).isA<Map<String, dynamic>>();
      check(source['document']).isA<List<dynamic>>();
      check(source.containsKey('snippet')).isFalse();

      final execution =
          (payload['code_executions'] as List).single as Map<String, dynamic>;
      check(execution['id']).equals('exec-1');
      check((execution['result'] as Map<String, dynamic>)['output'])
          .equals('1');
      check(payload.containsKey('codeExecutions')).isFalse();
    });

    group('persisted content (issue #703)', () {
      const renderedDetails =
          '<details type="tool_calls" done="true" id="call-1" '
          'name="get_weather" arguments="{&quot;city&quot;:&quot;Oslo&quot;}" '
          'result="&quot;Sunny&quot;">\n'
          '<summary>Tool Executed</summary>\n</details>\n';
      const structuredOutput = <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'function_call',
          'id': 'call-1',
          'call_id': 'call-1',
          'name': 'get_weather',
          'arguments': '{"city":"Oslo"}',
          'status': 'completed',
        },
        <String, dynamic>{
          'type': 'function_call_output',
          'call_id': 'call-1',
          'output': '"Sunny"',
        },
        <String, dynamic>{
          'type': 'message',
          'id': 'msg-1',
          'role': 'assistant',
          'status': 'completed',
          'content': <Map<String, dynamic>>[
            <String, dynamic>{'type': 'output_text', 'text': 'It is sunny.'},
          ],
        },
      ];

      ChatMessage assistant({
        required String content,
        List<Map<String, dynamic>>? output,
      }) => ChatMessage(
        id: 'assistant-2',
        role: 'assistant',
        content: content,
        timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        model: 'gpt-4o',
        isStreaming: false,
        output: output,
      );

      test('stores the output message text, not the rendered details', () {
        // The OWUI web client persists `content = getOutputText(output)` and
        // rebuilds the <details> presentation from `output` on load; pushing
        // the rendered markup leaks it into shares and exports.
        final row = localEchoRowForMessage(
          'chat-1',
          assistant(
            content: '${renderedDetails}It is sunny.',
            output: structuredOutput,
          ),
        );

        check(row.payload['content']).equals('It is sunny.');
        check(row.content).equals('It is sunny.');
        check(row.payload['output'])
            .isA<List<Object?>>()
            .deepEquals(structuredOutput);
      });

      test('keeps content byte-for-byte when the message has no output', () {
        const content = '${renderedDetails}It is sunny.';
        final row = localEchoRowForMessage(
          'chat-1',
          assistant(content: content, output: null),
        );

        check(row.payload['content']).equals(content);
        check(row.content).equals(content);
        check(row.payload.containsKey('output')).isFalse();
      });

      test('leaves user messages untouched', () {
        const content =
            '<details type="tool_calls"><summary>x</summary>'
            '</details>\nPlease keep this literally.';
        final user = ChatMessage(
          id: 'user-1',
          role: 'user',
          content: content,
          timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
          output: structuredOutput,
        );

        check(localEchoRowForMessage('chat-1', user).payload['content'])
            .equals(content);
      });

      test('direct payload stores the output message text too', () {
        final payload = directPersistedMessagePayloadForTest(
          assistant(
            content: '${renderedDetails}It is sunny.',
            output: structuredOutput,
          ),
        );

        check(payload['content']).equals('It is sunny.');
        check(payload['output'])
            .isA<List<Object?>>()
            .deepEquals(structuredOutput);
      });

      test('direct payload keeps the rendered content for a replay mirror', () {
        // On load the direct replay mirror short-circuits the structured
        // output re-synthesis, so the rendered content is the only copy of
        // the reasoning/tool presentation the UI can show.
        const content =
            '<details type="reasoning" done="true" duration="2">\n'
            '<summary>Thought for 2 seconds</summary>\n> hmm\n</details>\n'
            'It is sunny.';
        final payload = directPersistedMessagePayloadForTest(
          assistant(
            content: content,
            output: buildConduitDirectReplayOutput(
              assistantMessageId: 'assistant-2',
              rawContent: 'It is sunny.',
            ),
          ),
        );

        check(payload['content']).equals(content);
      });
    });
  });
}
