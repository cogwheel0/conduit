@TestOn('vm')
library;

import 'dart:convert';

import 'package:conduit_core/features/chat/views/assistant_message_blocks.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/services/chat_completion_transport.dart'
    show kHeldReplyUnresolvedMessage;
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/src/message_blocks.dart';
import 'package:test/test.dart';

import 'support/thread_cpu_time.dart';

/// Stored answers' blocks on the wire: how they map, when the cache answers,
/// and what one streaming frame of a long answer costs.
void main() {
  ChatMessage answer({
    String content = 'High water is at 06:12 [1].',
    List<ChatStatusUpdate> statuses = const <ChatStatusUpdate>[],
  }) => ChatMessage(
    id: 'msg-a',
    role: 'assistant',
    content: content,
    timestamp: DateTime.utc(2026, 11, 8),
    statusHistory: statuses,
    sources: const <ChatSourceReference>[
      ChatSourceReference(
        id: 'src-1',
        title: 'Tide tables',
        url: 'https://example.com/tides',
      ),
    ],
  );

  group('the cache', () {
    test('answers an unchanged message without parsing it again', () {
      final blocks = MessageBlocks();
      final first = blocks.forMessage(answer());
      expect((blocks.hits, blocks.misses), (0, 1));
      final second = blocks.forMessage(answer());
      expect((blocks.hits, blocks.misses), (1, 1));
      expect(identical(first, second), isTrue);
    });

    test('parses again when the content or anything else changes', () {
      final blocks = MessageBlocks();
      blocks.forMessage(answer());
      blocks.forMessage(answer(content: 'Low water is at 12:40 [1].'));
      blocks.forMessage(
        answer(
          content: 'Low water is at 12:40 [1].',
          statuses: const <ChatStatusUpdate>[
            ChatStatusUpdate(action: 'web_search', done: true),
          ],
        ),
      );
      expect((blocks.hits, blocks.misses), (0, 3));
    });

    test('keeps versions apart from the message they hang on', () {
      final blocks = MessageBlocks();
      final message = answer();
      final version = ChatMessageVersion(
        id: 'msg-v0',
        content: 'An earlier answer.',
        timestamp: DateTime.utc(2026, 11, 7),
      );
      final current = blocks.forMessage(message);
      final earlier = blocks.forVersion(message, version);
      expect(
        current.first.markdown,
        'High water is at 06:12 [1](conduit-cite:1).',
      );
      expect(earlier.single.markdown, 'An earlier answer.');
      blocks.forVersion(message, version);
      expect((blocks.hits, blocks.misses), (1, 2));
    });

    test('lets the least recently used message go past its capacity', () {
      final blocks = MessageBlocks(capacity: 2);
      for (final id in <String>['a', 'b', 'c']) {
        blocks.forMessage(answer().copyWith(id: id));
      }
      blocks.forMessage(answer().copyWith(id: 'c'));
      expect(blocks.hits, 1);
      blocks.forMessage(answer().copyWith(id: 'a'));
      expect(blocks.misses, 4);
    });

    test('has nothing for a question', () {
      final blocks = MessageBlocks();
      expect(blocks.forMessage(answer().copyWith(role: 'user')), isEmpty);
      expect(blocks.misses, 0);
    });
  });

  group('on the wire', () {
    test('alerts, embeds and a tool call\'s embeds have kinds of their own', () {
      final message = ChatMessage(
        id: 'msg-rich',
        role: 'assistant',
        content:
            '<details type="tool_calls" done="true" id="call_e1" '
            'name="tide_board" arguments="{&quot;port&quot;:&quot;Wren&quot;}" '
            'result="&quot;Shown&quot;" '
            'embeds="[&quot;&lt;p&gt;Board&lt;/p&gt;&quot;]">\n'
            '<summary>Tool Executed</summary>\n</details>\n\n'
            '> [!TIP]\n> Leave early.',
        timestamp: DateTime.utc(2026, 11, 8),
        embeds: const <Map<String, dynamic>>[
          {
            'type': 'mcp_app',
            'server_id': 'harbour',
            'tool_name': 'show_tides',
            'binding': 'signed',
            'arguments': {'port': 'Wren'},
          },
        ],
      );
      final dtos = MessageBlocks().forMessage(message);
      expect(dtos.map((b) => b.kind), [
        MessageBlockKind.embeds,
        MessageBlockKind.toolCalls,
        MessageBlockKind.alert,
      ]);
      final app = dtos.first.embeds!.single;
      expect(app.kind, EmbedKind.mcpApp);
      expect(app.app!.serverId, 'harbour');
      expect(jsonDecode(app.app!.arguments), {'port': 'Wren'});
      final call = dtos[1].calls!.single;
      expect(call.shownEmbeds, const <EmbedDto>[
        EmbedDto(
          kind: EmbedKind.html,
          source: '<p>Board</p>',
          argsText: '{"port":"Wren"}',
        ),
      ]);
      expect((dtos[2].type, dtos[2].markdown), ('tip', 'Leave early.'));
    });

    test('a citation reads as the source\'s site, or its title', () {
      final sources = chatSourceDtos(const <ChatSourceReference>[
        ChatSourceReference(
          title: 'Spring tides explained for sailors',
          url: 'https://www.example.com/tides/spring',
        ),
        ChatSourceReference(title: 'notes.pdf', type: 'file'),
      ]);
      expect(sources[0].inlineLabel, 'example.com');
      expect(sources[0].inlineTitle, 'Spring tides ex...or sailors');
      expect(sources[1].inlineLabel, 'notes.pdf');
      expect(sources[1].type, 'file');
    });

    test('the task checklist keeps its order and statuses', () {
      expect(
        chatTaskDtos(const <String, dynamic>{
          'openwebui_tasks': [
            {'id': '1', 'content': 'Read the tables', 'status': 'completed'},
            {'id': '2', 'status': 'pending'},
            {'id': '3', 'content': 'Plan the trip'},
          ],
        }),
        const <ChatTaskDto>[
          ChatTaskDto(id: '1', content: 'Read the tables', status: 'completed'),
          ChatTaskDto(id: '3', content: 'Plan the trip'),
        ],
      );
      expect(chatTaskDtos(null), isEmpty);
    });

    test('a status line names its pages by title, or by domain', () {
      final dtos = MessageBlocks().forMessage(
        answer(
          statuses: const <ChatStatusUpdate>[
            ChatStatusUpdate(
              action: 'sources_retrieved',
              count: 2,
              done: true,
              urls: <String>['https://www.example.org/b', 'ftp://example.net'],
              items: <ChatStatusItem>[
                ChatStatusItem(title: 'Tides', link: 'https://example.com/a'),
                ChatStatusItem(
                  title: 'A finding',
                  snippet: 'Twice a day.',
                  presentation: ChatStatusItemPresentation.detail,
                ),
              ],
            ),
          ],
        ),
      );
      final status = dtos.first;
      expect(status.kind, MessageBlockKind.status);
      expect(status.pending, isFalse);
      final line = status.statuses!.single;
      expect(line.description, 'Retrieved 2 sources');
      expect(line.done, isTrue);
      expect(line.links, const <ChatSourceDto>[
        ChatSourceDto(label: 'Tides', url: 'https://example.com/a'),
        ChatSourceDto(label: 'example.org', url: 'https://www.example.org/b'),
        // Not a web address: named, not linked.
        ChatSourceDto(label: 'example.net'),
      ]);
      expect(line.details, const <ChatSourceDto>[
        ChatSourceDto(label: 'A finding', snippet: 'Twice a day.'),
      ]);
    });

    test('a code execution carries its result and loads its files by id', () {
      final dtos = MessageBlocks().forMessage(
        answer(content: '').copyWith(
          codeExecutions: const <ChatCodeExecution>[
            ChatCodeExecution(
              id: 'exec-1',
              language: 'python',
              code: 'plot()',
              result: ChatCodeExecutionResult(
                error: 'NameError: plot',
                files: <ChatExecutionFile>[
                  ChatExecutionFile(
                    name: 'chart.png',
                    url: '/api/v1/files/file-7/content',
                  ),
                  ChatExecutionFile(
                    name: 'tracker.png',
                    url: 'https://tracker.example/pixel.png',
                  ),
                ],
              ),
            ),
          ],
        ),
      );
      final execution = dtos.firstWhere(
        (b) => b.kind == MessageBlockKind.codeExecution,
      );
      expect(execution.id, 'exec-1');
      expect(execution.name, isNull);
      expect(execution.code, 'plot()');
      expect(execution.error, 'NameError: plot');
      expect(
        (execution.done, execution.pending, execution.isError),
        (true, false, true),
      );
      // A remote address is never handed to the window.
      expect(execution.files, const <ChatFileDto>[
        ChatFileDto(id: 'file-7', name: 'chart.png'),
      ]);
    });

    test('a file is known by its address\'s path, whatever the query', () {
      final file = chatFileDto(<String, dynamic>{
        'url': '/api/v1/files/file-9/content?attachment=false',
        'name': 'notes.txt',
      });
      expect(file?.id, 'file-9');
    });

    test('a file keeps its name, under whichever key it was saved', () {
      // As Conduit saved a reply's video before, and as tools name one.
      final file = chatFileDto(<String, dynamic>{
        'type': 'video',
        'url': '/api/v1/files/file-otter/content',
        'content_type': 'video/mp4',
        'filename': 'generated-video.mp4',
      });
      expect(
        file,
        const ChatFileDto(
          id: 'file-otter',
          name: 'generated-video.mp4',
          contentType: 'video/mp4',
        ),
      );
      // An empty one names nothing: the file's own record has the name.
      final described = chatFileDto(<String, dynamic>{
        'url': '/api/v1/files/file-9/content',
        'filename': '',
        'file': <String, dynamic>{
          'meta': <String, dynamic>{'name': 'report.pdf'},
        },
      });
      expect(described?.name, 'report.pdf');
    });

    test('a refused tool definition is flagged for the window\'s advice', () {
      final dtos = MessageBlocks().forMessage(
        answer(content: '').copyWith(
          error: const ChatMessageError(
            content: 'HTTP 400: model does not support tools',
          ),
        ),
      );
      final error = dtos.firstWhere((b) => b.kind == MessageBlockKind.error);
      expect(error.type, 'directToolsUnsupported');
      expect(error.error, 'HTTP 400: model does not support tools');
    });

    test('a held reply a polling-only server may still write says so', () {
      final dtos = MessageBlocks().forMessage(
        answer(content: '').copyWith(
          error: const ChatMessageError(content: kHeldReplyUnresolvedMessage),
        ),
      );
      final error = dtos.firstWhere((b) => b.kind == MessageBlockKind.error);
      expect(error.type, 'heldReplyStillRunning');
    });

    test("a failed relay to one of the user's devices is named for the "
        "window's words, from what the answer recorded", () {
      const text = 'Open WebUI: Server Connection Error';
      for (final (relay, type) in const <(TetherRelayFailure, String)>[
        (TetherRelayFailure.interrupted, 'tetherInterrupted'),
        (TetherRelayFailure.unavailable, 'tetherUnavailable'),
        (TetherRelayFailure.busy, 'tetherBusy'),
      ]) {
        final dtos = MessageBlocks().forMessage(
          answer(content: '').copyWith(
            error: ChatMessageError(content: text, relay: relay),
          ),
        );
        final error = dtos.firstWhere((b) => b.kind == MessageBlockKind.error);
        expect(error.type, type);
        expect(error.error, text);
      }

      // Words alone are the server's to show.
      final dtos = MessageBlocks().forMessage(
        answer(content: '').copyWith(
          error: const ChatMessageError(
            content: 'Tether service is unavailable.',
          ),
        ),
      );
      final error = dtos.firstWhere((b) => b.kind == MessageBlockKind.error);
      expect(const [
        'tetherInterrupted',
        'tetherUnavailable',
        'tetherBusy',
      ], isNot(contains(error.type)));
    });

    test('a reasoning header that kept its timing in the summary', () {
      final dtos = MessageBlocks().forMessage(
        answer(
          content:
              '<details type="reasoning" done="true">\n'
              '<summary>Thought for 7 seconds</summary>\n'
              'Quietly.\n'
              '</details>\n\nDone.',
        ),
      );
      final reasoning = dtos.first;
      expect(reasoning.title, ReasoningTitle.thoughtFor);
      expect(reasoning.durationSeconds, 7);
      expect(reasoning.summary, 'Thought for 7 seconds');
    });
  });

  test('a 32K answer streams at well under a frame per tick', () {
    final full = _longAnswer(32 * 1024);
    final message = answer(content: '').copyWith(isStreaming: true);
    const chunk = 48; // About what a fast model writes in 16 ms.

    // Every tick does what TurnsService does: build the blocks, put them on
    // the wire and encode the frame.
    void tick(String content, StreamingContentBlocks? live) {
      final blocks = MessageBlocks.toDtos(
        assistantMessageBlocks(message, content: content, live: live),
      );
      jsonEncode(
        TurnBlocks(chatId: 'c', messageId: 'm', blocks: blocks).toJson(),
      );
    }

    // Warm up the parsers.
    for (var end = 0; end < 4096; end += 512) {
      tick(full.substring(0, end), null);
    }

    // Each tick's work in this thread's CPU time: the wall clock would also
    // count the waits for a core on a busy machine, which is not the
    // daemon's work. The wall clock is printed beside it.
    final live = StreamingContentBlocks();
    final watch = Stopwatch();
    var ticks = 0;
    var total = 0;
    var lateTotal = 0;
    var lateTicks = 0;
    for (var end = chunk; end <= full.length; end += chunk) {
      final before = threadCpuMicros();
      watch.start();
      tick(full.substring(0, end), live);
      watch.stop();
      final spent = threadCpuMicros() - before;
      total += spent;
      ticks++;
      if (end > full.length * 3 ~/ 4) {
        lateTotal += spent;
        lateTicks++;
      }
    }
    final average = total / ticks;
    final lateAverage = lateTotal / lateTicks;
    final wallAverage = watch.elapsedMicroseconds / ticks;

    final whole = Stopwatch()..start();
    for (var i = 0; i < 5; i++) {
      tick(full, null);
    }
    final uncached = whole.elapsedMicroseconds / 5;
    final timing =
        'per tick: ${(average / 1000).toStringAsFixed(2)} ms on average, '
        '${(lateAverage / 1000).toStringAsFixed(2)} ms over the last quarter '
        '(${threadCpuTimeAvailable ? 'CPU' : 'wall-clock'} time; '
        '${(wallAverage / 1000).toStringAsFixed(2)} ms wall-clock); '
        'uncached ${(uncached / 1000).toStringAsFixed(2)} ms '
        '($ticks ticks, ${full.length} chars)';
    expect(average, lessThan(4000), reason: timing);
    expect(lateAverage, lessThan(4000), reason: timing);
  });
}

/// An invented long answer: headings, prose with prices, math and
/// citations, lists, code and a tool call now and then.
String _longAnswer(int length) {
  final out = StringBuffer(
    '<details type="reasoning" done="true" duration="3">\n'
    '<summary>Thought for 3 seconds</summary>\n'
    '&gt; Plan the answer.\n'
    '</details>\n\n',
  );
  for (var i = 1; out.length < length; i++) {
    out
      ..write('## Section $i\n\n')
      ..write(
        'The harbour fee is \$5 and the swell grows as \$x^2\$ [1]. '
        'Tides **rise** and fall twice a day, see [1].\n\n',
      )
      ..write('- one point with `code \$x`\n- another point\n\n')
      ..write('```python\nprint("tide $i")\nheight = 1.5\n```\n\n')
      ..write('\$\$\n\\int_0^1 h(t)\\,dt\n\$\$\n\n');
    if (i % 7 == 0) {
      out.write(
        '<details type="tool_calls" done="true" id="c$i" name="tides" '
        'arguments="{}" result="&quot;ok&quot;">\n'
        '<summary>Tool Executed</summary>\n</details>\n\n',
      );
    }
  }
  return out.toString();
}
