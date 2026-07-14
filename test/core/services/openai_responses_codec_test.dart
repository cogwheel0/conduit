import 'package:checks/checks.dart';
import 'package:conduit/core/services/openai_responses_codec.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openai_dart/openai_dart.dart' as openai;

void main() {
  test('serializes standard Responses requests through openai_dart', () {
    final body = OpenAiResponsesCodec.createRequestBody(
      model: 'hermes-agent',
      input: openai.ResponseInput.items([
        openai.MessageItem.user([
          openai.InputContent.text('Describe this'),
          openai.InputContent.imageUrl(
            'https://example.com/image.png',
            detail: openai.ImageDetail.high,
          ),
        ]),
      ]),
      instructions: 'Be concise',
      previousResponseId: 'resp_0',
    );

    check(body['model']).equals('hermes-agent');
    check(body['input'] as List).deepEquals([
      {
        'type': 'message',
        'role': 'user',
        'content': [
          {'type': 'input_text', 'text': 'Describe this'},
          {
            'type': 'input_image',
            'image_url': 'https://example.com/image.png',
            'detail': 'high',
          },
        ],
      },
    ]);
    check(body['instructions']).equals('Be concise');
    check(body['previous_response_id']).equals('resp_0');
    check(body['stream']).equals(true);
    check(body.containsKey('store')).isFalse();

    final decoded = openai.CreateResponseRequest.fromJson(body);
    check(decoded.input).isA<openai.ResponseInputItems>();
  });

  test('decodes typed stream events and extracts terminal content', () {
    final event = OpenAiResponsesCodec.decodeStreamEvent({
      'type': 'response.output_text.delta',
      'item_id': 'msg_1',
      'output_index': 0,
      'content_index': 0,
      'delta': 'hello',
    });
    check(event)
        .isA<openai.OutputTextDeltaEvent>()
        .has((value) => value.delta, 'delta')
        .equals('hello');

    final response = OpenAiResponsesCodec.decodeResponse({
      'id': 'resp_1',
      'object': 'response',
      'created_at': 1,
      'status': 'completed',
      'output': [
        {
          'type': 'reasoning',
          'id': 'rs_1',
          'summary': [
            {'type': 'summary_text', 'text': 'thinking'},
          ],
        },
        {
          'type': 'message',
          'id': 'msg_1',
          'role': 'assistant',
          'status': 'completed',
          'content': [
            {'type': 'output_text', 'text': 'answer'},
            {'type': 'refusal', 'refusal': ' declined'},
          ],
        },
      ],
    });
    final content = OpenAiResponsesCodec.content(response);

    check(content.reasoning).equals('thinking');
    check(content.text).equals('answer declined');
    check(OpenAiResponsesCodec.statusError(response)).isNull();
  });

  test('separates multiple non-empty terminal reasoning items', () {
    final response = OpenAiResponsesCodec.decodeResponse({
      'id': 'resp_reasoning',
      'object': 'response',
      'created_at': 1,
      'status': 'completed',
      'output': [
        {
          'type': 'reasoning',
          'id': 'rs_1',
          'content': [
            {'type': 'reasoning_text', 'text': 'detail one'},
          ],
          'summary': [
            {'type': 'summary_text', 'text': 'summary one'},
          ],
        },
        {
          'type': 'reasoning',
          'id': 'rs_2',
          'summary': [
            {'type': 'summary_text', 'text': 'summary two'},
          ],
        },
        {
          'type': 'reasoning',
          'id': 'rs_3',
          'content': [
            {'type': 'reasoning_text', 'text': 'detail three'},
          ],
          'summary': <Map<String, Object?>>[],
        },
      ],
    });

    final content = OpenAiResponsesCodec.content(response);

    check(content.reasoningText).equals('detail one\ndetail three');
    check(content.reasoningSummary).equals('summary one\nsummary two');
    check(content.reasoning).equals('detail one\nsummary two\ndetail three');
  });
}
