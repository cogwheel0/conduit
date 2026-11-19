@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

import 'support/local_owui.dart';
import 'support/null_sink.dart';

/// `intents.*` against a local Open WebUI with synthetic data (start and
/// seed it with `tool/local_owui/owui.sh up`; without its env file this is
/// skipped): Ask Conduit through the real turn pipeline, and Open Chat's
/// list from the account's chats.
///
/// The fake model answers "... the word: X" with X, and a request for a
/// reasoned answer with a reasoning block first.
void main() {
  final credentials = LocalOwui.read();

  group(
    'intents against a local Open WebUI',
    skip: credentials == null
        ? 'no local Open WebUI env file (tool/local_owui/owui.sh up)'
        : null,
    () {
      late Directory temporary;
      late CoreRuntime runtime;
      late EventBus events;
      late TurnsService turns;
      late ChatsService chats;
      late IntentsService intents;
      final created = <String>{};

      setUpAll(() async {
        temporary = Directory.systemTemp.createTempSync('conduitd-intents');
        runtime = await CoreRuntime.start(
          config: BootstrapConfig(
            sessionToken: 'a' * 43,
            masterKey: base64.encode(List<int>.generate(32, (i) => i)),
            userDataDir: temporary.path,
          ),
          directories: DaemonDirectories.create(temporary.path),
          log: DaemonLog(level: 'error', sink: NullSink()),
        );
        final auth = AuthService(runtime.container);
        final accounts = AccountsService(runtime.container, events: EventBus());
        await auth.status();
        await accounts.list();
        await accounts.add(
          AddAccount(
            server: ServerDraft(name: 'Live', url: credentials!.url),
          ),
        );
        final signedIn = await auth.loginWithPassword(
          PasswordLogin(
            username: credentials.email,
            password: credentials.password,
          ),
        );
        expect(signedIn.isAuthenticated, isTrue);
        events = EventBus();
        turns = TurnsService(runtime.container, events);
        chats = ChatsService(runtime.container, events: events);
        intents = IntentsService.over(
          turns: turns,
          chats: chats,
          events: events,
        );
      });

      tearDownAll(() async {
        await turns.dispose();
        // The account keeps its seed: the chats made here go.
        final api = runtime.container.read(apiServiceProvider);
        for (final id in created.where((id) => !id.startsWith('local:'))) {
          try {
            await api?.deleteConversation(id);
          } on Object catch (error) {
            stderr.writeln('could not delete test chat $id: $error');
          }
        }
        await runtime.dispose();
        temporary.deleteSync(recursive: true);
      });

      test('asks, and gives back the answer and its chat', () async {
        final answer = await intents.ask(
          IntentAsk(
            text: 'Reply with exactly the word: osprey',
            model: credentials!.model,
          ),
        );
        created.add(answer.chatId);
        expect(answer.outcome, IntentAskOutcome.answered, reason: '$answer');
        expect(answer.text.trim(), 'osprey');
        expect(answer.chatId, isNotEmpty);

        // The chat is the account's: Open Chat's list has it.
        final recent = await intents.chats(const IntentChatsQuery());
        expect(recent.chats.map((c) => c.id), contains(answer.chatId));
        final byId = await intents.chats(
          IntentChatsQuery(ids: <String>[answer.chatId, 'no-such-chat']),
        );
        expect(byId.chats.map((c) => c.id), <String>[answer.chatId]);
      }, timeout: const Timeout(Duration(minutes: 3)));

      test('leaves the reasoning out, as Copy does', () async {
        final answer = await intents.ask(
          IntentAsk(
            text: 'Give a reasoned answer, please',
            model: credentials!.model,
          ),
        );
        created.add(answer.chatId);
        expect(answer.outcome, IntentAskOutcome.answered, reason: '$answer');
        expect(answer.text, contains('Hello from the fake model'));
        expect(answer.text, isNot(contains('synthetic planet')));
        expect(answer.text, isNot(contains('<details')));
      }, timeout: const Timeout(Duration(minutes: 3)));

      test("a refused answer carries the server's words", () async {
        final answer = await intents.ask(
          IntentAsk(
            text: 'Reply with exactly the word: refused',
            model: credentials!.refusedModel,
          ),
        );
        created.add(answer.chatId);
        expect(answer.outcome, IntentAskOutcome.failed, reason: '$answer');
        expect(answer.chatId, isNotEmpty);
      }, timeout: const Timeout(Duration(minutes: 3)));
    },
  );
}
