import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/realtime_call/bridge_call_engine.dart';
import 'package:conduit_core/features/chat/realtime_call/bridge_call_host.dart';
import 'package:conduit_core/features/chat/realtime_call/realtime_bridge_transport.dart';
import 'package:conduit_core/features/chat/realtime_call/realtime_call_ports.dart';
import 'package:conduit_core/features/chat/realtime_call/realtime_call_prompt.dart';
import 'package:conduit_core/features/chat/realtime_call/realtime_call_protocol.dart';
import 'package:conduit_core/features/chat/realtime_call/realtime_call_state.dart';
import 'package:conduit_core/voice/voice_session.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

/// A bridge that holds the engine to Open WebUI's rules: every command goes
/// through the same checks the server makes, and any it would refuse is
/// recorded in [refused].
final class _Transport implements RealtimeBridgeTransport {
  final _events = StreamController<Map<String, Object?>>();
  final _closed = Completer<String?>();
  final _protocol = RealtimeCallProtocol();
  final sent = <Map<String, Object?>>[];
  final refused = <String>[];

  void receive(Map<String, Object?> event) {
    _protocol.observe(event);
    _events.add(event);
  }

  void drop(String message) {
    if (!_closed.isCompleted) _closed.complete(message);
  }

  List<String?> get types => [for (final c in sent) c['type'] as String?];

  @override
  Future<RealtimeBridgeReady> open() async =>
      (model: 'gpt-realtime', voice: 'marin');

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  @override
  void send(Map<String, Object?> command) {
    sent.add(command);
    if (command['type'] == 'bridge.ping') return;
    try {
      _protocol.command(command);
    } on RealtimeProtocolException catch (error) {
      refused.add('${command['type']}: $error');
    }
  }

  @override
  Future<String?> get closed => _closed.future;

  @override
  Future<void> close() async {
    if (!_closed.isCompleted) _closed.complete(null);
  }
}

final class _Audio implements RealtimePcmAudioPort {
  final frames = StreamController<Uint8List>();
  final _reports = StreamController<RealtimePlaybackReport>();
  final enqueued = <String>[];
  final ended = <String>[];
  final clears = <int>[];
  var rendered = <RealtimeRenderedItem>[];
  bool? captureEnabled;
  var received = 0;

  /// A report after everything queued has played, as the engine reports it:
  /// tagged with the latest clear it was asked for.
  void idle() => _reports.add(
    RealtimePlaybackReport(
      clearId: clears.isEmpty ? 0 : clears.last,
      playbackActive: false,
      queuedSamples: 0,
      receivedSamples: received,
    ),
  );

  @override
  Future<void> start() async {}

  @override
  Stream<Uint8List> get captureFrames => frames.stream;

  @override
  Stream<RealtimePlaybackReport> get reports => _reports.stream;

  @override
  Stream<String> get failures => const Stream.empty();

  @override
  void setCaptureEnabled(bool enabled) => captureEnabled = enabled;

  @override
  void enqueue({
    required String responseId,
    required String itemId,
    required int contentIndex,
    required Uint8List pcm,
  }) {
    enqueued.add(itemId);
    received += pcm.length ~/ 2;
  }

  @override
  void endResponse(String responseId) => ended.add(responseId);

  @override
  Future<List<RealtimeRenderedItem>> clear(int clearId) async {
    clears.add(clearId);
    return rendered;
  }

  @override
  Duration get outputLatency => const Duration(milliseconds: 50);

  @override
  Future<void> stop() async {}
}

final class _Turn implements DelegatedTurn {
  _Turn({this.assistantMessageId = 'answer-1'});

  final _changes = StreamController<DelegatedTurnState>.broadcast();
  var cancelled = false;

  @override
  final String? assistantMessageId;

  @override
  var state = DelegatedTurnState.working;

  @override
  var answer = '';

  void move(DelegatedTurnState next, {String answer = ''}) {
    state = next;
    this.answer = answer;
    _changes.add(next);
  }

  @override
  Stream<DelegatedTurnState> get changes => _changes.stream;

  @override
  Future<void> cancel() async {
    cancelled = true;
    move(DelegatedTurnState.cancelled);
  }
}

