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
        ..has((e) => e.detail, 'detail').equals('provider unavailable');
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

    test('decodes Responses-API text deltas and terminal lifecycle', () async {
      final events = await parseHermesRunStream(
        _sse([
          'event: response.output_text.delta\ndata: {"delta":"world"}\n\n',
          'event: response.completed\ndata: {"status":"completed"}\n\n',
        ]),
      ).toList();

      check(events[0])
          .isA<HermesTokenDelta>()
          .has((e) => e.content, 'content')
          .equals('world');
      check(events[1])
          .isA<HermesLifecycle>()
          .has((e) => e.status, 'status')
          .equals('completed');
      check(events[2]).isA<HermesRunDone>();
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
}
