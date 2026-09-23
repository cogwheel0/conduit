@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
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

      test('reports what the composer may offer', () async {
        final options = await ComposerService(runtime.container).options();
        // The answer depends on the server's configuration, so this checks
        // the shape of it rather than particular switches. It also has to
        // come back at all: every source it waits on can be slow on first
        // read, and a one-off read of those is how `models.list` hung.
        printOnFailure('options: $options');
        expect(
          options.tools.map((t) => t.id).toSet(),
          hasLength(options.tools.length),
        );
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('lists prompts and fills one in', () async {
        // Read-only: the account's own prompts, if it has any. Creating one
        // to test with would leave it behind on someone's server.
        final service = PromptsService(runtime.container);
        final list = await service.list();
        printOnFailure('prompts: ${list.prompts.map((p) => p.command)}');
        for (final prompt in list.prompts) {
          expect(prompt.command, startsWith('/'));
        }
        if (list.prompts.isEmpty) return;
        final first = list.prompts.first;
        final rendered = await service.render(
          RenderPrompt(command: first.command),
        );
        // Either final text, or the fields to ask for -- never neither.
        expect(
          rendered.content.isNotEmpty || rendered.inputs.isNotEmpty,
          isTrue,
        );
        // No system variable survives rendering.
        expect(rendered.content, isNot(contains('{{CURRENT_DATE}}')));
      }, timeout: const Timeout(Duration(minutes: 1)));

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
          reason:
              'events seen: $seen; failed: ${payloads[ConduitEvents.turnFailed]}',
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
        // Not one this run made: those can still be mid-answer, with the
        // question stored and the reply not yet.
        final existing = list.chats.firstWhere(
          (chat) => !chat.archived && !created.contains(chat.id),
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

      test(
        'keeps a conversation\'s own system prompt, and clears it',
        () async {
          final events = EventBus();
          final turns = TurnsService(runtime.container, events);
          addTearDown(turns.dispose);
          final accepted = await turns.send(
            const SendTurn(model: 'gemma3:1b', text: 'Say the word: epsilon'),
          );
          created.add(accepted.chatId);
          final chats = ChatsService(runtime.container, events: events);

          final set = await chats.setSystemPrompt(
            ChatSystemPrompt(
              chatId: accepted.chatId,
              prompt: 'Answer in capital letters.',
            ),
          );
          expect(set?.systemPrompt, 'Answer in capital letters.');

          final cleared = await chats.setSystemPrompt(
            ChatSystemPrompt(chatId: accepted.chatId, prompt: ''),
          );
          expect(cleared?.systemPrompt, isNull);
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );

      test('an uploaded image comes back through the files route', () async {
        // The bytes the window's `<img>` gets: same bytes, image type. The
        // file is this test's own and is deleted again.
        final png = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8Dw'
          'HwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
        );
        final files = FilesService(runtime.container);
        final uploaded = await files.upload(
          name: 'conduit-e2e-$pid.png',
          bytes: png,
          contentType: 'image/png',
        );
        try {
          final server = await runtime.container.read(
            activeServerProvider.future,
          );
          final file = await files.download(server!.id, uploaded.id);
          expect(file.bytes, png);
          expect(file.contentType, startsWith('image/'));
          // And not for another server's id.
          await expectLater(
            files.download('not-${server.id}', uploaded.id),
            throwsA(isA<RpcError>()),
          );
        } finally {
          await runtime.container
              .read(apiServiceProvider)!
              .deleteFile(uploaded.id);
        }
      }, timeout: const Timeout(Duration(minutes: 1)));

      test('tags a chat, finds it by tag, and untags it', () async {
        final events = EventBus();
        final turns = TurnsService(runtime.container, events);
        addTearDown(turns.dispose);
        final accepted = await turns.send(
          const SendTurn(model: 'gemma3:1b', text: 'Say the word: delta'),
        );
        created.add(accepted.chatId);

        final chats = ChatsService(runtime.container, events: events);
        // Unique to this run, and gone again at the end: the server drops a
        // tag once no chat carries it.
        final name = 'Conduit e2e $pid';
        final id = name.replaceAll(' ', '_').toLowerCase();

        final added = await chats.addTag(
          ChatTagEdit(chatId: accepted.chatId, name: name),
        );
        expect(added.tags.map((t) => t.id), contains(id));
        expect(added.tags.firstWhere((t) => t.id == id).name, name);

        // The stored copy carries it, read from `meta.tags`.
        await _waitFor(
          () async =>
              (await chats.get(accepted.chatId))?.summary.tags.contains(id) ??
              false,
          seconds: 30,
        );

        final found = await chats.search(ChatSearchQuery(query: 'tag:$name'));
        expect(found.hits.map((h) => h.chatId), contains(accepted.chatId));

        final removed = await chats.removeTag(
          ChatTagEdit(chatId: accepted.chatId, name: name),
        );
        expect(removed.tags.map((t) => t.id), isNot(contains(id)));
        final all = await chats.allTags();
        expect(all.tags.map((t) => t.id), isNot(contains(id)));
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('rates an answer, and re-rating updates the same record', () async {
        final events = EventBus();
        final turns = TurnsService(runtime.container, events);
        addTearDown(turns.dispose);

        final accepted = await turns.send(
          const SendTurn(model: 'gemma3:1b', text: 'Say the word: gamma'),
        );
        created.add(accepted.chatId);
        await _waitFor(
          () async => (await _messagesOf(
            runtime,
            accepted.chatId,
          )).any((m) => m.id == accepted.assistantMessageId),
          seconds: 90,
        );

        final chats = ChatsService(runtime.container);
        Future<ChatMessageDto?> answer() async =>
            (await chats.get(accepted.chatId))?.messages
                .where((m) => m.id == accepted.assistantMessageId)
                .firstOrNull;

        await turns.rate(
          RateTurn(
            chatId: accepted.chatId,
            messageId: accepted.assistantMessageId,
            rating: 1,
          ),
        );
        await _waitFor(() async => (await answer())?.rating == 1, seconds: 30);
        final first = await _feedbackIdOf(runtime, accepted);
        expect(first, isNotNull);

        await turns.rate(
          RateTurn(
            chatId: accepted.chatId,
            messageId: accepted.assistantMessageId,
            rating: -1,
          ),
        );
        await _waitFor(() async => (await answer())?.rating == -1, seconds: 30);
        // The same evaluation, changed, rather than a second one filed.
        expect(await _feedbackIdOf(runtime, accepted), first);

        // Leave nothing behind: the chat is deleted by the suite, and the
        // evaluation would otherwise outlive it.
        await runtime.container
            .read(apiServiceProvider)!
            .deleteFeedback(first!);
      }, timeout: const Timeout(Duration(minutes: 3)));

      test('a fast answer arrives while windows keep reading', () async {
        // Regression: Open WebUI stamps changes to the second, and
        // gemma3:1b answers in less than one. A pull between the
        // placeholder and the answer stored the placeholder, the equal
        // timestamp made every later pull a no-op, and the answer never
        // reached the transcript -- about half the time, and only with a
        // window refetching alongside, which is what this loop is.
        final events = EventBus();
        final turns = TurnsService(runtime.container, events);
        addTearDown(turns.dispose);
        final chats = ChatsService(runtime.container, events: events);
        final accepted = await turns.send(
          const SendTurn(
            model: 'gemma3:1b',
            text: 'Reply with exactly the word: pong',
          ),
        );
        created.add(accepted.chatId);
        var stop = false;
        // What the renderer does: refetch on every chats.changed, and list.
        final hammer = () async {
          while (!stop) {
            await chats.get(accepted.chatId);
            await chats.list();
            await Future<void>.delayed(const Duration(milliseconds: 150));
          }
        }();
        await _waitFor(
          () async =>
              (await chats.get(accepted.chatId))?.messages.any(
                (m) =>
                    m.id == accepted.assistantMessageId && m.content.isNotEmpty,
              ) ??
              false,
          seconds: 60,
        );
        // And the turn over, as the window waits for before it offers
        // Regenerate: a pull can store the answer before the stream ends.
        await _waitFor(
          () => !turns.activeChatIds.contains(accepted.chatId),
          seconds: 30,
        );
        final again = await turns.regenerate(
          RegenerateTurn(
            chatId: accepted.chatId,
            messageId: accepted.assistantMessageId,
          ),
        );
        await _waitFor(
          () async =>
              (await chats.get(accepted.chatId))?.messages.any(
                (m) => m.id == again.assistantMessageId && m.content.isNotEmpty,
              ) ??
              false,
          seconds: 40,
        );
        final ok =
            (await chats.get(accepted.chatId))?.messages.any(
              (m) => m.id == again.assistantMessageId && m.content.isNotEmpty,
            ) ??
            false;
        stop = true;
        await hammer;
        final raw = await runtime.container
            .read(apiServiceProvider)!
            .getChatRaw(accepted.chatId);
        final history = (raw?['chat'] as Map?)?['history'] as Map?;
        final local = await chats.get(accepted.chatId);
        printOnFailure(
          'server.currentId=${history?['currentId']} '
          'new=${again.assistantMessageId} local=${local?.messages.map((m) => '${m.role}:${m.id}:${m.content.length}').join(', ')}',
        );
        expect(ok, isTrue);
      }, timeout: const Timeout(Duration(minutes: 3)));

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
        // What the server holds, for when this fails: whether it linked both
        // answers under the question, or the local copy missed one.
        final raw = await runtime.container
            .read(apiServiceProvider)!
            .getChatRaw(accepted.chatId);
        final history = (raw?['chat'] as Map?)?['history'] as Map?;
        final question =
            (history?['messages'] as Map?)?[accepted.userMessageId];
        printOnFailure(
          'server: currentId=${history?['currentId']} '
          'question.childrenIds=${(question as Map?)?['childrenIds']} '
          'local: ${(await _messagesOf(runtime, accepted.chatId)).map((m) => '${m.role}:${m.id}').join(', ')}',
        );
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
        // For the stored copy to show the edit, not merely for a
        // `chats.changed`: the first turn can announce itself again after
        // the clear above, and proceeding on that read the old branch.
        await _waitFor(
          () async => (await _messagesOf(
            runtime,
            accepted.chatId,
          )).any((m) => m.id == edited.userMessageId),
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

        // The overview sees both branches, and can go back to the first
        // (WP-3.4): its question and answer become the transcript again.
        final chats = ChatsService(runtime.container, events: events);
        final tree = await chats.tree(accepted.chatId);
        expect(
          tree.nodes.map((n) => n.id),
          containsAll(<String>[accepted.userMessageId, edited.userMessageId]),
        );
        final back = await chats.setCurrent(
          ChatCurrent(
            chatId: accepted.chatId,
            messageId: accepted.userMessageId,
          ),
        );
        expect(
          back?.messages.where((m) => m.role == 'user').map((m) => m.content),
          <String>['Say the word: gamma'],
        );
        final reread = await api.getChatRaw(accepted.chatId);
        expect(
          ((reread?['chat'] as Map?)?['history'] as Map?)?['currentId'],
          accepted.assistantMessageId,
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

      // M4: the daemon as the client. The test server's own OpenAI-compatible
      // endpoint stands in for a provider, signed in with the session's token,
      // so the daemon talks to it exactly as it would to any other.
      test('answers through a direct connection, locally and synced', () async {
        final api = runtime.container.read(apiServiceProvider)!;
        final direct = DirectService(runtime.container);
        final saved = await direct.save(
          DirectConnectionEdit(
            name: 'Live direct ${DateTime.now().millisecondsSinceEpoch}',
            kind: DirectKind.openai,
            baseUrl: '${credentials!.url.replaceAll(RegExp(r'/$'), '')}/api',
            apiKey: api.authToken,
          ),
        );
        final profileId = saved.connections.last.id;
        addTearDown(() => direct.remove(profileId));
        final model = DirectModelId.encode(profileId, 'gemma3:1b');
        // Offered alongside the server's models, as the picker needs it.
        await _waitFor(
          () async => (await models.list()).models.any((m) => m.id == model),
          seconds: 30,
        );
        final offered = (await models.list()).models.firstWhere(
          (m) => m.id == model,
        );
        expect(offered.connection, startsWith('Live direct'));

        final events = EventBus();
        final turns = TurnsService(runtime.container, events);
        final chats = ChatsService(runtime.container, events: events);
        addTearDown(turns.dispose);
        addTearDown(chats.dispose);
        final seen = <String, List<Map<String, dynamic>>>{};
        events.attach('probe', (envelope) {
          (seen[envelope.event] ??= <Map<String, dynamic>>[]).add(
            envelope.payload,
          );
        });

        Future<SendTurnAccepted> answered(
          SendTurn request, {
          RegenerateTurn? regenerate,
          EditTurn? edit,
        }) async {
          final before = seen[ConduitEvents.turnCompleted]?.length ?? 0;
          final accepted = edit != null
              ? await turns.edit(edit)
              : regenerate == null
              ? await turns.send(request)
              : await turns.regenerate(regenerate);
          events.subscribe(
            'probe',
            EventSubscription(scopes: <String>[accepted.chatId]),
          );
          await _waitFor(
            () =>
                (seen[ConduitEvents.turnCompleted]?.length ?? 0) > before ||
                seen.containsKey(ConduitEvents.turnFailed),
            seconds: 90,
          );
          expect(
            seen[ConduitEvents.turnFailed],
            isNull,
            reason: 'failed: ${seen[ConduitEvents.turnFailed]}',
          );
          final completed = TurnCompleted.fromJson(
            seen[ConduitEvents.turnCompleted]!.last,
          );
          expect(completed.text.trim(), isNotEmpty);
          return accepted;
        }

        // History kept on this computer: a `direct-local:` chat Open WebUI
        // never hears of.
        await direct.setHistory(localOnly: true);
        final local = await answered(
          SendTurn(model: model, text: 'Say the word: kappa'),
        );
        expect(local.chatId, startsWith('direct-local:'));
        // A follow-up reads the stored history and hangs off its answer.
        final followUp = await answered(
          SendTurn(
            chatId: local.chatId,
            model: model,
            text: 'Now say the word: lambda',
          ),
        );
        final detail = await chats.get(local.chatId);
        expect(detail, isNotNull);
        expect(detail!.messages.map((m) => m.role), <String>[
          'user',
          'assistant',
          'user',
          'assistant',
        ]);
        expect(detail.messages.last.content.trim(), isNotEmpty);

        // Regenerated as a branch: the new answer is current, the old one
        // is still there as a version of it.
        final again = await answered(
          SendTurn(text: '', model: model),
          regenerate: RegenerateTurn(
            chatId: local.chatId,
            messageId: followUp.assistantMessageId,
          ),
        );
        expect(again.assistantMessageId, isNot(followUp.assistantMessageId));
        final branched = (await chats.get(local.chatId))!;
        expect(branched.messages, hasLength(4));
        expect(branched.messages.last.id, again.assistantMessageId);
        expect(
          branched.messages.last.versions.map((v) => v.id),
          contains(followUp.assistantMessageId),
        );

        // Editing the first question starts a branch beside it.
        final edited = await answered(
          SendTurn(text: '', model: model),
          edit: EditTurn(
            chatId: local.chatId,
            messageId: local.userMessageId,
            text: 'Say the word: nu',
          ),
        );
        final rewritten = (await chats.get(local.chatId))!;
        expect(rewritten.messages.map((m) => m.id), <String>[
          edited.userMessageId,
          edited.assistantMessageId,
        ]);
        expect(rewritten.messages.first.content, 'Say the word: nu');

        // Mirrored to Open WebUI: made as `local:`, then renamed to the
        // server's id when it syncs -- which a window hears as `route.remap`.
        await direct.setHistory(localOnly: false);
        final synced = await answered(
          SendTurn(model: model, text: 'Say the word: mu'),
        );
        expect(synced.chatId, startsWith('local:'));
        await _waitFor(
          () => (seen[ConduitEvents.routeRemap] ?? const []).any(
            (payload) => payload['fromId'] == synced.chatId,
          ),
          seconds: 60,
        );
        final remap = RouteRemap.fromJson(
          seen[ConduitEvents.routeRemap]!.firstWhere(
            (payload) => payload['fromId'] == synced.chatId,
          ),
        );
        created.add(remap.toId);
        final raw = await api.getChatRaw(remap.toId);
        final messages =
            ((raw?['chat'] as Map?)?['history'] as Map?)?['messages'] as Map?;
        final answer = messages?[synced.assistantMessageId] as Map?;
        expect(answer?['content'], isA<String>());
        expect((answer!['content'] as String).trim(), isNotEmpty);
      }, timeout: const Timeout(Duration(minutes: 4)));

      // M4: a direct connection kept in the Open WebUI account. Open WebUI
      // sends the chat, then asks this app over the socket to make the
      // request -- the core's relay answers. Removed again afterwards; the
      // account had none before.
      test('answers through a connection kept in the account', () async {
        final api = runtime.container.read(apiServiceProvider)!;
        final direct = DirectService(runtime.container);
        final baseUrl = '${credentials!.url.replaceAll(RegExp(r'/$'), '')}/api';
        bool ours(DirectConnectionSummary c) =>
            c.openWebUi && c.baseUrl == baseUrl;
        final before = await direct.list();
        expect(before.openWebUiAvailable, isTrue);
        // A run that failed before its teardown leaves its connection
        // behind; this address is only ever this test's.
        for (final stale in before.connections.where(ours)) {
          await direct.remove(stale.id);
        }
        final saved = await direct.save(
          DirectConnectionEdit(
            // Open WebUI keeps no name for these; the core names them after
            // the host.
            name: 'ignored',
            kind: DirectKind.openai,
            baseUrl: baseUrl,
            apiKey: api.authToken,
            openWebUi: true,
            // Not gemma3:1b: over the socket Open WebUI adds its built-in
            // tools, and that model refuses any request that has tools.
            manualModelIds: const <String>['openai/gpt-oss-20b'],
          ),
        );
        final connection = saved.connections.singleWhere(ours);
        addTearDown(() async {
          if ((await direct.list()).connections.any(ours)) {
            await direct.remove(connection.id);
          }
        });
        final name = connection.name;
        expect(connection.openWebUi, isTrue);
        expect(connection.compatible, isTrue);
        expect(connection.hasApiKey, isTrue);

        // Offered alongside everything else, labelled with the connection.
        ModelSummary? offered;
        await _waitFor(() async {
          offered = (await models.list()).models
              .where((m) => m.connection == name)
              .firstOrNull;
          return offered != null;
        }, seconds: 60);
        expect(offered, isNotNull);

        final events = EventBus();
        final turns = TurnsService(runtime.container, events);
        addTearDown(turns.dispose);
        final seen = <String, Map<String, dynamic>>{};
        events.attach('probe', (envelope) {
          seen[envelope.event] = envelope.payload;
        });
        final accepted = await turns.send(
          SendTurn(model: offered!.id, text: 'Say the word: xi'),
        );
        created.add(accepted.chatId);
        events.subscribe(
          'probe',
          EventSubscription(scopes: <String>[accepted.chatId]),
        );
        await _waitFor(
          () =>
              seen.containsKey(ConduitEvents.turnCompleted) ||
              seen.containsKey(ConduitEvents.turnFailed),
          seconds: 120,
        );
        expect(
          seen[ConduitEvents.turnFailed],
          isNull,
          reason: '${seen[ConduitEvents.turnFailed]}',
        );
        expect(
          TurnCompleted.fromJson(seen[ConduitEvents.turnCompleted]!).text
              .trim(),
          isNotEmpty,
        );

        final after = await direct.remove(connection.id);
        expect(after.connections.where(ours), isEmpty);
      }, timeout: const Timeout(Duration(minutes: 4)));

      // M5: notes, stored as markdown and edited as Quill ops.
      test('creates, edits, pins and deletes a note', () async {
        final notes = NotesService(runtime.container);
        final title = 'Live note ${DateTime.now().millisecondsSinceEpoch}';
        final created = await notes.save(
          NoteSave(
            title: title,
            ops: const <Map<String, dynamic>>[
              <String, dynamic>{'insert': 'Groceries'},
              <String, dynamic>{
                'insert': '\n',
                'attributes': <String, dynamic>{'header': 2},
              },
              <String, dynamic>{'insert': 'milk'},
              <String, dynamic>{
                'insert': '\n',
                'attributes': <String, dynamic>{'list': 'bullet'},
              },
            ],
          ),
        );
        final id = created.summary.id;
        var deleted = false;
        // Straight to the server: a delete through the daemon is queued, and
        // the runtime is disposed before the queue would drain.
        addTearDown(() async {
          if (deleted) return;
          try {
            await runtime.container.read(apiServiceProvider)!.deleteNote(id);
          } on Object catch (error) {
            stderr.writeln('could not delete test note $id: $error');
          }
        });
        expect(created.summary.title, title);

        // Stored as markdown the web client reads.
        final raw = await runtime.container
            .read(apiServiceProvider)!
            .getNoteById(id);
        final markdown =
            ((raw['data'] as Map?)?['content'] as Map?)?['md'] as String? ?? '';
        expect(markdown, contains('## Groceries'));
        expect(markdown, contains('milk'));

        // And back as Quill ops.
        final opened = await notes.get(id);
        expect(
          opened!.ops.any((op) => (op['attributes'] as Map?)?['header'] == 2),
          isTrue,
        );
        expect((await notes.list('')).notes.map((n) => n.id), contains(id));

        final renamed = await notes.save(NoteSave(id: id, title: '$title!'));
        expect(renamed.summary.title, '$title!');
        // A rename leaves the body alone.
        expect((await notes.get(id))!.ops, isNotEmpty);

        expect((await notes.setPinned(id, pinned: true)).pinned, isTrue);
        // Asked twice, still pinned: a state, not a toggle.
        expect((await notes.setPinned(id, pinned: true)).pinned, isTrue);
        expect((await notes.setPinned(id, pinned: false)).pinned, isFalse);

        await notes.delete(id);
        // Written locally with its outbox operation; the server hears of it
        // when the drain runs.
        await _waitFor(() async => (await notes.get(id)) == null, seconds: 30);
        expect(await notes.get(id), isNull);
        deleted = true;
      }, timeout: const Timeout(Duration(minutes: 2)));

      // M5: a note's AI title and enhancement, from a model on the server.
      // Nothing is saved, so nothing is left behind.
      test('titles and enhances a note with a model', () async {
        final notes = NotesService(runtime.container);
        const ops = <Map<String, dynamic>>[
          <String, dynamic>{
            'insert': 'buy milk, eggs and bread; call the plumber\n',
          },
        ];
        final title = await notes.generateTitle(
          const NoteAi(ops: ops, model: 'gemma3:1b'),
        );
        expect(title.title, isNotEmpty);
        final body = await notes.enhance(
          const NoteAi(ops: ops, model: 'gemma3:1b'),
        );
        expect(body.ops, isNotEmpty);
        expect(
          body.ops.map((op) => '${op['insert']}').join().toLowerCase(),
          contains('milk'),
        );
      }, timeout: const Timeout(Duration(minutes: 3)));

      // M5: a file attached to a note, as a recording is. The note and the
      // file are deleted afterwards, straight through the API.
      test('attaches a file to a note and takes it off again', () async {
        final api = runtime.container.read(apiServiceProvider)!;
        final notes = NotesService(runtime.container);
        final created = await notes.save(
          NoteSave(title: 'Live note ${DateTime.now().millisecondsSinceEpoch}'),
        );
        final id = created.summary.id;
        final uploaded = await FilesService(runtime.container).upload(
          name: 'live-recording.webm',
          bytes: Uint8List.fromList(List<int>.generate(256, (i) => i)),
          contentType: 'audio/webm',
        );
        addTearDown(() async {
          for (final cleanup in <Future<void> Function()>[
            () async => api.deleteNote(id),
            () => api.deleteFile(uploaded.id),
          ]) {
            try {
              await cleanup();
            } on Object catch (error) {
              stderr.writeln(
                'could not clean up after the attach test: $error',
              );
            }
          }
        });

        final attached = await notes.attach(
          NoteAttach(
            noteId: id,
            file: NoteFile(
              id: uploaded.id,
              name: 'live-recording.webm',
              size: 256,
              contentType: 'audio/webm',
            ),
          ),
        );
        expect(attached.files.single.id, uploaded.id);
        expect(attached.files.single.contentType, 'audio/webm');

        // On the server, in the note's own files, once the outbox drains.
        Future<List<Object?>> serverFiles() async {
          final raw = await api.getNoteById(id);
          return ((raw['data'] as Map?)?['files'] as List?) ?? const [];
        }

        await _waitFor(
          () async => (await serverFiles()).any(
            (file) => (file as Map?)?['id'] == uploaded.id,
          ),
          seconds: 30,
        );
        expect(
          (await serverFiles()).map((file) => (file as Map?)?['id']),
          contains(uploaded.id),
        );

        final detached = await notes.detach(
          NoteDetach(noteId: id, fileId: uploaded.id),
        );
        expect(detached.files, isEmpty);
        await _waitFor(() async => (await serverFiles()).isEmpty, seconds: 30);
        expect(await serverFiles(), isEmpty);
      }, timeout: const Timeout(Duration(minutes: 2)));

      // M5: channels. This run's own channel, deleted at the end.
      test('posts, reacts, pins, threads and edits in a channel', () async {
        final events = EventBus();
        final heard = <String>[];
        events.attach('window', (envelope) => heard.add(envelope.event));
        final channels = ChannelsService(runtime.container, events: events);
        final name = 'live-channel-${DateTime.now().millisecondsSinceEpoch}';
        final created = await channels.save(
          ChannelEdit(name: name, description: 'made by a test'),
        );
        final channel = created.channels.singleWhere((c) => c.name == name);
        var deleted = false;
        addTearDown(() async {
          if (deleted) return;
          try {
            await runtime.container
                .read(apiServiceProvider)!
                .deleteChannel(channel.id);
          } on Object catch (error) {
            stderr.writeln('could not delete test channel: $error');
          }
        });
        expect(created.enabled, isTrue);
        expect(channel.manager, isTrue);
        events.subscribe(
          'window',
          EventSubscription(
            scopes: <String>[ChannelsService.scopeFor(channel.id)],
          ),
        );

        final opened = await channels.messages(
          ChannelMessagesQuery(channelId: channel.id),
        );
        expect(opened.messages, isEmpty);

        final posted = await channels.post(
          ChannelPost(channelId: channel.id, content: 'Deploy is done'),
        );
        expect(posted.mine, isTrue);
        expect(heard, contains(ConduitEvents.channelsMessage));
        var messages = (await channels.messages(
          ChannelMessagesQuery(channelId: channel.id),
        )).messages;
        expect(messages.first.content, 'Deploy is done');

        await channels.react(
          ChannelReact(
            channelId: channel.id,
            messageId: posted.id,
            emoji: '👍',
          ),
        );
        await channels.pin(
          ChannelPin(channelId: channel.id, messageId: posted.id, pinned: true),
        );
        messages = (await channels.messages(
          ChannelMessagesQuery(channelId: channel.id),
        )).messages;
        final reacted = messages.singleWhere((m) => m.id == posted.id);
        expect(reacted.pinned, isTrue);
        expect(reacted.reactions.single.name, '👍');
        expect(reacted.reactions.single.mine, isTrue);

        final reply = await channels.post(
          ChannelPost(
            channelId: channel.id,
            content: 'Thanks',
            parentId: posted.id,
          ),
        );
        final thread = await channels.messages(
          ChannelMessagesQuery(channelId: channel.id, parentId: posted.id),
        );
        expect(thread.messages.map((m) => m.id), contains(reply.id));

        final edited = await channels.editMessage(
          ChannelMessageEdit(
            channelId: channel.id,
            messageId: posted.id,
            content: 'Deploy is done.',
          ),
        );
        expect(edited.content, 'Deploy is done.');

        expect((await channels.members(channel.id)).users, isNotEmpty);

        await channels.deleteMessage(
          ChannelMessageRef(channelId: channel.id, messageId: posted.id),
        );
        messages = (await channels.messages(
          ChannelMessagesQuery(channelId: channel.id),
        )).messages;
        expect(messages.map((m) => m.id), isNot(contains(posted.id)));

        final after = await channels.delete(channel.id);
        deleted = true;
        expect(after.channels.map((c) => c.id), isNot(contains(channel.id)));
      }, timeout: const Timeout(Duration(minutes: 2)));
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
/// The evaluation id Open WebUI recorded on the answer, read from the
/// server rather than the local copy.
Future<String?> _feedbackIdOf(
  CoreRuntime runtime,
  SendTurnAccepted accepted,
) async {
  final raw = await runtime.container
      .read(apiServiceProvider)!
      .getChatRaw(accepted.chatId);
  final messages = ((raw?['chat'] as Map?)?['history'] as Map?)?['messages'];
  final answer = (messages as Map?)?[accepted.assistantMessageId];
  return (answer as Map?)?['feedbackId'] as String?;
}

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
