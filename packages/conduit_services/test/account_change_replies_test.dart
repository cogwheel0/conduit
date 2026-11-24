@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:conduit_core/database/database_provider.dart'
    show openWebUiCertifiedDatabaseServerProvider;
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduit_services/conduit_services.dart';
import 'package:test/test.dart';

import 'support/core.dart';
import 'support/fake_hermes_server.dart';
import 'support/fake_owui_auth_server.dart';
import 'support/scripted_openai.dart';
import 'support/window.dart';

/// A reply streaming while the Open WebUI account changes: a chat the
/// account does not own (Direct kept on this device, Hermes) stays open and
/// its reply runs to the end; a chat the account owns closes, its reply
/// ending as stopped with the words that came.
///
/// One daemon for the file, tests in order: `PreferencesStore` and Hive are
/// process-wide.
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
  late String directModel;
  final heard = <EventEnvelope>[];
  final finishing = <String, Completer<TurnFinished>>{};
  final windowScopes = <String>[];

  setUpAll(() async {
    temporary = Directory.systemTemp.createTempSync('account-change-replies');
    runtime = await startTestCore(temporary);
    owui = await FakeOwuiAuthServer.start(
      users: const {
        'ada@example.com': (id: 'user-ada', name: 'Ada', password: 'pw-ada'),
        'bob@example.com': (id: 'user-bob', name: 'Bob', password: 'pw-bob'),
      },
    );
    provider = await ScriptedOpenAi.start();
    hermesServer = await FakeHermesServer.start();
    events = EventBus();
    events.attach('window', (envelope) {
      heard.add(envelope);
      if (envelope.event == ConduitEvents.turnFinished) {
        final finished = TurnFinished.fromJson(envelope.payload);
        finishing.remove(finished.chatId)?.complete(finished);
      }
    });
    hermes = HermesService(runtime.container, events: events);
    turns = TurnsService(runtime.container, events, hermes: hermes);
    accounts = AccountsService(runtime.container, events: events, turns: turns);
    auth = AuthService(runtime.container);
    chats = ChatsService(runtime.container, events: events, hermes: hermes);
    final saved = await DirectService(runtime.container).save(
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

  tearDownAll(() async {
    accounts.dispose();
    await turns.dispose();
    chats.dispose();
    await provider.close();
    await hermesServer.close();
    await owui.close();
    await runtime.dispose();
    temporary.deleteSync(recursive: true);
  });

  void follow(String chatId) {
    windowScopes.add(chatId);
    subscribeWindow(events, turns, 'window', List<String>.of(windowScopes));
  }

  Future<TurnFinished> finished(String chatId) =>
      finishing.putIfAbsent(chatId, Completer<TurnFinished>.new).future;

  List<String> told(String chatId, {int from = 0}) => <String>[
    for (final e in heard.skip(from))
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

  Future<String> activeAccount() async =>
      (await accounts.list()).activeAccountId!;

  Future<ChatMessageDto> storedAnswer(String chatId) async =>
      (await chats.get(chatId))!.messages.lastWhere(
        (m) => m.role == 'assistant',
      );

  late String adaAccount;
  late String bobAccount;

  test('a Direct reply in a chat kept on this device runs to the end across '
      'a first sign-in, and the chat keeps it', () async {
    final asked = provider.asked('hold:first');
    final accepted = await turns.send(
      SendTurn(model: directModel, text: 'hold:first Some words so far'),
    );
    final chatId = accepted.chatId;
    follow(chatId);
    await asked;

    await accounts.add(
      AddAccount(server: ServerDraft(name: 'Lab', url: owui.url), force: true),
    );
    await auth.loginWithPassword(
      const PasswordLogin(username: 'ada@example.com', password: 'pw-ada'),
    );
    adaAccount = await activeAccount();
    await certified(adaAccount);
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

  test('Switch Anyway with a Direct reply in a chat Ada\'s account keeps '
      'stops it first, keeping the words that came', () async {
    await accounts.add(
      AddAccount(server: ServerDraft(name: 'Lab', url: owui.url), force: true),
    );
    await auth.loginWithPassword(
      const PasswordLogin(username: 'bob@example.com', password: 'pw-bob'),
    );
    bobAccount = await activeAccount();
    await certified(bobAccount);
    await accounts.switchTo(AccountRef(accountId: adaAccount));
    await certified(adaAccount);

    final asked = provider.asked('hold:third');
    final accepted = await turns.send(
      SendTurn(model: directModel, text: 'hold:third Part of it'),
    );
    final chatId = accepted.chatId;
    follow(chatId);
    await asked;
    while (!provider.steps.contains('third holding')) {
      await pumpEventQueue();
    }
    final blocked = await accounts.switchTo(AccountRef(accountId: bobAccount));
    expect(blocked.outcome, AccountChangeOutcome.blockedByActiveReply);
    final forced = await accounts.switchTo(
      AccountRef(accountId: bobAccount, force: true, askedOver: adaAccount),
    );
    expect(forced.outcome, AccountChangeOutcome.done);
    expect(told(chatId), <String>['turn.completed Part of it', 'turn.finished']);

    await accounts.switchTo(AccountRef(accountId: adaAccount));
    await certified(adaAccount);
    final answer = await storedAnswer(chatId);
    expect(answer.content.trim(), 'Part of it');
    expect(answer.streaming, isFalse);
  });

  test('signing in again while a Direct reply streams in a chat the account '
      'keeps closes it as session expired, keeping the words that came', () async {
    final asked = provider.asked('hold:fourth');
    final accepted = await turns.send(
      SendTurn(model: directModel, text: 'hold:fourth Still going'),
    );
    final chatId = accepted.chatId;
    follow(chatId);
    await asked;
    while (!provider.steps.contains('fourth holding')) {
      await pumpEventQueue();
    }

    final done = finished(chatId);
    await auth.loginWithPassword(
      const PasswordLogin(username: 'ada@example.com', password: 'pw-ada'),
    );
    final ended = await done;
    expect(ended.ok, isFalse);
    expect(ended.code, ConduitErrorCodes.sessionExpired);
    expect(told(chatId), <String>[
      'turn.failed ${ConduitErrorCodes.sessionExpired} Still going',
      'turn.finished ${ConduitErrorCodes.sessionExpired}',
    ]);
    await certified(adaAccount);
    final answer = await storedAnswer(chatId);
    expect(answer.content.trim(), 'Still going');
    expect(answer.streaming, isFalse);
  });

  test('a Hermes reply runs to the end when the account signs in again, and '
      'its chat keeps it', () async {
    await hermes.saveSettings(
      HermesSettingsEdit(
        baseUrl: hermesServer.baseUrl,
        apiKey: hermesServer.key,
      ),
    );
    final models = ModelsService(runtime.container);
    ModelSummary? agent;
    while (agent == null) {
      agent = (await models.list()).models
          .where((m) => m.id.startsWith('hermes:agent:'))
          .firstOrNull;
      if (agent == null) await pumpEventQueue();
    }
    final held = hermesServer.runHeld('herm');
    final accepted = await turns.send(
      SendTurn(model: agent.id, text: 'hold:herm Echo of the tide'),
    );
    final chatId = accepted.chatId;
    follow(chatId);
    await held;

    await auth.loginWithPassword(
      const PasswordLogin(username: 'ada@example.com', password: 'pw-ada'),
    );
    await certified(adaAccount);
    expect(told(chatId), isEmpty, reason: 'the turn must still be running');

    final done = finished(chatId);
    hermesServer.release('herm');
    expect((await done).ok, isTrue);
    expect(told(chatId).first, 'turn.completed Echo of the tide');
    final answer = await storedAnswer(chatId);
    expect(answer.content.trim(), 'Echo of the tide');
    expect(answer.streaming, isFalse);
  });
}
