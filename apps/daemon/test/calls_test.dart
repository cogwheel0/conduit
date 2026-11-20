@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show chatSessionRegistryProvider;
import 'package:conduit_core/features/chat/realtime_call/realtime_call_ports.dart';
import 'package:conduit_core/features/chat/services/chat_draft_queue.dart'
    show chatDraftQueueAdmissionWaitProvider, chatDraftQueueSendProvider;
import 'package:conduit_core/features/chat/voice_mode/chat_voice_send.dart';

import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import 'support/call_window.dart';
import 'support/null_sink.dart';
import 'support/scripted_openai.dart';

/// `calls.*`: a voice call runs in the daemon, in its chat's scope; a fake
/// window listens (as the desktop app's dictation does) and speaks (as its
/// read-aloud engine does). A Standard call against a scripted direct model:
/// the words go to the chat as a turn the windows see, the answer is said,
/// and the call listens again; barge-in, pause and end.
void main() {
  late Directory temporary;
  late CoreRuntime runtime;
  late ScriptedOpenAi provider;
  late EventBus events;
  late TurnsService turns;
  late SpeechService speech;
  late CallsService calls;
  late String model;
  late CallWindow window;
  final previousLinger = TurnsService.lingerAfterTurn;

  setUpAll(() async {
    TurnsService.lingerAfterTurn = const Duration(milliseconds: 300);
    temporary = Directory.systemTemp.createTempSync('calls-test');
    runtime = await CoreRuntime.start(
      config: BootstrapConfig(
        sessionToken: 'a' * 43,
        masterKey: base64.encode(List<int>.generate(32, (i) => i)),
        userDataDir: temporary.path,
      ),
      directories: DaemonDirectories.create(temporary.path),
      log: DaemonLog(level: 'error', sink: NullSink()),
    );
    provider = await ScriptedOpenAi.start();
    final direct = DirectService(runtime.container);
    await direct.setPreferred(preferred: true);
    await direct.setHistory(localOnly: true);
    final saved = await direct.save(
      DirectConnectionEdit(
        name: 'Scripted',
        kind: DirectKind.openai,
        baseUrl: provider.baseUrl,
        manualModelIds: const <String>['scripted-model'],
      ),
    );
    model = DirectModelId.encode(saved.connections.single.id, 'scripted-model');
    events = EventBus();
    // The waits before a turn run on a clock of the test's own: each pause
    // moves it on and lets the event loop turn once, never the wall clock.
    var now = DateTime(2026, 11, 16, 9);
    turns = TurnsService(
      runtime.container,
      events,
      now: () => now,
      pause: (duration) {
        now = now.add(duration);
        return Future<void>(() {});
      },
    );
    speech = SpeechService(
      runtime.container,
      events: events,
      voice: VoiceService(runtime.container),
    );
    calls = CallsService(
      runtime.container,
      events: events,
      turns: turns,
      ports: runtime.calls,
      speech: speech,
    );
    await runtime.container
        .read(appSettingsProvider.notifier)
        .setVoiceCallMode(VoiceCallMode.standard);
  });

  tearDownAll(() async {
    TurnsService.lingerAfterTurn = previousLinger;
    await calls.dispose();
    await speech.dispose();
    await turns.dispose();
    await provider.close();
    await runtime.dispose();
    temporary.deleteSync(recursive: true);
  });

  setUp(() async {
    window = CallWindow(events, calls, speech);
    await runtime.container
        .read(appSettingsProvider.notifier)
        .setVoiceBargeInEnabled(false);
  });

  tearDown(() async {
    await calls.end();
    events.detach('window');
  });

  test(
    'a Standard call sends what was said, says the answer, and listens again',
    () async {
      final started = await calls.start(CallStart(model: model));
      expect(started.phase, CallPhase.starting);
      await window.until(() => window.listens.isNotEmpty);
      expect(window.permissionAsked, isTrue);
      final first = window.listens.single;
      expect(first.continuous, isFalse);
      expect(first.modelId, model);
      await window.until(() => window.last?.phase == CallPhase.listening);
      expect(window.last!.mode, CallMode.standard);
      expect(window.last!.standardReason, isNull);

      window.say(first.listen, 'what time is the tide');
      // The words went to a new chat as a turn the windows saw.
      await window.until(() => window.spoken.isNotEmpty);
      expect(window.spoken.join(' '), contains('what time is the tide'));
      final chatId = window.last!.chatId;
      expect(chatId, startsWith('direct-local:'));
      // Said: the call listens again.
      await window.until(() => window.listens.length == 2);
      await window.until(() => window.last?.phase == CallPhase.listening);
      expect(window.events, contains(ConduitEvents.turnFinished));

      // Paused: no listening, until resumed.
      await calls.pause();
      await window.until(() => window.last?.phase == CallPhase.paused);
      expect(window.stopped, contains(window.listens.last.listen));
      await calls.resume();
      await window.until(() => window.listens.length == 3);
      await window.until(() => window.last?.phase == CallPhase.listening);

      final ended = await calls.end();
      expect(ended.phase, CallPhase.ended);
      expect(ended.chatId, chatId);
      expect(window.last?.phase, CallPhase.ended);
    },
  );

  test(
    'a new call keeps the temporary and folder choices it started with',
    () async {
      // Temporary, with "temporary by default" off: never stored.
      await calls.start(CallStart(model: model, temporary: true));
      await window.until(() => window.listens.isNotEmpty);
      window.say(window.listens.single.listen, 'a quick question');
      await window.until(() => window.spoken.isNotEmpty);
      final temporaryChat = window.last!.chatId!;
      expect(
        temporaryChat,
        startsWith('local:'),
        reason: 'a temporary call was saved as a chat',
      );
      expect(turns.temporary.contains(temporaryChat), isTrue);
      await calls.end();

      // In a folder: its first turn is made in the folder (the scope's
      // pending folder when the turn goes out), after the start's new-chat
      // reset cleared it. (A chat kept on this computer takes no folder; an
      // Open WebUI one is filed in it.)
      window = CallWindow(events, calls, speech);
      await calls.start(CallStart(model: model, folderId: 'garden'));
      final scope = runtime.container
          .read(chatSessionRegistryProvider)
          .scopes
          .last
          .container;
      final folders = <String?>[];
      final watch = scope.listen<String?>(
        pendingFolderIdProvider,
        (_, next) => folders.add(next),
        fireImmediately: true,
      );
      addTearDown(watch.close);
      await window.until(() => window.listens.isNotEmpty);
      window.say(window.listens.single.listen, 'when do tulips go in');
      await window.until(() => window.spoken.isNotEmpty);
      expect(
        folders.skipWhile((f) => f != null),
        contains('garden'),
        reason: 'the call\'s first turn left its folder',
      );
      await calls.end();

      // The call ends while its first words wait for the chat to settle:
      // the turn already under way still makes the chat as the call chose.
      final hold = await turns.holdForCall(model: model, temporary: true);
      final callScope = hold.scope.container;
      // What the call's start does to the scope: a new chat again, with the
      // app's own temporary default (off) and no folder.
      callScope.read(temporaryChatEnabledProvider.notifier).set(false);
      callScope.read(pendingFolderIdProvider.notifier).set(null);
      final words = callScope.read(chatVoiceSendProvider)(
        null,
        'is it too late for garlic',
      );
      hold.release();
      await words;
      final made = hold.chatId;
      expect(
        made,
        startsWith('local:'),
        reason: 'a temporary call\'s first turn was saved as a chat',
      );
      expect(turns.temporary.contains(made!), isTrue);
    },
  );

  /// Every send's turn starts, in order, each with its own answer, and the
  /// chat is left with nothing running once they are done. (The scope then
  /// lingers out on its own timer; a send's future completes only after its
  /// hold on the chat is let go.)
  Future<void> bothGoInOrder(
    CallScopeHold hold,
    Future<void> first,
    Future<void> Function() then,
    List<String> said,
  ) async {
    var firstDone = false;
    unawaited(first.whenComplete(() => firstDone = true));
    await then();
    await pumpEventQueue();
    expect(firstDone, isTrue, reason: 'the first words never got their turn');
    await first;
    final messages = hold.scope.messages;
    expect([
      for (final m in messages)
        if (m.role == 'user') m.content,
    ], said);
    expect(
      [for (final m in messages) m.role],
      ['user', 'assistant', 'user', 'assistant'],
      reason: 'each words have their own answer',
    );
    final chatId = hold.chatId!;
    hold.release();
    expect(
      turns.isRunning(chatId),
      isFalse,
      reason: 'a send still holds the chat',
    );
  }

  test(
    'words said while the last ones wait go after them, each with its answer',
    () async {
      final hold = await turns.holdForCall(model: model);
      addTearDown(hold.release);
      final send = hold.scope.container.read(chatVoiceSendProvider);
      // The first words wait for the chat to settle; the next come meanwhile.
      final first = send(null, 'is the soil warm yet');
      await bothGoInOrder(hold, first, () => send(null, 'and the beans'), [
        'is the soil warm yet',
        'and the beans',
      ]);
    },
  );

  test('a queued batch that comes while words wait goes after them', () async {
    final hold = await turns.holdForCall(model: model);
    addTearDown(hold.release);
    final scope = hold.scope.container;
    // The words wait for the chat to settle; the queue's batch comes
    // meanwhile.
    final words = scope.read(chatVoiceSendProvider)(
      null,
      'is the soil warm yet',
    );
    await bothGoInOrder(
      hold,
      words,
      () => scope.read(chatDraftQueueSendProvider)(null, 'and the beans', null),
      ['is the soil warm yet', 'and the beans'],
    );
  });

  test(
    'a queued batch waits for a delete begun after it was admitted',
    () async {
      final hold = await turns.holdForCall(model: model);
      addTearDown(hold.release);
      final scope = hold.scope.container;
      await scope.read(chatVoiceSendProvider)(null, 'drop this one');
      // The core's queue admits the batch: its admission wait says the chat
      // is quiet.
      await scope.read(chatDraftQueueAdmissionWaitProvider)()!;
      final chatId = hold.scope.conversation!.id;
      final dropped = hold.scope.messages
          .lastWhere((m) => m.role == 'assistant')
          .id;
      // Admitted, the batch is about to be sent; a delete begins first.
      final deleting = turns.deleteMessages(
        DeleteMessages(chatId: chatId, messageIds: <String>[dropped]),
      );
      final batch = scope.read(chatDraftQueueSendProvider)(
        null,
        'and the beans',
        null,
      );
      await deleting;
      await batch;
      await pumpEventQueue(times: 2000);
      expect(
        [
          for (final m in hold.scope.messages)
            if (m.role == 'user') m.content,
        ],
        contains('and the beans'),
        reason: 'the delete dropped the queued batch',
      );
      expect(hold.scope.messages.last.role, 'assistant');
    },
  );

  test(
    'words said while a queued batch waits are not held behind it',
    () async {
      final hold = await turns.holdForCall(model: model);
      addTearDown(hold.release);
      addTearDown(() => provider.release('loam'));
      addTearDown(() => provider.release('surf'));
      addTearDown(() => provider.release('dusk'));
      final scope = hold.scope.container;
      final send = scope.read(chatVoiceSendProvider);
      // An answer runs; the queue's batch comes and waits for it.
      final soil = provider.asked('hold:loam');
      unawaited(
        send(null, 'hold:loam is the soil warm yet', isVoiceMode: true),
      );
      await soil;
      final batch = scope.read(chatDraftQueueSendProvider)(
        null,
        'and the beans',
        null,
      );
      // Words talk over that answer, and theirs runs in turn.
      final tide = provider.asked('hold:surf');
      final second = send(
        null,
        'hold:surf when is high tide',
        isVoiceMode: true,
      );
      await tide;
      await pumpEventQueue(times: 2000);
      var secondEnded = false;
      unawaited(
        second.then(
          (_) => secondEnded = true,
          onError: (Object _) => secondEnded = true,
        ),
      );
      // More words, while the batch waits: they are admitted at once and
      // reach the model while the answer before them is still held (were
      // they behind the batch, this would wait until that answer ended).
      final moon = provider.asked('hold:dusk');
      final third = send(null, 'hold:dusk and the moon', isVoiceMode: true);
      await moon;
      expect(
        [
          for (final m in hold.scope.messages)
            if (m.role == 'assistant' && m.isStreaming) m,
        ],
        hasLength(lessThanOrEqualTo(1)),
        reason: 'the answer talked over still streams',
      );
      provider.release('dusk');
      await third;
      await batch;
      expect(secondEnded, isTrue);
    },
  );

  test('words said over an answer stop it before they go out', () async {
    final hold = await turns.holdForCall(model: model);
    addTearDown(hold.release);
    addTearDown(() => provider.release('tide'));
    final send = hold.scope.container.read(chatVoiceSendProvider);
    final secondAsked = provider.asked('and the beans');
    // The first answer streams, and holds there.
    await send(null, 'hold:tide is the soil warm yet', isVoiceMode: true);
    // The user talks over it.
    final second = send(null, 'and the beans', isVoiceMode: true);
    await secondAsked;
    final answers = [
      for (final m in hold.scope.messages)
        if (m.role == 'assistant') m,
    ];
    expect(
      answers.first.isStreaming,
      isFalse,
      reason: 'the first answer still ran when the next words went out',
    );
    await second;
  });

  test(
    'a queued batch waits for the answer running when it comes, however long',
    () async {
      final hold = await turns.holdForCall(model: model);
      addTearDown(hold.release);
      addTearDown(() => provider.release('soil'));
      final scope = hold.scope.container;
      final before = provider.requests.length;
      bool asked(String text) => provider.requests
          .skip(before)
          .any((r) => r.isNotEmpty && r.last['content'] == text);
      final answerRuns = provider.asked('hold:soil');
      // Words whose answer will run, and hold, past every quiet wait.
      final words = scope.read(chatVoiceSendProvider)(
        null,
        'hold:soil is the soil warm yet',
      );
      // The queue's batch comes meanwhile, as the core's queue sends it once
      // it found no answer on screen.
      final batch = scope.read(chatDraftQueueSendProvider)(
        null,
        'and the beans',
        null,
      );
      await answerRuns;
      // Turns of the event loop only (each wait before a turn takes one on
      // the test's clock): time for the batch to have gone, were it going.
      await pumpEventQueue(times: 2000);
      expect(
        asked('and the beans'),
        isFalse,
        reason: 'the queued batch went out over the running answer',
      );
      // The answer ends: the batch goes, after it, with its own answer.
      provider.release('soil');
      await words;
      await batch;
      expect(
        [
          for (final m in hold.scope.messages)
            if (m.role == 'user') m.content,
        ],
        ['hold:soil is the soil warm yet', 'and the beans'],
      );
      expect(
        [for (final m in hold.scope.messages) m.role],
        ['user', 'assistant', 'user', 'assistant'],
      );
    },
  );

  test('with barge-in the user talks over the answer', () async {
    await runtime.container
        .read(appSettingsProvider.notifier)
        .setVoiceBargeInEnabled(true);
    await calls.start(CallStart(model: model));
    await window.until(() => window.listens.isNotEmpty);
    final listen = window.listens.single;
    expect(listen.continuous, isTrue);
    await window.until(() => window.last?.phase == CallPhase.listening);

    window.holdSpeech = true;
    window.say(
      listen.listen,
      'hold:barge The tide turns at noon today and the boats wait by the pier. '
      'It comes back slowly over the old sand',
      end: false,
    );
    await window.until(() => window.spoken.isNotEmpty);
    await window.until(() => window.last?.phase == CallPhase.speaking);
    events.subscribe(
      'window',
      EventSubscription(scopes: <String>[window.last!.chatId!]),
    );
    // The same listen goes on through the answer, and the user's words
    // stop it and go to the chat.
    expect(window.listens, hasLength(1));
    window.say(listen.listen, 'never mind, a new question', end: false);
    await window.until(() => window.speechStops > 0);
    await window.until(
      () => provider.requests.any(
        (messages) => messages.any(
          (m) => '${m['content']}'.contains('never mind, a new question'),
        ),
      ),
    );
    provider.release('barge');
    // The stopped answer's turn ended, and the new one's.
    await window.until(
      () =>
          window.events.where((e) => e == ConduitEvents.turnFinished).length >=
          2,
    );
  });

  test('a realtime call\'s audio runs over the window\'s socket', () async {
    final audio = runtime.calls.newRealtimeAudio()!;
    final socket = StreamChannelController<dynamic>();
    final sent = <Map<String, Object?>>[];
    socket.local.stream.listen((message) {
      if (message is String) {
        sent.add((jsonDecode(message) as Map).cast<String, Object?>());
      }
    });
    window.onAudioStart = (command) {
      final handle = command.path!.substring('/calls/'.length);
      unawaited(calls.tunnel(handle, socket.foreign));
      socket.local.sink.add(jsonEncode({'type': 'started', 'latencyMs': 40}));
      calls.report(CallReport(id: command.id));
    };
    await audio.start();
    expect(audio.outputLatency, const Duration(milliseconds: 40));

    // The microphone's frames come in as they are.
    final frames = <Uint8List>[];
    final capturing = audio.captureFrames.listen(frames.add);
    audio.setCaptureEnabled(true);
    socket.local.sink.add(Uint8List.fromList(List<int>.filled(1920, 1)));
    await window.until(() => frames.isNotEmpty);
    expect(frames.single.length, 1920);

    // The voice's speech goes out with its item, in base64.
    audio.enqueue(
      responseId: 'resp_1',
      itemId: 'item_1',
      contentIndex: 0,
      pcm: Uint8List.fromList([1, 0, 255, 255]),
    );
    audio.endResponse('resp_1');
    await window.until(() => sent.any((m) => m['type'] == 'end'));
    final enqueue = sent.firstWhere((m) => m['type'] == 'enqueue');
    expect(enqueue['itemId'], 'item_1');
    expect(base64.decode(enqueue['pcm']! as String), [1, 0, 255, 255]);
    expect(
      sent.any((m) => m['type'] == 'capture' && m['enabled'] == true),
      isTrue,
    );

    // Reports, and a clear that says what was heard.
    final reports = <RealtimePlaybackReport>[];
    final reporting = audio.reports.listen(reports.add);
    socket.local.sink.add(
      jsonEncode({
        'type': 'report',
        'clearId': 0,
        'playbackActive': true,
        'queuedSamples': 2,
        'receivedSamples': 2,
        'inputLevel': 0.5,
        'outputLevel': 0.25,
      }),
    );
    await window.until(() => reports.isNotEmpty);
    expect(reports.single.queuedSamples, 2);
    expect(reports.single.outputLevel, 0.25);
    final clearing = audio.clear(3);
    await window.until(() => sent.any((m) => m['type'] == 'clear'));
    socket.local.sink.add(
      jsonEncode({
        'type': 'cleared',
        'clearId': 3,
        'items': [
          {
            'responseId': 'resp_1',
            'itemId': 'item_1',
            'contentIndex': 0,
            'samples': 1,
          },
        ],
      }),
    );
    final heard = await clearing;
    expect(heard.single.itemId, 'item_1');
    expect(heard.single.samples, 1);

    await audio.stop();
    expect(sent.last['type'], 'stop');
    await window.until(
      () => window.commands.any((c) => c.kind == CallCommandKind.audioStop),
    );
    await capturing.cancel();
    await reporting.cancel();
  });

  /// The window's side of a GPT-Live call's peer: [onStart] answers
  /// `webRtcStart` and connects [socket]; what the daemon sends is [sent].
  /// [sentType] is the first message of a type the daemon sent, once it
  /// has (a milestone, not a poll).
  ({
    StreamChannelController<dynamic> socket,
    List<Map<String, Object?>> sent,
    Future<Map<String, Object?>> Function(String type) sentType,
  })
  peerWindow() {
    final socket = StreamChannelController<dynamic>();
    final sent = <Map<String, Object?>>[];
    final arrivals = StreamController<Map<String, Object?>>.broadcast();
    socket.local.stream.listen((message) {
      if (message is String) {
        final decoded = (jsonDecode(message) as Map).cast<String, Object?>();
        sent.add(decoded);
        arrivals.add(decoded);
      }
    });
    Future<Map<String, Object?>> sentType(String type) async {
      for (final m in sent) {
        if (m['type'] == type) return m;
      }
      return arrivals.stream.firstWhere((m) => m['type'] == type);
    }

    window.onWebRtcStart = (command) {
      final handle = command.path!.substring('/calls/'.length);
      unawaited(calls.tunnel(handle, socket.foreign));
      calls.report(CallReport(id: command.id));
      socket.local.sink.add(jsonEncode({'type': 'ready'}));
    };
    return (socket: socket, sent: sent, sentType: sentType);
  }

  test(
    'a GPT-Live call\'s WebRTC peer runs over the window\'s socket',
    () async {
      final peer = runtime.calls.newWebRtcMedia()!;
      final (:socket, :sent, :sentType) = peerWindow();

      // The offer is made in the window, with the voice's data channel, and
      // comes back exactly as the page wrote it.
      final offering = peer.createOffer();
      expect((await sentType('offer'))['dataChannel'], 'oai-events');
      socket.local.sink.add(
        jsonEncode({'type': 'offer', 'sdp': 'v=0\r\noffer\r\n'}),
      );
      expect(await offering, 'v=0\r\noffer\r\n');

      final accepting = peer.acceptAnswer('v=0\r\nanswer\r\n');
      expect((await sentType('answer'))['sdp'], 'v=0\r\nanswer\r\n');
      socket.local.sink.add(jsonEncode({'type': 'answered'}));
      await accepting;

      // The data channel both ways, the connection's state, the meter.
      final message = peer.messages.first;
      final state = peer.states.first;
      final level = peer.levels.first;
      socket.local.sink
        ..add(jsonEncode({'type': 'state', 'state': 'connected'}))
        ..add(
          jsonEncode({
            'type': 'message',
            'text': jsonEncode({'type': 'session.started'}),
          }),
        )
        ..add(jsonEncode({'type': 'levels', 'input': 0.4, 'output': 3}));
      expect(jsonDecode(await message), {'type': 'session.started'});
      expect(await state, RealtimeMediaState.connected);
      expect(await level, (input: 0.4, output: 1.0));
      peer
        ..send(jsonEncode({'type': 'session.close'}))
        ..setMicrophoneEnabled(false);
      expect(jsonDecode((await sentType('send'))['text']! as String), {
        'type': 'session.close',
      });
      expect((await sentType('mic'))['enabled'], isFalse);

      // A closed connection is the call's failure.
      final failed = peer.states.first;
      socket.local.sink.add(jsonEncode({'type': 'state', 'state': 'failed'}));
      expect(await failed, RealtimeMediaState.failed);

      await peer.close();
      expect(sent.last['type'], 'stop');
      // The window hears audioStop for the peer's path (a microtask away).
      await pumpEventQueue();
      final started = window.commands.lastWhere(
        (c) => c.kind == CallCommandKind.webRtcStart,
      );
      expect(
        window.commands.any(
          (c) => c.kind == CallCommandKind.audioStop && c.path == started.path,
        ),
        isTrue,
      );
    },
  );

  test('closing a call ends every wait of its peer: an unanswered start, '
      'a page that never said ready, and the window\'s socket', () async {
    // The window never answers webRtcStart.
    window.onWebRtcStart = (_) {};
    final unanswered = runtime.calls.newWebRtcMedia()!;
    Object? first;
    final offering = unanswered.createOffer().then<Object?>(
      (_) => null,
      onError: (Object e) => first = e,
    );
    await pumpEventQueue();
    await unanswered.close();
    await pumpEventQueue();
    expect(first, isA<StateError>(), reason: 'the start waited past close');
    await offering;

    // The window answers and connects its socket, but its page never says
    // ready (and its socket stays open).
    final socket = StreamChannelController<dynamic>();
    // The page's side reads what the daemon sends (and its close).
    socket.local.stream.listen((_) {});
    Future<void>? tunnelled;
    window.onWebRtcStart = (command) {
      final handle = command.path!.substring('/calls/'.length);
      tunnelled = calls.tunnel(handle, socket.foreign);
      calls.report(CallReport(id: command.id));
    };
    final silent = runtime.calls.newWebRtcMedia()!;
    Object? second;
    final waiting = silent.createOffer().then<Object?>(
      (_) => null,
      onError: (Object e) => second = e,
    );
    await pumpEventQueue();
    expect(tunnelled, isNotNull);
    var ended = false;
    unawaited(tunnelled!.whenComplete(() => ended = true));
    await silent.close();
    await pumpEventQueue();
    expect(second, isA<StateError>(), reason: 'ready was waited past close');
    expect(ended, isTrue, reason: 'the socket was waited on past close');
    await waiting;
  });

  test('a microphone the peer cannot open fails the offer plainly', () async {
    final peer = runtime.calls.newWebRtcMedia()!;
    final (:socket, sent: _, :sentType) = peerWindow();
    final offering = peer.createOffer();
    await sentType('offer');
    socket.local.sink.add(
      jsonEncode({
        'type': 'failure',
        'reason': 'microphone',
        'message': 'NotAllowedError',
      }),
    );
    await expectLater(
      offering,
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'The microphone could not be opened.',
        ),
      ),
    );
    await peer.close();
  });

  test('a window without a peer refuses it, and nothing is offered', () async {
    final peer = runtime.calls.newWebRtcMedia()!;
    await expectLater(peer.createOffer(), throwsA(isA<Exception>()));
    await peer.close();
  });

  test('a second call is refused while one is on', () async {
    await calls.start(CallStart(model: model));
    await window.until(() => window.listens.isNotEmpty);
    await expectLater(
      calls.start(CallStart(model: model)),
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.conflict,
        ),
      ),
    );
  });
}
