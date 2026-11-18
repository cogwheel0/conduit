@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show
        ComposerTextInsertion,
        chatComposerTextInsertionTargetId,
        composerTextInsertionProvider;
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart'
    show hermesCapabilitiesProvider, hermesConfigProvider;
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart'
    show
        activeServerProvider,
        optimizedStorageServiceProvider,
        selectedModelProvider,
        serverConfigsProvider;
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

import 'support/fake_hermes_server.dart';
import 'support/null_sink.dart';
import 'support/window.dart';

/// Hermes Agent, against a fake of its API server: the connection,
/// a conversation in a session, an approval, and sessions. Its jobs,
/// catalog and connections are `hermes_admin_test.dart`'s.
void main() {
  late Directory temporary;
  late CoreRuntime runtime;
  late FakeHermesServer hermesServer;
  late HermesService hermes;
  var connected = false;

  /// Hermes saved as the connection in use, as the first test leaves it: a
  /// test that runs alone saves it itself.
  Future<void> connect() async {
    if (connected) return;
    hermes = HermesService(runtime.container, events: EventBus());
    await hermes.saveSettings(
      HermesSettingsEdit(
        baseUrl: hermesServer.baseUrl,
        apiKey: hermesServer.key,
      ),
    );
    connected = true;
  }

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
    final changed = <HermesChanged>[];
    events.attach('window', (envelope) {
      if (envelope.event == ConduitEvents.hermesChanged) {
        changed.add(HermesChanged.fromJson(envelope.payload));
      }
    });
    hermes = HermesService(runtime.container, events: events);
    final before = (await hermes.status()).connection;

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
    connected = true;
    expect(settings.enabled, isTrue);
    expect(settings.usable, isTrue);
    expect(settings.hasApiKey, isTrue);
    // The key itself never comes back.
    expect(jsonEncode(settings.toJson()), isNot(contains(hermesServer.key)));

    final status = await hermes.status();
    expect(status.reachable, isTrue);
    // Another connection has another name, and hermes.changed says it.
    expect(status.connection, allOf(isNotNull, isNot(before)));
    expect(changed.last.connection, status.connection);
    expect(status.capabilities.jobs, isTrue);
    expect(status.capabilities.runApproval, isTrue);

    // A sign-in asked for another connection than the one in use is
    // refused.
    await expectLater(
      hermes.signIn(
        HermesSignInRequest(connection: '${status.connection}-before'),
      ),
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.sessionExpired,
        ),
      ),
    );
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
    subscribeWindow(events, turns, 'window', <String>[first.chatId]);
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
    // Read Aloud reads its answers from the same record.
    final answer = detail.messages.lastWhere((m) => m.role == 'assistant');
    expect(
      (await chats.answerFor(first.chatId, answer.id)).content,
      answer.content,
    );

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

  test('sessions are pinned, archived, hidden, branched and continued from '
      'another Hermes app', () async {
    final events = EventBus();
    final turns = TurnsService(runtime.container, events, hermes: hermes);
    addTearDown(turns.dispose);
    final chats = ChatsService(
      runtime.container,
      events: events,
      hermes: hermes,
    );
    addTearDown(chats.dispose);
    final own = hermesServer.seedForeign(
      title: 'Pond plants',
      source: 'api_server',
      turns: <(String, String)>[
        ('Which plants suit a small pond?', 'Water lilies and irises.'),
        ('And for the edges?', 'Marsh marigolds.'),
      ],
    );
    final cli = hermesServer.seedForeign(
      title: 'Shed shelves',
      turns: <(String, String)>[
        ('How deep should shed shelves be?', 'About 30 cm.'),
      ],
    );

    var listed = await hermes.sessions();
    expect(listed.sessions.map((s) => s.id), containsAll(<String>[own, cli]));
    expect(listed.sessions.firstWhere((s) => s.id == cli).source, 'cli');
    expect(listed.archivedFailed, isFalse);

    // Pinned first; archived into its own row, unpinned; hidden from
    // both, and back.
    listed = await hermes.update(HermesSessionUpdate(id: own, pinned: true));
    expect(listed.sessions.first.id, own);
    expect(listed.sessions.first.pinned, isTrue);
    listed = await hermes.update(HermesSessionUpdate(id: own, archived: true));
    expect(listed.sessions.map((s) => s.id), isNot(contains(own)));
    expect(listed.archived.single.id, own);
    expect(listed.archived.single.pinned, isFalse);
    listed = await hermes.update(HermesSessionUpdate(id: own, archived: false));
    expect(listed.archived, isEmpty);
    listed = await hermes.update(HermesSessionUpdate(id: own, hidden: true));
    expect(listed.sessions.map((s) => s.id), isNot(contains(own)));
    final hidden = await hermes.hidden();
    expect(hidden.sessions.single.id, own);
    expect(hidden.sessions.single.hidden, isTrue);
    listed = await hermes.update(HermesSessionUpdate(id: own, hidden: false));
    expect(listed.sessions.map((s) => s.id), contains(own));
    expect((await hermes.hidden()).sessions, isEmpty);

    // This app's session can be branched from a reply; not undone on the
    // API server, which keeps no transcript to rewind.
    final ownDetail = await chats.get(hermesChatId(own));
    expect(ownDetail!.hermes!.readOnly, isFalse);
    expect(ownDetail.abilities.branchFromHere, isTrue);
    expect(ownDetail.abilities.undoLastTurn, isFalse);
    final firstReply = ownDetail.messages[1];
    final branch = await turns.branchHermes(
      HermesBranch(chatId: hermesChatId(own), messageId: firstReply.id),
    );
    expect(branch.id, isNot(own));
    final branched = await chats.get(branch.chatId);
    expect(branched!.messages.map((m) => m.content), <String>[
      'Which plants suit a small pond?',
      'Water lilies and irises.',
    ]);
    expect(
      (await turns.undoHermes(ChatRef(id: hermesChatId(own)))).ok,
      isFalse,
    );

    // Another app's session opens read-only, then goes on in a copy that
    // keeps its messages here, or through Hermes's fork.
    final detail = await chats.get(hermesChatId(cli));
    expect(detail!.hermes!.readOnly, isTrue);
    expect(detail.hermes!.owner, 'Hermes CLI');
    expect(detail.abilities.branchFromHere, isFalse);
    // Refused by conduitd too, not only left out of its menus.
    final readOnly = throwsA(
      isA<RpcError>().having(
        (e) => e.code,
        'code',
        ConduitErrorCodes.unsupported,
      ),
    );
    await expectLater(
      turns.branchHermes(
        HermesBranch(
          chatId: hermesChatId(cli),
          messageId: detail.messages[1].id,
        ),
      ),
      readOnly,
    );
    await expectLater(
      turns.undoHermes(ChatRef(id: hermesChatId(cli))),
      readOnly,
    );
    final copy = await hermes.continueChat(
      HermesContinue(chatId: hermesChatId(cli), copy: true),
    );
    expect(copy.id, isNot(cli));
    expect(copy.title, 'Shed shelves');
    final copied = await chats.get(copy.chatId);
    expect(copied!.hermes!.readOnly, isFalse);
    expect(copied.messages.map((m) => m.content), <String>[
      'How deep should shed shelves be?',
      'About 30 cm.',
    ]);
    final here = await hermes.continueChat(
      HermesContinue(chatId: hermesChatId(cli)),
    );
    expect(hermesServer.sessions[here.id]!['source'], 'api_server');

    for (final id in <String>[own, cli, branch.id, copy.id, here.id]) {
      await hermes.delete(id);
    }
  });

  test('scheduled runs leave the lists while Show Scheduled Runs is off, '
      'and the lists say how many', () async {
    await connect();
    final events = EventBus();
    final announced = <String>[];
    events.attach('test', (envelope) => announced.add(envelope.event));
    final watching = HermesService(runtime.container, events: events);
    addTearDown(watching.dispose);
    final settings = CoreSettingsService(runtime.container);
    final shown = settings.get().hermesShowScheduledSessions;
    addTearDown(
      () => settings.set(AppSettingsPatch(hermesShowScheduledSessions: shown)),
    );
    final run = hermesServer.seedForeign(
      title: 'Morning brief',
      source: 'cron',
    );
    addTearDown(() => hermes.delete(run));
    final kept = hermesServer.seedForeign(title: 'Tide tables');
    addTearDown(() => hermes.delete(kept));
    await settings.set(
      const AppSettingsPatch(hermesShowScheduledSessions: true),
    );

    var listed = await hermes.sessions();
    expect(listed.sessions.map((s) => s.id), containsAll(<String>[run, kept]));
    expect(listed.hiddenScheduledRuns, 0);

    await settings.set(
      const AppSettingsPatch(hermesShowScheduledSessions: false),
    );
    expect(settings.get().hermesShowScheduledSessions, isFalse);
    // The windows read the lists again.
    expect(announced, contains(ConduitEvents.hermesChanged));
    listed = await hermes.sessions();
    expect(listed.sessions.map((s) => s.id), contains(kept));
    expect(listed.sessions.map((s) => s.id), isNot(contains(run)));
    expect(listed.hiddenScheduledRuns, 1);

    // A run the user pinned stays.
    listed = await hermes.update(HermesSessionUpdate(id: run, pinned: true));
    expect(listed.sessions.first.id, run);
    expect(listed.hiddenScheduledRuns, 0);
  });

  test("Hermes' prefill goes to its chat's windows; words given back "
      'after a kept model stay in the chat, and the picker stays', () async {
    await connect();
    final events = EventBus();
    final given = <ComposerInsertText>[];
    final prefilled = Completer<ComposerInsertText>();
    events.tap((event, scope, payload) {
      if (event != ConduitEvents.composerInsertText) return;
      final text = ComposerInsertText.fromJson(payload);
      given.add(text);
      if (!prefilled.isCompleted) prefilled.complete(text);
    });
    final turns = TurnsService(runtime.container, events, hermes: hermes);
    addTearDown(turns.dispose);
    final id = hermesServer.seedForeign(
      title: 'Seed list',
      source: 'api_server',
      turns: <(String, String)>[('Which seeds first?', 'Peas.')],
    );
    addTearDown(() => hermes.delete(id));
    final chatId = hermesChatId(id);
    final scope = await turns.holdScope(chatId);
    addTearDown(() => turns.releaseScope(chatId));
    final picked = runtime.container.read(selectedModelProvider);
    addTearDown(() {
      if (picked != null) {
        runtime.container
            .read(selectedModelProvider.notifier)
            .set(picked, allowHidden: true);
      }
    });
    // The session's questions are this chat's.
    expect(turns.hermesChatOf(id), chatId);
    expect(turns.hermesChatOf('$id-other'), isNull);

    final takenBack = Completer<void>();
    scope.listen<ComposerTextInsertion?>(composerTextInsertionProvider, (
      before,
      now,
    ) {
      if (before != null && now == null && !takenBack.isCompleted) {
        takenBack.complete();
      }
    });
    final insertion = scope.read(composerTextInsertionProvider.notifier);
    insertion.insert(
      targetId: chatComposerTextInsertionTargetId,
      text: 'Plant the peas in March?',
      onlyIntoEmpty: true,
    );
    await takenBack.future;
    // The chat kept its model: core puts the chat back on it, and the
    // account's picker is left as it is.
    const kept = Model(id: 'hermes:demo-model', name: 'demo-model');
    scope.read(selectedModelProvider.notifier).set(kept, allowHidden: true);
    expect(runtime.container.read(selectedModelProvider)?.id, picked?.id);

    insertion.insert(
      targetId: chatComposerTextInsertionTargetId,
      text: '/plan ',
    );
    final sent = await prefilled.future;
    expect(sent, ComposerInsertText(chatId: chatId, text: '/plan '));
    expect(given, hasLength(1), reason: 'the kept words reached a window');
    // Never the app-wide composer's.
    expect(runtime.container.read(composerTextInsertionProvider), isNull);
  });

  test('a transcript whose rows have no ids keeps the names a window '
      'was given', () async {
    final events = EventBus();
    final turns = TurnsService(runtime.container, events, hermes: hermes);
    addTearDown(turns.dispose);
    final chats = ChatsService(
      runtime.container,
      events: events,
      hermes: hermes,
    );
    addTearDown(chats.dispose);
    final id = hermesServer.seedForeign(
      title: 'Kite knots',
      source: 'api_server',
      rowIds: false,
      turns: <(String, String)>[
        ('Which knot ties a kite line?', 'A bowline holds well.'),
        ('And to join two lines?', 'A double fisherman.'),
      ],
    );
    await hermes.sessions();
    final first = await chats.get(hermesChatId(id));
    // Read again, as a turn's end makes it read.
    hermes.forget(id);
    final again = await chats.get(hermesChatId(id));
    expect(again!.messages.map((m) => m.id), first!.messages.map((m) => m.id));
    // The chat's scope opens from a fresh read and still finds the reply
    // the window names.
    final branch = await turns.branchHermes(
      HermesBranch(chatId: hermesChatId(id), messageId: first.messages[1].id),
    );
    final branched = await chats.get(branch.chatId);
    expect(branched!.messages.map((m) => m.content), <String>[
      'Which knot ties a kite line?',
      'A bowline holds well.',
    ]);
    await hermes.delete(branch.id);
    await hermes.delete(id);
  });

  test('a chat read again keeps its names turn by turn, for Retry', () {
    ChatMessage message(String id, String role, String text, {String? error}) =>
        ChatMessage(
          id: id,
          role: role,
          content: text,
          timestamp: DateTime.utc(2026, 11, 11),
          error: error == null ? null : ChatMessageError(content: error),
        );
    // The chat's scope: one answer a turn, the last one a live failure.
    final scope = <ChatMessage>[
      message('q1', 'user', 'Make a plan for the picnic'),
      message('a1', 'assistant', 'The plan is drafted.'),
      message('q2', 'user', 'Book the ferry'),
      message('a2', 'assistant', '', error: 'Rate limit exceeded'),
    ];
    // Hermes' record: a row a tool step, and the row it closes a failed
    // turn with (its own notice).
    final read = <ChatMessage>[
      message('r1', 'user', 'Make a plan for the picnic'),
      message('r2', 'assistant', ''),
      message('r3', 'assistant', ''),
      message('r4', 'assistant', 'The plan is drafted.'),
      message('r5', 'user', 'Book the ferry'),
      message(
        'r6',
        'assistant',
        'The provider is rate limiting requests.',
        error: 'Rate limit exceeded',
      ),
    ];
    // The questions and answers keep the scope's names; the steps, the
    // last read's.
    final earlier = <ChatMessage>[
      message('q1', 'user', 'Make a plan for the picnic'),
      message('s1', 'assistant', ''),
      message('s2', 'assistant', ''),
      message('a1', 'assistant', 'The plan is drafted.'),
    ];
    expect(
      HermesService.keepIds(read, scope, earlier: earlier).map((m) => m.id),
      <String>['q1', 's1', 's2', 'a1', 'q2', 'a2'],
    );
    // Read again with nothing new: the same names.
    final named = HermesService.keepIds(read, scope, earlier: earlier);
    expect(
      HermesService.keepIds(read, named).map((m) => m.id),
      named.map((m) => m.id),
    );
    // Where a question differs, the turns no longer line up.
    final edited = <ChatMessage>[
      ...read.take(4),
      message('r5', 'user', 'Book the train'),
      read[5],
    ];
    expect(
      HermesService.keepIds(edited, scope).map((m) => m.id).skip(4),
      <String>['r5', 'r6'],
    );
  });

  test('a desktop gateway that signs in natively waits for it', () async {
    addTearDown(
      () => hermes.saveSettings(
        HermesSettingsEdit(
          baseUrl: hermesServer.baseUrl,
          apiKey: hermesServer.key,
        ),
      ),
    );
    final saved = await hermes.saveSettings(
      HermesSettingsEdit(
        baseUrl: hermesServer.baseUrl,
        mode: 'desktop',
        desktopAuthKind: 'nativePkce',
      ),
    );
    expect(saved.desktopSignedIn, isFalse);
    // Kept on the form with its sign-in button, rather than sent on to a
    // chat that cannot answer.
    expect(saved.usable, isFalse);

    // And a message sent anyway is refused as a sign-in, not a connection.
    final events = EventBus();
    final turns = TurnsService(runtime.container, events, hermes: hermes);
    addTearDown(turns.dispose);
    final models = ModelsService(runtime.container);
    ModelSummary? agent;
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (agent == null && DateTime.now().isBefore(deadline)) {
      agent = (await models.list()).models
          .where((m) => m.id.startsWith('hermes:'))
          .firstOrNull;
      if (agent == null) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    expect(agent, isNotNull);
    await expectLater(
      turns.send(SendTurn(model: agent!.id, text: 'hello')),
      throwsA(
        isA<RpcError>()
            .having((e) => e.code, 'code', ConduitErrorCodes.unauthenticated)
            .having((e) => e.args['backend'], 'backend', 'hermes'),
      ),
    );
  });

  // The gateway's sign-in belongs to the saved address: Test on another
  // one must not send it there.
  test('testing another server does not send the saved sign-in', () async {
    addTearDown(() async {
      await runtime.container
          .read(hermesConfigProvider.notifier)
          .signOutDesktop();
      await hermes.saveSettings(
        HermesSettingsEdit(
          baseUrl: hermesServer.baseUrl,
          apiKey: hermesServer.key,
        ),
      );
    });
    const gateway = HermesSettingsEdit(
      baseUrl: '',
      mode: 'desktop',
      desktopAuthKind: 'nativePkce',
    );
    await hermes.saveSettings(gateway.copyWith(baseUrl: hermesServer.baseUrl));
    await runtime.container
        .read(hermesConfigProvider.notifier)
        .nativeCredentialsWriter()(
      HermesDesktopCredentials(
        nativeTokens: HermesDesktopTokenSet(
          accessToken: 'native-access-secret',
          refreshToken: 'native-refresh-secret',
          expiresAt: DateTime.now().add(const Duration(hours: 1)),
        ),
      ),
    );

    final sent = <String>[];
    final elsewhere = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => elsewhere.close(force: true));
    elsewhere.listen((request) async {
      request.headers.forEach(
        (name, values) => sent.add('$name: ${values.join(',')}'),
      );
      await request.drain<void>();
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    });

    await hermes.test(
      gateway.copyWith(baseUrl: 'http://127.0.0.1:${elsewhere.port}'),
    );
    expect(sent, isNotEmpty, reason: 'the other server was asked');
    expect(sent.join('\n'), isNot(contains('native-')));
  });

  // A token typed with another server's address is that server's alone:
  // the saved sign-in and access headers stay with the old one.
  test(
    'a token saved with another address takes no old sign-in there',
    () async {
      final config = runtime.container.read(hermesConfigProvider.notifier);
      addTearDown(() async {
        await config.signOutDesktop();
        await hermes.saveSettings(
          HermesSettingsEdit(
            baseUrl: hermesServer.baseUrl,
            apiKey: hermesServer.key,
          ),
        );
      });
      await config.saveConnection(
        baseUrl: hermesServer.baseUrl,
        mode: HermesBackendMode.desktopGateway,
        desktopAuthKind: HermesDesktopAuthKind.nativePkce,
        desktopCredentialsChanged: true,
        desktopCredentials: HermesDesktopCredentials(
          nativeTokens: HermesDesktopTokenSet(
            accessToken: 'native-access-secret',
            refreshToken: 'native-refresh-secret',
            expiresAt: DateTime.now().add(const Duration(hours: 1)),
          ),
          accessHeaders: const {'X-Gate': 'gate-secret'},
        ),
      );
      final elsewhere = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => elsewhere.close(force: true));

      await hermes.saveSettings(
        HermesSettingsEdit(
          baseUrl: 'http://127.0.0.1:${elsewhere.port}',
          mode: 'desktop',
          desktopAuthKind: 'legacyToken',
          legacyToken: 'new-token',
        ),
      );
      final saved = runtime.container.read(hermesConfigProvider);
      expect(saved.desktopCredentials?.legacyToken, 'new-token');
      expect(saved.desktopCredentials?.nativeTokens, isNull);
      expect(saved.desktopCredentials?.accessHeaders ?? const {}, isEmpty);
    },
  );

  // A session one server listed is that server's: after a switch to
  // another, a session there with the same id is read as that server says,
  // never with the flags the first one gave it.
  test('another server is not told of the last one\'s sessions', () async {
    final other = await FakeHermesServer.start(key: 'other-key');
    final shed = hermesServer.seedForeign(title: 'Shed roof');
    other.sessions[shed] = <String, dynamic>{
      'id': shed,
      'title': 'Barn door',
      'source': 'api_server',
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    other.messages[shed] = <Map<String, dynamic>>[];
    addTearDown(() async {
      hermesServer.sessions.remove(shed);
      await hermes.saveSettings(
        HermesSettingsEdit(
          baseUrl: hermesServer.baseUrl,
          apiKey: hermesServer.key,
        ),
      );
      await other.close();
    });
    final listed = await hermes.sessions();
    expect(listed.sessions.firstWhere((s) => s.id == shed).source, 'cli');

    hermesServer.messages[shed] = <Map<String, dynamic>>[
      <String, dynamic>{'id': 'm-shed', 'role': 'user', 'content': 'Shed roof'},
    ];
    other.messages[shed] = <Map<String, dynamic>>[
      <String, dynamic>{'id': 'm-barn', 'role': 'user', 'content': 'Barn door'},
    ];
    // Read on the first server, so its words are kept for the chat.
    expect((await hermes.transcript(shed)).single.content, 'Shed roof');

    await hermes.saveSettings(
      HermesSettingsEdit(baseUrl: other.baseUrl, apiKey: other.key),
    );
    expect(
      (await hermes.transcript(shed)).single.content,
      'Barn door',
      reason: 'the first server\'s transcript was shown for this one',
    );
    expect(
      hermes.chatState(shed).readOnly,
      isFalse,
      reason: 'the first server\'s "Hermes CLI" made it read-only here',
    );

    // A read begun on this server and still out at the switch back ends
    // in an error (refused, or its client closed), and keeps nothing for
    // the first server's chat.
    other
      ..messagesAsked = Completer<void>()
      ..holdMessages = Completer<void>();
    final late = expectLater(
      hermes.transcript(shed, reload: true),
      throwsA(isA<RpcError>()),
    );
    // Asked of this server before the switch back.
    await other.messagesAsked.future;
    await hermes.saveSettings(
      HermesSettingsEdit(
        baseUrl: hermesServer.baseUrl,
        apiKey: hermesServer.key,
      ),
    );
    other.holdMessages!.complete();
    await late;
    expect(
      (await hermes.transcript(shed)).single.content,
      'Shed roof',
      reason: 'the other server\'s late read was kept for this one',
    );

    // A read whose read-only check is still finding out what this server
    // can do when the account's server changes: it is refused, and nothing
    // of it is marked or kept.
    await hermes.sessions();
    // What it can do is asked again by the read below.
    runtime.container.invalidate(hermesCapabilitiesProvider);
    // The account's server changes while it is asked.
    final storage = runtime.container.read(optimizedStorageServiceProvider);
    addTearDown(() async {
      await storage.setActiveServerId(null);
      await storage.saveServerConfigs(const <ServerConfig>[]);
      runtime.container
        ..invalidate(serverConfigsProvider)
        ..invalidate(activeServerProvider);
    });
    hermesServer.onCapabilities = () async {
      await storage.saveServerConfigs(const <ServerConfig>[
        ServerConfig(
          id: 'second-server',
          name: 'Second server',
          url: 'https://second.invalid',
        ),
      ]);
      await storage.setActiveServerId('second-server');
      runtime.container
        ..invalidate(serverConfigsProvider)
        ..invalidate(activeServerProvider);
      await runtime.container.read(activeServerProvider.future);
    };
    await expectLater(
      hermes.transcript(shed, reload: true),
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.sessionExpired,
        ),
      ),
    );
  });

  // A Desktop Gateway keeps no copied messages for a session it did not
  // write: a copy there would open empty, so none is made.
  test('a gateway makes no copy it cannot give the messages to', () async {
    final pond = hermesServer.seedForeign(
      title: 'Pond pump',
      turns: <(String, String)>[('Which pump size?', 'About 2000 l/h.')],
    );
    addTearDown(() async {
      hermesServer.sessions.remove(pond);
      await hermes.saveSettings(
        HermesSettingsEdit(
          baseUrl: hermesServer.baseUrl,
          apiKey: hermesServer.key,
        ),
      );
    });
    await hermes.saveSettings(
      HermesSettingsEdit(
        baseUrl: hermesServer.baseUrl,
        mode: 'desktop',
        desktopAuthKind: 'legacyToken',
        legacyToken: 'gateway-token',
      ),
    );
    final before = hermesServer.sessions.length;
    await expectLater(
      hermes.continueChat(
        HermesContinue(chatId: hermesChatId(pond), copy: true),
      ),
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.unsupported,
        ),
      ),
    );
    expect(hermesServer.sessions.length, before);
  });

  test('chosen in onboarding, Hermes is the backend the app is used through, '
      'once it can answer', () async {
    final apiKey = HermesSettingsEdit(
      baseUrl: hermesServer.baseUrl,
      apiKey: hermesServer.key,
    );
    // Saved from settings, Hermes joins whatever the app is used through;
    // with no account here that is nothing yet, so the chooser shows.
    await hermes.saveSettings(apiKey);
    expect(await runtime.needsOnboarding(), isTrue);

    // Chosen in onboarding, a gateway that still has to sign in keeps
    // onboarding open on its form rather than opening a chat it cannot
    // answer in.
    var saved = await hermes.saveSettings(
      HermesSettingsEdit(
        baseUrl: hermesServer.baseUrl,
        mode: 'desktop',
        desktopAuthKind: 'nativePkce',
        onboarding: true,
      ),
    );
    expect(saved.usable, isFalse);
    expect(await runtime.needsOnboarding(), isTrue);

    // Chosen and able to answer: the chat, as after the phone's "Finish
    // setup", and so after every launch.
    saved = await hermes.saveSettings(apiKey.copyWith(onboarding: true));
    expect(saved.usable, isTrue);
    expect(await runtime.needsOnboarding(), isFalse);
  });
}
