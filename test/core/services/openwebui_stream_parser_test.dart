import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/core/services/openwebui_stream_parser.dart';
import 'package:conduit/core/services/structured_output.dart';
import 'package:conduit/core/services/structured_output_renderer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseOpenWebUIStream', () {
    test('parses delta, usage, and done across split SSE frames', () async {
      final updates = await parseOpenWebUIStream(
        Stream<List<int>>.fromIterable([
          utf8.encode('data: {"choices":[{"delta":{"content":"Hel'),
          utf8.encode('lo"}}]}\n\n'),
          utf8.encode('data: {"usage":{"total_tokens":3}}\n\n'),
          utf8.encode('data: [DONE]\n\n'),
        ]),
      ).toList();

      check(updates).has((it) => it.length, 'length').equals(3);
      check(updates[0])
          .isA<OpenWebUIContentDelta>()
          .has((u) => u.content, 'content')
          .equals('Hello');
      check(updates[1])
          .isA<OpenWebUIUsageUpdate>()
          .has((u) => u.usage['total_tokens'], 'total_tokens')
          .equals(3);
      check(updates[2]).isA<OpenWebUIStreamDone>();
    });

    test('parses a simple single-frame delta', () async {
      final updates = await parseOpenWebUIStream(
        Stream<List<int>>.fromIterable([
          utf8.encode('data: {"choices":[{"delta":{"content":"hi"}}]}\n\n'),
        ]),
      ).toList();

      check(updates).has((it) => it.length, 'length').equals(1);
      check(updates[0])
          .isA<OpenWebUIContentDelta>()
          .has((u) => u.content, 'content')
          .equals('hi');
    });

    test(
      'parses sources, selected model, and structured error frames',
      () async {
        final updates = await parseOpenWebUIStream(
          Stream<List<int>>.fromIterable([
            utf8.encode('data: {"sources":[{"source":{"id":"src-1"}}]}\n\n'),
            utf8.encode('data: {"selected_model_id":"model-b"}\n\n'),
            utf8.encode('data: {"error":{"message":"boom"}}\n\n'),
          ]),
        ).toList();

        check(updates).has((it) => it.length, 'length').equals(3);
        check(updates[0]).isA<OpenWebUISourcesUpdate>();
        check(updates[1])
            .isA<OpenWebUISelectedModelUpdate>()
            .has((u) => u.selectedModelId, 'selectedModelId')
            .equals('model-b');
        check(updates[2]).isA<OpenWebUIErrorUpdate>();
      },
    );

    test('parses typed top-level error envelopes as errors', () async {
      final updates = await parseOpenWebUIStream(
        Stream<List<int>>.fromIterable([
          utf8.encode(
            'data: ${jsonEncode({
              'type': 'error',
              'error': {'message': 'boom'},
            })}\n\n',
          ),
        ]),
      ).toList();

      check(updates).has((it) => it.length, 'length').equals(1);
      check(updates[0])
          .isA<OpenWebUIErrorUpdate>()
          .has((u) => u.error['message'], 'message')
          .equals('boom');
    });

    test('parses OpenWebUI event emitter frames', () async {
      final citation = {
        'type': 'citation',
        'data': {
          'document': [''],
          'metadata': [
            {'source': 'https://example.com'},
          ],
          'source': {'name': 'Example Title'},
        },
      };
      final status = {
        'type': 'status',
        'data': {'description': 'Searching', 'done': false},
      };

      final updates = await parseOpenWebUIStream(
        Stream<List<int>>.fromIterable([
          utf8.encode('data: ${jsonEncode({'event': citation})}\n\n'),
          utf8.encode('data: ${jsonEncode(status)}\n\n'),
        ]),
      ).toList();

      check(updates).has((it) => it.length, 'length').equals(2);
      check(updates[0])
          .isA<OpenWebUIEventUpdate>()
          .has((u) => u.type, 'type')
          .equals('citation');
      check(updates[0])
          .isA<OpenWebUIEventUpdate>()
          .has((u) {
            final data = u.data as Map<String, dynamic>;
            final source = data['source'] as Map<String, dynamic>;
            return source['name'];
          }, 'source.name')
          .equals('Example Title');
      check(
        updates[1],
      ).isA<OpenWebUIEventUpdate>().has((u) => u.type, 'type').equals('status');
    });

    test('preserves direct top-level event payloads', () async {
      final updates = await parseOpenWebUIStream(
        Stream<List<int>>.fromIterable([
          utf8.encode(
            'data: ${jsonEncode({'type': 'status', 'description': 'Searching', 'done': false})}\n\n',
          ),
          utf8.encode(
            'data: ${jsonEncode({
              'type': 'citation',
              'source': {'name': 'Example Title'},
            })}\n\n',
          ),
        ]),
      ).toList();

      check(updates).has((it) => it.length, 'length').equals(2);
      check(updates[0])
          .isA<OpenWebUIEventUpdate>()
          .has(
            (u) => (u.data as Map<String, dynamic>)['description'],
            'description',
          )
          .equals('Searching');
      check(updates[1])
          .isA<OpenWebUIEventUpdate>()
          .has((u) {
            final data = u.data as Map<String, dynamic>;
            final source = data['source'] as Map<String, dynamic>;
            return source['name'];
          }, 'source.name')
          .equals('Example Title');
    });

    test(
      'parses trailing final frame without an extra chunk boundary',
      () async {
        final updates = await parseOpenWebUIStream(
          Stream<List<int>>.fromIterable([
            utf8.encode('data: {"choices":[{"delta":{"content":"done"}}]}\n\n'),
            utf8.encode('data: [DONE]'),
          ]),
        ).toList();

        check(updates).has((it) => it.length, 'length').equals(2);
        check(updates[0])
            .isA<OpenWebUIContentDelta>()
            .has((u) => u.content, 'content')
            .equals('done');
        check(updates[1]).isA<OpenWebUIStreamDone>();
      },
    );

    test('parses multiple SSE payloads from a single decoded chunk', () async {
      final updates = await parseOpenWebUIStream(
        Stream<List<int>>.fromIterable([
          utf8.encode(
            'data: {"choices":[{"delta":{"content":"hi"}}]}\n\n'
            'data: {"usage":{"total_tokens":2}}\n\n'
            'data: [DONE]\n\n',
          ),
        ]),
      ).toList();

      check(updates).has((it) => it.length, 'length').equals(3);
      check(updates[0])
          .isA<OpenWebUIContentDelta>()
          .has((u) => u.content, 'content')
          .equals('hi');
      check(updates[1])
          .isA<OpenWebUIUsageUpdate>()
          .has((u) => u.usage['total_tokens'], 'total_tokens')
          .equals(2);
      check(updates[2]).isA<OpenWebUIStreamDone>();
    });

    test('joins multi-line data fields within a single SSE frame', () async {
      final updates = await parseOpenWebUIStream(
        Stream<List<int>>.fromIterable([
          utf8.encode(
            'data: {"choices":[{"delta":{\n'
            'data: "content":"hello"}}]}\n\n',
          ),
        ]),
      ).toList();

      check(updates).has((it) => it.length, 'length').equals(1);
      check(updates[0])
          .isA<OpenWebUIContentDelta>()
          .has((u) => u.content, 'content')
          .equals('hello');
    });

    test('handles CRLF boundaries split across decoded chunks', () async {
      final updates = await parseOpenWebUIStream(
        Stream<List<int>>.fromIterable([
          utf8.encode('data: {"choices":[{"delta":{"content":"hi"}}]}\r'),
          utf8.encode('\n\r'),
          utf8.encode('\ndata: [DONE]\r\n\r'),
          utf8.encode('\n'),
        ]),
      ).toList();

      check(updates).has((it) => it.length, 'length').equals(2);
      check(updates[0])
          .isA<OpenWebUIContentDelta>()
          .has((u) => u.content, 'content')
          .equals('hi');
      check(updates[1]).isA<OpenWebUIStreamDone>();
    });

    test('flushes trailing unterminated data payloads at stream end', () async {
      final updates = await parseOpenWebUIStream(
        Stream<List<int>>.fromIterable([
          utf8.encode('data: {"choices":[{"delta":{"content":"tail"}}]}'),
        ]),
      ).toList();

      check(updates).has((it) => it.length, 'length').equals(1);
      check(updates[0])
          .isA<OpenWebUIContentDelta>()
          .has((u) => u.content, 'content')
          .equals('tail');
    });

    test('handles a multibyte UTF-8 character split across chunks', () async {
      final bytes = utf8.encode(
        'data: {"choices":[{"delta":{"content":"🙂"}}]}\n\n',
      );
      final updates = await parseOpenWebUIStream(
        Stream<List<int>>.fromIterable([
          bytes.sublist(0, bytes.length - 1),
          bytes.sublist(bytes.length - 1),
        ]),
      ).toList();

      check(updates).has((it) => it.length, 'length').equals(1);
      check(updates[0])
          .isA<OpenWebUIContentDelta>()
          .has((u) => u.content, 'content')
          .equals('🙂');
    });

    test(
      'normalizes CRLF-delimited frames and ignores comment lines',
      () async {
        final updates = await parseOpenWebUIStream(
          Stream<List<int>>.fromIterable([
            utf8.encode(': keepalive\r\n'),
            utf8.encode('event: message\r\n'),
            utf8.encode(
              'data: {"choices":[{"delta":{"content":"hi"}}]}\r\n\r\n',
            ),
          ]),
        ).toList();

        check(updates).has((it) => it.length, 'length').equals(1);
        check(updates[0])
            .isA<OpenWebUIContentDelta>()
            .has((u) => u.content, 'content')
            .equals('hi');
      },
    );

    test('skips keepalive frames that contain no data lines', () async {
      final updates = await parseOpenWebUIStream(
        Stream<List<int>>.fromIterable([
          utf8.encode(': keepalive\n\n'),
          utf8.encode('event: ping\n\n'),
        ]),
      ).toList();

      check(updates).isEmpty();
    });

    test('parses reasoning_content delta', () async {
      final updates = await parseOpenWebUIStream(
        Stream<List<int>>.fromIterable([
          utf8.encode(
            'data: {"choices":[{"delta":{"reasoning_content":"thinking..."}}]}\n\n',
          ),
          utf8.encode('data: {"choices":[{"delta":{"content":"result"}}]}\n\n'),
          utf8.encode('data: [DONE]\n\n'),
        ]),
      ).toList();

      check(updates).has((it) => it.length, 'length').equals(3);
      check(updates[0])
          .isA<OpenWebUIReasoningDelta>()
          .has((u) => u.content, 'content')
          .equals('thinking...');
      check(updates[1])
          .isA<OpenWebUIContentDelta>()
          .has((u) => u.content, 'content')
          .equals('result');
      check(updates[2]).isA<OpenWebUIStreamDone>();
    });

    test('parses output array from stream chunk', () async {
      final outputJson = jsonEncode([
        {
          'type': 'message',
          'id': 'msg_001',
          'status': 'in_progress',
          'role': 'assistant',
          'content': [
            {'type': 'output_text', 'text': 'hello'},
          ],
        },
      ]);
      final updates = await parseOpenWebUIStream(
        Stream<List<int>>.fromIterable([
          utf8.encode('data: {"output":$outputJson}\n\n'),
          utf8.encode('data: [DONE]\n\n'),
        ]),
      ).toList();

      check(updates).has((it) => it.length, 'length').equals(2);
      check(updates[0])
          .isA<OpenWebUIOutputUpdate>()
          .has((u) => u.output.length, 'output.length')
          .equals(1);
      check(updates[0])
          .isA<OpenWebUIOutputUpdate>()
          .has((u) => u.blocks.length, 'blocks.length')
          .equals(1);
      check(updates[0])
          .isA<OpenWebUIOutputUpdate>()
          .has((u) => u.blocks.single, 'block')
          .isA<StructuredOutputTextBlock>()
          .has((block) => block.text, 'text')
          .equals('hello');
      check(updates[1]).isA<OpenWebUIStreamDone>();
    });

    test('emits delta before output for mixed stream chunks', () async {
      final updates = await parseOpenWebUIStream(
        Stream<List<int>>.fromIterable([
          utf8.encode(
            'data: ${jsonEncode({
              'output': [
                {
                  'type': 'message',
                  'content': [
                    {'type': 'output_text', 'text': 'Hello'},
                  ],
                },
              ],
              'choices': [
                {
                  'delta': {'content': 'Hello'},
                },
              ],
            })}\n\n',
          ),
        ]),
      ).toList();

      check(updates).has((it) => it.length, 'length').equals(2);
      check(updates[0]).isA<OpenWebUIContentDelta>();
      check(updates[1]).isA<OpenWebUIOutputUpdate>();
    });

    test('emits usage and output from the same stream chunk', () async {
      final updates = await parseOpenWebUIStream(
        Stream<List<int>>.fromIterable([
          utf8.encode(
            'data: ${jsonEncode({
              'usage': {'total_tokens': 7},
              'output': [
                {
                  'type': 'message',
                  'content': [
                    {'type': 'output_text', 'text': 'Hello'},
                  ],
                },
              ],
            })}\n\n',
          ),
        ]),
      ).toList();

      check(updates).has((it) => it.length, 'length').equals(2);
      check(updates[0])
          .isA<OpenWebUIUsageUpdate>()
          .has((update) => update.usage['total_tokens'], 'total_tokens')
          .equals(7);
      check(updates[1])
          .isA<OpenWebUIOutputUpdate>()
          .has((update) => update.blocks.single, 'block')
          .isA<StructuredOutputTextBlock>()
          .has((block) => block.text, 'text')
          .equals('Hello');
    });

    test('parses both reasoning_content and content in same delta', () async {
      final updates = await parseOpenWebUIStream(
        Stream<List<int>>.fromIterable([
          utf8.encode(
            'data: {"choices":[{"delta":{"reasoning_content":"think","content":"say"}}]}\n\n',
          ),
        ]),
      ).toList();

      // Both should be emitted since the delta contains both fields.
      check(updates).has((it) => it.length, 'length').equals(2);
      check(updates[0])
          .isA<OpenWebUIReasoningDelta>()
          .has((u) => u.content, 'content')
          .equals('think');
      check(updates[1])
          .isA<OpenWebUIContentDelta>()
          .has((u) => u.content, 'content')
          .equals('say');
    });
  });

  group('structured output rendering', () {
    test('preserves multipart message text as one escaped block', () {
      final serialized = renderStructuredOutputBlocks(
        parseOpenWebUIStructuredOutput([
          {
            'type': 'message',
            'content': [
              {'type': 'output_text', 'text': ' hello '},
              {'type': 'text', 'text': '<world>\n'},
            ],
          },
        ]),
      );

      check(serialized).equals(' hello \n&lt;world&gt;\n');
    });

    test('extracts text-bearing message parts without a type', () {
      final serialized = renderStructuredOutputBlocks(
        parseOpenWebUIStructuredOutput([
          {
            'type': 'message',
            'content': [
              {'text': 'typeless text'},
            ],
          },
        ]),
      );

      check(serialized).equals('typeless text');
    });

    test('replacement text preserves text block ordering around details', () {
      final rendered = renderStructuredOutputBlocksWithContent(
        parseOpenWebUIStructuredOutput([
          {
            'type': 'message',
            'content': [
              {'type': 'output_text', 'text': 'A'},
            ],
          },
          {
            'type': 'reasoning',
            'status': 'completed',
            'summary': [
              {'type': 'summary_text', 'text': 'thinking'},
            ],
          },
          {
            'type': 'message',
            'content': [
              {'type': 'output_text', 'text': 'B'},
            ],
          },
        ]),
        'AB',
      );

      check(rendered).startsWith('A\n<details type="reasoning"');
      check(rendered).endsWith('</details>\nB');
    });

    test('replacement text is appended after detail-only output', () {
      final rendered = renderStructuredOutputBlocksWithContent(
        parseOpenWebUIStructuredOutput([
          {
            'type': 'reasoning',
            'status': 'completed',
            'summary': [
              {'type': 'summary_text', 'text': 'thinking'},
            ],
          },
        ]),
        'Final answer',
      );

      check(rendered).startsWith('<details type="reasoning"');
      check(rendered).endsWith('</details>\nFinal answer');
    });

    test('completed function call stays pending until output arrives', () {
      final blocks = parseOpenWebUIStructuredOutput([
        {
          'type': 'function_call',
          'call_id': 'call-1',
          'name': 'search',
          'status': 'completed',
          'arguments': {'query': 'docs'},
        },
      ]);
      final toolBlock = blocks.single as StructuredOutputToolCallBlock;
      final serialized = renderStructuredOutputBlocks(blocks);

      check(toolBlock.done).isFalse();
      check(serialized).contains('<summary>Executing...</summary>');
      check(serialized).contains('done="false"');
    });

    test('renders custom tool call output as details', () {
      final blocks = parseOpenWebUIStructuredOutput([
        {
          'type': 'custom_tool_call',
          'id': 'custom-1',
          'name': 'lookup',
          'input': {'query': 'docs'},
        },
        {
          'type': 'custom_tool_call_output',
          'id': 'custom-1',
          'content': 'result',
        },
      ]);
      final toolBlock = blocks.single as StructuredOutputToolCallBlock;

      check(toolBlock.name).equals('lookup');
      check(toolBlock.result).equals('result');
      check(toolBlock.done).isTrue();
    });

    test('code interpreter fence grows around untrusted backticks', () {
      final rendered = renderStructuredOutputBlocks(
        parseOpenWebUIStructuredOutput([
          {
            'type': 'code_interpreter',
            'status': 'completed',
            'language': 'dart',
            'code': 'print("before");\n```\nprint("after");',
          },
        ]),
      );

      check(rendered).contains('````dart');
      check(rendered).contains('print(&quot;after&quot;);');
    });

    test('escapes generated details body and attributes', () {
      final serialized = renderStructuredOutputBlocks(
        parseOpenWebUIStructuredOutput([
          {
            'type': 'reasoning',
            'duration': '1" autofocus="true',
            'summary': [
              {
                'type': 'summary_text',
                'text': '</details><script>alert(1)</script>',
              },
            ],
          },
          {
            'type': 'function_call',
            'call_id': 'call" onmouseover="x',
            'name': 'tool<script>',
            'arguments': {'q': '" onclick="x'},
          },
          {
            'type': 'function_call_output',
            'call_id': 'call" onmouseover="x',
            'output': '</details><img src=x onerror=alert(1)>',
          },
          {
            'type': 'code_interpreter',
            'status': 'completed',
            'duration': '2',
            'language': 'dart',
            'code': '</details><script>alert(1)</script>',
            'output': {'stdout': '<ok>'},
          },
        ]),
      );

      check(serialized).contains('&lt;&#47;details&gt;');
      check(serialized).contains('duration="1&quot; autofocus=&quot;true"');
      check(serialized).contains('id="call&quot; onmouseover=&quot;x"');
      check(serialized).contains('name="tool&lt;script&gt;"');
      check(serialized).not((it) => it.contains('<script>'));
      check(serialized).not((it) => it.contains('onmouseover="x"'));
      check(serialized).not((it) => it.contains('<img src=x'));
    });

    test('keeps in-progress reasoning open even when more output follows', () {
      final blocks = parseOpenWebUIStructuredOutput([
        {
          'type': 'reasoning',
          'status': 'in_progress',
          'summary': [
            {'type': 'summary_text', 'text': 'thinking'},
          ],
        },
        {
          'type': 'message',
          'content': [
            {'type': 'output_text', 'text': 'answer'},
          ],
        },
      ]);
      final serialized = renderStructuredOutputBlocks(blocks);

      check(blocks.first)
          .isA<StructuredOutputReasoningBlock>()
          .has((block) => block.done, 'done')
          .equals(false);
      check(serialized).contains('<details type="reasoning" done="false">');
    });

    test('falls back from empty reasoning summary to content', () {
      final blocks = parseOpenWebUIStructuredOutput([
        {
          'type': 'reasoning',
          'summary': [
            {'type': 'summary_text', 'text': ''},
          ],
          'content': [
            {'type': 'output_text', 'text': 'content reasoning'},
          ],
        },
      ]);
      final serialized = renderStructuredOutputBlocks(blocks);

      check(blocks.single)
          .isA<StructuredOutputReasoningBlock>()
          .has((block) => block.text, 'text')
          .equals('content reasoning');
      check(serialized).contains('&gt; content reasoning');
    });

    test('reads string reasoning content', () {
      final blocks = parseOpenWebUIStructuredOutput([
        {'type': 'reasoning', 'content': 'plain reasoning'},
      ]);

      check(blocks.single)
          .isA<StructuredOutputReasoningBlock>()
          .has((block) => block.text, 'text')
          .equals('plain reasoning');
    });

    test('keeps failed tool calls and code interpreter blocks open', () {
      final blocks = parseOpenWebUIStructuredOutput([
        {
          'type': 'function_call',
          'call_id': 'call-1',
          'name': 'search',
          'status': 'failed',
        },
        {
          'type': 'code_interpreter',
          'status': 'incomplete',
          'code': 'print(1)',
        },
      ]);

      check(blocks[0])
          .isA<StructuredOutputToolCallBlock>()
          .has((block) => block.done, 'done')
          .isFalse();
      check(blocks[1])
          .isA<StructuredOutputCodeInterpreterBlock>()
          .has((block) => block.done, 'done')
          .isFalse();
    });

    test('serializes upstream code interpreter output shape', () {
      final blocks = parseOpenWebUIStructuredOutput([
        {
          'type': 'open_webui:code_interpreter',
          'status': 'completed',
          'lang': 'python',
          'code': 'print("ok")',
          'output': {'stdout': 'ok'},
        },
      ]);
      final serialized = renderStructuredOutputBlocks(blocks);

      check(blocks.single)
          .isA<StructuredOutputCodeInterpreterBlock>()
          .has((block) => block.language, 'language')
          .equals('python');
      check(serialized).contains('<details type="code_interpreter"');
      check(serialized).contains('```python');
      check(serialized).contains('print(&quot;ok&quot;)');
    });

    test('marks non-last code interpreter output done without status', () {
      final blocks = parseOpenWebUIStructuredOutput([
        {
          'type': 'open_webui:code_interpreter',
          'lang': 'python',
          'code': 'print("ok")',
        },
        {
          'type': 'message',
          'content': [
            {'type': 'output_text', 'text': 'answer'},
          ],
        },
      ]);
      final codeBlock = blocks.first as StructuredOutputCodeInterpreterBlock;
      final serialized = renderStructuredOutputBlocks(blocks);

      check(codeBlock.done).isTrue();
      check(
        serialized,
      ).contains('<details type="code_interpreter" done="true"');
    });

    test('marks function call done when output item is present', () {
      final blocks = parseOpenWebUIStructuredOutput([
        {
          'type': 'function_call',
          'call_id': 'call-1',
          'name': 'search',
          'status': 'completed',
          'arguments': {'query': 'docs'},
        },
        {
          'type': 'function_call_output',
          'call_id': 'call-1',
          'output': 'result',
        },
      ]);
      final toolBlock = blocks.single as StructuredOutputToolCallBlock;
      final serialized = renderStructuredOutputBlocks(blocks);

      check(toolBlock.done).isTrue();
      check(serialized).contains('<summary>Tool Executed</summary>');
      check(serialized).contains('done="true"');
    });

    test('renders OpenAI built-in tool output types as details', () {
      final blocks = parseOpenWebUIStructuredOutput([
        {
          'type': 'web_search_call',
          'id': 'web-1',
          'status': 'completed',
          'action': {
            'type': 'search',
            'queries': ['cats', 'dogs'],
          },
        },
        {
          'type': 'file_search_call',
          'id': 'file-1',
          'status': 'in_progress',
          'queries': ['notes'],
        },
        {
          'type': 'computer_call',
          'id': 'computer-1',
          'status': 'completed',
          'action': {'type': 'click'},
        },
      ]);
      final serialized = renderStructuredOutputBlocks(blocks);

      check(blocks).has((items) => items.length, 'length').equals(3);
      check(serialized).contains('name="Web Search"');
      check(serialized).contains('name="File Search"');
      check(serialized).contains('name="Computer Use"');
      check(serialized).contains('result="&quot;Search: cats, dogs&quot;"');
      check(serialized).contains('result="&quot;Queries: notes&quot;"');
      check(serialized).contains('result="&quot;Action: click&quot;"');
    });

    test('preserves raw structured tool output values until rendering', () {
      final blocks = parseOpenWebUIStructuredOutput([
        {
          'type': 'function_call',
          'call_id': 'call-1',
          'name': 'search',
          'arguments': {'query': 'cats'},
        },
        {
          'type': 'function_call_output',
          'call_id': 'call-1',
          'output': [
            {'text': 'one'},
            {'text': 'two'},
          ],
        },
      ]);

      final toolBlock = blocks.single as StructuredOutputToolCallBlock;
      check(
        toolBlock.result,
      ).isA<List<dynamic>>().has((items) => items.length, 'length').equals(2);
      final serialized = renderStructuredOutputBlocks(blocks);
      check(serialized).contains(
        'result="[{&quot;text&quot;:&quot;one&quot;},{&quot;text&quot;:&quot;two&quot;}]"',
      );
    });
  });
}
