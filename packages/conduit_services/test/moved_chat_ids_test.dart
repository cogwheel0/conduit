@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:conduit_core/database/database_provider.dart'
    show openWebUiCertifiedDatabaseServerProvider;
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_core/sync/sync_engine.dart' show syncEngineProvider;
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduit_services/conduit_services.dart';
import 'package:test/test.dart';

import 'support/core.dart';
import 'support/fake_owui_auth_server.dart';
import 'support/scripted_openai.dart';
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

  setUp(() async {
    heard = <EventEnvelope>[];
    temporary = Directory.systemTemp.createTempSync('moved-chat-ids');
    addTearDown(() => temporary.deleteSync(recursive: true));
    runtime = await startTestCore(temporary);
    addTearDown(runtime.dispose);
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
    turns = TurnsService(runtime.container, events);
    addTearDown(turns.dispose);
    accounts = AccountsService(runtime.container, events: events, turns: turns);
    addTearDown(accounts.dispose);
    auth = AuthService(runtime.container);
    addTearDown(auth.dispose);
    chats = ChatsService(runtime.container, events: events)..turns = turns;
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

  /// [chatId]'s turn's end, as heard already or once it is.
  Future<void> finished(String chatId) {
    bool ends(EventEnvelope e) =>
        e.event == ConduitEvents.turnFinished && e.payload['chatId'] == chatId;
    if (heard.any(ends)) return Future<void>.value();
    final done = Completer<void>();
    events.attach('finished-$chatId', (e) {
      if (ends(e) && !done.isCompleted) done.complete();
    });
    return done.future;
  }

  /// A chat with one question and its answer, made here and then stored by
  /// the server: its old `local:` id and the server's.
  Future<(String, String)> movedChat() async {
    final accepted = await turns.send(
      SendTurn(model: model, text: 'Which shelf?'),
    );
    final old = accepted.chatId;
    subscribeWindow(events, turns, 'window', <String>[old]);
    await finished(old);
    final moved = Completer<String>();
    events.attach('remap-$old', (e) {
      if (e.event == ConduitEvents.routeRemap &&
          e.payload['fromId'] == old &&
          !moved.isCompleted) {
        moved.complete('${e.payload['toId']}');
      }
    });
    await runtime.container.read(syncEngineProvider.notifier).drainNow();
    final now = await moved.future;
    expect(now, isNot(old));
    return (old, now);
  }

  test('a chat asked for by its old id answers with its transcript, under '
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

  test('a rename and a delete by the old id land on the moved chat', () async {
    await signIn('ada@example.com', 'pw-ada');
    final (old, now) = await movedChat();

    await chats.rename(old, 'The shelf question');
    expect((await chats.get(now))!.summary.title, 'The shelf question');

    await chats.delete(old);
    expect((await chats.list()).chats.map((c) => c.id), isNot(contains(now)));
  });

  test('a send by the old id continues the moved chat, and makes no other',
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

  test('another account never takes a chat by an old id of the last one\'s',
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
}
