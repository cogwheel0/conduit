@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/database/database_provider.dart'
    show openWebUiCertifiedDatabaseServerProvider;
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

import 'support/fake_owui_auth_server.dart';
import 'support/null_sink.dart';
import 'support/window.dart';

/// The queue of an Open WebUI chat, against a fake Open WebUI that takes
/// sends: an answer held running where the live test asks for a slow one.
void main() {
  late CoreRuntime runtime;
  late FakeOwuiAuthServer owui;
  late EventBus events;
  late TurnsService turns;

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
    turns = TurnsService(runtime.container, events);
    addTearDown(turns.dispose);
  });

  /// Completes once [ok] holds: checked now, and after each event the
  /// daemon sends.
  Future<void> until(bool Function() ok) {
    if (ok()) return Future<void>.value();
    final done = Completer<void>();
    late final void Function() untap;
    untap = events.tap((_, _, _) {
      if (done.isCompleted || !ok()) return;
      done.complete();
      scheduleMicrotask(untap);
    });
    return done.future;
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
    await turns.send(
      const SendTurn(
        chatId: chatId,
        model: 'kettle-model',
        text: 'Is the kettle on?',
      ),
    );
    subscribeWindow(events, turns, 'probe', <String>[chatId]);
    await until(() => completed.isNotEmpty);

    chats.holdStream = Completer<void>();
    await turns.send(
      SendTurn(chatId: chatId, model: 'kettle-model', text: 'Answer slow'),
    );
    await until(() => turns.queueGet(chatId).offer);
    turns.queueAdd(QueueAdd(chatId: chatId, text: 'And the north side?'));
    final two = turns.queueAdd(
      QueueAdd(chatId: chatId, text: 'And the south side?'),
    );
    final now = await turns.queueSendNow(
      QueueDraftRef(chatId: chatId, draftId: two.drafts.first.id),
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
    await turns.send(
      SendTurn(chatId: chatId, model: 'kettle-model', text: 'Answer long'),
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
    await chats.chatReadAsked.future;
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
    await meanwhile;
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
}
