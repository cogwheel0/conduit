@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:conduit_core/database/chat_database_repository.dart'
    show ChatStorageIdentity, ChatStorageKind;
import 'package:conduit_core/database/database_provider.dart'
    show openWebUiCertifiedDatabaseServerProvider;
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_core/providers/app_providers.dart'
    show modelsProvider;
import 'package:conduit_core/providers/storage_providers.dart'
    show optimizedStorageServiceProvider;
import 'package:conduit_core/sync/sync_engine.dart' show syncEngineProvider;
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduit_services/conduit_services.dart';
import 'package:conduit_services/src/account_scope.dart'
    show accountSwitchCountProvider;
import 'package:drift/drift.dart' show QueryExecutor, QueryInterceptor;
import 'package:test/test.dart';

import 'support/core.dart';
import 'support/fake_owui_auth_server.dart';
import 'support/scripted_openai.dart';
import 'support/step_clock.dart';
import 'support/window.dart';

/// A chat made here goes by a `local:` id until the server stores it, then
/// by the server's (`route.remap`). A request that still names the old id,
/// from a window that missed the move, is served as the chat it became, and
/// its answer names the chat's current id. Only the active account's moves
/// count.
void main() {
  late Directory temporary;
  late CoreRuntime runtime;
  late FakeOwuiAuthServer owui;
  late EventBus events;
  late TurnsService turns;
  late AccountsService accounts;
  late AuthService auth;
  late ChatsService chats;
  late String model;
  late List<EventEnvelope> heard;
  late _MoveLookups moves;
  late _DrainGate outbox;
  late StepClock clock;
  Future<void> Function()? beforeBranchCheck;

  setUp(() async {
    beforeBranchCheck = null;
    heard = <EventEnvelope>[];
    temporary = Directory.systemTemp.createTempSync('moved-chat-ids');
    addTearDown(() => temporary.deleteSync(recursive: true));
    moves = _MoveLookups();
    // Nothing made here reaches the server until a test lets it: the outbox
    // drains only past this gate ([reachServer]), never on its own.
    outbox = _DrainGate();
    runtime = await startTestCore(
      temporary,
      interceptDatabase: (_) => moves,
      outboxDrainGate: outbox.wait,
    );
    addTearDown(runtime.dispose);
    // Open before the runtime goes, so nothing it waits for stays held.
    addTearDown(outbox.open);
    owui = await FakeOwuiAuthServer.start(
      users: const {
        'ada@example.com': (id: 'user-ada', name: 'Ada', password: 'pw-ada'),
        'bob@example.com': (id: 'user-bob', name: 'Bob', password: 'pw-bob'),
      },
    );
    addTearDown(owui.close);
    // Serves chats, so a chat made here reaches the server and moves to its
    // id.
    owui.models = const <String>['harbor-model'];
    final provider = await ScriptedOpenAi.start();
    addTearDown(provider.close);
    events = EventBus();
    events.attach('window', heard.add);
    // The turns' own waits (a chat settling before its next turn) on a
    // clock that moves only while a test runs ([steps]): none of real time.
    clock = StepClock();
    turns = TurnsService(
      runtime.container,
      events,
      now: clock.now,
      pause: clock.pause,
    );
    addTearDown(turns.dispose);
    accounts = AccountsService(runtime.container, events: events, turns: turns);
    addTearDown(accounts.dispose);
    auth = AuthService(runtime.container);
    addTearDown(auth.dispose);
    // The branch check's waits pass at once: no test waits on real time.
    chats = ChatsService(
      runtime.container,
      events: events,
      pause: (_) async => await beforeBranchCheck?.call(),
    )..turns = turns;
    addTearDown(chats.dispose);
    final saved = await DirectService(runtime.container).save(
      DirectConnectionEdit(
        name: 'Scripted',
        kind: DirectKind.openai,
        baseUrl: provider.baseUrl,
        manualModelIds: const <String>['scripted-model'],
      ),
    );
    model = DirectModelId.encode(
      saved.connections.single.id,
      'scripted-model',
    );
  });

  /// A test whose waits on the turns' clock pass as it runs.
  void step(String name, Future<void> Function() body) =>
      test(name, () => clock.during(body()));

  Future<void> certified(String accountId) async {
    final done = Completer<void>();
    final watch = runtime.container.listen<String?>(
      openWebUiCertifiedDatabaseServerProvider,
      (_, next) {
        if (next == accountId && !done.isCompleted) done.complete();
      },
      fireImmediately: true,
    );
    await done.future;
    watch.close();
  }

  Future<String> signIn(String email, String password) async {
    await accounts.add(
      AddAccount(server: ServerDraft(name: 'Lab', url: owui.url), force: true),
    );
    await auth.loginWithPassword(
      PasswordLogin(username: email, password: password),
    );
    final id = (await accounts.list()).activeAccountId!;
    await certified(id);
    return id;
  }

  /// The end of [chatId]'s turn (the one answering [messageId], when
  /// given), as heard already or once it is.
  Future<void> finished(String chatId, {String? messageId}) {
    bool ends(String event, Map<String, dynamic> payload) =>
        event == ConduitEvents.turnFinished &&
        payload['chatId'] == chatId &&
        (messageId == null || payload['messageId'] == messageId);
    if (heard.any((e) => ends(e.event, e.payload))) {
      return Future<void>.value();
    }
    final done = Completer<void>();
    final untap = events.tap((event, _, payload) {
      if (ends(event, payload) && !done.isCompleted) done.complete();
    });
    return done.future.whenComplete(untap);
  }

  /// A chat with one question and its answer, made here and not yet
  /// stored by the server: its `local:` id.
  Future<String> localChat() async {
    final accepted = await turns.send(
      SendTurn(model: model, text: 'Which shelf?'),
    );
    final old = accepted.chatId;
    subscribeWindow(events, turns, 'window', <String>[old]);
    await finished(old);
    return old;
  }

  /// Lets what this device made reach the server: every drain held at the
  /// gate goes, and every later one runs at once.
  void reachServer() => outbox.open();

  /// The id [old] moves to, once the windows are told (`route.remap`).
  Future<String> remapOf(String old) {
    final moved = Completer<String>();
    events.attach('remap-$old', (e) {
      if (e.event == ConduitEvents.routeRemap &&
          e.payload['fromId'] == old &&
          !moved.isCompleted) {
        moved.complete('${e.payload['toId']}');
      }
    });
    return moved.future;
  }

  /// [old] stored by the server, and so moved to its id: that id.
  ///
  /// Returns once the creation has ended too: its op is marked done after the
  /// move ([_MoveLookups.opDone]), so nothing of it is still in flight.
  Future<String> move(String old) async {
    final moved = remapOf(old);
    final created = moves.opDone = Completer<void>();
    reachServer();
    await runtime.container.read(syncEngineProvider.notifier).drainNow();
    final now = await moved;
    await created.future;
    expect(now, isNot(old));
    return now;
  }

  /// The chats the windows are told changed, from now on. Not the list's
  /// own notice, which names none and comes when its debounce ends.
  List<String> toldChanged() {
    final told = <String>[];
    final untap = events.tap((event, _, payload) {
      if (event != ConduitEvents.chatsChanged) return;
      if (payload['chatId'] case final String chatId) told.add(chatId);
    });
    addTearDown(untap);
    return told;
  }

  /// A chat made here and then stored by the server: its old `local:` id
  /// and the server's.
  Future<(String, String)> movedChat() async {
    final old = await localChat();
    return (old, await move(old));
  }

  /// The model list read again from the server, and held there, so the
  /// next request that needs it waits: what lets it go.
  Future<Completer<void>> holdModels() async {
    final hold = owui.holdModels = Completer<void>();
    addTearDown(() {
      if (!hold.isCompleted) hold.complete();
    });
    // No cached list to answer with first.
    await runtime.container
        .read(optimizedStorageServiceProvider)
        .saveLocalModels(const []);
    runtime.container.invalidate(modelsProvider);
    return hold;
  }

  step('a chat asked for by its old id answers with its transcript, under '
      'its current id', () async {
    await signIn('ada@example.com', 'pw-ada');
    final (old, now) = await movedChat();

    final detail = await chats.get(old);
    expect(detail?.summary.id, now);
    expect(
      detail!.messages.map((m) => m.role).toList(),
      <String>['user', 'assistant'],
    );
  });

  step('a rename and a delete by the old id land on the moved chat', () async {
    await signIn('ada@example.com', 'pw-ada');
    final (old, now) = await movedChat();

    await chats.rename(old, 'The shelf question');
    expect((await chats.get(now))!.summary.title, 'The shelf question');

    await chats.delete(old);
    expect((await chats.list()).chats.map((c) => c.id), isNot(contains(now)));
  });

  step('a send by the old id continues the moved chat, and makes no other',
      () async {
    await signIn('ada@example.com', 'pw-ada');
    final (old, now) = await movedChat();

    final next = await turns.send(
      SendTurn(model: model, text: 'And the next?', chatId: old),
    );
    expect(next.chatId, now);
    await finished(now);
    expect((await chats.list()).chats.map((c) => c.id), <String>[now]);
    expect((await chats.get(now))!.messages, hasLength(4));
  });

  step('another account never takes a chat by an old id of the last one\'s',
      () async {
    final ada = await signIn('ada@example.com', 'pw-ada');
    final (old, now) = await movedChat();
    final bob = await signIn('bob@example.com', 'pw-bob');

    expect(
      (await chats.get(old))?.messages ?? const <ChatMessageDto>[],
      isEmpty,
    );
    try {
      await chats.rename(old, 'Not Bob\'s to name');
    } on Object {
      // Refused is as good as left alone.
    }
    await accounts.switchTo(AccountRef(accountId: ada));
    await certified(ada);
    expect((await chats.get(now))!.summary.title, isNot('Not Bob\'s to name'));
    expect(bob, isNot(ada));
  });

  step('a regenerate and an edit by the old id answer in the moved chat',
      () async {
    await signIn('ada@example.com', 'pw-ada');
    final (old, now) = await movedChat();
    final asked = (await chats.get(now))!.messages;

    final again = await turns.regenerate(
      RegenerateTurn(chatId: old, messageId: asked.last.id),
    );
    expect(again.chatId, now);
    await finished(now, messageId: again.assistantMessageId);

    final edited = await turns.edit(
      EditTurn(chatId: old, messageId: asked.first.id, text: 'Which drawer?'),
    );
    expect(edited.chatId, now);
    await finished(now, messageId: edited.assistantMessageId);

    expect((await chats.list()).chats.map((c) => c.id), <String>[now]);
    final transcript = (await chats.get(now))!.messages;
    expect(transcript.first.content, 'Which drawer?');
    expect(transcript.last.id, edited.assistantMessageId);
  });

  step('a batch naming an old id is refused, and changes nothing, once '
      'another account takes charge while the id is looked up', () async {
    final ada = await signIn('ada@example.com', 'pw-ada');
    final (old, now) = await movedChat();

    final lookup = moves.held = Completer<void>();
    // Whatever the batch leaves unhandled lands here, not in the test.
    final escaped = <Object>[];
    final refused = Completer<Object?>();
    runZonedGuarded(() {
      chats
          .bulk(
            BulkChats(
              action: BulkChatAction.delete,
              chatIds: <String>[now, old],
            ),
          )
          .then<void>(
            (_) => refused.complete(null),
            onError: (Object error) => refused.complete(error),
          );
    }, (error, _) => escaped.add(error));
    await moves.asked.future;
    final switched = Completer<void>();
    final watch = runtime.container.listen<int>(
      accountSwitchCountProvider,
      (_, _) {
        if (!switched.isCompleted) switched.complete();
      },
    );
    final bob = signIn('bob@example.com', 'pw-bob');
    await switched.future;
    watch.close();
    moves.held = null;
    lookup.complete();

    expect(
      await refused.future,
      isA<RpcError>().having(
        (e) => e.code,
        'code',
        ConduitErrorCodes.sessionExpired,
      ),
    );
    await pumpEventQueue();
    expect(escaped, isEmpty);
    final bobId = await bob;
    expect(bobId, isNot(ada));
    expect(owui.chats.stored.keys, contains(now));

    // A batch that also names a chat of the other backend is refused before
    // any of its ids is looked up: no lookup is left for a switch to fail.
    await accounts.switchTo(AccountRef(accountId: ada));
    await certified(ada);
    final held = moves.held = Completer<void>();
    moves.asked = Completer<void>();
    final theirs = ChatStorageIdentity(
      rawId: now,
      storage: ChatStorageKind.libreChat,
    ).scopedId;
    final refusedAgain = Completer<Object?>();
    runZonedGuarded(() {
      chats
          .bulk(
            BulkChats(
              action: BulkChatAction.delete,
              chatIds: <String>[old, theirs],
            ),
          )
          .then<void>(
            (_) => refusedAgain.complete(null),
            onError: (Object error) => refusedAgain.complete(error),
          );
    }, (error, _) => escaped.add(error));
    expect(
      await refusedAgain.future,
      isA<RpcError>().having(
        (e) => e.code,
        'code',
        ConduitErrorCodes.notFound,
      ),
    );
    final switchedAgain = Completer<void>();
    final watchAgain = runtime.container.listen<int>(
      accountSwitchCountProvider,
      (_, _) {
        if (!switchedAgain.isCompleted) switchedAgain.complete();
      },
    );
    final toBob = accounts.switchTo(AccountRef(accountId: bobId));
    await switchedAgain.future;
    watchAgain.close();
    moves.held = null;
    held.complete();
    await toBob;
    await pumpEventQueue();
    expect(escaped, isEmpty);
    expect(owui.chats.stored.keys, contains(now));
  });

  step('a send that waits for the models while its chat moves continues '
      'the moved chat', () async {
    await signIn('ada@example.com', 'pw-ada');
    final old = await localChat();
    final models = await holdModels();

    final sending = turns.send(
      SendTurn(model: model, text: 'And the next?', chatId: old),
    );
    await owui.modelsAsked.future;
    final now = await move(old);
    models.complete();

    final accepted = await sending;
    expect(accepted.chatId, now);
    await finished(now, messageId: accepted.assistantMessageId);
    expect((await chats.list()).chats.map((c) => c.id), <String>[now]);
    expect((await chats.get(now))!.messages, hasLength(4));
  });

  step('a call that waits for its model while its chat moves holds the '
      'moved chat', () async {
    await signIn('ada@example.com', 'pw-ada');
    final old = await localChat();
    final models = await holdModels();

    final holding = turns.holdForCall(chatId: old, model: model);
    await owui.modelsAsked.future;
    final now = await move(old);
    models.complete();

    final hold = await holding;
    addTearDown(hold.release);
    expect(hold.chatId, now);
    expect(hold.scope.messages.map((m) => m.role), <String>[
      'user',
      'assistant',
    ]);
  });

  test('a delete whose chat moves while it waits for the chat to settle '
      'tells the windows under its current id', () async {
    await clock.during(signIn('ada@example.com', 'pw-ada'));
    final old = await clock.during(localChat());
    final answer = (await clock.during(chats.get(old)))!.messages.last;
    final told = toldChanged();

    // Outside a step the turns' clock stands still: the delete, which came
    // under `old`, waits there for the chat to settle while it moves.
    final settling = clock.nextPause();
    final deleting = turns.deleteMessages(
      DeleteMessages(chatId: old, messageIds: <String>[answer.id]),
    );
    await settling;
    final now = await move(old);
    await clock.during(deleting);

    expect(told.last, now);
    expect(
      (await clock.during(chats.get(now)))!.messages.map((m) => m.id),
      isNot(contains(answer.id)),
    );
  });

  step('a branch chosen in a chat made here, whose drain moves it, is told '
      'under its current id, and made again there', () async {
    await signIn('ada@example.com', 'pw-ada');
    final old = await localChat();
    final transcript = (await chats.get(old))!.messages;
    final answer = transcript.last;
    final moved = remapOf(old);
    // Its own drain stores the chat, which moves it.
    reachServer();
    final told = toldChanged();
    // The server shows another message as the chat's current one at the
    // first check (a pull from before the switch, another device): the
    // switch is made again, on the chat as it goes now.
    Map<String, dynamic> history() =>
        (owui.chats.stored.values.single['chat']
                as Map<String, dynamic>)['history']
            as Map<String, dynamic>;
    var checks = 0;
    beforeBranchCheck = () async {
      if (checks++ == 0) {
        // On the server, under its id, before the first check.
        await moved;
        history()['currentId'] = transcript.first.id;
        return;
      }
      // The switch made again goes out with whichever drain runs next
      // (a drain asked for while one runs only asks it to run again):
      // checked once the server has it.
      while (history()['currentId'] != answer.id) {
        await (owui.chats.chatSaved = Completer<String>()).future;
      }
    };

    final detail = await chats.setCurrent(
      ChatCurrent(chatId: old, messageId: answer.id),
    );
    final now = await moved;
    expect(detail?.summary.id, now);
    expect(told.last, now);
    expect(checks, greaterThan(1));
    expect(history()['currentId'], answer.id);
  });

  step('an archive and a rename by a scoped old id reach the server under '
      'the raw current id', () async {
    await signIn('ada@example.com', 'pw-ada');
    final (old, now) = await movedChat();
    final scoped = ChatStorageIdentity(
      rawId: old,
      storage: ChatStorageKind.openWebUi,
    ).scopedId;

    await chats.rename(scoped, 'The shelf question');
    await chats.setArchived(scoped, value: true);
    expect(owui.chats.stored[now]!['title'], 'The shelf question');
    expect(owui.chats.stored[now]!['archived'], isTrue);
  });
}

/// Holds the lookups of a chat's move (its `chat_remap:` row) while [held]
/// is set; [asked] completes as the first one arrives.
final class _MoveLookups extends QueryInterceptor {
  Completer<void>? held;
  Completer<void> asked = Completer<void>();

  /// Completed, and cleared, once an outbox op is next marked done (its row
  /// deleted): for a chat made here, the last step of its creation.
  Completer<void>? opDone;

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final deleted = await executor.runDelete(statement, args);
    final done = opDone;
    if (done != null && statement.contains('outbox_ops')) {
      opDone = null;
      done.complete();
    }
    return deleted;
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final gate = held;
    if (gate != null &&
        args.any((a) => a is String && a.startsWith('chat_remap:'))) {
      if (!asked.isCompleted) asked.complete();
      await gate.future;
    }
    return executor.runSelect(statement, args);
  }
}

/// What every outbox drain waits for in these tests
/// ([outboxDrainGateProvider]): closed until [open], then open for good.
final class _DrainGate {
  final Completer<void> _opened = Completer<void>();

  Future<void> wait() => _opened.future;

  void open() {
    if (!_opened.isCompleted) _opened.complete();
  }
}
