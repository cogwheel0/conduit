import 'dart:convert';
import 'dart:typed_data';

import 'package:conduit_core/features/direct_connections/models/direct_completion.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/services/direct_chat_bridge.dart';
import 'package:conduit_core/features/direct_connections/services/ollama_adapter.dart';
import 'package:conduit_core/features/direct_connections/services/openai_compatible_adapter.dart';
import 'package:conduit_markdown/conduit_markdown.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// Models that write their reasoning inline (`<think>…</think>` in
/// `content`) must reach every direct consumer as reasoning, the way Open
/// WebUI chats split it.
void main() {
  group('OpenAI-compatible stream', () {
    test('reads deltas whose unset optional fields are null', () async {
      // Python-based compatible servers serialize every optional field, so
      // unset ones arrive as nulls that openai_dart would otherwise reject.
      final turn = await _openAiChunks(<Map<String, Object?>>[
        for (final (content, finish) in [
          ('High tide', null),
          (' is at 14:05.', 'stop'),
        ])
          {
            'id': 'chunk-1',
            'object': 'chat.completion.chunk',
            'created': 1,
            'model': 'tide-model',
            'system_fingerprint': null,
            'obfuscation': null,
            'choices': [
              {
                'index': 0,
                'delta': {
                  'role': 'assistant',
                  'content': content,
                  'function_call': null,
                  'tool_calls': null,
                  'audio': null,
                  'refusal': null,
                },
                'logprobs': null,
                'finish_reason': finish,
              },
            ],
          },
      ]);

      expect(turn.answer, 'High tide is at 14:05.');
    });

    test('splits an opening and a closing tag cut across deltas', () async {
      final turn = await _openAi(<Map<String, String>>[
        {'content': '<thi'},
        {'content': 'nk>Tide tables first.</th'},
        {'content': 'ink>'},
        {'content': 'High tide is at 14:05.'},
      ]);

      expect(turn.reasoning, 'Tide tables first.');
      expect(turn.answer, 'High tide is at 14:05.');
    });

    test('keeps a block opened first as reasoning until it closes', () async {
      final turn = await _openAi(<Map<String, String>>[
        {'content': '<think>'},
        for (var step = 1; step <= 40; step++) {'content': 'Step $step. '},
        {'content': '</think>\n\nHigh tide is at 14:05.'},
      ]);

      expect(turn.reasoning, startsWith('Step 1. Step 2.'));
      expect(turn.reasoning, endsWith('Step 40. '));
      // Nothing reached the answer while the block was open, and the blank
      // line the model wrote between reasoning and answer is dropped.
      expect(turn.contentDeltas, <String>['High tide is at 14:05.']);
    });

    test('keeps everything after an unclosed tag as reasoning', () async {
      final open = await _openAi(<Map<String, String>>[
        {'content': '<think>Still weighing'},
        {'content': ' the two harbours'},
      ]);
      expect(open.reasoning, 'Still weighing the two harbours');
      expect(open.answer, isEmpty);

      final cut = await _openAi(<Map<String, String>>[
        {'content': '<think>Almost there'},
        {'content': '</thi'},
      ]);
      expect(cut.reasoning, 'Almost there</thi');
      expect(cut.answer, isEmpty);
    });

    test('splits every tag pair Open WebUI recognises', () async {
      for (final (start, end) in defaultReasoningTagPairs) {
        final half = start.length ~/ 2;
        final turn = await _openAi(<Map<String, String>>[
          {'content': start.substring(0, half)},
          {'content': '${start.substring(half)}Plan.$end'},
          {'content': 'Answer.'},
        ]);

        expect(turn.reasoning, 'Plan.', reason: start);
        expect(turn.answer, 'Answer.', reason: start);
      }

      final attributed = await _openAi(<Map<String, String>>[
        {'content': '<think eff'},
        {'content': 'ort="low">Plan.</think>Answer.'},
      ]);
      expect(attributed.reasoning, 'Plan.');
      expect(attributed.answer, 'Answer.');
    });

    test(
      'merges reasoning_content and an inline block into one section',
      () async {
        final turn = await _openAi(<Map<String, String>>[
          {'reasoning_content': 'Check the chart. '},
          {'content': '<think>Then the buoy.</think>'},
          {'content': 'Swell is 1.2 m.'},
        ]);

        expect(turn.reasoning, 'Check the chart. Then the buoy.');
        expect(turn.answer, 'Swell is 1.2 m.');
        expect(_reasoningSections(turn.events), 1);
      },
    );

    test('separates reasoning that follows a closed inline block', () async {
      final turn = await _openAi(<Map<String, String>>[
        {'content': '<think>Read the chart.</think>'},
        {'reasoning_content': 'Now the buoy.'},
        {'content': 'Swell is 1.2 m.'},
      ]);

      expect(turn.reasoning, 'Read the chart.\n\nNow the buoy.');
      expect(_reasoningSections(turn.events), 1);
    });

    test('leaves tags inside Markdown code as answer text', () async {
      const answer =
          'Wrap it in `<think>` tags, as in:\n'
          '\n'
          '```xml\n'
          '<think>draft</think>\n'
          '```\n'
          '\n'
          '~~~\n'
          '<thinking>also code</thinking>\n'
          '~~~\n'
          'Then `` <think> `` once more.';
      final whole = await _openAi(<Map<String, String>>[
        {'content': answer},
      ]);
      expect(whole.reasoning, isEmpty);
      expect(whole.answer, answer);

      // The same answer, cut through backtick runs and tags.
      final cuts = <int>[12, 13, 30, 33, 34, 47, 80, 99];
      final pieces = <Map<String, String>>[];
      var from = 0;
      for (final cut in cuts) {
        pieces.add({'content': answer.substring(from, cut)});
        from = cut;
      }
      pieces.add({'content': answer.substring(from)});
      final cutUp = await _openAi(pieces);
      expect(cutUp.reasoning, isEmpty);
      expect(cutUp.answer, answer);
    });

    test('still splits a block after a closed code fence', () async {
      final turn = await _openAi(<Map<String, String>>[
        {'content': '```\nx\n```\n<think>Real thought.</think>Done.'},
      ]);

      expect(turn.reasoning, 'Real thought.');
      expect(turn.answer, '```\nx\n```\nDone.');
    });
  });

  group('Ollama stream', () {
    test('splits tags cut across chunks', () async {
      final turn = await _ollama(<String>[
        '<think>Look up',
        ' the harbour.</thi',
        'nk>\n',
        'High tide is at 14:05.',
      ]);

      expect(turn.reasoning, 'Look up the harbour.');
      expect(turn.answer, 'High tide is at 14:05.');
    });

    test('merges native thinking and an inline block', () async {
      final turn = await _ollama(<String>[
        '<think>Then the buoy.</think>',
        'Swell is 1.2 m.',
      ], thinking: 'Check the chart. ');

      expect(turn.reasoning, 'Check the chart. Then the buoy.');
      expect(turn.answer, 'Swell is 1.2 m.');
      expect(_reasoningSections(turn.events), 1);
    });

    test('keeps an unclosed block as reasoning', () async {
      final turn = await _ollama(<String>['<think>No answer yet']);

      expect(turn.reasoning, 'No answer yet');
      expect(turn.answer, isEmpty);
    });
  });
}

