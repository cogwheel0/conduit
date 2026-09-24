@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

import 'support/fake_hermes_server.dart';
import 'support/null_sink.dart';

/// Hermes Agent, against a fake of its API server: the connection,
/// a conversation in a session, an approval, sessions and jobs.
void main() {
  late Directory temporary;
  late CoreRuntime runtime;
  late FakeHermesServer hermesServer;
  late HermesService hermes;

  setUpAll(() async {
    temporary = Directory.systemTemp.createTempSync('hermes-test');
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
  });

  tearDownAll(() async {
    await hermesServer.close();
    await runtime.dispose();
    temporary.deleteSync(recursive: true);
  });

  test('a connection is tested, saved, and reports what it can do', () async {
    final events = EventBus();
    hermes = HermesService(runtime.container, events: events);

    var settings = await hermes.settings();
    expect(settings.enabled, isFalse);
    expect(settings.usable, isFalse);

    final wrongKey = await hermes.test(
      HermesSettingsEdit(baseUrl: hermesServer.baseUrl, apiKey: 'wrong'),
    );
    expect(wrongKey.ok, isFalse);
    final right = HermesSettingsEdit(
      baseUrl: hermesServer.baseUrl,
      apiKey: hermesServer.key,
    );
    expect((await hermes.test(right)).ok, isTrue);

    settings = await hermes.saveSettings(right);
    expect(settings.enabled, isTrue);
    expect(settings.usable, isTrue);
    expect(settings.hasApiKey, isTrue);
    // The key itself never comes back.
    expect(jsonEncode(settings.toJson()), isNot(contains(hermesServer.key)));

    final status = await hermes.status();
    expect(status.reachable, isTrue);
    expect(status.capabilities.jobs, isTrue);
    expect(status.capabilities.runApproval, isTrue);

    final catalog = await hermes.catalog();
    expect(catalog.skills.single.name, 'review');
    expect(catalog.toolsets.single.tools, <String>['search', 'fetch']);
  });

  test('a conversation is a session, answered through turns', () async {
    final events = EventBus();
    final uiRequests = UiRequestsService(events);
    final turns = TurnsService(
      runtime.container,
      events,
      uiRequests: uiRequests,
      hermes: hermes,
    );
    addTearDown(turns.dispose);
    final chats = ChatsService(
      runtime.container,
      events: events,
      hermes: hermes,
    );
    addTearDown(chats.dispose);

    final completed = <TurnCompleted>[];
    final failed = <TurnFailed>[];
    final asked = <UiRequest>[];
    events.attach('window', (envelope) {
      switch (envelope.event) {
        case ConduitEvents.turnCompleted:
          completed.add(TurnCompleted.fromJson(envelope.payload));
        case ConduitEvents.turnFailed:
          failed.add(TurnFailed.fromJson(envelope.payload));
        case ConduitEvents.uiRequest:
          asked.add(UiRequest.fromJson(envelope.payload));
      }
    });

    // The Hermes model is offered once the connection is usable.
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

    // With the agent chosen, the `/` menu is its skills.
    await models.select(agent!.id);
    final prompts = await PromptsService(runtime.container).list();
    expect(prompts.prompts.map((p) => p.command), <String>['/review']);

    Future<void> answered(int count) async {
      final until = DateTime.now().add(const Duration(seconds: 20));
      while (completed.length + failed.length < count &&
          DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }

    final first = await turns.send(
      SendTurn(text: 'Hello Hermes', model: agent.id),
    );
    events.subscribe(
      'window',
      EventSubscription(scopes: <String>[first.chatId]),
    );
    expect(first.chatId, startsWith('local:hermes_sess_'));
    await answered(1);
    expect(failed, isEmpty);
    expect(completed.single.text.trim(), 'Echo: Hello Hermes');
    final sessionId = first.chatId.substring('local:hermes_'.length);
    expect(hermesServer.sessions.keys, contains(sessionId));
    expect(hermesServer.runRequests.single['session_id'], sessionId);

    // The second turn replays what came before it.
    await turns.send(
      SendTurn(text: 'And again', model: agent.id, chatId: first.chatId),
    );
    await answered(2);
    expect(completed.last.text.trim(), 'Echo: And again');
    final history =
        hermesServer.runRequests.last['conversation_history'] as List;
    expect(history.map((m) => (m as Map)['content']), <String>[
      'Hello Hermes',
      'Echo: Hello Hermes',
    ]);

    // An approval, asked of the window and answered back to Hermes.
    final waiting = turns.send(
      SendTurn(
        text: 'Please approve the cleanup',
        model: agent.id,
        chatId: first.chatId,
      ),
    );
    await waiting;
    final until = DateTime.now().add(const Duration(seconds: 10));
    while (asked.isEmpty && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(asked.single.kind, UiRequestKind.hermesDecision);
    expect(asked.single.messageCode, 'hermes.approval');
    uiRequests.respond(
      UiResponse(requestId: asked.single.requestId, choice: 'once'),
    );
    await answered(3);
    expect(completed.last.text.trim(), 'Approved and done.');
    expect(hermesServer.approvals.single['choice'], 'once');

    // Opened again, from Hermes's own record.
    final detail = await chats.get(first.chatId);
    expect(detail, isNotNull);
    expect(detail!.messages.map((m) => m.content).first, 'Hello Hermes');
    expect(detail.messages, hasLength(6));

    // Listed, renamed, forked, deleted.
    var sessions = await hermes.sessions();
    expect(sessions.sessions.single.chatId, first.chatId);
    sessions = await hermes.rename(
      HermesRename(id: sessionId, title: 'Echoes'),
    );
    expect(sessions.sessions.single.title, 'Echoes');
    final fork = await hermes.fork(sessionId);
    expect(fork.id, isNot(sessionId));
    sessions = await hermes.delete(fork.id);
    sessions = await hermes.delete(sessionId);
    expect(sessions.sessions, isEmpty);
  });

  test('scheduled agents are made, paused, run and deleted', () async {
    var jobs = await hermes.saveJob(
      const HermesJobEdit(
        name: 'Morning brief',
        prompt: 'Summarise the news',
        schedule: '0 8 * * *',
      ),
    );
    final job = jobs.jobs.single;
    expect(job.name, 'Morning brief');
    expect(job.enabled, isTrue);
    expect(job.scheduleText, isNotNull);
    jobs = await hermes.setJobEnabled(
      HermesJobToggle(id: job.id, enabled: false),
    );
    expect(jobs.jobs.single.enabled, isFalse);
    jobs = await hermes.saveJob(
      HermesJobEdit(
        id: job.id,
        prompt: 'Summarise the tech news',
        schedule: '0 9 * * *',
      ),
    );
    expect(jobs.jobs.single.prompt, 'Summarise the tech news');
    jobs = await hermes.runJob(job.id);
    expect(jobs.jobs.single.lastStatus, 'ok');
    jobs = await hermes.deleteJob(job.id);
    expect(jobs.jobs, isEmpty);
  });
}
