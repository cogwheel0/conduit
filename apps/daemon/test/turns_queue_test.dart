@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/database/database_provider.dart'
    show appDatabaseProvider, openWebUiCertifiedDatabaseServerProvider;
import 'package:conduit_core/models/chat_comparison.dart';
import 'package:conduit_core/models/model.dart' as core;
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/connectivity_service.dart'
    show isOnlineProvider;
import 'package:conduit_core/sync/sync_engine.dart' show syncEngineProvider;
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:conduitd/src/queued_completions_service.dart';
import 'package:test/test.dart';

import 'support/fake_owui_auth_server.dart';
import 'support/null_sink.dart';
import 'support/step_clock.dart';
import 'support/window.dart';

/// What a held send leaves: the send, the reply running elsewhere that
/// holds it, and what the daemon has said since.
typedef HeldSend = ({
  SendTurnAccepted sent,
  Completer<void> elsewhere,
  List<String> completed,
  List<TurnFinished> finished,
  int Function() changed,
});

/// The queue of an Open WebUI chat, and its Stop, against a fake Open WebUI
/// that takes sends: an answer held running where the live test asks for a
/// slow one.
void main() {
  late CoreRuntime runtime;
  late FakeOwuiAuthServer owui;
  late EventBus events;
  late TurnsService turns;
  late QueuedCompletionsService queued;
  late StepClock clock;

  setUp(() async {
    final temporary = Directory.systemTemp.createTempSync('turns-queue');
    addTearDown(() => temporary.deleteSync(recursive: true));
    runtime = await CoreRuntime.start(
      config: BootstrapConfig(
        sessionToken: 'a' * 43,
        masterKey: base64.encode(List<int>.generate(32, (i) => i)),
        userDataDir: temporary.path,
      ),
      directories: DaemonDirectories.create(temporary.path),
      log: DaemonLog(level: 'error', sink: NullSink()),
    );
    addTearDown(runtime.dispose);
    owui =
        await FakeOwuiAuthServer.start(
            users: const {
              'ada@example.com': (
                id: 'user-ada',
                name: 'Ada',
                password: 'pw-ada',
              ),
            },
          )
          ..models = const ['kettle-model'];
    addTearDown(owui.close);
    events = EventBus();
    final accounts = AccountsService(runtime.container, events: events);
    addTearDown(accounts.dispose);
    final auth = AuthService(runtime.container);
    addTearDown(auth.dispose);
    final added = await accounts.add(
      AddAccount(
        server: ServerDraft(name: 'Lab', url: owui.url),
        force: true,
      ),
    );
    final accountId = added.accounts.activeAccountId!;
    await auth.loginWithPassword(
      const PasswordLogin(username: 'ada@example.com', password: 'pw-ada'),
    );
    await runtime.container.read(activeServerProvider.future);
    // A chat already on the server opens as the account's once its user is
    // bound. Certification starts that bind right after it is announced,
    // queued on storage's lock: a registry read made after the
    // announcement's own work (a microtask) is queued behind it.
    final storage = runtime.container.read(optimizedStorageServiceProvider);
    final bound = Completer<void>();
    final watch = runtime.container.listen<Object?>(
      openWebUiCertifiedDatabaseServerProvider,
      (_, _) => Future<void>.microtask(() async {
        final registry = await storage.getOpenWebUiRegistryStrict();
        if (registry.account(accountId)?.userId != null && !bound.isCompleted) {
          bound.complete();
        }
      }),
      fireImmediately: true,
    );
    addTearDown(watch.close);
    await bound.future;
    clock = StepClock();
    queued = QueuedCompletionsService(runtime.container, events);
    addTearDown(queued.dispose);
    turns = TurnsService(
      runtime.container,
      events,
      now: clock.now,
      pause: clock.pause,
      queued: queued,
    );
    addTearDown(turns.dispose);
  });

  /// Completes once [ok] holds: checked now, and after each event the
  /// daemon sends, with the clock moving meanwhile.
  Future<void> until(bool Function() ok) {
    if (ok()) return Future<void>.value();
    final done = Completer<void>();
    late final void Function() untap;
    untap = events.tap((_, _, _) {
      if (done.isCompleted || !ok()) return;
      done.complete();
      scheduleMicrotask(untap);
    });
    return clock.during(done.future);
  }

  test('each queued batch goes out once, in a chat whose earlier batch went '
      'out after a Stop & Send', () async {
    const chatId = 'chat-kitchen';
    final chats = owui.chats..seed(chatId, userId: 'user-ada');
    final completed = <String>[];
    events.attach('probe', (envelope) {
      if (envelope.event == ConduitEvents.turnCompleted) {
        completed.add(TurnCompleted.fromJson(envelope.payload).messageId);
      }
    });
    await clock.during(
      turns.send(
        const SendTurn(
          chatId: chatId,
          model: 'kettle-model',
          text: 'Is the kettle on?',
        ),
      ),
    );
    subscribeWindow(events, turns, 'probe', <String>[chatId]);
    await until(() => completed.isNotEmpty);

    chats.holdStream = Completer<void>();
    await clock.during(
      turns.send(
        const SendTurn(
          chatId: chatId,
          model: 'kettle-model',
          text: 'Answer slow',
        ),
      ),
    );
    await until(() => turns.queueGet(chatId).offer);
    turns.queueAdd(QueueAdd(chatId: chatId, text: 'And the north side?'));
    final two = turns.queueAdd(
      QueueAdd(chatId: chatId, text: 'And the south side?'),
    );
    final now = await clock.during(
      turns.queueSendNow(
        QueueDraftRef(chatId: chatId, draftId: two.drafts.first.id),
      ),
    );
    expect(now.outcome, 'admitted');
    await until(
      () =>
          completed.length >= 4 &&
          turns.queueGet(chatId).drafts.isEmpty &&
          !turns.isRunning(chatId),
    );
    expect(completed, hasLength(4));

    final long = chats.holdStream = Completer<void>();
    await clock.during(
      turns.send(
        const SendTurn(
          chatId: chatId,
          model: 'kettle-model',
          text: 'Answer long',
        ),
      ),
    );
    await until(() => turns.queueGet(chatId).offer);
    turns.queueAdd(QueueAdd(chatId: chatId, text: 'And the east side?'));
    // The batch waits for the long answer's stored copy, held here, and then
    // for a window's message that claimed the chat meanwhile. Such a send
    // reaches its claim without any I/O, so an emptied event queue means it
    // has it.
    final reads = chats.holdChatReads = Completer<void>();
    long.complete();
    await until(() => completed.length >= 5);
    await clock.during(chats.chatReadAsked.future);
    final meanwhile = turns.send(
      const SendTurn(
        chatId: chatId,
        model: 'kettle-model',
        text: 'And the lark?',
      ),
    );
    await pumpEventQueue();
    expect(chats.completions, hasLength(5));
    chats.holdChatReads = null;
    reads.complete();
    await clock.during(meanwhile);
    await until(
      () =>
          completed.length >= 7 &&
          turns.queueGet(chatId).drafts.isEmpty &&
          !turns.isRunning(chatId),
    );

    const asked = <String>[
      'Is the kettle on?',
      'Answer slow',
      'And the north side?',
      'And the south side?',
      'Answer long',
      'And the lark?',
      'And the east side?',
    ];
    expect(<Object?>[
      for (final completion in chats.completions) completion['session_id'],
    ], everyElement(isNotNull));
    expect(<Object?>[
      for (final completion in chats.completions)
        (completion['user_message'] as Map?)?['content'],
    ], asked);
    final chat = await ChatsService(
      runtime.container,
      events: events,
    ).get(chatId);
    expect(<String>[
      for (final message in chat!.messages)
        if (message.role == 'user') message.content,
    ], asked);
    expect(completed, hasLength(7));
  });

  /// One answered turn in [chatId], with a window showing the chat; then,
  /// under an answer another device is running, a send the server holds.
  Future<HeldSend> heldSend(String chatId) async {
    final chats = owui.chats..seed(chatId, userId: 'user-ada');
    final completed = <String>[];
    final finished = <TurnFinished>[];
    var changed = 0;
    events.attach('probe', (envelope) {
      switch (envelope.event) {
        case ConduitEvents.turnCompleted:
          completed.add(TurnCompleted.fromJson(envelope.payload).messageId);
        case ConduitEvents.turnFinished:
          finished.add(TurnFinished.fromJson(envelope.payload));
      }
    });
    // A tap, so the count is current when [until] looks after an event.
    final untap = events.tap((event, _, _) {
      if (event == ConduitEvents.chatsChanged) changed++;
    });
    addTearDown(untap);
    await clock.during(
      turns.send(
        SendTurn(
          chatId: chatId,
          model: 'kettle-model',
          text: 'Is the kettle on?',
        ),
      ),
    );
    subscribeWindow(events, turns, 'probe', <String>[chatId]);
    await until(() => completed.isNotEmpty);

    final elsewhere = chats.runElsewhere(chatId);
    final sent = await clock.during(
      turns.send(
        SendTurn(
          chatId: chatId,
          model: 'kettle-model',
          text: 'And the pantry?',
        ),
      ),
    );
    await until(
      () => finished.any((f) => f.messageId == sent.assistantMessageId),
    );
    return (
      sent: sent,
      elsewhere: elsewhere,
      completed: completed,
      finished: finished,
      changed: () => changed,
    );
  }

  test('a message the server holds behind another device\'s answer waits, '
      'and its answer comes with the chat', () async {
    // Open WebUI 0.13.4 keeps a message sent under an answer still running,
    // and answers it under new ids once that answer ends. The chat's scope
    // hears that answer, so it stays however long the other answer runs.
    final linger = TurnsService.lingerAfterTurn;
    TurnsService.lingerAfterTurn = Duration.zero;
    addTearDown(() => TurnsService.lingerAfterTurn = linger);
    const chatId = 'chat-pantry';
    final held = await heldSend(chatId);
    final chats = owui.chats;
    final sent = held.sent;

    final ended = held.finished.lastWhere(
      (f) => f.messageId == sent.assistantMessageId,
    );
    expect((ended.ok, ended.held), (true, true));
    expect(held.completed, isNot(contains(sent.assistantMessageId)));
    expect(chats.heldCompletions, hasLength(1));
    expect(chats.deletedMessages, ['$chatId/${sent.assistantMessageId}']);
    // Messages typed meanwhile queue behind it, as behind a running answer.
    expect(turns.queueGet(chatId).offer, isTrue);
    // The scope's own copy: reading the chat would pull it, and hear the
    // answer that way rather than as the scope does.
    final waiting = turns.openMessages(chatId)!;
    expect(waiting.last.content, 'And the pantry?');
    expect(waiting.last.isHeldByServer, isTrue);
    expect(waiting.map((m) => m.id), isNot(contains(sent.assistantMessageId)));

    await pumpEventQueue();
    final before = held.changed();
    held.elsewhere.complete();
    await until(() => held.changed() > before);

    final chatsService = ChatsService(runtime.container, events: events);
    final answered = (await chatsService.get(chatId))!.messages;
    expect(
      <String>[
        for (final message in answered)
          if (message.role == 'user') message.content,
      ],
      ['Is the kettle on?', 'Write the shopping list', 'And the pantry?'],
    );
    expect(answered.where((m) => m.held), isEmpty);
    expect(answered.last.content, chats.answer);
    // The server answered it: it was never asked again.
    expect(chats.completions, hasLength(2));
  });

  test('a held message answered before its chat\'s scope would linger to a '
      'close is announced too', () async {
    final linger = TurnsService.lingerAfterTurn;
    TurnsService.lingerAfterTurn = const Duration(hours: 1);
    addTearDown(() => TurnsService.lingerAfterTurn = linger);
    const chatId = 'chat-larder';
    final held = await heldSend(chatId);

    await pumpEventQueue();
    final before = held.changed();
    held.elsewhere.complete();
    await until(() => held.changed() > before);

    final answered = turns.openMessages(chatId)!;
    expect(answered.where((m) => m.isHeldByServer), isEmpty);
    expect(answered.last.content, owui.chats.answer);
  });

  test(
    'a held message\'s chat keeps its scope while a window shows it, and '
    'closes it a while after; a later pull still brings the answer',
    () async {
      final linger = TurnsService.lingerAfterTurn;
      TurnsService.lingerAfterTurn = Duration.zero;
      addTearDown(() => TurnsService.lingerAfterTurn = linger);
      const chatId = 'chat-cellar';
      final held = await heldSend(chatId);
      await pumpEventQueue();

      // Past the bound, the window still shows the chat.
      clock.advance(TurnsService.heldOpenLimit);
      await pumpEventQueue();
      expect(turns.hasScope(chatId), isTrue);

      // Once no window shows it, the scope goes after another while.
      subscribeWindow(events, turns, 'probe', const <String>[]);
      await pumpEventQueue();
      expect(turns.hasScope(chatId), isTrue);
      // It closes as that wait ends, without a second linger, which would run
      // on the wall clock the test does not move.
      TurnsService.lingerAfterTurn = const Duration(seconds: 30);
      clock.advance(TurnsService.heldOpenLimit);
      await pumpEventQueue();
      expect(turns.hasScope(chatId), isFalse);

      held.elsewhere.complete();
      await pumpEventQueue();
      await runtime.container
          .read(syncEngineProvider.notifier)
          .pullChatNow(chatId);
      final chatsService = ChatsService(runtime.container, events: events);
      final answered = (await chatsService.get(chatId))!.messages;
      expect(answered.where((m) => m.held), isEmpty);
      expect(answered.last.content, owui.chats.answer);
      expect(owui.chats.completions, hasLength(2));
    },
  );

  /// One answered turn in [chatId], with a window showing the chat, and what
  /// the daemon says from then on.
  Future<
    ({
      List<String> started,
      List<TurnFinished> finished,
      List<String> completed,
    })
  >
  answeredChat(String chatId) async {
    owui.chats.seed(chatId, userId: 'user-ada');
    final started = <String>[];
    final finished = <TurnFinished>[];
    final completed = <String>[];
    events.attach('probe', (envelope) {
      switch (envelope.event) {
        case ConduitEvents.turnStarted:
          started.add(TurnStarted.fromJson(envelope.payload).messageId);
        case ConduitEvents.turnFinished:
          finished.add(TurnFinished.fromJson(envelope.payload));
        case ConduitEvents.turnCompleted:
          completed.add(TurnCompleted.fromJson(envelope.payload).messageId);
      }
    });
    await clock.during(
      turns.send(
        SendTurn(
          chatId: chatId,
          model: 'kettle-model',
          text: 'Is the kettle on?',
        ),
      ),
    );
    subscribeWindow(events, turns, 'probe', <String>[chatId]);
    await until(() => completed.isNotEmpty);
    return (started: started, finished: finished, completed: completed);
  }

  /// Once a held send's empty answer is deleted on the server, and while the
  /// reply to that delete is late: the answer [elsewhere] runs ends, the
  /// server answers the held question in place, and a pull stores that
  /// answer. Then the reply comes.
  Future<void> answeredWhileDeleting(
    String chatId,
    Completer<void> elsewhere,
    Completer<void> deletes,
  ) async {
    final chats = owui.chats..answerHeldInPlace = true;
    await clock.during(chats.messageDeleteAsked.future);
    elsewhere.complete();
    await clock.during(elsewhere.future);
    await clock.during(
      runtime.container.read(syncEngineProvider.notifier).pullChatNow(chatId),
    );
    chats.holdMessageDeletes = null;
    deletes.complete();
  }

  /// [chatId] once the server has answered its held question [answerId]:
  /// nothing streams in its scope, and the chat the windows read shows the
  /// question with that answer.
  Future<void> expectAnsweredInPlace(String chatId, String answerId) async {
    expect(turns.isRunning(chatId), isFalse);
    expect(
      turns
          .openMessages(chatId)!
          .where((m) => m.isStreaming || m.id == answerId),
      isEmpty,
    );
    final chatsService = ChatsService(runtime.container, events: events);
    final answered = (await chatsService.get(chatId))!.messages;
    expect(answered.where((m) => m.held), isEmpty);
    expect(answered.map((m) => m.id), isNot(contains(answerId)));
    expect(
      [for (final m in answered.skip(answered.length - 2)) m.content],
      ['And the pantry?', owui.chats.answer],
    );
  }

  test('a held message the server answers while its empty answer\'s delete '
      'is out ends its turn held', () async {
    const chatId = 'chat-wine-rack';
    final said = await answeredChat(chatId);
    final chats = owui.chats;
    final elsewhere = chats.runElsewhere(chatId);
    // A drain already running (another chat's send, its save held here)
    // takes the request once it is free: the send returns first, and its
    // turn starts before the server holds it.
    const otherId = 'chat-larder';
    chats
      ..seed(otherId, userId: 'user-ada')
      ..holdChatSavesOf = otherId
      ..chatSaveAsked = Completer<void>();
    final saves = chats.holdChatSaves = Completer<void>();
    final other = clock.during(
      turns.send(
        const SendTurn(
          chatId: otherId,
          model: 'kettle-model',
          text: 'Is the oven on?',
        ),
      ),
    );
    await clock.during(chats.chatSaveAsked.future);
    final sent = await clock.during(
      turns.send(
        const SendTurn(
          chatId: chatId,
          model: 'kettle-model',
          text: 'And the pantry?',
        ),
      ),
    );
    final main = sent.assistantMessageId;
    await until(() => said.started.contains(main));
    final ended = Completer<void>();
    final untap = events.tap((event, _, payload) {
      if (event == ConduitEvents.turnFinished &&
          TurnFinished.fromJson(payload).messageId == main &&
          !ended.isCompleted) {
        ended.complete();
      }
    });
    addTearDown(untap);

    final deletes = chats.holdMessageDeletes = Completer<void>();
    chats.holdChatSaves = null;
    saves.complete();
    await answeredWhileDeleting(chatId, elsewhere, deletes);
    await clock.during(other);
    // The other chat's send returns as its turn starts, before this one ends.
    await clock.during(ended.future);

    expect(chats.heldCompletions, hasLength(1));
    expect(
      [
        for (final f in said.finished)
          if (f.messageId == main) (f.ok, f.held),
      ],
      [(true, true)],
    );
    expect(said.completed, isNot(contains(main)));
    await expectAnsweredInPlace(chatId, main);
  });

  test('a held message the server answers while its empty answer\'s delete '
      'is out, before its turn has started, is sent and ends held', () async {
    const chatId = 'chat-spice-rack';
    final said = await answeredChat(chatId);
    final chats = owui.chats;
    final elsewhere = chats.runElsewhere(chatId);
    final deletes = chats.holdMessageDeletes = Completer<void>();
    final sending = clock.during(
      turns.send(
        const SendTurn(
          chatId: chatId,
          model: 'kettle-model',
          text: 'And the pantry?',
        ),
      ),
    );
    await answeredWhileDeleting(chatId, elsewhere, deletes);
    final sent = await sending;

    final main = sent.assistantMessageId;
    expect(chats.heldCompletions, hasLength(1));
    expect(said.started, isNot(contains(main)));
    expect(
      [
        for (final f in said.finished)
          if (f.messageId == main) (f.ok, f.held),
      ],
      [(true, true)],
    );
    await expectAnsweredInPlace(chatId, main);
  });

  test('a comparison the server holds ends each of its other columns held, '
      'before its own', () async {
    const chatId = 'chat-scullery';
    final chats = owui.chats..seed(chatId, userId: 'user-ada');
    // The account's model, as one picked or offered by default.
    runtime.container
        .read(selectedModelProvider.notifier)
        .set(const core.Model(id: 'kettle-model', name: 'kettle-model'));
    final started = <TurnStarted>[];
    final finished = <TurnFinished>[];
    final completed = <String>[];
    events.attach('probe', (envelope) {
      switch (envelope.event) {
        case ConduitEvents.turnStarted:
          started.add(TurnStarted.fromJson(envelope.payload));
        case ConduitEvents.turnFinished:
          finished.add(TurnFinished.fromJson(envelope.payload));
        case ConduitEvents.turnCompleted:
          completed.add(TurnCompleted.fromJson(envelope.payload).messageId);
      }
    });
    await clock.during(
      turns.send(
        const SendTurn(
          chatId: chatId,
          model: 'kettle-model',
          text: 'Is the kettle on?',
        ),
      ),
    );
    subscribeWindow(events, turns, 'probe', <String>[chatId]);
    await until(() => completed.isNotEmpty);

    final elsewhere = chats.runElsewhere(chatId);
    // A drain already running (another chat's send, its save held here)
    // takes the comparison's request once it is free: the comparison's send
    // returns first, and its turn starts with its columns before the server
    // holds it.
    const otherId = 'chat-larder';
    chats
      ..seed(otherId, userId: 'user-ada')
      ..holdChatSavesOf = otherId
      ..chatSaveAsked = Completer<void>();
    final saves = chats.holdChatSaves = Completer<void>();
    final other = clock.during(
      turns.send(
        const SendTurn(
          chatId: otherId,
          model: 'kettle-model',
          text: 'Is the oven on?',
        ),
      ),
    );
    await clock.during(chats.chatSaveAsked.future);
    final sent = await clock.during(
      turns.send(
        const SendTurn(
          chatId: chatId,
          model: 'kettle-model',
          compareModels: <String>['kettle-model', 'kettle-model'],
          text: 'And the pantry?',
        ),
      ),
    );
    final main = sent.assistantMessageId;
    await until(() => started.any((s) => s.messageId == main));
    chats.holdChatSaves = null;
    saves.complete();
    await clock.during(other);
    await until(() => finished.any((f) => f.messageId == main));

    final turn = started.lastWhere((s) => s.messageId == main);
    final others = [
      for (final id in turn.companionIds)
        if (id != main) id,
    ];
    expect(others, hasLength(1));
    expect(chats.heldCompletions, hasLength(1));
    expect(
      [
        for (final f in finished)
          if (f.messageId == main || others.contains(f.messageId))
            (f.messageId, f.ok, f.held),
      ],
      [for (final id in others) (id, true, true), (main, true, true)],
    );
    expect(completed, isNot(contains(anyOf([main, ...others]))));
    elsewhere.complete();
    await pumpEventQueue();
  });

  test('a window back after a held comparison was answered is told each of '
      'its answers ended held, and nothing more', () async {
    final linger = TurnsService.lingerAfterTurn;
    TurnsService.lingerAfterTurn = const Duration(hours: 1);
    addTearDown(() => TurnsService.lingerAfterTurn = linger);
    const chatId = 'chat-pantry-shelf';
    final chats = owui.chats..seed(chatId, userId: 'user-ada');
    runtime.container
        .read(selectedModelProvider.notifier)
        .set(const core.Model(id: 'kettle-model', name: 'kettle-model'));
    final started = <TurnStarted>[];
    final completed = <String>[];
    events.attach('window', (envelope) {
      switch (envelope.event) {
        case ConduitEvents.turnStarted:
          started.add(TurnStarted.fromJson(envelope.payload));
        case ConduitEvents.turnCompleted:
          completed.add(TurnCompleted.fromJson(envelope.payload).messageId);
      }
    });
    final held = <String>{};
    final untap = events.tap((event, _, payload) {
      if (event != ConduitEvents.turnFinished) return;
      final finished = TurnFinished.fromJson(payload);
      if (finished.held) held.add(finished.messageId);
    });
    addTearDown(untap);
    await clock.during(
      turns.send(
        const SendTurn(
          chatId: chatId,
          model: 'kettle-model',
          text: 'Is the kettle on?',
        ),
      ),
    );
    subscribeWindow(events, turns, 'window', <String>[chatId]);
    await until(() => completed.isNotEmpty);

    // As in the test before: the comparison starts with its columns, and
    // only then does the server hold it.
    final elsewhere = chats.runElsewhere(chatId);
    const otherId = 'chat-larder';
    chats
      ..seed(otherId, userId: 'user-ada')
      ..holdChatSavesOf = otherId
      ..chatSaveAsked = Completer<void>();
    final saves = chats.holdChatSaves = Completer<void>();
    final other = clock.during(
      turns.send(
        const SendTurn(
          chatId: otherId,
          model: 'kettle-model',
          text: 'Is the oven on?',
        ),
      ),
    );
    await clock.during(chats.chatSaveAsked.future);
    final sent = await clock.during(
      turns.send(
        const SendTurn(
          chatId: chatId,
          model: 'kettle-model',
          compareModels: <String>['kettle-model', 'kettle-model'],
          text: 'And the pantry?',
        ),
      ),
    );
    final main = sent.assistantMessageId;
    await until(() => started.any((s) => s.messageId == main));
    final turn = started.lastWhere((s) => s.messageId == main);
    final others = [
      for (final id in turn.companionIds)
        if (id != main) id,
    ];
    expect(others, hasLength(1));

    // The window's connection drops; meanwhile the turn ends held, and the
    // server answers the question under new ids.
    events.detach('window');
    chats.holdChatSaves = null;
    saves.complete();
    await clock.during(other);
    await until(() => held.contains(main));
    elsewhere.complete();
    await until(
      () => turns.openMessages(chatId)?.lastOrNull?.role == 'assistant',
    );
    final answered = turns.openMessages(chatId)!;
    expect(answered.where((m) => m.isHeldByServer), isEmpty);
    expect(
      answered.map((m) => m.id),
      isNot(contains(anyOf([main, ...others]))),
    );

    // The window back, as a new session.
    final caughtUp = <(String, String, bool)>[];
    events.attach('window-again', (envelope) {
      final payload = envelope.payload;
      caughtUp.add(switch (envelope.event) {
        ConduitEvents.turnFinished => (
          envelope.event,
          TurnFinished.fromJson(payload).messageId,
          TurnFinished.fromJson(payload).held,
        ),
        _ => (envelope.event, payload['messageId'] as String? ?? '', false),
      });
    });
    subscribeWindow(events, turns, 'window-again', <String>[chatId]);
    expect(caughtUp, [
      for (final id in others) (ConduitEvents.turnFinished, id, true),
      (ConduitEvents.turnFinished, main, true),
    ]);
  });

  test('a Stop on an answer the server stopped in the middle of keeps what '
      'streamed, in the server\'s copy too', () async {
    const chatId = 'chat-gale';
    final first = Completer<void>();
    final chats = owui.chats
      ..seed(chatId, userId: 'user-ada')
      ..holdFirstWord = first
      ..holdStream = Completer<void>();
    var streamed = false;
    events.attach('probe', (envelope) {
      if (envelope.event == ConduitEvents.turnDelta &&
          envelope.payload['text'] == 'The') {
        streamed = true;
      }
    });
    final sent = await clock.during(
      turns.send(
        const SendTurn(
          chatId: chatId,
          model: 'kettle-model',
          text: 'Will the gale veer?',
        ),
      ),
    );
    subscribeWindow(events, turns, 'probe', <String>[chatId]);
    first.complete();
    await until(() => streamed);

    // The server stops in the middle of the answer and is started again,
    // with no task running.
    chats
      ..stopServer()
      ..startServer();
    final saved = chats.chatSaved = Completer<String>();
    await clock.during(turns.stop(chatId));

    // Open WebUI's stop finished its copy with the text it had stored: none.
    // What streamed here is stored, and goes to the server.
    final db = runtime.container.read(appDatabaseProvider)!;
    final stored = await db.messagesDao.getMessage(
      chatId,
      sent.assistantMessageId,
    );
    expect(stored?.content, 'The');
    expect(await clock.during(saved.future), chatId);
    final history =
        (chats.stored[chatId]!['chat'] as Map<String, dynamic>)['history']
            as Map<String, dynamic>;
    final answer =
        (history['messages'] as Map<String, dynamic>)[sent.assistantMessageId]
            as Map<String, dynamic>;
    expect(answer['content'], 'The');
    expect(answer['done'], isTrue);
  });

  /// Reports the network [online] or not, as the window does, and completes
  /// once the core reads it so.
  Future<void> reportNetwork({required bool online}) {
    final read = Completer<void>();
    final watch = runtime.container.listen<bool>(isOnlineProvider, (_, next) {
      if (next == online && !read.isCompleted) read.complete();
    });
    runtime.reportNetwork(online: online);
    return read.future.whenComplete(watch.close);
  }

  /// Sends into [chatId], streams the answer's first word, stops the server
  /// in the middle of it, and presses Stop while it is away: the sent turn.
  Future<SendTurnAccepted> stopWhileAway(String chatId) async {
    final first = Completer<void>();
    final chats = owui.chats
      ..seed(chatId, userId: 'user-ada')
      ..holdFirstWord = first
      ..holdStream = Completer<void>();
    var streamed = false;
    events.attach('probe', (envelope) {
      if (envelope.event == ConduitEvents.turnDelta &&
          envelope.payload['text'] == 'The') {
        streamed = true;
      }
    });
    final sent = await clock.during(
      turns.send(
        SendTurn(
          chatId: chatId,
          model: 'kettle-model',
          text: 'Will the squall pass?',
        ),
      ),
    );
    subscribeWindow(events, turns, 'probe', <String>[chatId]);
    first.complete();
    await until(() => streamed);

    chats.stopServer();
    await reportNetwork(online: false);
    await clock.during(turns.stop(chatId));
    return sent;
  }

  Map<String, dynamic> serverAnswer(String chatId, String id) =>
      ((owui.chats.stored[chatId]!['chat'] as Map)['history']
              as Map)['messages'][id]
          as Map<String, dynamic>;

  test('a Stop while the server is away reaches it once it is back: the '
      'queued update stops the chat and sends what streamed', () async {
    const chatId = 'chat-squall';
    final sent = await stopWhileAway(chatId);

    // Kept here, and owed to the server in the store.
    final db = runtime.container.read(appDatabaseProvider)!;
    final stored = await db.messagesDao.getMessage(
      chatId,
      sent.assistantMessageId,
    );
    expect(stored?.content, 'The');
    expect(
      (await db.outboxDao.activeForChat(chatId)).map((op) => op.kind),
      contains('updateChat'),
    );

    // Started again with no task running, its copy not done and empty.
    owui.chats.startServer();
    runtime.reportNetwork(online: true);
    // The update has gone, past its stop and the save that follows it.
    await clock.during(
      (db.select(db.outboxOps)..where((op) => op.chatId.equals(chatId)))
          .watch()
          .firstWhere((ops) => !ops.any((op) => op.kind == 'updateChat')),
    );

    final answer = serverAnswer(chatId, sent.assistantMessageId);
    expect(answer['content'], 'The');
    expect(answer['done'], isTrue);
  });

  test('a Stop owed from an outage asks no stop while another device '
      'answers in the chat, and leaves that answer as it is', () async {
    const chatId = 'chat-hail';
    final sent = await stopWhileAway(chatId);

    final chats = owui.chats..startServer();
    final elsewhere = chats.runElsewhere(chatId);
    final saved = chats.chatSaved = Completer<String>();
    runtime.reportNetwork(online: true);
    expect(await clock.during(saved.future), chatId);

    expect(chats.stopped, isEmpty);
    final theirsId =
        (((chats.stored[chatId]!['chat'] as Map)['history'] as Map)['messages']
                as Map)
            .keys
            .cast<String>()
            .singleWhere((id) => id.startsWith('elsewhere-answer-'));
    final theirs = serverAnswer(chatId, theirsId);
    expect(theirs['content'], 'Eggs,');
    expect(theirs['done'], isFalse);
    final ours = serverAnswer(chatId, sent.assistantMessageId);
    expect(ours['content'], '');
    expect(ours['done'], isFalse);

    // Their answer ends; the next drain asks the stop, and sends ours.
    final db = runtime.container.read(appDatabaseProvider)!;
    await clock.during(
      (db.select(db.outboxOps)..where((op) => op.chatId.equals(chatId)))
          .watch()
          .firstWhere((ops) => ops.any((op) => op.lastError != null)),
    );
    elsewhere.complete();
    final again = chats.chatSaved = Completer<String>();
    await clock.during(
      runtime.container.read(syncEngineProvider.notifier).drainNow(),
    );
    expect(await clock.during(again.future), chatId);
    expect(serverAnswer(chatId, sent.assistantMessageId)['content'], 'The');
    expect(serverAnswer(chatId, sent.assistantMessageId)['done'], isTrue);
  });

  test('a message sent while the server is away shows queued, and goes out '
      'once when it is back', () async {
    const chatId = 'chat-tern';
    const question = 'And the terns?';
    final chats = owui.chats..seed(chatId, userId: 'user-ada');
    final completed = <String>[];
    final endedQueued = <String>[];
    events.attach('probe', (envelope) {
      switch (envelope.event) {
        case ConduitEvents.turnCompleted:
          completed.add(TurnCompleted.fromJson(envelope.payload).messageId);
        case ConduitEvents.turnFinished:
          final finished = TurnFinished.fromJson(envelope.payload);
          if (finished.queued) endedQueued.add(finished.messageId);
      }
    });
    await clock.during(
      turns.send(
        const SendTurn(
          chatId: chatId,
          model: 'kettle-model',
          text: 'Are the plovers back?',
        ),
      ),
    );
    subscribeWindow(events, turns, 'probe', <String>[chatId]);
    await until(() => completed.isNotEmpty);

    chats.stopServer();
    final sent = await clock.during(
      turns.send(
        const SendTurn(chatId: chatId, model: 'kettle-model', text: question),
      ),
    );
    // The chat's first op is tried, and fails: the server is away.
    final db = runtime.container.read(appDatabaseProvider)!;
    await clock.during(
      db.outboxDao
          .watchChatQueuesWithCompletions(chatId: chatId)
          .firstWhere((ops) => ops.any((op) => op.attempts > 0)),
    );
    // Only then does the connection count as gone.
    runtime.reportNetwork(online: false);
    await until(() => !runtime.container.read(isOnlineProvider));

    expect(endedQueued, [sent.assistantMessageId]);
    expect(queued.isQueued(chatId, sent.assistantMessageId), isTrue);
    expect(turns.isRunning(chatId), isFalse);

    chats.startServer();
    runtime.reportNetwork(online: true);
    await until(() => completed.contains(sent.assistantMessageId));
    expect(
      chats.completions.where(
        (asked) => (asked['user_message'] as Map?)?['content'] == question,
      ),
      hasLength(1),
    );
  });

  test('dispose waits for the pull a finished turn started', () async {
    const chatId = 'chat-bread-bin';
    final chats = owui.chats..seed(chatId, userId: 'user-ada');
    // The pull after the turn reads the chat, which the server renames while
    // that read is out.
    final pullRead = Completer<void>();
    // Before teardown's own dispose, which would wait for the read.
    addTearDown(() {
      if (!pullRead.isCompleted) pullRead.complete();
    });
    final untap = events.tap((event, _, _) {
      if (event != ConduitEvents.turnFinished || chats.holdChatReads != null) {
        return;
      }
      chats
        ..chatReadAsked = Completer<void>()
        ..holdChatReads = pullRead;
    });
    addTearDown(untap);
    await clock.during(
      turns.send(
        const SendTurn(
          chatId: chatId,
          model: 'kettle-model',
          text: 'Is there bread?',
        ),
      ),
    );
    await clock.during(chats.chatReadAsked.future);
    final row = chats.stored[chatId]!;
    row['title'] = 'Bread bin';
    row['updated_at'] = (row['updated_at'] as int) + 1;

    var disposed = false;
    final disposing = turns.dispose().whenComplete(() => disposed = true);
    await pumpEventQueue();
    expect(disposed, isFalse);
    pullRead.complete();
    await clock.during(disposing);

    final db = runtime.container.read(appDatabaseProvider)!;
    expect((await db.chatsDao.getChat(chatId))?.title, 'Bread bin');
  });

  test('a finished turn\'s check of its answer leaves no read of the chat '
      'out once dispose returns', () async {
    const chatId = 'chat-pantry';
    owui.chats.seed(chatId, userId: 'user-ada');
    // The engine's own sync cycles, which the end of a turn asks for on a
    // timer of the wall clock, wait at the chat list until the count is
    // taken: they read the chat whenever that timer lets them.
    final lists = owui.chats.holdChatLists = Completer<void>();
    addTearDown(() {
      if (!lists.isCompleted) lists.complete();
    });
    bool chatRead(String request) => request == 'GET /api/v1/chats/$chatId';
    var readsBefore = 0;
    var finished = false;
    final announced = Completer<void>();
    final untap = events.tap((event, _, _) {
      if (event == ConduitEvents.turnFinished && !finished) {
        finished = true;
        readsBefore = owui.requests.where(chatRead).length;
      } else if (finished &&
          event == ConduitEvents.chatsChanged &&
          !announced.isCompleted) {
        announced.complete();
      }
    });
    addTearDown(untap);
    await clock.during(
      turns.send(
        const SendTurn(
          chatId: chatId,
          model: 'kettle-model',
          text: 'Is there jam?',
        ),
      ),
    );
    await clock.during(announced.future);
    await clock.during(turns.dispose());

    // Asked for after the check, this read reaches the server after any
    // read the check started.
    await runtime.container
        .read(syncEngineProvider.notifier)
        .pullChatNow(chatId);
    // The pull after the turn, and this one.
    expect(owui.requests.where(chatRead).length - readsBefore, 2);
  });
}
