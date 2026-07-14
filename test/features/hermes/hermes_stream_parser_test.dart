import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/features/hermes/models/hermes_run_event.dart';
import 'package:conduit/features/hermes/services/hermes_stream_parser.dart';
import 'package:flutter_test/flutter_test.dart';

Stream<List<int>> _sse(List<String> chunks) =>
    Stream<List<int>>.fromIterable(chunks.map(utf8.encode));

void main() {
  group('extractHermesOutputText', () {
    test('rejects a wide output before queueing all children', () {
      final output = List<Object?>.filled(100000, null, growable: false);

      check(() => extractHermesOutputText(output)).throws<FormatException>();
    });

    test('allows exactly the configured node budget', () {
      final output = List<Object?>.filled(99999, null, growable: false);

      check(extractHermesOutputText(output)).isEmpty();
    });
  });

  group('parseHermesRunStream', () {
    test('empty terminal lifecycle data still emits done', () async {
      final events = await parseHermesRunStream(
        _sse(['event: run.completed\ndata:\n\n']),
      ).toList();

      check(events).length.equals(1);
      check(events.single).isA<HermesRunDone>();
    });

    test('event-only remote cancellation is a terminal error', () async {
      for (final status in const ['cancelled', 'canceled', 'stopped']) {
        final events = await parseHermesRunStream(
          _sse(['event: run.$status\ndata:\n\n']),
        ).toList();

        final expected = status == 'stopped'
            ? 'Hermes run was stopped.'
            : 'Hermes run was cancelled.';
        check(events).length.equals(2);
        check(events.first)
            .isA<HermesRunError>()
            .has((event) => event.message, 'message')
            .equals(expected);
        check(events.last).isA<HermesRunDone>();
      }
    });

    test('status-only remote cancellation is a terminal error', () async {
      final events = await parseHermesRunStream(
        _sse(['data: {"status":"stopped"}\n\n']),
      ).toList();

      check(events).length.equals(2);
      check(events.first)
          .isA<HermesRunError>()
          .has((event) => event.message, 'message')
          .equals('Hermes run was stopped.');
      check(events.last).isA<HermesRunDone>();
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

    test('decodes the official approval.request run payload', () async {
      final events = await parseHermesRunStream(
        _sse([
          'data: {"event":"approval.request","run_id":"run_0123abcdef","timestamp":1720000000.0,"command":"rm -rf /tmp/nope","description":"dangerous command","choices":["once","session","always","deny"]}\n\n',
        ]),
      ).toList();

      check(events).has((e) => e.length, 'length').equals(1);
      check(events.single).isA<HermesApprovalRequested>()
        ..has((e) => e.approvalId, 'approvalId').equals('run_0123abcdef')
        ..has((e) => e.summary, 'summary').equals('dangerous command')
        ..has(
          (e) => e.raw['choices'] as List<Object?>,
          'raw choices',
        ).deepEquals(['once', 'session', 'always', 'deny']);
    });

    test('rejects an invalid run_id approval fallback', () async {
      final events = await parseHermesRunStream(
        _sse([
          'data: {"event":"approval.request","run_id":"run id with spaces","description":"dangerous command"}\n\n',
        ]),
      ).toList();

      check(events.whereType<HermesApprovalRequested>()).isEmpty();
    });

    test(
      'rejects non-string approval control fields without coercion',
      () async {
        Object nested = const <String, dynamic>{'leaf': 'value'};
        for (var depth = 0; depth < 128; depth++) {
          nested = <String, dynamic>{'nested': nested};
        }
        final events = await parseHermesRunStream(
          _sse([
            'event: approval.requested\n'
                'data: ${jsonEncode(<String, dynamic>{
                  'approval_id': nested,
                  'summary': <String, dynamic>{'not': 'display text'},
                })}\n\n',
          ]),
        ).toList();

        check(events.whereType<HermesApprovalRequested>()).isEmpty();
      },
    );

    test('falls back to a valid alternate approval identifier', () async {
      final events = await parseHermesRunStream(
        _sse([
          'event: approval.requested\n'
              'data: {"approval_id":null,"approvalId":"a1"}\n\n',
        ]),
      ).toList();

      check(
        events.whereType<HermesApprovalRequested>().single.approvalId,
      ).equals('a1');
    });

    test('legacy approval identifiers take precedence over run_id', () async {
      final events = await parseHermesRunStream(
        _sse([
          'event: approval.requested\n'
              'data: {"approval_id":"legacy-a1","run_id":"run_0123abcdef"}\n\n',
        ]),
      ).toList();

      check(
        events.whereType<HermesApprovalRequested>().single.approvalId,
      ).equals('legacy-a1');
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

    test('does not coerce a structured Responses id into a control id', () async {
      Object nestedId = const <String, dynamic>{'leaf': 'response-id'};
      for (var depth = 0; depth < 128; depth++) {
        nestedId = <String, dynamic>{'nested': nestedId};
      }
      final events = await parseHermesResponseStream(
        _sse([
          'event: response.created\n'
              'data: ${jsonEncode(<String, dynamic>{
                'type': 'response.created',
                'response': <String, dynamic>{'id': nestedId, 'status': 'in_progress'},
              })}\n\n',
        ]),
      ).toList();

      check(events.whereType<HermesResponseCreated>()).isEmpty();
      check(
        events.whereType<HermesLifecycle>().single.status,
      ).equals('created');
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

    test('maps oversized terminal output shape to a typed run error', () async {
      Object? output = 'leaf';
      for (var depth = 0; depth <= 128; depth++) {
        output = <Object?>[output];
      }

      final events = await parseHermesRunStream(
        _sse([
          'event: run.completed\n'
              'data: ${jsonEncode(<String, Object?>{'output': output})}\n\n',
        ]),
      ).toList();

      check(events).length.equals(1);
      check(events.single)
          .isA<HermesRunError>()
          .has((event) => event.message, 'message')
          .contains('size or shape limit');
    });

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
    test(
      'maps sparse response terminal output shape to a typed run error',
      () async {
        Object? output = 'leaf';
        for (var depth = 0; depth <= 128; depth++) {
          output = <Object?>[output];
        }

        final events = await parseHermesResponseStream(
          _sse([
            'event: response.completed\n'
                'data: ${jsonEncode(<String, Object?>{
                  'response': <String, Object?>{'id': 'resp_deep', 'status': 'completed', 'output': output},
                })}\n\n',
          ]),
        ).toList();

        check(
          events.whereType<HermesResponseCreated>().single.responseId,
        ).equals('resp_deep');
        check(
          events.whereType<HermesRunError>().single.message,
        ).contains('size or shape limit');
      },
    );

    test(
      'delegates event-only terminal frames to the Hermes fallback',
      () async {
        final completed = await parseHermesResponseStream(
          _sse(['event: response.completed\ndata:\n\n']),
        ).toList();
        final failed = await parseHermesResponseStream(
          _sse(['event: response.failed\ndata:\n\n']),
        ).toList();

        check(completed).length.equals(1);
        check(completed.single).isA<HermesRunDone>();
        check(failed).length.equals(2);
        check(failed.first)
            .isA<HermesRunError>()
            .has((event) => event.message, 'message')
            .equals('Hermes run failed.');
        check(failed.last).isA<HermesRunDone>();
      },
    );

    test('keeps unrelated empty event frames ignorable', () async {
      final events = await parseHermesResponseStream(
        _sse(['event: tool.started\ndata:\n\n']),
      ).toList();

      check(events).isEmpty();
    });

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
