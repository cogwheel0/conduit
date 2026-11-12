import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/features/chat/views/assistant_message_blocks.dart';
import 'package:conduit_core/features/chat/views/chat_status_display.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_markdown/conduit_markdown.dart';
import 'package:test/test.dart';

/// The display blocks an assistant answer turns into for a plain markdown
/// renderer: what the mobile app draws, in its order, and the same frame by
/// frame while it streams.
void main() {
  const reasoning =
      '<details type="reasoning" done="true" duration="4">\n'
      '<summary>Thought for 4 seconds</summary>\n'
      'The reader wants tide times, which cost \$0 to look up.\n'
      '</details>';
  const toolCall =
      '<details type="tool_calls" done="true" id="call_t1" name="tide_table" '
      'arguments="{&quot;harbour&quot;:&quot;Port Wren&quot;}" '
      'result="&quot;High water 06:12&quot;">\n'
      '<summary>Tool Executed</summary>\n'
      '</details>';
  const answer =
      'High water is at 06:12 [1], and the range is \$h = 2.4\$ m [2]. '
      'A chart costs \$5.';

  ChatMessage mixed({bool streaming = false, String? content}) => ChatMessage(
    id: 'msg-a1',
    role: 'assistant',
    content: content ?? '$reasoning\n\n$toolCall\n\n$answer',
    timestamp: DateTime.utc(2026, 11, 8),
    isStreaming: streaming,
    files: const <Map<String, dynamic>>[
      {
        'type': 'image',
        'id': 'file-chart',
        'url': '/api/v1/files/file-chart/content',
        'name': 'chart.png',
      },
    ],
    output: const <Map<String, dynamic>>[
      {
        'type': 'function_call',
        'call_id': 'show-1',
        'name': 'display_file',
        'arguments': '{}',
      },
      {
        'type': 'function_call_output',
        'call_id': 'show-1',
        'output':
            '{"type":"file","exists":true,"source":"open_webui",'
            '"path":"/api/v1/files/file-notes/content","name":"notes.pdf",'
            '"content_type":"application/pdf"}',
      },
    ],
    statusHistory: const <ChatStatusUpdate>[
      ChatStatusUpdate(
        action: 'web_search_queries_generated',
        queries: <String>['port wren tides', ' port wren tides '],
        done: true,
      ),
      ChatStatusUpdate(
        action: 'sources_retrieved',
        count: 2,
        urls: <String>['https://example.com/tides'],
        items: <ChatStatusItem>[
          ChatStatusItem(title: 'Tide basics', link: 'https://example.org/a'),
        ],
        done: true,
      ),
      ChatStatusUpdate(description: 'Hidden', hidden: true, done: true),
    ],
    codeExecutions: const <ChatCodeExecution>[
      ChatCodeExecution(
        id: 'exec-1',
        name: 'chart.py',
        language: 'python',
        code: 'plot(tides)',
        result: ChatCodeExecutionResult(output: 'saved'),
      ),
      ChatCodeExecution(id: 'exec-2', code: 'pending()'),
    ],
    sources: const <ChatSourceReference>[
      ChatSourceReference(id: 's1', title: 'Tide tables'),
      ChatSourceReference(id: 's2', title: 'Harbour notes'),
    ],
    followUps: const <String>[
      ' Why two tides? ',
      '',
      'Show a chart',
      'More',
      'x',
    ],
    error: const ChatMessageError(content: 'The search quota ran out.'),
  );

  String kinds(List<AssistantBlock> blocks) => [
    for (final block in blocks)
      switch (block) {
        AssistantFilesBlock() => 'files',
        AssistantStatusBlock() => 'status',
        AssistantMarkdownBlock(:final block) => block.kind.name,
        AssistantErrorBlock() => 'error',
        AssistantCodeExecutionBlock() => 'codeExecution',
        AssistantSourcesBlock() => 'sources',
        AssistantFollowUpsBlock() => 'followUps',
      },
  ].join(' ');

  group('a finished answer', () {
    final blocks = assistantMessageBlocks(mixed());

    test('comes out in the mobile app\'s order', () {
      expect(
        kinds(blocks),
        'files status reasoning toolCalls text error codeExecution '
        'codeExecution sources followUps',
      );
    });

    test('shows its own files, then the files the model showed', () {
      final files = (blocks[0] as AssistantFilesBlock).files;
      expect(files.map((f) => f['name']), <String>['chart.png', 'notes.pdf']);
    });

    test('groups files as the mobile app shows them: images, videos, rest', () {
      final files =
          (assistantMessageBlocks(
                    ChatMessage(
                      id: 'msg-files',
                      role: 'assistant',
                      content: 'Here they are.',
                      timestamp: DateTime.utc(2026, 11, 8),
                      files: const <Map<String, dynamic>>[
                        {'type': 'file', 'id': 'f1', 'name': 'tides.pdf'},
                        {'type': 'image', 'id': 'f2', 'name': 'chart.png'},
                        {
                          'type': 'file',
                          'id': 'f3',
                          'name': 'swell.mp4',
                          'content_type': 'video/mp4',
                        },
                        {'type': 'file', 'id': 'f4', 'name': 'notes.txt'},
                        {'type': 'image', 'id': 'f5', 'name': 'map.png'},
                      ],
                    ),
                  ).first
                  as AssistantFilesBlock)
              .files;
      expect(files.map((f) => f['name']), <String>[
        'chart.png',
        'map.png',
        'swell.mp4',
        'tides.pdf',
        'notes.txt',
      ]);
    });

    test('reads its status lines as Open WebUI words them', () {
      final status = blocks[1] as AssistantStatusBlock;
      expect(status.pending, isFalse);
      expect(status.toolSummary, isNull);
      expect(status.lines.map((l) => l.description), <String>[
        'Searching',
        'Retrieved 2 sources',
      ]);
      expect(status.lines.first.queries, <String>['port wren tides']);
      expect(status.lines.last.links, const <StatusLink>[
        StatusLink(url: 'https://example.org/a', title: 'Tide basics'),
        StatusLink(url: 'https://example.com/tides'),
      ]);
    });

    test('splits and normalises the content', () {
      final reasoningBlock =
          (blocks[2] as AssistantMarkdownBlock).block as ReasoningMessageBlock;
      expect(reasoningBlock.title.kind, ReasoningTitleKind.thoughtFor);
      expect(reasoningBlock.title.seconds, 4);
      // Reasoning is markdown too: its prose dollar is escaped.
      expect(reasoningBlock.body, contains(r'cost \$0'));

      final tools =
          (blocks[3] as AssistantMarkdownBlock).block as ToolCallsMessageBlock;
      expect(tools.calls.single.name, 'tide_table');
      expect(tools.calls.single.arguments, '{"harbour":"Port Wren"}');
      expect(tools.calls.single.result, '"High water 06:12"');

      final text = (blocks[4] as AssistantMarkdownBlock).block;
      expect(
        (text as TextMessageBlock).markdown,
        r'High water is at 06:12 [1](conduit-cite:1), and the range is '
        r'$h = 2.4$ m [2](conduit-cite:2). A chart costs \$5.',
      );
    });

    test('carries the error, the code executions and the sources', () {
      final error = blocks[5] as AssistantErrorBlock;
      expect(error.text, 'The search quota ran out.');
      expect(error.toolsUnsupported, isFalse);

      final ran = blocks[6] as AssistantCodeExecutionBlock;
      expect(ran.execution.name, 'chart.py');
      expect((ran.done, ran.isError), (true, false));
      final running = blocks[7] as AssistantCodeExecutionBlock;
      expect(running.done, isFalse);

      // Marker n cites sources[n - 1], as the mobile chips do.
      final sources = blocks[8] as AssistantSourcesBlock;
      expect(sources.sources.map((s) => s.title), <String>[
        'Tide tables',
        'Harbour notes',
      ]);
    });

    test('offers at most three trimmed follow-ups', () {
      expect((blocks[9] as AssistantFollowUpsBlock).followUps, <String>[
        'Why two tides?',
        'Show a chart',
        'More',
      ]);
    });
  });

  group('a streaming answer', () {
    test('holds back an unfinished section and waits on follow-ups', () {
      final partial = mixed(
        streaming: true,
        content:
            '$reasoning\n\nHigh water is at 06:12 [1].\n\n'
            '<details type="tool_calls" done="false" id="call_t2" '
            'name="tide_table">',
      );
      // An answer with an error has failed, not streaming; mobile's phase
      // rule.
      expect(kinds(assistantMessageBlocks(partial)), endsWith('followUps'));
      final blocks = assistantMessageBlocks(partial.copyWith(error: null));
      expect(
        kinds(blocks),
        'files status reasoning text codeExecution codeExecution sources',
      );
      final text = (blocks[3] as AssistantMarkdownBlock).block;
      expect(
        (text as TextMessageBlock).markdown,
        'High water is at 06:12 [1](conduit-cite:1).',
      );
    });

    test('keeps every status while running, and shimmers on the last', () {
      final message = ChatMessage(
        id: 'msg-s',
        role: 'assistant',
        content: '',
        timestamp: DateTime.utc(2026, 11, 8),
        isStreaming: true,
        statusHistory: const <ChatStatusUpdate>[
          ChatStatusUpdate(description: 'Searching the web', done: false),
        ],
      );
      final running = assistantMessageBlocks(message);
      expect(kinds(running), 'status');
      final status = running.single as AssistantStatusBlock;
      expect(status.pending, isTrue);
      expect(status.lines.single.description, 'Searching the web');

      // Settled with no update done, the last one stays, not shimmering.
      final settled = assistantMessageBlocks(
        message.copyWith(isStreaming: false),
      );
      expect((settled.single as AssistantStatusBlock).pending, isFalse);
    });

    test('groups Hermes tools under one summary', () {
      final message = ChatMessage(
        id: 'msg-h',
        role: 'assistant',
        content: '',
        timestamp: DateTime.utc(2026, 11, 8),
        isStreaming: true,
        statusHistory: const <ChatStatusUpdate>[
          ChatStatusUpdate(action: 'hermes_tool_terminal', done: true),
          ChatStatusUpdate(action: 'hermes_tool_terminal', done: true),
          ChatStatusUpdate(action: 'hermes_tool_web_search', done: false),
        ],
      );
      final status =
          assistantMessageBlocks(message).single as AssistantStatusBlock;
      expect(status.toolSummary, 'terminal (2), web_search');
      expect(status.pending, isTrue);
    });

    test('names an unnamed Hermes tool in the host\'s words', () {
      final message = ChatMessage(
        id: 'msg-h',
        role: 'assistant',
        content: '',
        timestamp: DateTime.utc(2026, 11, 8),
        isStreaming: true,
        statusHistory: const <ChatStatusUpdate>[
          ChatStatusUpdate(action: 'hermes_tool_terminal', done: true),
          ChatStatusUpdate(action: 'hermes_tool_opaque', done: true),
        ],
      );
      final status =
          assistantMessageBlocks(message, unnamedTool: 'Werkzeug').single
              as AssistantStatusBlock;
      expect(status.toolSummary, contains('Werkzeug'));
      expect(status.toolSummary, isNot(contains('tool')));
    });
  });

  test('an earlier version shows its own parts and no status', () {
    final version = ChatMessageVersion(
      id: 'msg-v0',
      content: 'An older answer [1].',
      timestamp: DateTime.utc(2026, 11, 7),
      sources: const <ChatSourceReference>[ChatSourceReference(id: 's1')],
      followUps: const <String>['Again?'],
    );
    final blocks = assistantVersionBlocks(version);
    expect(kinds(blocks), 'text sources followUps');
    expect(
      ((blocks.first as AssistantMarkdownBlock).block as TextMessageBlock)
          .markdown,
      'An older answer [1](conduit-cite:1).',
    );
  });

  test('a citation past the sources stays text, as on mobile', () {
    final message = ChatMessage(
      id: 'msg-c',
      role: 'assistant',
      content: 'One [1], two [2].',
      timestamp: DateTime.utc(2026, 11, 8),
      sources: const <ChatSourceReference>[ChatSourceReference(id: 's1')],
    );
    final text =
        (assistantMessageBlocks(message).first as AssistantMarkdownBlock).block
            as TextMessageBlock;
    expect(text.markdown, 'One [1](conduit-cite:1), two [2].');
  });

  test('a model that refused tools is flagged for the hosts\' advice', () {
    final message = ChatMessage(
      id: 'msg-e',
      role: 'assistant',
      content: '',
      timestamp: DateTime.utc(2026, 11, 8),
      error: const ChatMessageError(
        content: 'HTTP 400: this model does not support tools',
      ),
    );
    final error = assistantMessageBlocks(message).single as AssistantErrorBlock;
    expect(error.toolsUnsupported, isTrue);
  });

  test('a question has no blocks', () {
    final question = ChatMessage(
      id: 'msg-q',
      role: 'user',
      content: 'When is high water?',
      timestamp: DateTime.utc(2026, 11, 8),
    );
    expect(assistantMessageBlocks(question), isEmpty);
  });

  test('placeholders go and a bare base64 image becomes an image', () {
    expect(
      assistantDisplayContent(
        '[TYPING_INDICATOR]Here:\ndata:image/png;base64,iVBORw0KGgo=\n',
      ),
      'Here:\n![Generated Image](data:image/png;base64,iVBORw0KGgo=)\n',
    );
  });

  group('streaming frame by frame', () {
    // Blank-line runs can differ around display math: the segmenter's
    // `<details>` path pads it with blank lines its plain path does not.
    // Both render the same.
    String canonical(List<MessageBlock> blocks) =>
        [for (final block in blocks) jsonEncode(block.toJson())]
            .join('\n')
            .replaceAll(RegExp(r'(\\n){3,}'), r'\n\n');

    void expectSameAsWholeParse(
      String name,
      String content, {
      required int sources,
      int step = 1,
    }) {
      final live = StreamingContentBlocks();
      for (var end = 0; end <= content.length; end += step) {
        final text = assistantDisplayContent(content.substring(0, end));
        if (text.trim().isEmpty) continue;
        final incremental = live.blocks(text, sourceCount: sources);
        final whole = plainMarkdownContentBlocks(
          text,
          streaming: true,
          sourceCount: sources,
        );
        if (canonical(incremental) != canonical(whole)) {
          fail(
            '$name: frame ending at $end (kept ${live.closedLength}) '
            'differs:\n${canonical(incremental)}\n---\n${canonical(whole)}',
          );
        }
      }
    }

    test('matches a whole parse at every length of the corpus', () {
      final corpus = (jsonDecode(
        File(
          '../conduit_markdown/test/corpus/'
          'assistant_message_blocks.json',
        ).readAsStringSync(),
      ) as List).cast<Map<String, Object?>>();
      expect(corpus.length, greaterThan(40));
      for (final entry in corpus) {
        final name = entry['name']! as String;
        final content = entry['content']! as String;
        expectSameAsWholeParse(name, content, sources: 3);
        expectSameAsWholeParse('$name, no sources', content, sources: 0);
      }
    });

    test('matches a whole parse through code, math, HTML and sections', () {
      final hard = _hardStream();
      expectSameAsWholeParse('hard', hard, sources: 3);
      expectSameAsWholeParse('hard, no sources', hard, sources: 0);
      expectSameAsWholeParse('hard twice', '$hard$hard', sources: 2, step: 3);
    });

    test('a section tag shown in code does not hold the rest open', () {
      final paragraphs = [
        for (var i = 0; i < 20; i++) 'Paragraph $i on tides.\n\n',
      ].join();
      for (final example in <String>[
        'A section is written like this:\n\n'
            '```html\n<details>\n<summary>More</summary>\n```\n\n',
        'Write `<details>` to open a section.\n\n',
        'A tilde fence:\n\n~~~\n<details open>\n~~~\n\n',
      ]) {
        final content = '$example${paragraphs}Still writ';
        final live = StreamingContentBlocks()..blocks(content, sourceCount: 0);
        expect(
          live.closedLength,
          greaterThan(content.indexOf('Paragraph 18')),
          reason: example,
        );
        expectSameAsWholeParse(example, content, sources: 0, step: 7);
      }
    });

    test('a tool call opened in code still holds the rest open', () {
      // While an answer streams, an unfinished tool call is dropped with
      // everything after it, in code or not.
      final content =
          'The call looks like:\n\n```\n<details type="tool_calls" '
          'name="tide_table">\n```\n\n'
          '${[for (var i = 0; i < 6; i++) 'Paragraph $i.\n\n'].join()}'
          'Still writ';
      expectSameAsWholeParse('tool call in code', content, sources: 0);
      expectSameAsWholeParse(
        'tool call in code, closed',
        content.replaceFirst('Paragraph 3.', 'Paragraph 3 </details>.'),
        sources: 0,
      );
    });

    test('keeps what is closed and re-reads only the tail', () {
      final live = StreamingContentBlocks();
      final long = [for (var i = 0; i < 50; i++) 'Paragraph $i costs \$$i.\n\n']
          .join();
      live.blocks('${long}Still writ', sourceCount: 0);
      expect(
        live.closedLength,
        long.length - 'Paragraph 49 costs \$49.\n\n'.length,
      );
      // Replaced rather than extended: starts over.
      live.blocks('Something else entirely.', sourceCount: 0);
      expect(live.closedLength, 0);
      // An open section keeps everything after it open.
      live.blocks(_hardStream(), sourceCount: 0);
      expect(live.closedLength, lessThan(_hardStream().indexOf('Visible.')));
    });
  });
}

