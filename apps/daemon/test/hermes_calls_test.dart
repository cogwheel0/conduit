@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

import 'support/call_window.dart';
import 'support/fake_hermes_server.dart';
import 'support/null_sink.dart';

/// A voice call in a Hermes chat, as the phone allows one: the core admits
/// a Hermes model while its connection is usable (`composer.options`
/// `voiceCall`, which the call button follows), and the call is a Standard
/// one: what was said goes to the chat's Hermes session as a turn, and the
/// answer is said.
void main() {
  late Directory temporary;
  late CoreRuntime runtime;
  late FakeHermesServer hermesServer;
  late EventBus events;
  late HermesService hermes;
  late TurnsService turns;
  late SpeechService speech;
  late CallsService calls;

  setUpAll(() async {
    temporary = Directory.systemTemp.createTempSync('hermes-calls-test');
    runtime = await CoreRuntime.start(
      config: BootstrapConfig(
        sessionToken: 'a' * 43,
        masterKey: base64.encode(List<int>.generate(32, (i) => i)),
        userDataDir: temporary.path,
      ),
      directories: DaemonDirectories.create(temporary.path),
      log: DaemonLog(level: 'error', sink: NullSink()),
    );
    hermesServer = await FakeHermesServer.start();
    events = EventBus();
    hermes = HermesService(runtime.container, events: events);
    turns = TurnsService(
      runtime.container,
      events,
      uiRequests: UiRequestsService(events),
      hermes: hermes,
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
  });

  tearDownAll(() async {
    await calls.dispose();
    await speech.dispose();
    await turns.dispose();
    await hermesServer.close();
    await runtime.dispose();
    temporary.deleteSync(recursive: true);
  });

  test('a Standard call in a Hermes chat goes to its session', () async {
    await hermes.saveSettings(
      HermesSettingsEdit(
        baseUrl: hermesServer.baseUrl,
        apiKey: hermesServer.key,
      ),
    );
    final models = ModelsService(runtime.container);
    ModelSummary? agent;
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (agent == null && DateTime.now().isBefore(deadline)) {
      agent = (await models.list()).models
          .where((m) => m.id.startsWith('hermes:agent:'))
          .firstOrNull;
      if (agent == null) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    expect(agent, isNotNull);
    await models.select(agent!.id);

    // The core admits a call with the Hermes model.
    final composer = ComposerService(runtime.container);
    expect((await composer.options()).voiceCall, isTrue);

    // A Hermes chat.
    final finished = <TurnFinished>[];
    events.attach('probe', (envelope) {
      if (envelope.event == ConduitEvents.turnFinished) {
        finished.add(TurnFinished.fromJson(envelope.payload));
      }
    });
    addTearDown(() => events.detach('probe'));
    final first = await turns.send(
      SendTurn(text: 'Hello Hermes', model: agent.id),
    );
    final chatId = first.chatId;
    expect(chatId, startsWith('local:hermes_'));
    final sessionId = chatId.substring('local:hermes_'.length);
    await _until(() => finished.isNotEmpty);

    // A call in it: Standard (this Hermes has no realtime voice), its
    // words to the session, its answer said.
    final window = CallWindow(events, calls, speech);
    addTearDown(() => events.detach('window'));
    await calls.start(CallStart(chatId: chatId, model: agent.id));
    await window.until(() => window.listens.isNotEmpty);
    await window.until(() => window.last?.phase == CallPhase.listening);
    expect(window.last!.mode, CallMode.standard);
    expect(window.last!.chatId, chatId);
    window.say(window.listens.single.listen, 'Which way is the tide going');
    await window.until(
      () => window.spoken.join(' ').contains('Which way is the tide going'),
    );
    final asked = hermesServer.runRequests.last;
    expect(asked['session_id'], sessionId);
    expect(jsonEncode(asked), contains('Which way is the tide going'));
    // Said: it listens again.
    await window.until(() => window.listens.length == 2);
    final ended = await calls.end();
    expect(ended.chatId, chatId);

    // Hermes turned off: no call with its model.
    await hermes.saveSettings(
      HermesSettingsEdit(
        enabled: false,
        baseUrl: hermesServer.baseUrl,
        apiKey: hermesServer.key,
      ),
    );
    expect((await composer.options()).voiceCall, isFalse);
  });
}

Future<void> _until(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
