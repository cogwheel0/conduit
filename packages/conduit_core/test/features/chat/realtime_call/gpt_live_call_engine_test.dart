import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/realtime_call/bridge_call_host.dart';
import 'package:conduit_core/features/chat/realtime_call/gpt_live_call_engine.dart';
import 'package:conduit_core/features/chat/realtime_call/realtime_bridge_transport.dart';
import 'package:conduit_core/features/chat/realtime_call/realtime_call_ports.dart';
import 'package:conduit_core/features/chat/realtime_call/realtime_call_state.dart';
import 'package:conduit_core/voice/voice_session.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

final class _Media implements RealtimeWebRtcMediaPort {
  final _messages = StreamController<String>.broadcast();
  final _states = StreamController<RealtimeMediaState>.broadcast();
  final sent = <Map<String, Object?>>[];
  String? answer;
  bool? microphone;
  var closed = false;

  void receive(Map<String, Object?> event) => _messages.add(jsonEncode(event));

  List<String> get types => [
    for (final event in sent) event['type']! as String,
  ];

  @override
  Future<String> createOffer({String dataChannel = 'oai-events'}) async =>
      'v=0\r\noffer\r\n';

  @override
  Future<void> acceptAnswer(String sdp) async => answer = sdp;

  @override
  Stream<String> get messages => _messages.stream;

  @override
  Stream<RealtimeMediaState> get states => _states.stream;

  @override
  void send(String message) =>
      sent.add(jsonDecode(message) as Map<String, Object?>);

  @override
  void setMicrophoneEnabled(bool enabled) => microphone = enabled;

  @override
  Future<void> close() async => closed = true;
}

final class _Turn implements DelegatedTurn {
  final _changes = StreamController<DelegatedTurnState>.broadcast();
  var cancelled = false;
  Completer<void>? cancelGate;

  @override
  String? get assistantMessageId => 'answer-1';

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

  var closed = false;

  @override
  void close() => closed = true;

  @override
  Future<void> cancel() async {
    cancelled = true;
    await cancelGate?.future;
    move(DelegatedTurnState.cancelled);
  }
}

final class _Host implements BridgeCallHost {
  final requests = <(String, String?)>[];
  final turns = <_Turn>[];
  Completer<void>? gate;

  @override
  List<Map<String, String>> chatSnapshot() => const [];

  @override
  Future<void> recordExchange(RealtimeVoiceExchange exchange) async {}

  @override
  Future<void> mergeSpeech(String id, Map<String, Object?> voice) async {}

  @override
  Future<DelegatedTurn> delegate(
    String text, {
    required Map<String, Object?> userVoice,
    String? spokenContext,
  }) async {
    requests.add((text, spokenContext));
    await gate?.future;
    final turn = _Turn();
    turns.add(turn);
    return turn;
  }

