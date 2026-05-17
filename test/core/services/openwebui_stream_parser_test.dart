import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/core/services/openwebui_stream_parser.dart';
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
      check(updates[1]).isA<OpenWebUIStreamDone>();
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
}
