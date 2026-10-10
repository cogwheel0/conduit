import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/realtime_call/bridge_commands.dart';
import 'package:conduit_core/features/chat/realtime_call/realtime_call_prompt.dart';
import 'package:conduit_core/features/chat/realtime_call/realtime_call_protocol.dart';
import 'package:test/test.dart';

/// Each case mirrors a rule of Open WebUI's `CallProtocol`
/// (`backend/open_webui/routers/audio/realtime.py`), which the shared engine
/// relies on whichever bridge it talks to.
void main() {
  late RealtimeCallProtocol protocol;

  setUp(() => protocol = RealtimeCallProtocol());

  void transcribed(String itemId, [String transcript = 'What time is it?']) =>
      protocol.observe({
        'type': 'conversation.item.input_audio_transcription.completed',
        'item_id': itemId,
        'transcript': transcript,
      });

  void delegated(String callId, {String request = 'time'}) => protocol.observe({
    'type': 'response.output_item.done',
    'response_id': 'resp-1',
    'item': {
      'type': 'function_call',
      'status': 'completed',
      'name': kDelegateFunctionName,
      'call_id': callId,
      'arguments': jsonEncode({'request': request}),
    },
  });

  Subject<List<Map<String, Object?>>> sent(Map<String, Object?> command) =>
      check(protocol.command(command));

  void refused(Map<String, Object?> command) =>
      check(() => protocol.command(command))
          .throws<RealtimeProtocolException>();

  group('answering an input', () {
    test('needs a transcript, then is asked for once', () {
      refused(BridgeCommands.respondToInput('item-1'));

      transcribed('item-1');
      sent(BridgeCommands.respondToInput('item-1')).deepEquals([
        {
          'type': 'response.create',
          'response': {
            'metadata': {'input_item_id': 'item-1'},
          },
        },
      ]);
      refused(BridgeCommands.respondToInput('item-1'));
    });

    test('an empty transcript is never answered', () {
      transcribed('item-1', '   ');

      refused(BridgeCommands.respondToInput('item-1'));
    });
  });

  group('a delegation', () {
    test('returns its result once, then speaks it once without tools', () {
      delegated('call-1');
      refused(BridgeCommands.respondToResult('call-1'));

      sent(
        BridgeCommands.result(
          callId: 'call-1',
          status: BridgeTurnStatus.completed,
          answer: 'It is noon.',
        ),
      ).deepEquals([
        {
          'type': 'conversation.item.create',
          'item': {
            'type': 'function_call_output',
            'call_id': 'call-1',
            'output': '{"status":"completed","answer":"It is noon."}',
          },
        },
      ]);
      refused(
        BridgeCommands.result(
          callId: 'call-1',
          status: BridgeTurnStatus.completed,
          answer: 'Again.',
        ),
      );

      sent(BridgeCommands.respondToResult('call-1')).deepEquals([
        {
          'type': 'response.create',
          'response': {
            'tools': <Object>[],
            'tool_choice': 'none',
            'metadata': {'call_id': 'call-1'},
          },
        },
      ]);
      refused(BridgeCommands.respondToResult('call-1'));
    });

    test('a failed result is spoken as a failure', () {
      delegated('call-1');
      protocol.command(
        BridgeCommands.result(
          callId: 'call-1',
          status: BridgeTurnStatus.failed,
          answer: 'boom',
        ),
      );

      final response = protocol
          .command(BridgeCommands.respondToResult('call-1'))
          .single;
      check((response['response'] as Map)['instructions'])
          .equals(kFailedResultInstructions);
    });

    test('malformed or unknown functions end the call', () {
      check(() => delegated('call-1', request: '  '))
          .throws<RealtimeProtocolException>();
      check(
        () => protocol.observe({
          'type': 'response.output_item.done',
          'response_id': 'resp-1',
          'item': {
            'type': 'function_call',
            'status': 'completed',
            'name': 'play_animation',
            'call_id': 'call-2',
            'arguments': '{"name":"wave"}',
          },
        }),
      ).throws<RealtimeProtocolException>();
      check(
        () => protocol.observe({
          'type': 'response.output_item.done',
          'response_id': 'resp-1',
          'item': {
            'type': 'function_call',
            'status': 'completed',
            'name': kDelegateFunctionName,
            'call_id': 'call-3',
            'arguments': '{"request":"a","extra":1}',
          },
        }),
      ).throws<RealtimeProtocolException>();
    });

    test('an unknown status or an oversized answer is refused', () {
      delegated('call-1');
      refused({
        'type': 'bridge.result',
        'call_id': 'call-1',
        'status': 'done',
        'answer': 'x',
      });
      refused(
        BridgeCommands.result(
          callId: 'call-1',
          status: BridgeTurnStatus.completed,
          answer: 'x' * 100001,
        ),
      );
    });
  });

  test('a chat snapshot replaces the one before it', () {
    final messages = [
      {'role': 'user', 'content': 'Hi'},
      {'role': 'assistant', 'content': 'Hello!'},
    ];

    final first = protocol.command(BridgeCommands.context(messages));
    check(first).length.equals(1);
    final created = first.single['item'] as Map;
    check(created['id']).equals('chat_context_1');
    check(created['role']).equals('system');
    check(((created['content'] as List).single as Map)['text'])
        .equals('$kChatSnapshotPreamble${jsonEncode(messages)}');

    final second = protocol.command(BridgeCommands.context(const []));
    check(second.first).deepEquals({
      'type': 'conversation.item.delete',
      'item_id': 'chat_context_1',
    });
    check((second.last['item'] as Map)['id']).equals('chat_context_2');
  });

  test('a snapshot outside its bounds is refused', () {
    refused(
      BridgeCommands.context([
        {'role': 'system', 'content': 'x'},
      ]),
    );
    refused(
      BridgeCommands.context([
        for (var i = 0; i < 3; i++) {'role': 'user', 'content': 'x' * 30000},
      ]),
    );
    refused(
      BridgeCommands.context([
        for (var i = 0; i < 101; i++) {'role': 'user', 'content': 'x'},
      ]),
    );
  });

  test('a truncation stays within the audio received', () {
    // 2400 samples is 100 ms at 24 kHz.
    protocol.observe({
      'type': 'response.output_audio.delta',
      'response_id': 'resp-1',
      'item_id': 'item-a',
      'content_index': 0,
      'delta': base64.encode(List.filled(4800, 0)),
    });

    sent(
      BridgeCommands.truncate(
        itemId: 'item-a',
        contentIndex: 0,
        audioEndMs: 100,
      ),
    ).length.equals(1);
    refused(
      BridgeCommands.truncate(
        itemId: 'item-a',
        contentIndex: 0,
        audioEndMs: 101,
      ),
    );
    refused(
      BridgeCommands.truncate(itemId: 'item-b', contentIndex: 0, audioEndMs: 0),
    );
  });

  test('microphone audio is whole samples, at most a second', () {
    sent(BridgeCommands.appendAudio(base64.encode([1, 2]))).length.equals(1);
    refused(BridgeCommands.appendAudio(''));
    refused(BridgeCommands.appendAudio(base64.encode([1, 2, 3])));
    refused(BridgeCommands.appendAudio(base64.encode(List.filled(48002, 0))));
    refused(BridgeCommands.appendAudio('not base64!'));
  });

  test('only responses that exist can be cancelled', () {
    refused(BridgeCommands.cancelResponse('resp-1'));
    protocol.observe({
      'type': 'response.created',
      'response': {'id': 'resp-1'},
    });
    sent(BridgeCommands.cancelResponse('resp-1')).length.equals(1);
  });

  test('a status is spoken outside the conversation', () {
    final response =
        protocol
                .command(BridgeCommands.status(BridgeCallStatus.approval))
                .single['response']
            as Map;

    check(response['conversation']).equals('none');
    check(response['tool_choice']).equals('none');
    check(response['instructions'] as String)
        .contains(kRealtimeCallStatusLines['approval']!);
  });

  test('any other shape ends the call, extra keys included', () {
    refused({...BridgeCommands.respondToInput('item-1'), 'event_id': 'e'});
    refused(BridgeCommands.ping);
    refused(
      BridgeCommands.animationResult(
        callId: 'call-1',
        status: BridgeAnimationStatus.unavailable,
      ),
    );
    refused({'type': 'session.update', 'session': <String, Object?>{}});
  });

  test('the voice is configured to wait to be asked', () {
    final update = directRealtimeSessionUpdate(
      voice: 'marin',
      transcriptionModel: 'whisper-1',
    );
    final session = update['session'] as Map;
    final input = (session['audio'] as Map)['input'] as Map;

    check(update['type']).equals('session.update');
    check(session['instructions']).equals(kRealtimeCallInstructions);
    check(input['turn_detection']).isA<Map>().deepEquals({
      'type': 'server_vad',
      'interrupt_response': true,
      'create_response': false,
    });
    check(input['transcription']).isA<Map>().deepEquals({'model': 'whisper-1'});
    check(((session['tools'] as List).single as Map)['name'])
        .equals(kDelegateFunctionName);
    check(
          directRealtimeSessionUpdate(
            voice: 'marin',
            transcriptionModel: 'whisper-1',
            instructions: 'Be brief.',
          )['session'],
        )
        .isA<Map>()
        .has((s) => s['instructions'], 'instructions')
        .equals('Be brief.');
  });
}