  @override
  void notice(ChatVoiceModeNotice notice) {}
}

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late _Media media;
  late _Host host;
  late GptLiveCallEngine engine;
  late List<(String, List<Map<String, Object?>>)> opened;

  Future<void> start() async {
    final connecting = engine.connect();
    await _settle();
    media.receive({
      'type': 'session.started',
      'session': {'id': 'sess-1'},
    });
    await connecting;
  }

  setUp(() async {
    media = _Media();
    host = _Host();
    opened = [];
    engine = GptLiveCallEngine(
      media: media,
      host: host,
      callId: 'call',
      // These tests end calls without the session confirming it.
      closeTimeout: const Duration(milliseconds: 20),
      history: const [
        {
          'type': 'message',
          'role': 'user',
          'content': [
            {'type': 'input_text', 'text': 'Earlier'},
          ],
        },
      ],
      open: (offer, history) async {
        opened.add((offer, history));
        return 'v=0\r\nanswer\r\n';
      },
    );
  });

  void says(String text) =>
      media.receive({'type': 'session.input_transcript.delta', 'delta': text});

  void voiceSays(String text) =>
      media.receive({'type': 'session.output_transcript.delta', 'delta': text});

  void delegates(String id) => media.receive({
    'type': 'session.delegation.created',
    'delegation': {'id': id, 'type': 'delegation', 'target': 'client'},
  });

  test('opens through Hermes with the offer as it is, and goes live', () async {
    await start();

    check(opened.single.$1).equals('v=0\r\noffer\r\n');
    check(opened.single.$2).length.equals(1);
    check(media.answer).equals('v=0\r\nanswer\r\n');
    check(engine.state.phase).equals(RealtimeCallPhase.live);
    await engine.end();
  });

  test(
    'a delegated request is the latest words, with the conversation',
    () async {
      await start();
      says('Plan my ');
      says('day');
      voiceSays('Sure, which day?');
      says('Tomorrow, please.');
      delegates('del-1');
      await _settle();

      final (request, context) = host.requests.single;
      check(request).equals('Tomorrow, please.');
      check(context).equals(
        'User: Plan my day\nVoice assistant: Sure, which day?\n'
        'User: Tomorrow, please.',
      );
      final thinking = media.sent.singleWhere(
        (event) => event['type'] == 'session.thinking.append',
      );
      check(thinking['delegation_id']).equals('del-1');
      check(engine.state.working).isTrue();

      host.turns.single.move(
        DelegatedTurnState.completed,
        answer: 'Gym at 7. Lunch at noon.',
      );
      await _settle();
      final commentary = media.sent.where(
        (event) => event['type'] == 'session.commentary.append',
      );
      check(commentary.single).deepEquals({
        'type': 'session.commentary.append',
        'event_id': commentary.single['event_id'],
        'delegation_id': 'del-1',
        'content': 'Gym at 7. Lunch at noon.',
      });
      check(engine.state.working).isFalse();
      await engine.end();
    },
  );

  test('every event carries its own id', () async {
    await start();
    engine
      ..setMuted(true)
      ..setMuted(false);

    final ids = media.sent.map((event) => event['event_id']).toSet();
    check(ids).length.equals(media.sent.length);
    await engine.end();
  });

  test('a turn waiting in the chat is said once', () async {
    await start();
    says('Delete the old files');
    delegates('del-1');
    await _settle();

    host.turns.single.move(DelegatedTurnState.approval);
    host.turns.single.move(DelegatedTurnState.approval);
    await _settle();

    check(media.sent.where((e) => e['type'] == 'session.commentary.append'))
        .length
        .equals(1);
    check(engine.state.approval).isTrue();
    await engine.end();
  });

  test('a newer request stops the one still running', () async {
    await start();
    says('First thing');
    delegates('del-1');
    await _settle();
    says(' and then another');
    delegates('del-2');
    await _settle();

    check(host.turns.first.cancelled).isTrue();
    check(host.requests).length.equals(2);
    await engine.end();
  });

  test('a request replaced while the one before it stops is never sent',
      () async {
    await start();
    says('First thing');
    delegates('del-1');
    await _settle();
    final stopping = host.turns.single.cancelGate = Completer<void>();

    says(' and then another');
    delegates('del-2');
    await _settle();
    says(' no, this');
    delegates('del-3');
    await _settle();
    // The chat takes the newest only once the first answer has stopped.
    check(host.requests).length.equals(1);
    stopping.complete();
    await _settle();

    // del-2 was replaced while del-1 was still stopping.
    check(host.requests).length.equals(2);
    await engine.end();
  });

  test('muting tells the voice and closes the microphone', () async {
    await start();

    engine.setMuted(true);

    check(media.microphone).equals(false);
    check(media.types.last).equals('session.input_audio.mute');
    check(engine.state.muted).isTrue();
    await engine.end();
  });

  test('ending closes the session before the connection', () async {
    await start();
    final ending = engine.end();
    await _settle();
    check(media.types.last).equals('session.close');
    // Nothing more is heard while the session confirms.
    check(media.microphone).equals(false);
    check(media.closed).isFalse();

    media.receive({'type': 'session.closed', 'reason': 'close_requested'});
    await ending;
    check(media.closed).isTrue();
    check(engine.state.phase).equals(RealtimeCallPhase.ended);
  });

  test('an answer handed over as the call ends goes on in the chat', () async {
    await start();
    final gate = host.gate = Completer<void>();
    says('Plan my day');
    delegates('del-1');
    await _settle();

    final ending = engine.end();
    gate.complete();
    await ending;
    await _settle();
    host.turns.single.move(DelegatedTurnState.approval);
    await _settle();

    check(host.turns.single.cancelled).isFalse();
    check(host.turns.single.closed).isTrue();
    check(engine.state.approval).isFalse();
  });

  test('a request still being handed over stops before the next one goes',
      () async {
    await start();
    final handing = host.gate = Completer<void>();
    says('First thing');
    delegates('del-1');
    await _settle();
    says(' no, this');
    delegates('del-2');
    await _settle();
    // The chat has not answered the first hand-over yet.
    check(host.requests).length.equals(1);

    handing.complete();
    await _settle();
    check(host.turns.first.cancelled).isTrue();
    check(host.requests).length.equals(2);
    await engine.end();
  });

  test('words from minutes ago are not part of a new request', () {
    fakeAsync((async) {
      var now = DateTime.utc(2026, 1, 1, 12);
      final timed = GptLiveCallEngine(
        media: media,
        host: host,
        callId: 'call',
        clock: () => now,
        open: (offer, history) async => 'v=0\r\nanswer\r\n',
      );
      unawaited(timed.connect());
      async.flushMicrotasks();
      media.receive({
        'type': 'session.started',
        'session': {'id': 'sess-1'},
      });
      async.flushMicrotasks();

      says('Remind me later');
      async.elapse(const Duration(seconds: 2));
      now = now.add(const Duration(minutes: 6));
      says('What is the weather?');
      delegates('del-1');
      async.flushMicrotasks();

      final (request, context) = host.requests.single;
      check(request).equals('What is the weather?');
      check(context).equals('User: What is the weather?');
    });
  });

  test('a session that runs out of time ends the call and says so', () async {
    await start();

    media.receive({'type': 'session.closed', 'reason': 'expired'});
    await _settle();

    check(engine.state.phase).equals(RealtimeCallPhase.ended);
    check(engine.state.error).isNotNull().contains('time limit');
  });

  test('a session that never starts fails the call', () {
    fakeAsync((async) {
      Object? failure;
      engine.connect().catchError((Object error) => failure = error);
      async.elapse(const Duration(seconds: 16));

      check(failure).isA<RealtimeBridgeException>();
      check(engine.state.phase).equals(RealtimeCallPhase.ended);
    });
  });

  group('chunkForCommentary', () {
    test('keeps short text whole', () {
      check(chunkForCommentary('It is sunny.')).deepEquals(['It is sunny.']);
    });

    test('cuts after sentences, within the limit', () {
      check(chunkForCommentary('One two. Three four. Five six.', limit: 18))
          .deepEquals(['One two.', 'Three four.', 'Five six.']);
    });

    test('takes only a positive limit', () {
      check(() => chunkForCommentary('text', limit: 0))
          .throws<ArgumentError>();
    });

    test('cuts a sentence longer than the limit at the limit', () {
      check(chunkForCommentary('abcdefghij', limit: 4))
          .deepEquals(['abcd', 'efgh', 'ij']);
    });
  });
}
