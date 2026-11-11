import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/librechat/models/librechat_stream_event.dart';
import 'package:conduit_core/features/librechat/services/librechat_message_mapper.dart';
import 'package:conduit_core/features/librechat/services/librechat_stream_reducer.dart';
import 'package:conduit_core/services/sse_frame_scanner.dart';
import 'package:test/test.dart';

/// The events of a stream fixture, read the way the client reads a stream.
List<LibreChatStreamEvent> fixtureEvents(String name) {
  final text = File(
    'test/features/librechat/fixtures/streams/$name',
  ).readAsStringSync();
  final scanner = SseFrameScanner();
  return [
    // Fed in uneven chunks, as a network delivers them.
    for (var start = 0; start < text.length; start += 37)
      for (final frame in scanner.addChunk(
        text.substring(start, (start + 37).clamp(0, text.length)),
      ))
        ?LibreChatStreamEvent.fromFrame(event: frame.event, data: frame.data),
  ];
}

/// What the parts render as, which is what must agree with the saved reply.
List<Map<String, dynamic>> rendered(List<Map<String, dynamic>> parts) =>
    LibreChatMessageMapper.outputItems(parts);

void main() {
  test('a fresh reply builds the parts its final frame saves', () {
    final reducer = LibreChatStreamReducer();
    final events = fixtureEvents('fresh_tool_reply.sse');
    LibreChatStreamFinal? last;
    for (final event in events) {
      if (event is LibreChatStreamFinal) {
        last = event;
        continue;
      }
      reducer.apply(event);
    }
    // Before the final frame: built from deltas alone, including the
    // reasoning delta that arrived ahead of its run step.
    final saved = [
      for (final part in last!.responseMessage!['content'] as List)
        Map<String, dynamic>.from(part as Map),
    ];
    check(rendered(reducer.parts)).deepEquals(rendered(saved));
    check(reducer.responseMessageId).equals('r1');
    check(reducer.userMessage!['messageId']).equals('u1');
    check(reducer.title).equals('Paris weather');
    check(reducer.attachments).length.equals(1);

    reducer.apply(last);
    check(reducer.isDone).isTrue();
    check(rendered(reducer.parts)).deepEquals(rendered(saved));
  });

  test('tool arguments stream into the call, then its output', () {
    final reducer = LibreChatStreamReducer();
    final events = fixtureEvents('fresh_tool_reply.sse');
    final completed = events.indexWhere(
      (event) =>
          event is LibreChatStreamStep &&
          event.name == 'on_run_step_completed',
    );
    for (final event in events.take(completed)) {
      reducer.apply(event);
    }
    final call = reducer.parts[1]['tool_call'] as Map;
    check(call['args']).equals('{"city":"Paris"}');
    check(call['output']).isNull();
    // The reply is still running, so the call waiting on its output is too.
    check(
      LibreChatMessageMapper.outputItems(
        reducer.parts,
        inProgress: true,
      )[1]['status'],
    ).equals('in_progress');

    reducer.apply(events[completed]);
    final done = reducer.parts[1]['tool_call'] as Map;
    check(done['output']).equals('Sunny, 21C');
    check(done['progress']).equals(1);
  });

  test('a resumed stream starts from the snapshot', () {
    final reducer = LibreChatStreamReducer();
    final events = fixtureEvents('resume_mid_text.sse');
    check(events.first).isA<LibreChatStreamSync>();
    reducer.apply(events.first);
    check(reducer.parts).deepEquals([
      {'type': 'text', 'text': 'One, two, three'},
    ]);
    check(reducer.responseMessageId).equals('r2');
    check(reducer.title).equals('Counting');
    reducer.apply(events[1]);
    check(reducer.parts.single['text']).equals('One, two, three, four.');
  });

  test('a pause for approval waits on the stream', () {
    final reducer = LibreChatStreamReducer();
    for (final event in fixtureEvents('pending_action.sse')) {
      reducer.apply(event);
    }
    check(reducer.isDone).isFalse();
    check(reducer.pendingAction!['actionId']).equals('act_1');
    final call = reducer.parts.single['tool_call'] as Map;
    check(call['name']).equals('echo_mcp_everything');
    reducer.clearPendingAction();
    check(reducer.pendingAction).isNull();
  });

  test('a snapshot without the pause means it was answered', () {
    final reducer = LibreChatStreamReducer()
      ..apply(const LibreChatStreamPendingAction({'actionId': 'act_1'}));
    check(reducer.pendingAction).isNotNull();

    // Answered on another device while this one was away.
    reducer.apply(
      const LibreChatStreamSync(
        resumeState: {'aggregatedContent': <Object>[]},
        pendingEvents: [],
      ),
    );
    check(reducer.pendingAction).isNull();

    // A pause that landed after the snapshot arrives among its events.
    reducer.apply(
      const LibreChatStreamSync(
        resumeState: {'aggregatedContent': <Object>[]},
        pendingEvents: [
          LibreChatStreamPendingAction({'actionId': 'act_2'}),
        ],
      ),
    );
    check(reducer.pendingAction!['actionId']).equals('act_2');
  });

  test('a stopped reply ends aborted with what was saved', () {
    final reducer = LibreChatStreamReducer();
    final events = fixtureEvents('aborted.sse');
    for (final event in events) {
      reducer.apply(event);
    }
    final frame = reducer.finalFrame!;
    check(frame.aborted).isTrue();
    check(frame.earlyAbort).isFalse();
    check(frame.responseMessage!['unfinished']).equals(true);
    check(reducer.parts.single['text']).equals('Once upon');
  });

  test('failures and reconcile frames end the stream', () {
    final failed = fixtureEvents('failed.sse');
    check(failed.last).isA<LibreChatStreamFailed>().has(
      (it) => it.message,
      'message',
    ).equals('The model is not available.');

    final reconcile = fixtureEvents('reconcile.sse').single;
    check(reconcile).isA<LibreChatStreamFinal>()
      ..has((it) => it.reconcile, 'reconcile').isTrue()
      ..has((it) => it.responseMessage, 'responseMessage').isNull();
  });

  test('a delta whose step never arrives changes nothing', () {
    final reducer = LibreChatStreamReducer();
    final changed = reducer.apply(
      const LibreChatStreamStep('on_message_delta', {
        'id': 'ghost',
        'delta': {
          'content': [
            {'type': 'text', 'text': 'boo'},
          ],
        },
      }),
    );
    check(changed).isFalse();
    check(reducer.parts).isEmpty();
  });

  test('a part of another type is never overwritten', () {
    final reducer = LibreChatStreamReducer()
      ..apply(
        const LibreChatStreamStep('on_run_step', {
          'id': 's',
          'runId': 'r',
          'index': 0,
          'stepDetails': {'type': 'message_creation'},
        }),
      )
      ..apply(
        const LibreChatStreamStep('on_message_delta', {
          'id': 's',
          'delta': {
            'content': [
              {'type': 'text', 'text': 'hi'},
            ],
          },
        }),
      );
    final changed = reducer.apply(
      const LibreChatStreamStep('on_reasoning_delta', {
        'id': 's',
        'delta': {
          'content': [
            {'type': 'think', 'think': 'x'},
          ],
        },
      }),
    );
    check(changed).isFalse();
    check(reducer.parts.single).deepEquals({'type': 'text', 'text': 'hi'});
  });
}
