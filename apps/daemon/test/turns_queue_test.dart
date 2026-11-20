@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/database/database_provider.dart'
    show openWebUiCertifiedDatabaseServerProvider;
import 'package:conduit_core/models/chat_comparison.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/sync/sync_engine.dart' show syncEngineProvider;
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
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

/// The queue of an Open WebUI chat, against a fake Open WebUI that takes
/// sends: an answer held running where the live test asks for a slow one.
void main() {
  late CoreRuntime runtime;
  late FakeOwuiAuthServer owui;
  late EventBus events;
  late TurnsService turns;
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
    turns = TurnsService(
      runtime.container,
      events,
      now: clock.now,
      pause: clock.pause,
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
}
