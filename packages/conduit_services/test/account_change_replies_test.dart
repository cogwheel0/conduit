@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:conduit_core/database/database_provider.dart'
    show openWebUiCertifiedDatabaseServerProvider;
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_core/models/model.dart' show Model;
import 'package:conduit_core/providers/app_providers.dart' show modelsProvider;
import 'package:conduit_core/sync/sync_engine.dart' show syncEngineProvider;
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduit_services/conduit_services.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import 'support/core.dart';
import 'support/fake_hermes_server.dart';
import 'support/fake_owui_auth_server.dart';
import 'support/scripted_openai.dart';
import 'support/window.dart';

/// A reply streaming while the Open WebUI account changes: a chat the
/// account does not own (Direct kept on this device, Hermes) stays open and
/// its reply runs to the end; a chat the account owns closes, its reply
/// ending as stopped with the words that came. Each case has a daemon of its
/// own.
void main() {
  late Directory temporary;
  late CoreRuntime runtime;
  late FakeOwuiAuthServer owui;
  late ScriptedOpenAi provider;
  late FakeHermesServer hermesServer;
  late EventBus events;
  late HermesService hermes;
  late TurnsService turns;
  late AccountsService accounts;
  late AuthService auth;
  late ChatsService chats;
  late DirectService direct;
  late String directModel;
  late List<EventEnvelope> heard;
  late Map<String, Completer<TurnFinished>> finishing;
  late List<(String, String, Completer<void>)> awaitedText;
  late List<String> windowScopes;

  setUp(() async {
    heard = <EventEnvelope>[];
    finishing = <String, Completer<TurnFinished>>{};
    awaitedText = <(String, String, Completer<void>)>[];
    windowScopes = <String>[];
    temporary = Directory.systemTemp.createTempSync('account-change-replies');
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
    provider = await ScriptedOpenAi.start();
    addTearDown(provider.close);
    hermesServer = await FakeHermesServer.start();
    addTearDown(hermesServer.close);
    events = EventBus();
    events.attach('window', (envelope) {
      heard.add(envelope);
      final chatId = envelope.payload['chatId'];
      if (envelope.event == ConduitEvents.turnFinished) {
        finishing
            .remove(chatId)
            ?.complete(TurnFinished.fromJson(envelope.payload));
      }
      if (envelope.event == ConduitEvents.turnDelta) {
        final text = '${envelope.payload['text']}'.trim();
        awaitedText.removeWhere((waiter) {
          final (id, words, done) = waiter;
          if (id != chatId || text != words) return false;
          done.complete();
          return true;
        });
      }
    });
    hermes = HermesService(runtime.container, events: events);
    turns = TurnsService(runtime.container, events, hermes: hermes);
    addTearDown(turns.dispose);
    accounts = AccountsService(runtime.container, events: events, turns: turns);
    addTearDown(accounts.dispose);
    auth = AuthService(runtime.container);
    addTearDown(auth.dispose);
    chats = ChatsService(
      runtime.container,
      events: events,
      hermes: hermes,
      temporary: turns.temporary,
    );
    addTearDown(chats.dispose);
    direct = DirectService(runtime.container);
    final saved = await direct.save(
      DirectConnectionEdit(
        name: 'Scripted',
        kind: DirectKind.openai,
        baseUrl: provider.baseUrl,
        manualModelIds: const <String>['scripted-model'],
      ),
    );
    directModel = DirectModelId.encode(
      saved.connections.single.id,
      'scripted-model',
    );
  });

  /// [chatId]'s turn's end: as heard already, or once it is.
  Future<TurnFinished> finished(String chatId) {
    for (final e in heard) {
      if (e.event == ConduitEvents.turnFinished &&
          e.payload['chatId'] == chatId) {
        return Future<TurnFinished>.value(TurnFinished.fromJson(e.payload));
      }
    }
    return finishing.putIfAbsent(chatId, Completer<TurnFinished>.new).future;
  }

  void follow(String chatId) {
    windowScopes.add(chatId);
    subscribeWindow(events, turns, 'window', List<String>.of(windowScopes));
  }

  /// Sends [turn] and returns its chat once the window has been told
  /// [words], all of the answer before the provider holds it.
  Future<String> sendUntil(SendTurn turn, String words) async {
    final accepted = await turns.send(turn);
    final shown = Completer<void>();
    awaitedText.add((accepted.chatId, words, shown));
    follow(accepted.chatId);
    await shown.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () => throw StateError(
        'never told "$words": ${[
          for (final e in heard)
            if (e.payload['chatId'] == accepted.chatId)
              '${e.event} ${e.payload['text']}',
        ]}',
      ),
    );
    return accepted.chatId;
  }

  List<String> told(String chatId) => <String>[
    for (final e in heard)
      if (e.payload['chatId'] == chatId &&
          (e.event == ConduitEvents.turnCompleted ||
              e.event == ConduitEvents.turnFailed ||
              e.event == ConduitEvents.turnFinished))
        <Object?>[
          e.event,
          e.payload['code'],
          e.payload['text'] ?? e.payload['partialText'],
        ].where((part) => part != null && part != '').join(' ').trim(),
  ];

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

  /// Adds an account for [email] and signs in to it; its id.
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

  /// Signs in again to the account in use: a new session for it.
  Future<void> signInAgain(String email, String password) async {
    await auth.loginWithPassword(
      PasswordLogin(username: email, password: password),
    );
    await certified((await accounts.list()).activeAccountId!);
  }

  /// The id [chatId] goes by once the server stores it: the `route.remap`
  /// the windows follow, as heard already or once it is.
  Future<String> remapped(String chatId) async {
    for (final e in heard) {
      if (e.event == ConduitEvents.routeRemap &&
          e.payload['fromId'] == chatId) {
        return '${e.payload['toId']}';
      }
    }
    final told = Completer<String>();
    events.attach('remap-$chatId', (envelope) {
      if (envelope.event == ConduitEvents.routeRemap &&
          envelope.payload['fromId'] == chatId &&
          !told.isCompleted) {
        told.complete('${envelope.payload['toId']}');
      }
    });
    return told.future;
  }

  Future<ChatMessageDto> storedAnswer(String chatId) async =>
      (await chats.get(chatId))!.messages.lastWhere(
        (m) => m.role == 'assistant',
      );

  test('a Direct reply in a chat kept on this device runs to the end across '
      'a first sign-in, and the chat keeps it', () async {
    final chatId = await sendUntil(
      SendTurn(model: directModel, text: 'hold:first Some words so far'),
      'Some words so far',
    );

    await signIn('ada@example.com', 'pw-ada');
    expect(told(chatId), isEmpty, reason: 'the turn must still be running');
    expect(turns.activeChatIds, contains(chatId));

    final done = finished(chatId);
    provider.release('first');
    expect((await done).ok, isTrue);
    expect(told(chatId), <String>[
      'turn.completed Some words so far',
      'turn.finished',
    ]);
    final answer = await storedAnswer(chatId);
    expect(answer.content.trim(), 'Some words so far');
    expect(answer.streaming, isFalse);
  });

  test('a switch asks nothing of a Direct reply in a chat kept on this '
      'device, and the reply runs to the end', () async {
    final ada = await signIn('ada@example.com', 'pw-ada');
    final bob = await signIn('bob@example.com', 'pw-bob');
    await accounts.switchTo(AccountRef(accountId: ada));
    await certified(ada);
    await direct.setHistory(localOnly: true);
    final chatId = await sendUntil(
      SendTurn(model: directModel, text: 'hold:kept Kept on this Mac'),
      'Kept on this Mac',
    );

    final switched = await accounts.switchTo(AccountRef(accountId: bob));
    expect(switched.outcome, AccountChangeOutcome.done);
    await certified(bob);
    expect(told(chatId), isEmpty, reason: 'the turn must still be running');

    final done = finished(chatId);
    provider.release('kept');
    expect((await done).ok, isTrue);
    expect((await storedAnswer(chatId)).content.trim(), 'Kept on this Mac');
  });

  test('Switch Anyway with a Direct reply in a chat Ada\'s account keeps '
      'stops it first, keeping the words that came', () async {
    // Serves chats and a socket: the chat syncs to the server's id, so its
    // scope keeps its transcript as the switched-back account's socket
    // binds, and the window is told the words the run has taken in.
    owui.models = const <String>['harbor-model'];
    final ada = await signIn('ada@example.com', 'pw-ada');
    final bob = await signIn('bob@example.com', 'pw-bob');
    await accounts.switchTo(AccountRef(accountId: ada));
    await certified(ada);
    final chatId = await sendUntil(
      SendTurn(model: directModel, text: 'hold:third Part of it'),
      'Part of it',
    );

    final blocked = await accounts.switchTo(AccountRef(accountId: bob));
    expect(blocked.outcome, AccountChangeOutcome.blockedByActiveReply);
    final forced = await accounts.switchTo(
      AccountRef(accountId: bob, force: true, askedOver: ada),
    );
    expect(forced.outcome, AccountChangeOutcome.done);
    expect(told(chatId), <String>['turn.completed Part of it', 'turn.finished']);

    await accounts.switchTo(AccountRef(accountId: ada));
    await certified(ada);
    // Synced to the server meanwhile, the chat goes by the server's id now.
    final listed = (await chats.list()).chats;
    final answer = await storedAnswer(listed.single.id);
    expect(answer.content.trim(), 'Part of it');
    expect(answer.streaming, isFalse);
  });

  test('signing in again while a Direct reply streams in a chat the account '
      'keeps closes it as session expired with the words that came, though '
      'the chat shows its stopped answer first', () async {
    // Serves chats and a socket: the chat syncs to the server's id, and its
    // scope keeps its transcript, the stopped answer in it, as the change
    // comes.
    owui.models = const <String>['harbor-model'];
    await signIn('ada@example.com', 'pw-ada');
    final chatId = await sendUntil(
      SendTurn(model: directModel, text: 'hold:fourth Still going'),
      'Still going',
    );

    final done = finished(chatId);
    await signInAgain('ada@example.com', 'pw-ada');
    final ended = await done;
    expect(ended.ok, isFalse);
    expect(ended.code, ConduitErrorCodes.sessionExpired);
    expect(told(chatId), <String>[
      'turn.failed ${ConduitErrorCodes.sessionExpired} Still going',
      'turn.finished ${ConduitErrorCodes.sessionExpired}',
    ]);
    // The chat reaches the server and moves to its id, as a sync can do at
    // any moment; the answer is read where the windows follow it to.
    final moved = remapped(chatId);
    await runtime.container.read(syncEngineProvider.notifier).drainNow();
    final answer = await storedAnswer(await moved);
    expect(answer.content.trim(), 'Still going');
    expect(answer.streaming, isFalse);
  });

  test('a Hermes reply runs to the end when the account signs in again, and '
      'its chat keeps it', () async {
    await signIn('ada@example.com', 'pw-ada');
    final offered = Completer<Model>();
    final watch = runtime.container.listen<AsyncValue<List<Model>>>(
      modelsProvider,
      (_, next) {
        final agent = next.value
            ?.where((m) => m.id.startsWith('hermes:agent:'))
            .firstOrNull;
        if (agent != null && !offered.isCompleted) offered.complete(agent);
      },
      fireImmediately: true,
    );
    addTearDown(watch.close);
    await hermes.saveSettings(
      HermesSettingsEdit(
        baseUrl: hermesServer.baseUrl,
        apiKey: hermesServer.key,
      ),
    );
    final agent = await offered.future;
    final chatId = await sendUntil(
      SendTurn(model: agent.id, text: 'hold:herm Echo of the tide'),
      'Echo',
    );

    await signInAgain('ada@example.com', 'pw-ada');
    expect(told(chatId), isEmpty, reason: 'the turn must still be running');

    final done = finished(chatId);
    hermesServer.release('herm');
    expect((await done).ok, isTrue);
    expect(told(chatId).first, 'turn.completed Echo of the tide');
    final answer = await storedAnswer(chatId);
    expect(answer.content.trim(), 'Echo of the tide');
    expect(answer.streaming, isFalse);
  });

  test('a temporary Direct chat stays readable across an account change, and '
      'a temporary Open WebUI chat does not', () async {
    owui.models = const <String>['harbor-model'];
    await signIn('ada@example.com', 'pw-ada');
    final kept = await turns.send(
      SendTurn(model: directModel, text: 'A note to self', temporary: true),
    );
    final server = await turns.send(
      SendTurn(model: 'harbor-model', text: 'Kettle?', temporary: true),
    );
    follow(kept.chatId);
    follow(server.chatId);
    await Future.wait(<Future<void>>[
      finished(kept.chatId),
      finished(server.chatId),
    ]);

    await signInAgain('ada@example.com', 'pw-ada');

    final readable = await chats.get(kept.chatId);
    expect(readable?.temporary, isTrue);
    expect(
      readable!.messages.lastWhere((m) => m.role == 'assistant').content,
      contains('A note to self'),
    );
    final gone = await chats.get(server.chatId);
    expect(gone?.messages ?? const <ChatMessageDto>[], isEmpty);
  });

  test('a temporary chat that had an Open WebUI answer before a Direct one '
      'is the account\'s: an account change closes and forgets it', () async {
    owui.models = const <String>['harbor-model'];
    await signIn('ada@example.com', 'pw-ada');
    final first = await turns.send(
      SendTurn(model: 'harbor-model', text: 'Kettle?', temporary: true),
    );
    final chatId = first.chatId;
    follow(chatId);
    await finished(chatId);
    finishing.remove(chatId);
    heard.removeWhere(
      (e) =>
          e.event == ConduitEvents.turnFinished &&
          e.payload['chatId'] == chatId,
    );
    final second = await turns.send(
      SendTurn(model: directModel, text: 'And the tea?', chatId: chatId),
    );
    expect(second.chatId, chatId);
    await finished(chatId);
    // Both answers are in the chat: the mix is one the send path allows.
    expect(
      turns.openMessages(chatId)!.where((m) => m.role == 'assistant'),
      hasLength(2),
    );

    await signInAgain('ada@example.com', 'pw-ada');
    await pumpEventQueue();

    expect(turns.temporary.contains(chatId), isFalse);
    final gone = await chats.get(chatId);
    expect(gone?.messages ?? const <ChatMessageDto>[], isEmpty);
  });
}
