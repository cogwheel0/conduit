@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

import 'support/null_sink.dart';

/// Drives the daemon against a real Open WebUI server.
///
/// Skipped unless `OWUI_URL`, `OWUI_EMAIL` and `OWUI_PASSWORD` are set in a
/// `.env` at the repository root, so a clean clone and a CI job without a
/// server both pass. Nothing here logs a credential.
({String url, String email, String password})? _credentials() {
  final file = File('../../.env');
  if (!file.existsSync()) return null;
  final values = <String, String>{};
  for (final line in const LineSplitter().convert(file.readAsStringSync())) {
    final match = RegExp(r'^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$').firstMatch(line);
    if (match == null) continue;
    values[match.group(1)!] = match
        .group(2)!
        .replaceAll(RegExp('^["\']|["\']\$'), '');
  }
  final url = values['OWUI_URL'];
  final email = values['OWUI_EMAIL'];
  final password = values['OWUI_PASSWORD'];
  if (url == null || email == null || password == null) return null;
  return (url: url, email: email, password: password);
}

void main() {
  final credentials = _credentials();

  group(
    'against a real server',
    skip: credentials == null ? 'no OWUI_* credentials in .env' : null,
    () {
      late Directory temporary;
      late CoreRuntime runtime;
      late ServersService servers;
      late AuthService auth;
      late ModelsService models;

      setUpAll(() async {
        temporary = Directory.systemTemp.createTempSync('conduitd-live');
        final config = BootstrapConfig(
          sessionToken: 'a' * 43,
          masterKey: base64.encode(List<int>.generate(32, (i) => i)),
          userDataDir: temporary.path,
        );
        runtime = await CoreRuntime.start(
          config: config,
          directories: DaemonDirectories.create(temporary.path),
          log: DaemonLog(level: 'error', sink: NullSink()),
        );
        servers = ServersService(runtime.container);
        auth = AuthService(runtime.container);
        models = ModelsService(runtime.container);
      });

      // Every conversation a test creates on the real account, deleted
      // at the end. These tests run against someone's actual server. Before
      // this, each run left five or so "Say the word: alpha" chats in that
      // person's sidebar, and every future run added more.
      final created = <String>{};

      tearDownAll(() async {
        final api = runtime.container.read(apiServiceProvider);
        for (final id in created) {
          try {
            await api?.deleteConversation(id);
          } on Object catch (error) {
            // Reported, not thrown: a failed cleanup should not hide the
            // result of the tests that ran.
            stderr.writeln('could not delete test chat $id: $error');
          }
        }
        await runtime.dispose();
        temporary.deleteSync(recursive: true);
      });

      test('recognises the server', () async {
        // The renderer asks for these on load, before any server exists.
        // Reproducing that order matters: it is what builds the auth manager
        // for the first time.
        await auth.status();
        await servers.list();

        final added = await servers.add(
          ServerDraft(name: 'Live', url: credentials!.url),
        );
        await servers.connect(added.id);

        final status = await servers.status();
        expect(
          status.reachability,
          ServerReachability.reachable,
          reason: 'errorCode=${status.errorCode}',
        );
        expect(status.version, isNotNull);
      });

      test('signs in with a password', () async {
        final snapshot = await auth.loginWithPassword(
          PasswordLogin(
            username: credentials!.email,
            password: credentials.password,
          ),
        );
        expect(
          snapshot.isAuthenticated,
          isTrue,
          reason: 'phase=${snapshot.phase} code=${snapshot.errorCode}',
        );
        expect(snapshot.user?.name, isNotEmpty);
      });

      test('lists models', () async {
        final list = await models.list();
        expect(list.models, isNotEmpty);
        // This test hung often enough to look like a slow server, but the
        // server answers in about a second. The daemon read `modelsProvider`
        // without listening to it. Signing in certifies the account's
        // storage about 30 ms into that read, which invalidates the build,
        // and with no listener nothing ever rebuilt it. See `readSettled`.
      });

      test('renames, pins and deletes a conversation', () async {
        final chats = ChatsService(runtime.container);

        // Created through the API rather than by sending a turn, so this
        // does not depend on a model answering.
        final api = runtime.container.read(apiServiceProvider)!;
        final created = await api.createConversation(
          title: 'live-mutation-probe',
          messages: const <ChatMessage>[],
        );

        final renamed = await chats.rename(created.id, 'renamed by a test');
        expect(
          renamed.chats.where((c) => c.id == created.id).single.title,
          'renamed by a test',
        );

        final pinned = await chats.setPinned(created.id, value: true);
        expect(
          pinned.chats.where((c) => c.id == created.id).single.pinned,
          isTrue,
        );

        final afterDelete = await chats.delete(created.id);
        expect(
          afterDelete.chats.where((c) => c.id == created.id),
          isEmpty,
          reason: 'the deleted conversation should be gone from the list',
        );
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('search returns hits with sane timestamps', () async {
        final chats = ChatsService(runtime.container);
        // Pull first, so the FTS index has something to match.
        await chats.list();

        final results = await chats.search(
          const ChatSearchQuery(query: 'the', limit: 5),
        );
        for (final hit in results.hits) {
          expect(hit.chatId, isNotEmpty);
          // Epoch seconds passed through as milliseconds would land in 1970;
          // this is the assertion that catches the missing factor of 1000.
          expect(
            hit.updatedAtMs,
            greaterThan(DateTime(2020).millisecondsSinceEpoch),
            reason: 'timestamps should be milliseconds, not seconds',
          );
        }
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('rejects an empty title rather than clearing it', () async {
        final chats = ChatsService(runtime.container);
        expect(
          () => chats.rename('any-id', '   '),
          throwsA(
            isA<RpcError>().having(
              (e) => e.code,
              'code',
              ConduitErrorCodes.invalidParams,
            ),
          ),
        );
      });

      test(
        'reports a refused model as a failure, not an empty answer',
        () async {
          // This server's first model is paid-tier, which is a refusal the
          // helper reports by setting an error on the message and finishing --
          // not by throwing. Before this was wired up the daemon published
          // `turn.completed` with an empty string, so the user saw the model
          // answer nothing and had no idea why.
          final events = EventBus();
          final turns = TurnsService(runtime.container, events);
          addTearDown(turns.dispose);

          final seen = <String, Map<String, dynamic>>{};
          events.attach('probe', (e) => seen[e.event] = e.payload);

          final accepted = await turns.send(
            const SendTurn(model: 'google/gemma-4-31b-it', text: 'say pong'),
          );
          created.add(accepted.chatId);
          events.subscribe(
            'probe',
            EventSubscription(scopes: <String>[accepted.chatId]),
          );

          final deadline = DateTime.now().add(const Duration(seconds: 60));
          while (DateTime.now().isBefore(deadline) &&
              !seen.containsKey(ConduitEvents.turnFailed) &&
              !seen.containsKey(ConduitEvents.turnCompleted)) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }

          expect(
            seen.keys,
            contains(ConduitEvents.turnFailed),
            reason: 'saw ${seen.keys.toList()}',
          );
          final failed = TurnFailed.fromJson(seen[ConduitEvents.turnFailed]!);
          // The server's own explanation, which is the only actionable part.
          expect(failed.args['detail'], isNotEmpty);
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );

      test('sends a turn and streams an answer', () async {
        final events = EventBus();
        final turns = TurnsService(runtime.container, events);
        addTearDown(turns.dispose);

        final seen = <String>[];
        final payloads = <String, Map<String, dynamic>>{};
        events.attach('probe', (envelope) {
          seen.add(envelope.event);
          payloads[envelope.event] = envelope.payload;
        });

        final accepted = await turns.send(
          // Named explicitly: this server's first model is paid-tier, and the
          // daemon's fallback is "the first one offered".
          const SendTurn(
            model: 'gemma3:1b',
            text: 'Reply with exactly the word: pong',
          ),
        );
        created.add(accepted.chatId);
        expect(accepted.chatId, isNotEmpty);
        expect(accepted.assistantMessageId, isNotEmpty);

        // `turn.*` is scoped to the chat, and the chat id only exists once
        // the send returns -- which is exactly the window a renderer is in.
        // Nothing is lost by subscribing late: a delta carries the whole
        // content rather than an increment.
        events.subscribe(
          'probe',
          EventSubscription(scopes: <String>[accepted.chatId]),
        );

        // Wait for the turn to finish, or give up with what we saw.
        final deadline = DateTime.now().add(const Duration(seconds: 90));
        while (DateTime.now().isBefore(deadline) &&
            !seen.contains(ConduitEvents.turnCompleted)) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }

        expect(
          seen,
          contains(ConduitEvents.turnCompleted),
          reason: 'events seen: $seen',
        );
        final completed = TurnCompleted.fromJson(
          payloads[ConduitEvents.turnCompleted]!,
        );
        // The answer itself, which is the only thing that proves the stream
        // reached the daemon rather than merely finishing.
        expect(
          completed.text.trim(),
          isNotEmpty,
          reason: 'empty answer; events seen: $seen',
        );
        // A real model answering a real prompt over a real network.
      }, timeout: const Timeout(Duration(minutes: 3)));

      test('opens an existing conversation with its transcript', () async {
        // The bug this pins: `conversationsProvider` is the sidebar's list,
        // and its rows are envelopes with no message bodies. Reading
        // `.messages` off one gave an empty transcript for every chat not
        // created in this session -- so the app could list two hundred
        // conversations and open none of them -- and sent every follow-up
        // to the model with no memory of the conversation it was in.
        final chats = ChatsService(runtime.container);
        final list = await chats.list();
        final existing = list.chats.firstWhere(
          (chat) => !chat.archived,
          orElse: () => throw StateError('this account has no conversations'),
        );

        final detail = await chats.get(existing.id);
        expect(detail, isNotNull);
        expect(
          detail!.messages,
          isNotEmpty,
          reason: 'opened ${existing.id} and it had no messages',
        );
        // A transcript, not a single row: any real conversation has both
        // sides of at least one exchange.
        expect(
          detail.messages.map((m) => m.role).toSet(),
          containsAll(<String>['user', 'assistant']),
        );
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('regenerates an answer as a branch, not an overwrite', () async {
        final events = EventBus();
        final turns = TurnsService(runtime.container, events);
        addTearDown(turns.dispose);

        final accepted = await turns.send(
          const SendTurn(model: 'gemma3:1b', text: 'Say the word: alpha'),
        );
        created.add(accepted.chatId);

        final seen = <String>[];
        final payloads = <String, Map<String, dynamic>>{};
        events.attach('probe', (envelope) {
          seen.add(envelope.event);
          payloads[envelope.event] = envelope.payload;
        });
        events.subscribe(
          'probe',
          EventSubscription(scopes: <String>[accepted.chatId]),
        );
        await _waitFor(
          () => seen.contains(ConduitEvents.turnCompleted),
          seconds: 90,
        );
        expect(seen, contains(ConduitEvents.turnCompleted));

        // The synced conversation is what `regenerate` reads to find the
        // answer and its prompt, so the pull has to have landed first.
        await _waitFor(
          () async => (await _messagesOf(
            runtime,
            accepted.chatId,
          )).any((m) => m.id == accepted.assistantMessageId),
          seconds: 60,
        );

        final before = await _messagesOf(runtime, accepted.chatId);
        seen.clear();
        final again = await turns.regenerate(
          RegenerateTurn(
            chatId: accepted.chatId,
            messageId: accepted.assistantMessageId,
          ),
        );

        // A new answer, hung beside the old one rather than replacing it.
        expect(again.assistantMessageId, isNot(accepted.assistantMessageId));
        // And answering the same prompt, which is what makes it a redo
        // rather than a new turn.
        expect(again.userMessageId, accepted.userMessageId);

        await _waitFor(
          () =>
              seen.contains(ConduitEvents.turnCompleted) ||
              seen.contains(ConduitEvents.turnFailed),
          seconds: 90,
        );
        expect(
          seen,
          contains(ConduitEvents.turnCompleted),
          reason: 'events after regenerate: $seen, payloads: $payloads',
        );

        // Nothing was deleted: the server owns which child is current, and
        // a user who prefers the first answer has not lost it.
        final after = await _messagesOf(runtime, accepted.chatId);
        expect(after.length, greaterThanOrEqualTo(before.length));

        // And the first answer is *reachable*: `chats.get` returns it as a
        // version of the new one, which is what the renderer's arrows use.
        final chats = ChatsService(runtime.container);
        ChatMessageDto? answer;
        await _waitFor(() async {
          runtime.container.invalidate(
            loadConversationProvider(accepted.chatId),
          );
          final detail = await chats.get(accepted.chatId);
          answer = detail?.messages
              .where((m) => m.role == 'assistant')
              .lastOrNull;
          return answer != null && answer!.versions.isNotEmpty;
        }, seconds: 60);
        expect(
          answer?.versions.map((v) => v.id),
          contains(accepted.assistantMessageId),
          reason: 'the regenerated-away answer should be a version',
        );
      }, timeout: const Timeout(Duration(minutes: 5)));

      test('a sent chat is listed under the id the send returned', () async {
        // The renderer selects a new chat by the id `turns.send` returns and
        // highlights the sidebar row whose id matches. If the two id spaces
        // differ, the open conversation is never highlighted, and it can
        // look as though it is missing from the list.
        final events = EventBus();
        final turns = TurnsService(runtime.container, events);
        addTearDown(turns.dispose);
        final seen = <String>[];
        events.attach('probe', (envelope) => seen.add(envelope.event));
        final accepted = await turns.send(
          const SendTurn(model: 'gemma3:1b', text: 'Say the word: epsilon'),
        );
        created.add(accepted.chatId);
        events.subscribe(
          'probe',
          EventSubscription(scopes: <String>[accepted.chatId]),
        );
        await _waitFor(
          () => seen.contains(ConduitEvents.chatsChanged),
          seconds: 90,
        );

        final chats = ChatsService(runtime.container);
        // Regenerating keeps it first: it is still the conversation most
        // recently touched.
        seen.clear();
        await turns.regenerate(
          RegenerateTurn(
            chatId: accepted.chatId,
            messageId: accepted.assistantMessageId,
          ),
        );
        await _waitFor(
          () => seen.contains(ConduitEvents.chatsChanged),
          seconds: 90,
        );
        final list = await chats.list();
        final ids = list.chats.map((c) => c.id).toList();
        printOnFailure('first ids: ${ids.take(5).toList()}');
        printOnFailure('accepted: ${accepted.chatId}');
        expect(ids, contains(accepted.chatId));
        // And first: it is the most recently touched conversation.
        expect(
          list.chats.where((c) => !c.pinned).first.id,
          accepted.chatId,
          reason:
              'order: ${list.chats.take(5).map((c) => '${c.id}@${c.updatedAtMs}').toList()}',
        );
      }, timeout: const Timeout(Duration(minutes: 3)));

      test('edits a question as a new branch, keeping the old one', () async {
        final events = EventBus();
        final turns = TurnsService(runtime.container, events);
        addTearDown(turns.dispose);
        final seen = <String>[];
        events.attach('probe', (envelope) => seen.add(envelope.event));

        final accepted = await turns.send(
          const SendTurn(model: 'gemma3:1b', text: 'Say the word: gamma'),
        );
        created.add(accepted.chatId);
        events.subscribe(
          'probe',
          EventSubscription(scopes: <String>[accepted.chatId]),
        );
        await _waitFor(
          () => seen.contains(ConduitEvents.chatsChanged),
          seconds: 90,
        );

        seen.clear();
        final edited = await turns.edit(
          EditTurn(
            chatId: accepted.chatId,
            messageId: accepted.userMessageId,
            text: 'Say the word: delta',
          ),
        );
        expect(edited.userMessageId, isNot(accepted.userMessageId));
        await _waitFor(
          () => seen.contains(ConduitEvents.chatsChanged),
          seconds: 90,
        );

        // The conversation now reads as the edited question and its
        // answer...
        final after = await _messagesOf(runtime, accepted.chatId);
        expect(
          after.where((m) => m.role == 'user').map((m) => m.content),
          <String>['Say the word: delta'],
        );

        // ...and the original question and its answer are still on the
        // server, which is what makes this a branch and not an overwrite.
        final api = runtime.container.read(apiServiceProvider)!;
        final raw = await api.getChatRaw(accepted.chatId);
        final chat = (raw?['chat'] as Map?) ?? raw;
        final messages =
            ((chat?['history'] as Map?)?['messages'] as Map?) ?? const {};
        expect(messages.keys, contains(accepted.userMessageId));
        expect(messages.keys, contains(accepted.assistantMessageId));
        expect(
          (chat?['history'] as Map?)?['currentId'],
          edited.assistantMessageId,
        );
      }, timeout: const Timeout(Duration(minutes: 5)));

      test(
        'a temporary chat remembers itself and the server never sees it',
        () async {
          final events = EventBus();
          final temporary = TemporaryChats();
          final turns = TurnsService(
            runtime.container,
            events,
            temporary: temporary,
          );
          final chats = ChatsService(runtime.container, temporary: temporary);
          addTearDown(turns.dispose);
          final seen = <String>[];
          events.attach('probe', (envelope) => seen.add(envelope.event));

          final first = await turns.send(
            const SendTurn(
              model: 'gemma3:1b',
              text: 'My favourite colour is teal. Reply with just: noted.',
              temporary: true,
            ),
          );
          expect(first.chatId, startsWith('local:'));
          events.subscribe(
            'probe',
            EventSubscription(scopes: <String>[first.chatId]),
          );
          await _waitFor(
            () => seen.contains(ConduitEvents.turnCompleted),
            seconds: 90,
          );

          // The second turn has to carry the first, or the model cannot know
          // the colour. Nothing but the daemon's memory holds it.
          seen.clear();
          await turns.send(
            SendTurn(
              chatId: first.chatId,
              model: 'gemma3:1b',
              text: 'What is my favourite colour? Reply with one word.',
            ),
          );
          await _waitFor(
            () => seen.contains(ConduitEvents.turnCompleted),
            seconds: 90,
          );

          final detail = await chats.get(first.chatId);
          expect(detail!.messages, hasLength(4));
          expect(detail.messages.last.content.toLowerCase(), contains('teal'));

          // And the server has no such chat. Temporary has to mean it.
          final list = await chats.list();
          expect(list.chats.map((c) => c.id), isNot(contains(first.chatId)));
        },
        timeout: const Timeout(Duration(minutes: 5)),
      );

      test('refuses to regenerate a message that is not an answer', () async {
        final events = EventBus();
        final turns = TurnsService(runtime.container, events);
        addTearDown(turns.dispose);

        final seen = <String>[];
        events.attach('probe', (envelope) => seen.add(envelope.event));
        final accepted = await turns.send(
          const SendTurn(model: 'gemma3:1b', text: 'Say the word: beta'),
        );
        created.add(accepted.chatId);
        events.subscribe(
          'probe',
          EventSubscription(scopes: <String>[accepted.chatId]),
        );
        // The turn has to finish first, or `regenerate` refuses with
        // `conflict` -- correctly, since a chat may only generate once at a
        // time -- and never reaches the check this test is about.
        await _waitFor(
          () =>
              seen.contains(ConduitEvents.turnCompleted) ||
              seen.contains(ConduitEvents.turnFailed),
          seconds: 90,
        );
        await _waitFor(
          () async => (await _messagesOf(
            runtime,
            accepted.chatId,
          )).any((m) => m.id == accepted.userMessageId),
          seconds: 90,
        );

        // Naming the prompt is ambiguous once it has several answers, so
        // the daemon refuses rather than picking one.
        await expectLater(
          turns.regenerate(
            RegenerateTurn(
              chatId: accepted.chatId,
              messageId: accepted.userMessageId,
            ),
          ),
          throwsA(
            isA<RpcError>().having(
              (e) => e.code,
              'code',
              ConduitErrorCodes.invalidParams,
            ),
          ),
        );

        await expectLater(
          turns.regenerate(
            RegenerateTurn(chatId: accepted.chatId, messageId: 'nope'),
          ),
          throwsA(
            isA<RpcError>().having(
              (e) => e.code,
              'code',
              ConduitErrorCodes.notFound,
            ),
          ),
        );
      }, timeout: const Timeout(Duration(minutes: 3)));
    },
  );
}

/// Polls [condition] until it holds or [seconds] elapse.
///
/// The live server is eventually consistent from this side: a turn finishes
/// before the sync that records it lands, and `regenerate` reads the synced
/// conversation.
Future<void> _waitFor(
  FutureOr<bool> Function() condition, {
  required int seconds,
}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
}

/// The transcript as the daemon would serve it.
///
/// Deliberately the same path `chats.get` takes, so a test that says "the
/// message is there" means the app would show it.
Future<List<ChatMessage>> _messagesOf(
  CoreRuntime runtime,
  String chatId,
) async {
  runtime.container.invalidate(loadConversationProvider(chatId));
  try {
    final conversation = await runtime.container.read(
      loadConversationProvider(chatId).future,
    );
    return conversation.messages;
  } on Object {
    return const <ChatMessage>[];
  }
}
