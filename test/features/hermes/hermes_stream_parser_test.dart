import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/features/hermes/models/hermes_run_event.dart';
import 'package:conduit/features/hermes/services/hermes_stream_parser.dart';
import 'package:flutter_test/flutter_test.dart';

Stream<List<int>> _sse(List<String> chunks) =>
    Stream<List<int>>.fromIterable(chunks.map(utf8.encode));

void main() {
  group('parseHermesRunStream', () {
    test('empty terminal lifecycle data still emits done', () async {
      final events = await parseHermesRunStream(
        _sse(['event: run.completed\ndata:\n\n']),
      ).toList();

      check(events).length.equals(1);
      check(events.single).isA<HermesRunDone>();
    });

    test('run.canceled with empty data is terminal', () async {
      final events = await parseHermesRunStream(
        _sse(['event: run.canceled\ndata:\n\n']),
      ).toList();

      check(events).length.equals(1);
      check(events.single).isA<HermesRunDone>();
    });

    test('empty non-terminal Hermes events remain ignorable', () async {
      final events = await parseHermesRunStream(
        _sse(['event: tool.started\ndata:\n\n']),
      ).toList();

      check(events).isEmpty();
    });

    test('maps token deltas, tool start/complete, and done', () async {
      final events = await parseHermesRunStream(
        _sse([
          'event: tool.started\ndata: {"tool":"terminal"}\n\n',
          'data: {"choices":[{"delta":{"content":"Hi"}}]}\n\n',
          'event: tool.completed\ndata: {"tool":"terminal","status":"completed"}\n\n',
          'data: [DONE]\n\n',
        ]),
      ).toList();

      check(events).has((e) => e.length, 'length').equals(4);

      check(events[0]).isA<HermesToolProgress>()
        ..has((e) => e.toolName, 'toolName').equals('terminal')
        ..has((e) => e.done, 'done').isFalse();
      check(
        events[1],
      ).isA<HermesTokenDelta>().has((e) => e.content, 'content').equals('Hi');
      check(events[2]).isA<HermesToolProgress>()
        ..has((e) => e.toolName, 'toolName').equals('terminal')
        ..has((e) => e.done, 'done').isTrue();
      check(events[3]).isA<HermesRunDone>();
    });

    test(
      'run.failed with a falsy error marker yields a generic error',
      () async {
        final events = await parseHermesRunStream(
          _sse(['event: run.failed\ndata: {"error":"False"}\n\n']),
        ).toList();

        check(events.whereType<HermesRunError>()).isNotEmpty();
        check(
          events.whereType<HermesRunError>().first,
        ).has((e) => e.message, 'message').equals('Hermes run failed.');
      },
    );

    test('run.failed with a real error preserves the message', () async {
      final events = await parseHermesRunStream(
        _sse(['event: run.failed\ndata: {"error":"boom"}\n\n']),
      ).toList();

      check(
        events.whereType<HermesRunError>().first,
      ).has((e) => e.message, 'message').equals('boom');
    });

    test('response.failed surfaces an error event', () async {
      final events = await parseHermesRunStream(
        _sse(['event: response.failed\ndata: {"status":"failed"}\n\n']),
      ).toList();

      check(events.whereType<HermesRunError>()).isNotEmpty();
      check(events.whereType<HermesRunDone>()).isNotEmpty();
    });

    test('a failed tool event is marked terminal (done)', () async {
      final events = await parseHermesRunStream(
        _sse([
          'event: tool.completed\ndata: {"tool":"terminal","status":"failed"}\n\n',
        ]),
      ).toList();

      check(
        events.whereType<HermesToolProgress>().first,
      ).has((e) => e.done, 'done').isTrue();
    });

    test('tool.failed keeps a string error scoped to the tool', () async {
      final events = await parseHermesRunStream(
        _sse([
          'event: tool.failed\n'
              'data: {"tool":"terminal","error":"command failed"}\n\n',
        ]),
      ).toList();

      check(events).has((e) => e.length, 'length').equals(1);
      check(events.single).isA<HermesToolProgress>()
        ..has((e) => e.toolName, 'toolName').equals('terminal')
        ..has((e) => e.done, 'done').isTrue()
        ..has((e) => e.failed, 'failed').isTrue()
        ..has((e) => e.detail, 'detail').equals('command failed');
      check(events.whereType<HermesRunError>()).isEmpty();
    });

    test('tool.failed keeps a structured error scoped to the tool', () async {
      final events = await parseHermesRunStream(
        _sse([
          'event: tool.failed\n'
              'data: {"tool":"web_search",'
              '"error":{"message":"provider unavailable"}}\n\n',
        ]),
      ).toList();

      check(events).has((e) => e.length, 'length').equals(1);
      check(events.single).isA<HermesToolProgress>()
        ..has((e) => e.toolName, 'toolName').equals('web_search')
        ..has((e) => e.done, 'done').isTrue()
        ..has((e) => e.failed, 'failed').isTrue()
        ..has((e) => e.detail, 'detail').equals('provider unavailable');
      check(events.whereType<HermesRunError>()).isEmpty();
    });

    test('tool.error is failed and terminal', () async {
      final events = await parseHermesRunStream(
        _sse([
          'event: tool.error\n'
              'data: {"tool":"terminal","error":"permission denied"}\n\n',
        ]),
      ).toList();

      check(events).length.equals(1);
      check(events.single).isA<HermesToolProgress>()
        ..has((e) => e.toolName, 'toolName').equals('terminal')
        ..has((e) => e.done, 'done').isTrue()
        ..has((e) => e.failed, 'failed').isTrue()
        ..has((e) => e.detail, 'detail').equals('permission denied');
      check(events.whereType<HermesRunError>()).isEmpty();
    });

    for (final eventType in [
      'tool.cancelled',
      'tool.canceled',
      'tool.stopped',
    ]) {
      test('$eventType without a status is marked terminal (done)', () async {
        final events = await parseHermesRunStream(
          _sse(['event: $eventType\ndata: {"tool":"terminal"}\n\n']),
        ).toList();

        check(events).has((e) => e.length, 'length').equals(1);
        check(events.single).isA<HermesToolProgress>()
          ..has((e) => e.toolName, 'toolName').equals('terminal')
          ..has((e) => e.done, 'done').isTrue();
      });
    }

    test('decodes an approval-requested event', () async {
      final events = await parseHermesRunStream(
        _sse([
          'event: approval.requested\ndata: {"approval_id":"a1","summary":"Run rm -rf?"}\n\n',
        ]),
      ).toList();

      check(events).has((e) => e.length, 'length').equals(1);
      check(events[0]).isA<HermesApprovalRequested>()
        ..has((e) => e.approvalId, 'approvalId').equals('a1')
        ..has((e) => e.summary, 'summary').equals('Run rm -rf?');
    });

    test('decodes Responses created, text delta, and completed envelope', () async {
      final events = await parseHermesRunStream(
        _sse([
          'event: response.created\n'
              'data: {"type":"response.created","response":{"id":"resp_1","status":"in_progress","output":[]}}\n\n',
          'event: response.output_text.delta\n'
              'data: {"type":"response.output_text.delta","delta":"world"}\n\n',
          'event: response.completed\n'
              'data: {"type":"response.completed","response":{"id":"resp_1","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"world"}]}]}}\n\n',
        ]),
      ).toList();

      check(events[0])
          .isA<HermesResponseCreated>()
          .has((e) => e.responseId, 'responseId')
          .equals('resp_1');
      check(
        events[1],
      ).isA<HermesLifecycle>().has((e) => e.status, 'status').equals('created');
      check(events[2])
          .isA<HermesTokenDelta>()
          .has((e) => e.content, 'content')
          .equals('world');
      check(events[3])
          .isA<HermesResponseCreated>()
          .has((e) => e.responseId, 'responseId')
          .equals('resp_1');
      check(
        events[4],
      ).isA<HermesFinalOutput>().has((e) => e.text, 'text').equals('world');
      check(events[5]).isA<HermesRunDone>();
    });

    test(
      'extracts structured terminal output without rendering tool calls',
      () async {
        final events = await parseHermesRunStream(
          _sse([
            'event: run.completed\n'
                'data: {"output":[{"type":"output_text","text":"Hello "},'
                '{"type":"function_call","name":"search"},'
                '{"type":"output_text","text":"world"}]}\n\n',
          ]),
        ).toList();

        check(
          events.whereType<HermesFinalOutput>().single.text,
        ).equals('Hello world');
        check(events.last).isA<HermesRunDone>();
      },
    );

    test('surfaces errors', () async {
      final events = await parseHermesRunStream(
        _sse(['data: {"error":{"message":"boom"}}\n\n']),
      ).toList();
      check(events).has((e) => e.length, 'length').equals(1);
      check(
        events[0],
      ).isA<HermesRunError>().has((e) => e.message, 'message').equals('boom');
    });

    test('surfaces top-level type error messages', () async {
      final events = await parseHermesRunStream(
        _sse(['data: {"type":"error","code":"bad","message":"boom"}\n\n']),
      ).toList();

      check(events).has((e) => e.length, 'length').equals(1);
      check(
        events.single,
      ).isA<HermesRunError>().has((e) => e.message, 'message').equals('boom');
    });
  });

  group('parseHermesResponseStream', () {
    test('maps SDK Responses events and preserves frame-declared types', () async {
      final responseCreated = {
        'id': 'resp_sdk',
        'object': 'response',
        'created_at': 1,
        'status': 'in_progress',
        'model': 'hermes-agent',
        'output': <dynamic>[],
      };
      final responseCompleted = {
        ...responseCreated,
        'status': 'completed',
        'output': [
          {
            'type': 'reasoning',
            'id': 'reason_1',
            'summary': [
              {'type': 'summary_text', 'text': 'final thought'},
            ],
          },
          {
            'type': 'message',
            'id': 'msg_1',
            'role': 'assistant',
            'status': 'completed',
            'content': [
              {'type': 'output_text', 'text': 'hello'},
            ],
          },
        ],
      };
      final functionCall = {
        'type': 'function_call',
        'id': 'fc_1',
        'call_id': 'call_1',
        'name': 'terminal',
        'arguments': '{"command":"pwd"}',
        'status': 'in_progress',
      };
      final events = await parseHermesResponseStream(
        _sse([
          'event: response.created\n'
              'data: ${jsonEncode({'response': responseCreated})}\n\n',
          'event: response.output_text.delta\n'
              'data: {"output_index":0,"content_index":0,"delta":"hello"}\n\n',
          'data: {"type":"response.refusal.delta","output_index":0,"content_index":0,"delta":" declined"}\n\n',
          'data: {"type":"response.reasoning_text.delta","output_index":0,"content_index":0,"delta":"think"}\n\n',
          'data: {"type":"response.reasoning_summary_text.delta","output_index":0,"summary_index":0,"delta":"summary"}\n\n',
          'data: ${jsonEncode({'type': 'response.output_item.added', 'output_index': 0, 'item': functionCall})}\n\n',
          'data: ${jsonEncode({
            'type': 'response.output_item.done',
            'output_index': 0,
            'item': {...functionCall, 'status': 'completed'},
          })}\n\n',
          'data: ${jsonEncode({'type': 'response.completed', 'response': responseCompleted})}\n\n',
        ]),
      ).toList();

      check(
        events.whereType<HermesResponseCreated>().map(
          (event) => event.responseId,
        ),
      ).deepEquals(['resp_sdk', 'resp_sdk']);
      check(
        events.whereType<HermesTokenDelta>().map((event) => event.content),
      ).deepEquals(['hello', ' declined']);
      check(
        events.whereType<HermesReasoningDelta>().map((event) => event.content),
      ).deepEquals(['think', 'summary', 'final thought']);
      final tools = events.whereType<HermesToolProgress>().toList();
      check(tools).length.equals(2);
      check(tools.first.done).isFalse();
      check(tools.last.done).isTrue();
      check(tools.first.toolName).equals('terminal');
      check(events.whereType<HermesFinalOutput>().single.text).equals('hello');
      check(events.last).isA<HermesRunDone>();
    });

    test('keeps sparse and custom Hermes frames behind the fallback', () async {
      final events = await parseHermesResponseStream(
        _sse([
          'data: not-json\n\n',
          'event: response.output_text.delta\n'
              'data: {"delta":"legacy"}\n\n',
          'data: {"type":"response.reasoning.delta","delta":"alias"}\n\n',
          'event: tool.started\n'
              'data: {"tool":"terminal"}\n\n',
          'event: approval.requested\n'
              'data: {"approval_id":"a1","summary":"Allow?"}\n\n',
          'data: {"type":"response.keepalive"}\n\n',
        ]),
      ).toList();

      check(
        events.whereType<HermesTokenDelta>().single.content,
      ).equals('legacy');
      check(
        events.whereType<HermesReasoningDelta>().single.content,
      ).equals('alias');
      check(
        events.whereType<HermesToolProgress>().single.toolName,
      ).equals('terminal');
      check(
        events.whereType<HermesApprovalRequested>().single.approvalId,
      ).equals('a1');
    });

    test('surfaces typed incomplete responses as terminal errors', () async {
      final events = await parseHermesResponseStream(
        _sse([
          'data: ${jsonEncode({
            'type': 'response.incomplete',
            'response': {
              'id': 'resp_incomplete',
              'object': 'response',
              'created_at': 1,
              'status': 'incomplete',
              'output': <dynamic>[],
              'incomplete_details': {'reason': 'max_output_tokens'},
            },
          })}\n\n',
        ]),
      ).toList();

      check(events.first)
          .isA<HermesResponseCreated>()
          .has((event) => event.responseId, 'responseId')
          .equals('resp_incomplete');
      check(
        events.whereType<HermesRunError>().single.message,
      ).contains('max_output_tokens');
      check(events.last).isA<HermesRunDone>();
    });

    test('rejects a sparse completed envelope with cancelled status', () async {
      final events = await parseHermesResponseStream(
        _sse([
          'event: response.completed\n'
              'data: {"response":{"id":"resp_cancelled","status":"cancelled"}}\n\n',
        ]),
      ).toList();

      check(events.first)
          .isA<HermesResponseCreated>()
          .has((event) => event.responseId, 'responseId')
          .equals('resp_cancelled');
      check(
        events.whereType<HermesRunError>().single.message,
      ).contains('cancelled');
      check(events.last).isA<HermesRunDone>();
    });

    test('surfaces sparse incomplete envelopes through the fallback', () async {
      final events = await parseHermesResponseStream(
        _sse([
          'event: response.incomplete\n'
              'data: {"response":{"id":"resp_sparse","status":"incomplete","incomplete_details":{"reason":"content_filter"}}}\n\n',
        ]),
      ).toList();

      check(events.first)
          .isA<HermesResponseCreated>()
          .has((event) => event.responseId, 'responseId')
          .equals('resp_sparse');
      check(
        events.whereType<HermesRunError>().single.message,
      ).contains('content_filter');
      check(events.last).isA<HermesRunDone>();
    });
  });
}