typedef _Turn = ({
  List<DirectStreamEvent> events,
  String reasoning,
  String answer,
  List<String> contentDeltas,
});

_Turn _summarise(List<DirectStreamEvent> events) {
  final contentDeltas = <String>[
    for (final event in events)
      if (event is DirectContentDelta) event.content,
  ];
  return (
    events: events,
    reasoning: events
        .whereType<DirectReasoningDelta>()
        .map((e) => e.content)
        .join(),
    answer: contentDeltas.join(),
    contentDeltas: contentDeltas,
  );
}

int _reasoningSections(List<DirectStreamEvent> events) {
  final accumulator = DirectStreamingAccumulator();
  for (final event in events) {
    accumulator.apply(event);
  }
  return '<details type="reasoning"'
      .allMatches(accumulator.render(done: true))
      .length;
}

Future<_Turn> _openAi(List<Map<String, String>> deltas) => _openAiChunks([
  for (final delta in deltas)
    {
      'choices': [
        {'delta': delta},
      ],
    },
]);

Future<_Turn> _openAiChunks(List<Map<String, Object?>> chunks) async {
  final http = _StreamingHttp(<String>[
    for (final chunk in chunks) 'data: ${jsonEncode(chunk)}\n\n',
    'data: [DONE]\n\n',
  ], contentType: 'text/event-stream');
  final adapter = OpenAiCompatibleAdapter(
    dioFactory: (_) => Dio()..httpClientAdapter = http,
    closeClients: false,
  );
  final run = adapter.startCompletion(
    DirectConnectionProfile(
      id: 'tide-openai',
      name: 'Tide provider',
      adapterKey: kOpenAiCompatibleAdapterKey,
      baseUrl: 'https://tides.example/v1',
      apiKey: 'synthetic-key',
    ),
    DirectCompletionRequest(
      remoteModelId: 'tide-model',
      messages: [DirectChatMessage.text(role: 'user', text: 'When?')],
    ),
  );
  final events = await run.events.toList();
  await run.done;
  expect(events.whereType<DirectStreamError>(), isEmpty);
  expect(events.last, isA<DirectStreamDone>());
  return _summarise(events);
}

Future<_Turn> _ollama(List<String> chunks, {String? thinking}) async {
  final http = _StreamingHttp(<String>[
    if (thinking != null)
      '${jsonEncode({
        'message': {'thinking': thinking, 'content': ''},
        'done': false,
      })}\n',
    for (final chunk in chunks)
      '${jsonEncode({
        'message': {'content': chunk},
        'done': false,
      })}\n',
    '${jsonEncode({
      'message': {'content': ''},
      'done': true,
    })}\n',
  ], contentType: 'application/x-ndjson');
  final adapter = OllamaAdapter(
    dioFactory: (_) => Dio()..httpClientAdapter = http,
    closeClients: false,
  );
  final run = adapter.startCompletion(
    DirectConnectionProfile(
      id: 'tide-ollama',
      name: 'Tide Ollama',
      adapterKey: kOllamaAdapterKey,
      baseUrl: 'http://localhost:11434',
    ),
    DirectCompletionRequest(
      remoteModelId: 'tide-model',
      messages: [DirectChatMessage.text(role: 'user', text: 'When?')],
    ),
  );
  final events = await run.events.toList();
  await run.done;
  expect(events.whereType<DirectStreamError>(), isEmpty);
  expect(events.last, isA<DirectStreamDone>());
  return _summarise(events);
}

/// Answers the one completion request with [chunks], each its own read.
final class _StreamingHttp implements HttpClientAdapter {
  _StreamingHttp(this.chunks, {required this.contentType});

  final List<String> chunks;
  final String contentType;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody(
    Stream<Uint8List>.fromIterable(<Uint8List>[
      for (final chunk in chunks) Uint8List.fromList(utf8.encode(chunk)),
    ]),
    200,
    headers: <String, List<String>>{
      Headers.contentTypeHeader: <String>[contentType],
    },
  );

  @override
  void close({bool force = false}) {}
}
