import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/services/openwebui_response_stream.dart';
import 'package:conduit_core/services/structured_output.dart';
import 'package:test/test.dart';

void main() {
  group('applyOpenWebUIResponseStreamEvent', () {
    test('accumulates reasoning then message text into output items', () {
      var output = <Map<String, dynamic>>[];
      output = applyOpenWebUIResponseStreamEvent(output, {
        'type': 'response.reasoning_text.delta',
        'item_id': 'r1',
        'output_index': 0,
        'content_index': 0,
        'delta': 'User wants',
      });
      output = applyOpenWebUIResponseStreamEvent(output, {
        'type': 'response.reasoning_text.delta',
        'item_id': 'r1',
        'output_index': 0,
        'content_index': 0,
        'delta': ' a greeting',
      });
      output = applyOpenWebUIResponseStreamEvent(output, {
        'type': 'response.output_text.delta',
        'item_id': 'msg1',
        'output_index': 1,
        'content_index': 0,
        'delta': 'Hello',
      });

      check(output).length.equals(2);
      check(output[0]['type']).equals('reasoning');
      check(output[0]['status']).equals('in_progress');
      check((output[0]['content'] as List).single['text'])
          .equals('User wants a greeting');
      check(output[1]['type']).equals('message');
      check((output[1]['content'] as List).single['text']).equals('Hello');

      final blocks = parseOpenWebUIStructuredOutput(output);
      check(blocks[0])
          .isA<StructuredOutputReasoningBlock>()
          .has((b) => b.done, 'done')
          .isTrue();
      check(blocks[1])
          .isA<StructuredOutputTextBlock>()
          .has((b) => b.text, 'text')
          .equals('Hello');
    });

    test('stamps reasoning timing when the answer item starts', () {
      var output = applyOpenWebUIResponseStreamEvent(const [], {
        'type': 'response.reasoning_text.delta',
        'output_index': 0,
        'delta': 'thinking',
      });
      check(output.single['started_at']).isA<num>();
      check(output.single['duration']).isNull();

      output = applyOpenWebUIResponseStreamEvent(output, {
        'type': 'response.output_text.delta',
        'output_index': 1,
        'delta': 'answer',
      });
      final reasoning = output.first;
      check(reasoning['ended_at']).isA<num>();
      check(reasoning['duration']).isA<int>();

      final blocks = parseOpenWebUIStructuredOutput(output);
      final block = blocks.first as StructuredOutputReasoningBlock;
      check(block.done).isTrue();
      check(block.duration).isNotNull();
    });

    test('output_item.added inserts and output_item.done replaces by id', () {
      var output = applyOpenWebUIResponseStreamEvent(const [], {
        'type': 'response.output_item.added',
        'output_index': 0,
        'item': {'type': 'reasoning', 'id': 'r1', 'status': 'in_progress'},
      });
      output = applyOpenWebUIResponseStreamEvent(output, {
        'type': 'response.output_item.done',
        'output_index': 0,
        'item': {
          'type': 'reasoning',
          'id': 'r1',
          'status': 'completed',
          'duration': 3,
          'content': [
            {'type': 'output_text', 'text': 'done thinking'},
          ],
        },
      });

      check(output).length.equals(1);
      check(output.single['status']).equals('completed');
      check(output.single['duration']).equals(3);
    });

    test('response.completed replaces the whole list and ignores markers', () {
      final seeded = applyOpenWebUIResponseStreamEvent(const [], {
        'type': 'response.output_text.delta',
        'output_index': 0,
        'delta': 'partial',
      });
      check(
        applyOpenWebUIResponseStreamEvent(seeded, {'type': 'response.created'}),
      ).identicalTo(seeded);
      final completed = applyOpenWebUIResponseStreamEvent(seeded, {
        'type': 'response.completed',
        'response': {
          'output': [
            {
              'type': 'message',
              'content': [
                {'type': 'output_text', 'text': 'final'},
              ],
            },
          ],
        },
      });
      check((completed.single['content'] as List).single['text'])
          .equals('final');
    });

    test('snapshots keep the locally measured reasoning duration', () {
      final local = <Map<String, dynamic>>[
        {
          'type': 'reasoning',
          'id': 'rs_1',
          'started_at': 100.0,
          'ended_at': 109.4,
          'duration': 9,
        },
        {
          'type': 'message',
          'id': 'msg_1',
          'content': [
            {'type': 'output_text', 'text': 'answer'},
          ],
        },
      ];
      // The server only records ended_at for provider-owned reasoning items.
      final server = <Map<String, dynamic>>[
        {
          'type': 'reasoning',
          'id': 'rs_1',
          'status': 'completed',
          'ended_at': 109.9,
          'summary': [
            {'type': 'summary_text', 'text': 'Counting primes'},
          ],
        },
        {
          'type': 'message',
          'id': 'msg_1',
          'status': 'completed',
          'content': [
            {'type': 'output_text', 'text': 'answer'},
          ],
        },
      ];

      final merged = mergeOpenWebUIReasoningTiming(local, server);
      check(merged.first['duration']).equals(9);
      check(merged.first['ended_at']).equals(109.9);
      check(merged.first['summary']).isNotNull();
      check(mergeOpenWebUIReasoningTiming(const [], server))
          .identicalTo(server);

      final completed = applyOpenWebUIResponseStreamEvent(local, {
        'type': 'response.completed',
        'response': {'output': server},
      });
      check(completed.first['duration']).equals(9);
    });

    test('keeps measured timing when the server replaces the item', () {
      // Azure Responses sequence: reasoning added empty, summary lands late,
      // output_item.done replaces the item with a copy lacking timing, then
      // the answer item starts.
      var output = applyOpenWebUIResponseStreamEvent(const [], {
        'type': 'response.output_item.added',
        'output_index': 0,
        'item': {'type': 'reasoning', 'id': 'rs_1', 'summary': []},
      });
      final startedAt = output.single['started_at'] as num;
      output = applyOpenWebUIResponseStreamEvent(output, {
        'type': 'response.reasoning_summary_text.delta',
        'item_id': 'rs_1',
        'output_index': 0,
        'summary_index': 0,
        'delta': 'Counting primes',
      });
      output = applyOpenWebUIResponseStreamEvent(output, {
        'type': 'response.output_item.done',
        'output_index': 0,
        'item': {
          'type': 'reasoning',
          'id': 'rs_1',
          'status': 'completed',
          'summary': [
            {'type': 'summary_text', 'text': 'Counting primes'},
          ],
        },
      });
      check(output.single['started_at']).equals(startedAt);
      check(output.single['duration']).isNull();

      output = applyOpenWebUIResponseStreamEvent(output, {
        'type': 'response.output_item.added',
        'output_index': 1,
        'item': {'type': 'message', 'id': 'msg_1', 'content': []},
      });
      check(output.first['started_at']).equals(startedAt);
      check(output.first['duration']).isA<int>();
      check(output.first['ended_at']).isA<num>();

      final blocks = parseOpenWebUIStructuredOutput(output);
      check(blocks.first)
          .isA<StructuredOutputReasoningBlock>()
          .has((b) => b.duration, 'duration')
          .isNotNull();
    });

    test('terminal failure and incomplete events still apply their output', () {
      final failed = applyOpenWebUIResponseStreamEvent(const [], {
        'type': 'response.failed',
        'response': {
          'error': {'message': 'rate limited'},
          'output': [
            {
              'type': 'message',
              'content': [
                {'type': 'output_text', 'text': 'partial'},
              ],
            },
          ],
        },
      });
      check((failed.single['content'] as List).single['text'])
          .equals('partial');
      // An empty terminal list must not erase what already streamed.
      final kept = applyOpenWebUIResponseStreamEvent(failed, {
        'type': 'response.incomplete',
        'response': {
          'output': <Map<String, dynamic>>[],
          'incomplete_details': {'reason': 'max_output_tokens'},
        },
      });
      check(kept).identicalTo(failed);
      check(openWebUIResponseStreamEventTouchesOutput('response.failed'))
          .isTrue();
      check(openWebUIResponseStreamEventIsStructural('response.incomplete'))
          .isTrue();
    });

    test('does not mutate the input list', () {
      final original = applyOpenWebUIResponseStreamEvent(const [], {
        'type': 'response.output_text.delta',
        'output_index': 0,
        'delta': 'a',
      });
      // Deep copy so shared nested lists and part maps cannot mask an
      // in-place mutation.
      final snapshot = jsonDecode(jsonEncode(original)) as List<Object?>;
      applyOpenWebUIResponseStreamEvent(original, {
        'type': 'response.output_text.delta',
        'output_index': 0,
        'delta': 'b',
      });
      check(jsonDecode(jsonEncode(original)) as List<Object?>)
          .deepEquals(snapshot);
    });
  });
}
