import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/features/hermes/models/hermes_run_event.dart';
import 'package:conduit/features/hermes/services/hermes_stream_parser.dart';
import 'package:flutter_test/flutter_test.dart';

Stream<List<int>> _sse(List<String> chunks) =>
    Stream<List<int>>.fromIterable(chunks.map(utf8.encode));

void main() {
  group('parseHermesRunStream', () {
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
      check(events[1])
          .isA<HermesTokenDelta>()
          .has((e) => e.content, 'content')
          .equals('Hi');
      check(events[2]).isA<HermesToolProgress>()
        ..has((e) => e.toolName, 'toolName').equals('terminal')
        ..has((e) => e.done, 'done').isTrue();
      check(events[3]).isA<HermesRunDone>();
    });

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
      check(events[1]).isA<HermesLifecycle>()
          .has((e) => e.status, 'status').equals('completed');
      check(events[2]).isA<HermesRunDone>();
    });

    test('surfaces errors', () async {
      final events = await parseHermesRunStream(
        _sse(['data: {"error":{"message":"boom"}}\n\n']),
      ).toList();
      check(events).has((e) => e.length, 'length').equals(1);
      check(events[0])
          .isA<HermesRunError>()
          .has((e) => e.message, 'message')
          .equals('boom');
    });
  });
}