/// Invented content that exercises every construct the cut must not split.
String _hardStream() => [
  '<details type="reasoning" done="true" duration="3">\n'
      '<summary>Thought for 3 seconds</summary>\n'
      'Plan: \$5 and \$x\$.\n'
      '</details>\n\n',
  'Intro costs \$5 and \$10 but \$x^2\$ is math [1].\n\n',
  '\$\$\na = b\n\nc = d\n\$\$\n\n',
  'A paragraph with a `stray backtick\n\nNext \$y\$ [2][3].\n\n',
  '```python\nprint("\$x")\n\nmore = 1\n```\n\n',
  '~~~\ncode \$z\n\n~~~\n\n',
  '````md\n```\ninner\n```\n````\n\n',
  '- item one\n\n    continued \$q\$\n\n- item two\n\n',
  '    indented code \$x\$\n\nAfter code.\n\n',
  '\\[\n\\int_0^1 x\n\n\\]\n\n',
  'Inline \\(a + b\\) and \\(c\n\nd\\) end.\n\n',
  '<!-- comment\n\n<details type="tool_calls">\n-->\n\nVisible.\n\n',
  '<pre>\n\$a\n\n\$b\n</pre>\n\n',
  '<details type="tool_calls" done="true" id="c1" name="a" arguments="{}" '
      'result="&quot;ok&quot;">\n<summary>Tool Executed</summary>\n'
      '</details>\n\n',
  '<details type="tool_calls" done="true" id="c2" name="b" arguments="{}" '
      'result="&quot;ok&quot;">\n<summary>Tool Executed</summary>\n'
      '</details>\n\n',
  'Between tools.\n\n',
  '<details type="code_interpreter" done="false">\n<summary>Analyzing'
      '</summary>\n```python\nprint(1)\n```\n</details>\n\n',
  '| a | b |\n|---|---|\n| \$1 | 2 |\n\n',
  '> quote \$5\n\n> more\n\n',
  '**Label**\n---\n\nTrailing spaces  \n\nx```\n\ncode\n```\n\nEnd [1].\n',
  'Text\n\n\n\nAfter three blanks.\n\n  Indented start\n\n\tTab start\n\n',
  'Line ending space \n\nNext.\n\n',
  '<details type="reasoning" done="false">\n<summary>Thinking…</summary>\n'
      'Still going',
].join();
