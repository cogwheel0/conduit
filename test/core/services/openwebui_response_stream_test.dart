import 'package:checks/checks.dart';
import 'package:conduit/core/services/openwebui_response_stream.dart';
import 'package:conduit/core/services/structured_output.dart';
import 'package:flutter_test/flutter_test.dart';

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

    test('does not mutate the input list', () {
      final original = applyOpenWebUIResponseStreamEvent(const [], {
        'type': 'response.output_text.delta',
        'output_index': 0,
        'delta': 'a',
      });
      final snapshot = original.map((e) => Map.of(e)).toList();
      applyOpenWebUIResponseStreamEvent(original, {
        'type': 'response.output_text.delta',
        'output_index': 0,
        'delta': 'b',
      });
      check(original).deepEquals(snapshot);
    });
  });
}