final class _Host implements BridgeCallHost {
  var snapshot = <Map<String, String>>[];
  final exchanges = <RealtimeVoiceExchange>[];
  final merges = <(String, Map<String, Object?>)>[];
  final delegated = <String>[];
  final notices = <ChatVoiceModeNotice>[];
  var turn = _Turn();

  @override
  List<Map<String, String>> chatSnapshot() => snapshot;

  @override
  Future<void> recordExchange(RealtimeVoiceExchange exchange) async =>
      exchanges.add(exchange);

  @override
  Future<void> mergeSpeech(
    String assistantMessageId,
    Map<String, Object?> voice,
  ) async => merges.add((assistantMessageId, voice));

  @override
  Future<DelegatedTurn> delegate(
    String text, {
    required Map<String, Object?> userVoice,
    String? spokenContext,
  }) async {
    delegated.add(text);
    return turn;
  }

  @override
  void notice(ChatVoiceModeNotice notice) => notices.add(notice);
}

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late _Transport transport;
  late _Audio audio;
  late _Host host;
  late BridgeCallEngine engine;

  setUp(() async {
    transport = _Transport();
    audio = _Audio();
    host = _Host();
    engine = BridgeCallEngine(
      transport: transport,
      audio: audio,
      host: host,
      callId: 'call',
    );
    await engine.connect();
    await _settle();
  });

  tearDown(() async {
    await engine.end();
    check(transport.refused).isEmpty();
  });

  void say(String itemId, String text) {
    transport.receive({
      'type': 'input_audio_buffer.speech_started',
      'item_id': itemId,
    });
    transport.receive({
      'type': 'input_audio_buffer.speech_stopped',
      'item_id': itemId,
    });
    transport.receive({
      'type': 'conversation.item.input_audio_transcription.completed',
      'item_id': itemId,
      'transcript': text,
    });
  }

  void replyStarts(String responseId, Map<String, Object?> metadata) =>
      transport.receive({
        'type': 'response.created',
        'response': {'id': responseId, 'metadata': metadata},
      });

  void speaks(String responseId, String itemId, String text) {
    transport.receive({
      'type': 'response.output_audio.delta',
      'response_id': responseId,
      'item_id': itemId,
      'content_index': 0,
      'delta': base64.encode(List.filled(4800, 0)),
    });
    transport.receive({
      'type': 'response.output_audio_transcript.done',
      'response_id': responseId,
      'item_id': itemId,
      'transcript': text,
    });
  }

  Future<void> replyEnds(String responseId) async {
    transport.receive({
      'type': 'response.done',
      'response': {'id': responseId, 'status': 'completed'},
    });
    await _settle();
    audio.idle();
    await _settle();
  }

  void delegates(String responseId, String callId) => transport.receive({
    'type': 'response.output_item.done',
    'response_id': responseId,
    'item': {
      'type': 'function_call',
      'status': 'completed',
      'name': kDelegateFunctionName,
      'call_id': callId,
      'arguments': '{"request":"weather in Oslo"}',
    },
  });

  test('goes live with the voice and sends the chat first', () {
    check(engine.state.phase).equals(RealtimeCallPhase.live);
    check(engine.state.voiceModel).equals('gpt-realtime');
    check(audio.captureEnabled).equals(true);
    check(transport.types).deepEquals(['bridge.context']);
  });

  test('small talk is answered and saved with the words it answers', () async {
    say('item-1', 'Hello there');
    await _settle();
    check(transport.sent.last)
        .deepEquals({'type': 'bridge.respond', 'item_id': 'item-1'});
    check(engine.state.userCaption).equals('Hello there');

    replyStarts('resp-1', {'input_item_id': 'item-1'});
    speaks('resp-1', 'speech-1', 'Hi! How can I help?');
    await replyEnds('resp-1');

    final exchange = host.exchanges.single;
    check(exchange.userText).equals('Hello there');
    check(exchange.replyText).equals('Hi! How can I help?');
    check(exchange.voiceModel).equals('gpt-realtime');
    check(exchange.userVoice).deepEquals({
      'call_id': 'call',
      'input_item_id': 'item-1',
      'model': 'gpt-realtime',
    });
    check(exchange.replyVoice['speech']).isA<List<Object?>>().deepEquals([
      {
        'item_id': 'speech-1',
        'transcript': 'Hi! How can I help?',
        'response_id': 'resp-1',
        'model': 'gpt-realtime',
        'interrupted': false,
      },
    ]);
    check(audio.ended).deepEquals(['resp-1']);
  });

  test('words that could not be made out are noticed, not answered', () async {
    transport.receive({
      'type': 'conversation.item.input_audio_transcription.failed',
      'item_id': 'item-1',
    });
    await _settle();

    check(host.notices).deepEquals([ChatVoiceModeNotice.transcriptionFailed]);
    check(transport.types).not((it) => it.contains('bridge.respond'));
  });

  test('asks for one reply at a time', () async {
    say('item-1', 'First');
    await _settle();
    replyStarts('resp-1', {'input_item_id': 'item-1'});
    say('item-2', 'Second');
    await _settle();
    // The second request waits for the first reply.
    check(transport.sent.where((c) => c['type'] == 'bridge.respond')).length
        .equals(1);

    await replyEnds('resp-1');
    check(transport.sent.last)
        .deepEquals({'type': 'bridge.respond', 'item_id': 'item-2'});
  });

  test(
    'a delegated request runs in the chat and its answer is spoken',
    () async {
      say('item-1', 'What is the weather in Oslo?');
      await _settle();
      replyStarts('resp-1', {'input_item_id': 'item-1'});
      speaks('resp-1', 'speech-1', 'Let me check.');
      delegates('resp-1', 'fn-1');
      await replyEnds('resp-1');

      check(host.delegated).deepEquals(['What is the weather in Oslo?']);
      check(host.exchanges).isEmpty();
      check(engine.state.working).isTrue();

      host.turn.move(DelegatedTurnState.completed, answer: 'Sunny, 21 °C.');
      await _settle();
      check(transport.sent.firstWhere((c) => c['type'] == 'bridge.result'))
          .deepEquals({
            'type': 'bridge.result',
            'call_id': 'fn-1',
            'status': 'completed',
            'answer': 'Sunny, 21 °C.',
          });
      check(transport.sent.last)
          .deepEquals({'type': 'bridge.respond', 'call_id': 'fn-1'});
      check(engine.state.working).isFalse();

      replyStarts('resp-2', {'call_id': 'fn-1'});
      speaks('resp-2', 'speech-2', "It's sunny in Oslo.");
      await replyEnds('resp-2');

      final (assistantId, voice) = host.merges.last;
      check(assistantId).equals('answer-1');
      check(voice['function_call_id']).equals('fn-1');
      check(
        (voice['speech'] as List).map((entry) => (entry as Map)['transcript']),
      ).deepEquals(['Let me check.', "It's sunny in Oslo."]);
    },
  );

  test('a turn waiting for approval is announced once', () async {
    say('item-1', 'Delete my files');
    await _settle();
    replyStarts('resp-1', {'input_item_id': 'item-1'});
    delegates('resp-1', 'fn-1');
    await replyEnds('resp-1');

    host.turn.move(DelegatedTurnState.approval);
    host.turn.move(DelegatedTurnState.approval);
    await _settle();

    check(engine.state.approval).isTrue();
    check(transport.sent.where((c) => c['type'] == 'bridge.status')).single
        .deepEquals({'type': 'bridge.status', 'status': 'approval'});
  });

  test('small talk during a running answer is saved after it', () async {
    say('item-1', 'Plan my week');
    await _settle();
    replyStarts('resp-1', {'input_item_id': 'item-1'});
    delegates('resp-1', 'fn-1');
    await replyEnds('resp-1');

    say('item-2', 'Thanks');
    await _settle();
    replyStarts('resp-2', {'input_item_id': 'item-2'});
    speaks('resp-2', 'speech-2', 'You are welcome.');
    await replyEnds('resp-2');
    check(host.exchanges).isEmpty();

    host.turn.move(DelegatedTurnState.completed, answer: 'Done.');
    await _settle();
    check(host.exchanges.single.userText).equals('Thanks');
  });

  test('a request the chat cannot take now is reported back', () async {
    host.turn = _Turn(assistantMessageId: null)
      ..state = DelegatedTurnState.deferred;
    say('item-1', 'Summarize this');
    await _settle();
    replyStarts('resp-1', {'input_item_id': 'item-1'});
    delegates('resp-1', 'fn-1');
    await replyEnds('resp-1');

    check(
      transport.sent.firstWhere((c) => c['type'] == 'bridge.result')['status'],
    ).equals('deferred');
  });

  test('speaking over the voice stops it where the user cut in', () async {
    say('item-1', 'Tell me a story');
    await _settle();
    replyStarts('resp-1', {'input_item_id': 'item-1'});
    speaks('resp-1', 'speech-1', 'Once upon a time');
    transport.receive({
      'type': 'response.output_audio.delta',
      'response_id': 'resp-1',
      'item_id': 'speech-2',
      'content_index': 0,
      'delta': base64.encode([0, 0]),
    });
    await _settle();
    // All 2400 samples (100 ms) played; 50 ms had not reached the speaker.
    audio.rendered = [
      (
        responseId: 'resp-1',
        itemId: 'speech-1',
        contentIndex: 0,
        samples: 2400,
      ),
    ];

    transport.receive({
      'type': 'input_audio_buffer.speech_started',
      'item_id': 'item-2',
    });
    await _settle();

    check(transport.sent.where((c) => c['type'] == 'response.cancel')).single
        .deepEquals({'type': 'response.cancel', 'response_id': 'resp-1'});
    // Every start of speech clears playback; this one cut the voice off.
    check(audio.clears).deepEquals([1, 2]);
    final truncations = transport.sent
        .where((c) => c['type'] == 'conversation.item.truncate')
        .toList();
    check(truncations).deepEquals([
      {
        'type': 'conversation.item.truncate',
        'item_id': 'speech-1',
        'content_index': 0,
        'audio_end_ms': 50,
      },
      {
        'type': 'conversation.item.truncate',
        'item_id': 'speech-2',
        'content_index': 0,
        'audio_end_ms': 0,
      },
    ]);
    check(engine.state.assistantSpeaking).isFalse();
  });

  test('muting stops sending the microphone and drops what it heard', () async {
    audio.frames.add(Uint8List(4));
    await _settle();
    check(transport.types).contains('input_audio_buffer.append');

    engine.setMuted(true);
    final before = transport.sent.length;
    audio.frames.add(Uint8List(4));
    await _settle();

    check(audio.captureEnabled).equals(false);
    check(transport.sent.sublist(before - 1)).deepEquals([
      {'type': 'input_audio_buffer.clear'},
    ]);
  });

  test(
    'a reply cut off by the end of the call is saved as far as it got',
    () async {
      say('item-1', 'Tell me a joke');
      await _settle();
      replyStarts('resp-1', {'input_item_id': 'item-1'});
      speaks('resp-1', 'speech-1', 'Why did the');
      await _settle();

      await engine.end();

      final exchange = host.exchanges.single;
      check(exchange.replyText).equals('Why did the');
      check(
        ((exchange.replyVoice['speech'] as List).single as Map)['interrupted'],
      ).equals(true);
      check(engine.state.phase).equals(RealtimeCallPhase.ended);
    },
  );

  test('words nothing answered stay in the captions', () async {
    say('item-1', 'Hold on');
    await _settle();

    await engine.end();

    check(host.exchanges).isEmpty();
    check(engine.state.userCaption).equals('Hold on');
  });

  test('a dropped bridge ends the call with its reason', () async {
    transport.drop('Call session expired. Start a new call.');
    await _settle();

    check(engine.state.phase).equals(RealtimeCallPhase.ended);
    check(engine.state.error).equals('Call session expired. Start a new call.');
  });

  test('a bridge that stops answering pings ends the call', () {
    fakeAsync((async) {
      final silent = BridgeCallEngine(
        transport: _Transport(),
        audio: _Audio(),
        host: _Host(),
      );
      unawaited(silent.connect());
      async.flushMicrotasks();

      async.elapse(const Duration(seconds: 40));
      check(silent.state.phase).equals(RealtimeCallPhase.live);
      async.elapse(const Duration(seconds: 10));
      async.flushMicrotasks();
      check(silent.state.phase).equals(RealtimeCallPhase.ended);
      check(silent.state.error).isNotNull();
    });
  });
}
