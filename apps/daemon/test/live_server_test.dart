@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_core/features/notes/utils/note_page_data.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/features/workspace/models/workspace_resources.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'support/fake_terminal_server.dart';
import 'support/local_owui.dart';
import 'support/null_sink.dart';
import 'support/window.dart';

/// Drives the daemon against a local Open WebUI with synthetic data.
///
/// Start and seed it with `tool/local_owui/owui.sh up` (see its README);
/// the seed writes the env file read here. Without that file the group is
/// skipped, so a clean clone and CI pass. Nothing here logs a credential.
///
/// Turns run on the server's fake model (`OWUI_MODEL`), which answers
/// "Say the word: X" with X and remembers a favourite colour.
void main() {
  final credentials = LocalOwui.read();
  final turnModel = credentials?.model ?? 'fake-model';
  final secondModel = credentials?.secondModel ?? 'fake-model-b';

  group(
    'against a local Open WebUI',
    skip: credentials == null
        ? 'no local Open WebUI env file (tool/local_owui/owui.sh up)'
        : null,
    () {
      late Directory temporary;
      late CoreRuntime runtime;
      late ServersService servers;
      late AccountsService accounts;
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
        accounts = AccountsService(runtime.container, events: EventBus());
        auth = AuthService(runtime.container);
        models = ModelsService(runtime.container);
      });

      // Every conversation a test creates, deleted at the end, so the
      // seeded account keeps its seed across runs: the sidebar and E2E
      // passes count on it. Before this, each run left five or so "Say the
      // word: alpha" chats behind, and every later run added more.
      final created = <String>{};

      /// The account's chats before the run, read once signed in, so the run
      /// can leave it with exactly these.
      Set<String>? before;

      tearDownAll(() async {
        final api = runtime.container.read(apiServiceProvider);
        // Chats the run made that it did not record -- a new chat sent under
        // its local id and given the server's afterwards -- found by
        // comparing the account with what it had before.
        final initial = before;
        if (api != null && initial != null) {
          try {
            final now = await _allChatIds(api);
            created.addAll(now.where((id) => !initial.contains(id)));
          } on Object catch (error) {
            stderr.writeln('could not list chats for cleanup: $error');
          }
        }
        for (final id in created.where((id) => !id.startsWith('local:'))) {
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
        await accounts.list();

        final added = await accounts.add(
          AddAccount(
            server: ServerDraft(name: 'Live', url: credentials!.url),
          ),
        );
        expect(added.outcome, AccountChangeOutcome.needsSignIn);

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
        final api = runtime.container.read(apiServiceProvider)!;
        before = await _allChatIds(api);
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
        // Read-only: the account's own prompts (the seed adds two). Making
        // and deleting prompts is the workspace group's job.
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

        // A pin in the same second as the create looks, to a pull, like
        // the row it already has.
        await _nextSecond();
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

      test('makes, nests, renames and deletes folders, keeping their '
          'chats', () async {
        final events = EventBus();
        final chats = ChatsService(runtime.container, events: events);
        final heard = <String>[];
        events.attach('probe', (e) => heard.add(e.event));
        final api = runtime.container.read(apiServiceProvider)!;
        // Unique per run, so a run that failed half-way cannot leave a
        // name the next one trips over.
        final stamp = DateTime.now().millisecondsSinceEpoch;
        final made = await chats.createFolder(
          CreateFolder(name: 'live-folder-$stamp'),
        );
        String? top = made.folder.id;
        try {
          expect(made.list.folders.map((f) => f.id), contains(top));
          expect(made.list.foldersEnabled, isTrue);
          expect(heard, contains(ConduitEvents.chatsChanged));

          final sub = await chats.createFolder(
            CreateFolder(name: 'live-sub-$stamp', parentId: top),
          );
          expect(sub.folder.parentId, top);

          // A second folder of the same name beside the first is refused
          // before the server is asked.
          await expectLater(
            chats.createFolder(CreateFolder(name: 'LIVE-FOLDER-$stamp')),
            throwsA(
              isA<RpcError>().having(
                (e) => e.code,
                'code',
                ConduitErrorCodes.conflict,
              ),
            ),
          );

          final renamed = await chats.renameFolder(
            RenameFolder(id: sub.folder.id, name: 'live-renamed-$stamp'),
          );
          expect(
            renamed.folders.singleWhere((f) => f.id == sub.folder.id).name,
            'live-renamed-$stamp',
          );
          final server = await api.getFolderById(sub.folder.id);
          expect(server?['name'], 'live-renamed-$stamp');

          // A chat filed in the subfolder outlives the folder.
          final chat = await api.createConversation(
            title: 'live-folder-chat-$stamp',
            messages: const <ChatMessage>[],
          );
          created.add(chat.id);
          await chats.move(MoveChat(chatId: chat.id, folderId: sub.folder.id));

          final after = await chats.deleteFolder(top);
          top = null;
          expect(
            after.folders.map((f) => f.id),
            isNot(anyOf(contains(made.folder.id), contains(sub.folder.id))),
          );
          final raw = await api.getChatRaw(chat.id);
          expect(raw, isNotNull, reason: 'the chat was kept');
          expect(raw?['folder_id'], isNull);
          final listed = after.chats.where((c) => c.id == chat.id);
          if (listed.isNotEmpty) expect(listed.single.folderId, isNull);
        } finally {
          if (top != null) {
            await api.deleteFolderRaw(top, deleteContents: false);
          }
        }
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
          // The provider refuses this model with a 400, as one does for a
          // model the account may not use. The helper reports that by
          // setting an error on the message and finishing -- not by
          // throwing. Before this was wired up the daemon published
          // `turn.completed` with an empty string, so the user saw the model
          // answer nothing and had no idea why.
          final events = EventBus();
          final turns = TurnsService(runtime.container, events);
          addTearDown(turns.dispose);

          final seen = <String, Map<String, dynamic>>{};
          events.attach('probe', (e) => seen[e.event] = e.payload);

          final accepted = await turns.send(
            SendTurn(model: credentials!.refusedModel, text: 'say pong'),
          );
          created.add(accepted.chatId);
          subscribeWindow(events, turns, 'probe', <String>[accepted.chatId]);

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
          // Named explicitly: the daemon's fallback is "the first one
          // offered", and the server also offers a model that refuses.
          SendTurn(model: turnModel, text: 'Reply with exactly the word: pong'),
        );
        created.add(accepted.chatId);
        expect(accepted.chatId, isNotEmpty);
        expect(accepted.assistantMessageId, isNotEmpty);

        // `turn.*` is scoped to the chat, and the chat id only exists once
        // the send returns -- which is exactly the window a renderer is in.
        // Nothing is lost by subscribing late: a delta carries the whole
        // content rather than an increment.
        subscribeWindow(events, turns, 'probe', <String>[accepted.chatId]);

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
        // The parsed answer came too, before the end, and ends in its text;
        // every window heard that the turn finished.
        expect(seen, contains(ConduitEvents.turnBlocks));
        expect(
          seen.lastIndexOf(ConduitEvents.turnBlocks),
          lessThan(seen.indexOf(ConduitEvents.turnCompleted)),
        );
        final blocks = TurnBlocks.fromJson(payloads[ConduitEvents.turnBlocks]!);
        expect(blocks.messageId, accepted.assistantMessageId);
        final text = blocks.blocks.lastWhere(
          (block) => block.kind == MessageBlockKind.text,
        );
        expect(text.markdown!.toLowerCase(), contains('pong'));
        final finished = TurnFinished.fromJson(
          payloads[ConduitEvents.turnFinished]!,
        );
        expect((finished.chatId, finished.ok), (accepted.chatId, true));
      }, timeout: const Timeout(Duration(minutes: 3)));

      test(
        'the composer finds the seed\'s people, skills, context and files',
        () async {
          final composer = ComposerService(runtime.container);
          final options = await composer.options();
          printOnFailure('options: $options');
          // The server runs code itself (Jupyter), so the switch is offered.
          expect(options.codeInterpreter, isTrue);
          expect(options.codeInterpreterBlock, isNull);
          expect(options.attachments.serverFiles, isTrue);
          expect(options.attachments.webPage, isTrue);
          expect(options.skills && options.context && options.mentions, isTrue);

          final mentions = await composer.mentions('');
          expect(mentions.users.map((u) => u.name), contains('Riley Example'));
          expect(mentions.channels.map((c) => c.name), contains('garden-club'));
          expect((await composer.mentions('gard')).users, isEmpty);

          final skills = await composer.skills('plain');
          expect(skills.items.map((s) => s.id), contains('plain-english'));

          final context = await composer.context('');
          final kinds = {for (final s in context.items) s.kind};
          expect(kinds, containsAll(ContextSuggestionKind.values));
          // Four of each kind come back, and notes made by earlier runs may
          // be newer than the seed's: look the note up by name.
          expect(
            (await composer.context('garden')).items
                .where((s) => s.kind == ContextSuggestionKind.note)
                .map((s) => s.name),
            contains('Garden plan for spring'),
          );
          expect(
            context.items
                .where((s) => s.kind == ContextSuggestionKind.knowledgeFile)
                .map((s) => s.name),
            contains('soil-guide.md'),
          );

          final files = await composer.serverFiles('');
          expect(files.items.map((f) => f.name), contains('field-notes.txt'));
          expect(
            (await composer.serverFiles('soil')).items.single.name,
            'soil-guide.md',
          );

          final page = credentials!.values['FAKE_PAGE_URL'];
          if (page != null) {
            final fetched = await composer.fetchUrl(page);
            expect(fetched.error, isNull, reason: '$fetched');
            expect(fetched.attachment!.kind, ContextAttachmentKind.web);
            expect(fetched.attachment!.content, contains('raised bed'));
          }
          expect((await composer.fetchUrl('not a url')).error, 'invalidUrl');
          // Shortcuts' Send Link to Conduit reads the page the same way.
          if (page != null) {
            final sent = await composer.sendLink(' $page ');
            expect(sent.url, page);
            expect(sent.youtube, isFalse);
            expect(sent.attachment!.kind, ContextAttachmentKind.web);
            expect(sent.attachment!.content, contains('raised bed'));
          }
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );

      test(
        'queues messages behind an answer: one sent now, the rest after',
        () async {
          final events = EventBus();
          final turns = TurnsService(runtime.container, events);
          addTearDown(turns.dispose);
          final started = <String>[];
          final completed = <String>[];
          final queues = <QueueState>[];
          events.attach('probe', (envelope) {
            if (envelope.event == ConduitEvents.turnStarted) {
              started.add(TurnStarted.fromJson(envelope.payload).messageId);
            } else if (envelope.event == ConduitEvents.turnCompleted) {
              completed.add(TurnCompleted.fromJson(envelope.payload).messageId);
            } else if (envelope.event == ConduitEvents.queueChanged) {
              queues.add(QueueState.fromJson(envelope.payload));
            }
          });
          // A stored chat: a queue drains only once a chat has its server id.
          final first = await turns.send(
            SendTurn(
              model: turnModel,
              text: 'Reply with exactly the word: pong',
            ),
          );
          created.add(first.chatId);
          subscribeWindow(events, turns, 'probe', <String>[first.chatId]);
          await _waitFor(() => completed.isNotEmpty, seconds: 60);
          expect(completed, isNotEmpty);

          // A slow answer, and two messages queued behind it.
          final slow = await turns.send(
            SendTurn(
              chatId: first.chatId,
              model: turnModel,
              text: 'Answer slow please',
            ),
          );
          await _waitFor(() => turns.queueGet(first.chatId).offer, seconds: 30);
          expect(turns.queueGet(first.chatId).offer, isTrue);
          turns.queueAdd(
            QueueAdd(chatId: first.chatId, text: 'And the north side?'),
          );
          final two = turns.queueAdd(
            QueueAdd(chatId: first.chatId, text: 'And the south side?'),
          );
          expect(two.drafts.map((d) => d.text), [
            'And the north side?',
            'And the south side?',
          ]);
          expect(queues.last.drafts, hasLength(2));
          // Edited, then sent at once: the slow answer stops for it.
          turns.queueEdit(
            QueueEdit(
              chatId: first.chatId,
              draftId: two.drafts.first.id,
              text: 'And the east side?',
            ),
          );
          final now = await turns.queueSendNow(
            QueueDraftRef(chatId: first.chatId, draftId: two.drafts.first.id),
          );
          expect(now.outcome, 'admitted');
          // The one left goes out once that answer is done -- the moment it
          // ends, while that turn's stored copy is still being fetched --
          // and the window follows its answer like any other: it starts,
          // streams and ends here, not only in the stored copy.
          await _waitFor(
            () =>
                completed.length >= 4 &&
                turns.queueGet(first.chatId).drafts.isEmpty &&
                !turns.isRunning(first.chatId),
            seconds: 60,
          );
          expect(completed, hasLength(4));
          expect(started, completed);
          expect(completed, contains(slow.assistantMessageId));
          expect(turns.queueGet(first.chatId).drafts, isEmpty);
          final detail = await ChatsService(
            runtime.container,
            events: events,
          ).get(first.chatId);
          final asked = detail!.messages
              .where((m) => m.role == 'user')
              .map((m) => m.content)
              .toList();
          expect(asked, <String>[
            'Reply with exactly the word: pong',
            'Answer slow please',
            'And the east side?',
            'And the south side?',
          ]);
          // And the chat takes the next message straight away: nothing is
          // left looking as if it were still being written.
          final next = await turns.send(
            SendTurn(
              chatId: first.chatId,
              model: turnModel,
              text: 'Reply with exactly the word: kite',
            ),
          );
          await _waitFor(
            () => completed.contains(next.assistantMessageId),
            seconds: 60,
          );
          expect(completed, contains(next.assistantMessageId));
        },
        timeout: const Timeout(Duration(minutes: 4)),
      );

      test('a message sent while a queued batch waits for the chat to settle '
          'goes first, and the batch follows its answer', () async {
        final events = EventBus();
        final turns = TurnsService(runtime.container, events);
        addTearDown(turns.dispose);
        final completed = <String>[];
        // `turn.started` and the queue's size, in the order they went out.
        final heard = <String>[];
        late String chatId;
        Future<SendTurnAccepted>? meanwhile;
        events.attach('probe', (envelope) {
          switch (envelope.event) {
            case ConduitEvents.turnStarted:
              heard.add(
                'started ${TurnStarted.fromJson(envelope.payload).messageId}',
              );
            case ConduitEvents.turnCompleted:
              completed.add(TurnCompleted.fromJson(envelope.payload).messageId);
            case ConduitEvents.queueChanged:
              final queue = QueueState.fromJson(envelope.payload);
              heard.add('queued ${queue.drafts.length}');
              // The answer before it has ended and the batch waits for
              // the chat to settle: a window that shows Send is used now.
              if (queue.phase == QueuePhase.admitting && meanwhile == null) {
                meanwhile = turns.send(
                  SendTurn(
                    chatId: chatId,
                    model: turnModel,
                    text: 'Reply with exactly the word: kite',
                  ),
                )..ignore();
              }
          }
        });
        final first = await turns.send(
          SendTurn(model: turnModel, text: 'Reply with exactly the word: pong'),
        );
        chatId = first.chatId;
        created.add(chatId);
        subscribeWindow(events, turns, 'probe', <String>[chatId]);
        await _waitFor(() => completed.isNotEmpty, seconds: 60);
        expect(completed, isNotEmpty);

        // An answer of a few seconds, and a message queued behind it.
        final long = await turns.send(
          SendTurn(
            chatId: chatId,
            model: turnModel,
            text: 'Tell me something long',
          ),
        );
        await _waitFor(() => turns.queueGet(chatId).offer, seconds: 30);
        turns.queueAdd(QueueAdd(chatId: chatId, text: 'And the west side?'));
        await _waitFor(() => meanwhile != null, seconds: 60);
        expect(completed, contains(long.assistantMessageId));

        // Sent, not refused: it goes first, and the batch waits whole.
        final kite = await meanwhile!;
        expect(turns.queueGet(chatId).drafts.map((d) => d.text), <String>[
          'And the west side?',
        ]);
        await _waitFor(
          () =>
              completed.length >= 4 &&
              turns.queueGet(chatId).drafts.isEmpty &&
              !turns.isRunning(chatId),
          seconds: 60,
        );
        expect(completed, hasLength(4));
        expect(completed[2], kite.assistantMessageId);
        final asked = (await ChatsService(
          runtime.container,
          events: events,
        ).get(chatId))!.messages.where((m) => m.role == 'user');
        expect(asked.map((m) => m.content), <String>[
          'Reply with exactly the word: pong',
          'Tell me something long',
          'Reply with exactly the word: kite',
          'And the west side?',
        ]);
        // The batch's turn started before it left the queue: once it is
        // committed, the windows show the chat answering, not Send.
        final batch = 'started ${completed.last}';
        final left = heard.indexOf(
          'queued 0',
          heard.indexOf('started ${kite.assistantMessageId}'),
        );
        expect(heard.indexOf(batch), allOf(isNonNegative, lessThan(left)));
      }, timeout: const Timeout(Duration(minutes: 4)));

      test('each queued batch goes out once, in a chat whose earlier batch '
          'went out after a Stop & Send', () async {
        final events = EventBus();
        final turns = TurnsService(runtime.container, events);
        addTearDown(turns.dispose);
        final completed = <String>[];
        late String chatId;
        Future<SendTurnAccepted>? meanwhile;
        var armed = false;
        events.attach('probe', (envelope) {
          switch (envelope.event) {
            case ConduitEvents.turnCompleted:
              completed.add(TurnCompleted.fromJson(envelope.payload).messageId);
            case ConduitEvents.queueChanged:
              final queue = QueueState.fromJson(envelope.payload);
              // The second batch waits for the chat to settle: a window that
              // shows Send is used now, as the desktop's E2E does.
              if (armed &&
                  queue.phase == QueuePhase.admitting &&
                  meanwhile == null) {
                meanwhile = turns.send(
                  SendTurn(
                    chatId: chatId,
                    model: turnModel,
                    text: 'Reply with exactly the word: lark',
                  ),
                )..ignore();
              }
          }
        });
        final first = await turns.send(
          SendTurn(model: turnModel, text: 'Reply with exactly the word: pong'),
        );
        chatId = first.chatId;
        created.add(chatId);
        subscribeWindow(events, turns, 'probe', <String>[chatId]);
        await _waitFor(() => completed.isNotEmpty, seconds: 60);
        expect(completed, isNotEmpty);

        // A slow answer, two messages queued behind it, the first sent now.
        await turns.send(
          SendTurn(
            chatId: chatId,
            model: turnModel,
            text: 'Answer slow please',
          ),
        );
        await _waitFor(() => turns.queueGet(chatId).offer, seconds: 30);
        turns.queueAdd(QueueAdd(chatId: chatId, text: 'And the north side?'));
        final two = turns.queueAdd(
          QueueAdd(chatId: chatId, text: 'And the south side?'),
        );
        final now = await turns.queueSendNow(
          QueueDraftRef(chatId: chatId, draftId: two.drafts.first.id),
        );
        expect(now.outcome, 'admitted');
        await _waitFor(
          () =>
              completed.length >= 4 &&
              turns.queueGet(chatId).drafts.isEmpty &&
              !turns.isRunning(chatId),
          seconds: 60,
        );
        expect(completed, hasLength(4));

        // A long answer, one message queued behind it, and a message sent
        // while that batch waits for the chat to settle.
        await turns.send(
          SendTurn(
            chatId: chatId,
            model: turnModel,
            text: 'Tell me something long',
          ),
        );
        await _waitFor(() => turns.queueGet(chatId).offer, seconds: 30);
        armed = true;
        turns.queueAdd(QueueAdd(chatId: chatId, text: 'And the east side?'));
        await _waitFor(() => meanwhile != null, seconds: 60);
        await meanwhile!;
        await _waitFor(
          () =>
              completed.length >= 7 &&
              turns.queueGet(chatId).drafts.isEmpty &&
              !turns.isRunning(chatId),
          seconds: 60,
        );
        final asked = (await ChatsService(
          runtime.container,
          events: events,
        ).get(chatId))!.messages.where((m) => m.role == 'user');
        expect(asked.map((m) => m.content), <String>[
          'Reply with exactly the word: pong',
          'Answer slow please',
          'And the north side?',
          'And the south side?',
          'Tell me something long',
          'Reply with exactly the word: lark',
          'And the east side?',
        ]);
        expect(completed, hasLength(7));
      }, timeout: const Timeout(Duration(minutes: 4)));

      test('compares two models: one message, two answers', () async {
        final events = EventBus();
        final turns = TurnsService(runtime.container, events);
        addTearDown(turns.dispose);
        final finished = <TurnFinished>[];
        events.attach('probe', (envelope) {
          if (envelope.event == ConduitEvents.turnFinished) {
            finished.add(TurnFinished.fromJson(envelope.payload));
          }
        });
        final accepted = await turns.send(
          SendTurn(
            text: 'Reply with exactly the word: twins',
            compareModels: <String>[turnModel, turnModel],
          ),
        );
        created.add(accepted.chatId);
        await _waitFor(() => finished.isNotEmpty, seconds: 90);
        expect(finished, isNotEmpty);
        expect(finished.first.ok, isTrue, reason: '${finished.first.code}');
        // Both answers are kept, under the one question.
        late ChatDetail detail;
        await _waitFor(() async {
          final got = await ChatsService(
            runtime.container,
            events: events,
          ).get(accepted.chatId);
          if (got == null) return false;
          detail = got;
          final answer = got.messages.where((m) => m.role == 'assistant');
          // Both written: an empty placeholder is not an answer yet.
          return answer.isNotEmpty &&
              <String>[
                    for (final a in answer) a.content,
                    for (final v in answer.first.versions) v.content,
                  ].where((text) => text.trim().isNotEmpty).length >=
                  2;
        }, seconds: 60);
        final answers = detail.messages.where((m) => m.role == 'assistant');
        printOnFailure('messages: ${detail.messages}');
        expect(answers.length + answers.first.versions.length, 2);
        expect(
          <String>[
            for (final a in answers) a.content,
            for (final v in answers.first.versions) v.content,
          ].where((text) => text.trim().isNotEmpty),
          hasLength(2),
        );
        expect(
          detail.messages.where((m) => m.role == 'user').single.content,
          'Reply with exactly the word: twins',
        );
      }, timeout: const Timeout(Duration(minutes: 3)));

      group('message and chat actions', () {
        late EventBus events;
        late TurnsService turns;
        late ChatsService chats;
        final seen = <EventEnvelope>[];

        setUp(() {
          events = EventBus();
          final temporary = TemporaryChats();
          turns = TurnsService(runtime.container, events, temporary: temporary);
          chats = ChatsService(
            runtime.container,
            events: events,
            temporary: temporary,
          )..turns = turns;
          seen.clear();
          events.attach('probe', seen.add);
        });
        tearDown(() async {
          await turns.dispose();
          chats.dispose();
        });

        bool ended(String messageId) => seen.any(
          (e) =>
              (e.event == ConduitEvents.turnCompleted ||
                  e.event == ConduitEvents.turnFailed) &&
              e.payload['messageId'] == messageId,
        );

        /// One turn, answered and in the stored copy.
        Future<SendTurnAccepted> answered(String text, {String? chatId}) async {
          final accepted = await turns.send(
            SendTurn(chatId: chatId, model: turnModel, text: text),
          );
          created.add(accepted.chatId);
          subscribeWindow(events, turns, 'probe', <String>[accepted.chatId]);
          await _waitFor(() => ended(accepted.assistantMessageId), seconds: 90);
          await _waitFor(
            () async => (await _messagesOf(runtime, accepted.chatId)).any(
              (m) =>
                  m.id == accepted.assistantMessageId &&
                  m.content.isNotEmpty &&
                  m.usage != null,
            ),
            seconds: 60,
          );
          return accepted;
        }

        Future<ChatDetail> reopened(String chatId) async {
          runtime.container.invalidate(loadConversationProvider(chatId));
          return (await ChatsService(runtime.container).get(chatId))!;
        }

        test(
          'a chat says what it offers, and its answers carry usage',
          () async {
            final accepted = await answered('Say the word: offers');
            final detail = await reopened(accepted.chatId);
            expect(detail.abilities.fork, isTrue, reason: 'admin may import');
            expect(detail.abilities.export, isTrue);
            expect(detail.abilities.branch, isTrue);
            expect(detail.abilities.deleteMessages, isTrue);
            expect(detail.abilities.share, isTrue);
            expect(detail.abilities.generateTitle, isTrue);
            expect(detail.abilities.saveTemporary, isFalse);
            final answer = detail.messages.lastWhere(
              (m) => m.role == 'assistant',
            );
            expect(answer.parentId, accepted.userMessageId);
            expect(answer.usage?.generationTokens, isNotNull);
          },
          timeout: const Timeout(Duration(minutes: 3)),
        );

        test('compares two models: both stream under their own ids, then '
            'merge into one', () async {
          final accepted = await turns.send(
            SendTurn(
              text: 'Reply with exactly the word: columns',
              compareModels: <String>[turnModel, secondModel],
            ),
          );
          created.add(accepted.chatId);
          subscribeWindow(events, turns, 'probe', <String>[accepted.chatId]);
          await _waitFor(
            () => seen.any((e) => e.event == ConduitEvents.turnFinished),
            seconds: 120,
          );
          final started = seen
              .where((e) => e.event == ConduitEvents.turnStarted)
              .map((e) => TurnStarted.fromJson(e.payload))
              .firstOrNull;
          printOnFailure('events: ${seen.map((e) => e.event).toList()}');
          expect(started?.companionIds, hasLength(1));
          final companion = started!.companionIds.single;
          expect(ended(accepted.assistantMessageId), isTrue);
          expect(
            seen.any(
              (e) =>
                  e.event == ConduitEvents.turnCompleted &&
                  e.payload['messageId'] == companion,
            ),
            isTrue,
            reason: 'the second column ends on its own',
          );
          expect(
            seen.any(
              (e) =>
                  e.event == ConduitEvents.turnBlocks &&
                  e.payload['messageId'] == companion,
            ),
            isTrue,
          );

          late ChatMessageDto answer;
          await _waitFor(() async {
            final got = await reopened(accepted.chatId);
            final shown = got.messages
                .where((m) => m.role == 'assistant')
                .lastOrNull;
            if (shown == null || shown.comparison.length < 2) return false;
            answer = shown;
            return shown.mergeableIds.length >= 2;
          }, seconds: 60);
          printOnFailure('answer: $answer');
          expect(answer.comparison.map((s) => s.index), <int>[0, 1]);
          expect(answer.slot, isNotNull);
          expect(answer.siblingIds, hasLength(2));
          expect(answer.mergeableIds, hasLength(2));

          seen.clear();
          final merge = await turns.merge(
            MergeTurn(
              chatId: accepted.chatId,
              messageId: answer.id,
              targetId: answer.id,
              sourceIds: answer.mergeableIds,
            ),
          );
          expect(merge.targetId, answer.id);
          await _waitFor(
            () => seen.any(
              (e) =>
                  e.event == ConduitEvents.messagesMerge &&
                  e.payload['running'] == false,
            ),
            seconds: 90,
          );
          final last = MergeProgress.fromJson(
            seen
                .lastWhere((e) => e.event == ConduitEvents.messagesMerge)
                .payload,
          );
          printOnFailure('merge: $last');
          expect(last.error, isNull);
          expect(last.text, contains('merged'));
          await _waitFor(
            () async =>
                (await reopened(accepted.chatId)).messages
                    .any((m) => (m.merged ?? '').contains('merged')) ||
                (await reopened(accepted.chatId)).messages.any(
                  (m) => m.versions.any(
                    (v) => (v.merged ?? '').contains('merged'),
                  ),
                ),
            seconds: 30,
          );
          final merged = await reopened(accepted.chatId);
          expect(
            merged.messages.any((m) => (m.merged ?? '').contains('merged')),
            isTrue,
          );
        }, timeout: const Timeout(Duration(minutes: 5)));

        test('regenerates with another model, then switches back to the '
            'first answer on the server', () async {
          final accepted = await answered('Say the word: original');
          final again = await turns.regenerate(
            RegenerateTurn(
              chatId: accepted.chatId,
              messageId: accepted.assistantMessageId,
              model: secondModel,
            ),
          );
          await _waitFor(() => ended(again.assistantMessageId), seconds: 90);
          late ChatMessageDto shown;
          // Switched at once, while Open WebUI may still be writing the new
          // answer: `chats.setCurrent` checks the server kept the switch.
          await _waitFor(() async {
            final got = await reopened(accepted.chatId);
            shown = got.messages.lastWhere((m) => m.role == 'assistant');
            return shown.id == again.assistantMessageId &&
                shown.content.startsWith('B: ');
          }, seconds: 60);
          expect(shown.content, startsWith('B: '));
          expect(shown.siblingIds, <String>[
            accepted.assistantMessageId,
            again.assistantMessageId,
          ]);

          final back = await chats.setCurrent(
            ChatCurrent(
              chatId: accepted.chatId,
              messageId: accepted.assistantMessageId,
              alternativeTo: again.assistantMessageId,
            ),
          );
          expect(
            back?.messages.lastWhere((m) => m.role == 'assistant').id,
            accepted.assistantMessageId,
          );
          // Kept on the server, so a reopen (or another device) shows it.
          String? currentId;
          await _waitFor(() async {
            final raw = await runtime.container
                .read(apiServiceProvider)!
                .getChatRaw(accepted.chatId);
            currentId =
                ((raw?['chat'] as Map?)?['history'] as Map?)?['currentId']
                    as String?;
            return currentId == accepted.assistantMessageId;
          }, seconds: 30);
          expect(currentId, accepted.assistantMessageId);
          final reread = await reopened(accepted.chatId);
          expect(
            reread.messages.lastWhere((m) => m.role == 'assistant').id,
            accepted.assistantMessageId,
          );
          // An answer that is not the shown one's sibling is refused.
          await expectLater(
            chats.setCurrent(
              ChatCurrent(
                chatId: accepted.chatId,
                messageId: accepted.userMessageId,
                alternativeTo: accepted.assistantMessageId,
              ),
            ),
            throwsA(isA<RpcError>()),
          );
        }, timeout: const Timeout(Duration(minutes: 5)));

        test('deletes an answer, after counting what goes', () async {
          final first = await answered('Say the word: keep');
          final second = await answered(
            'Say the word: drop',
            chatId: first.chatId,
          );
          final count = await turns.deleteMessages(
            DeleteMessages(
              chatId: first.chatId,
              messageIds: <String>[second.userMessageId],
              dryRun: true,
            ),
          );
          expect(count, 2, reason: 'the question and its answer');
          expect(
            await turns.deleteMessages(
              DeleteMessages(
                chatId: first.chatId,
                messageIds: <String>[second.assistantMessageId],
              ),
            ),
            1,
          );
          await _waitFor(
            () async =>
                !(await reopened(first.chatId)).messages
                    .any((m) => m.id == second.assistantMessageId),
            seconds: 30,
          );
          final after = await reopened(first.chatId);
          expect(
            after.messages.map((m) => m.id),
            isNot(contains(second.assistantMessageId)),
          );
          final raw = await runtime.container
              .read(apiServiceProvider)!
              .getChatRaw(first.chatId);
          final messages =
              (((raw?['chat'] as Map?)?['history'] as Map?)?['messages']
                  as Map?) ??
              const <String, Object?>{};
          expect(messages.keys, isNot(contains(second.assistantMessageId)));
        }, timeout: const Timeout(Duration(minutes: 5)));

        test('forks a chat at an answer, and exports it both ways', () async {
          final first = await answered('Say the word: trunk');
          await answered('Say the word: branch', chatId: first.chatId);
          final fork = await chats.fork(
            ForkChat(chatId: first.chatId, messageId: first.assistantMessageId),
          );
          created.add(fork.chatId);
          expect(fork.chatId, isNot(first.chatId));
          final forked = await reopened(fork.chatId);
          expect(forked.messages.map((m) => m.content), <String>[
            'Say the word: trunk',
            'trunk',
          ]);

          final json = await chats.export(
            ExportChat(chatId: first.chatId, format: ChatExportFormat.json),
          );
          expect(json.fileName, endsWith('.json'));
          expect(json.mimeType, 'application/json');
          final decoded = jsonDecode(json.content);
          expect(decoded, isA<List<Object?>>());
          expect(
            (((decoded as List).single as Map)['chat'] as Map)['history'],
            isA<Map<Object?, Object?>>(),
          );
          final markdown = await chats.export(
            ExportChat(chatId: first.chatId, format: ChatExportFormat.markdown),
          );
          expect(markdown.fileName, endsWith('.md'));
          expect(markdown.content, contains('Say the word: branch'));
        }, timeout: const Timeout(Duration(minutes: 5)));

        test('titles a chat, marks it unread and read', () async {
          final accepted = await answered('Say the word: heading');
          final title = await chats.generateTitle(accepted.chatId);
          expect(
            title.outcome,
            isIn(<GenerateTitleOutcome>[
              GenerateTitleOutcome.saved,
              GenerateTitleOutcome.unchanged,
            ]),
          );
          expect(title.title, isNotEmpty);

          ChatSummary? listed(ChatList list) =>
              list.chats.where((c) => c.id == accepted.chatId).firstOrNull;
          final unread = await chats.markUnread(
            MarkUnread(chatId: accepted.chatId),
          );
          expect(listed(unread)?.unread, isTrue);
          final read = await chats.markUnread(
            MarkUnread(chatId: accepted.chatId, unread: false),
          );
          expect(listed(read)?.unread, isFalse);
        }, timeout: const Timeout(Duration(minutes: 3)));

        test('shares a chat, chooses who may open it, and unshares', () async {
          final accepted = await answered('Say the word: linked');
          final shared = await chats.share(ShareChat(id: accepted.chatId));
          expect(shared.shareId, isNotEmpty);
          expect(shared.url, contains('/s/${shared.shareId}'));
          final read = await chats.share(
            ShareChat(id: accepted.chatId, publish: false),
          );
          expect(read.shareId, shared.shareId);
          final open = await chats.share(
            ShareChat(
              id: accepted.chatId,
              publish: false,
              audience: ShareAudience.open,
            ),
          );
          expect(open.audience, ShareAudience.open);
          final public = await chats.share(
            ShareChat(
              id: accepted.chatId,
              publish: false,
              audience: ShareAudience.public,
            ),
          );
          expect(public.audience, ShareAudience.public);
          final gone = await chats.unshare(accepted.chatId);
          expect(gone.shareId, isNull);
          final after = await reopened(accepted.chatId);
          expect(after.shareId, isNull);
        }, timeout: const Timeout(Duration(minutes: 3)));

        test('saves a temporary chat as a stored one', () async {
          final first = await turns.send(
            SendTurn(
              model: turnModel,
              text: 'Say the word: kept',
              temporary: true,
            ),
          );
          subscribeWindow(events, turns, 'probe', <String>[first.chatId]);
          await _waitFor(() => ended(first.assistantMessageId), seconds: 90);
          final temporaryDetail = await chats.get(first.chatId);
          expect(temporaryDetail?.temporary, isTrue);
          final saved = await turns.saveTemporary(first.chatId);
          created.add(saved.chatId);
          expect(saved.chatId, isNot(startsWith('local:')));
          expect(
            seen.any(
              (e) =>
                  e.event == ConduitEvents.routeRemap &&
                  e.payload['fromId'] == first.chatId &&
                  e.payload['toId'] == saved.chatId,
            ),
            isTrue,
          );
          final stored = await reopened(saved.chatId);
          expect(stored.temporary, isFalse);
          expect(
            stored.messages.map((m) => m.content),
            containsAll(<String>['Say the word: kept', 'kept']),
          );
        }, timeout: const Timeout(Duration(minutes: 3)));
      });

      test('opens a conversation from past the list it has loaded', () async {
        // A search hit, a link or a notification can name a conversation
        // the sidebar has not paged to; opening it must not need the list.
        final chats = ChatsService(runtime.container);
        final loaded = (await chats.list()).chats.map((c) => c.id).toSet();
        final api = runtime.container.read(apiServiceProvider)!;
        String? older;
        for (var page = 2; page <= 12 && older == null; page++) {
          final rows = await api.getChatListPageRaw(page: page);
          for (final row in rows) {
            final id = row['id'];
            if (id is String && !loaded.contains(id)) {
              older = id;
              break;
            }
          }
          if (rows.isEmpty) break;
        }
        if (older == null) {
          markTestSkipped(
            'the account has no conversation past the first page',
          );
          return;
        }
        final detail = await chats.get(older);
        expect(detail, isNotNull);
        expect(detail!.summary.id, older);
      }, timeout: const Timeout(Duration(minutes: 1)));

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
            SendTurn(model: turnModel, text: 'Say the word: epsilon'),
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
          session: files.session(),
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
          SendTurn(model: turnModel, text: 'Say the word: delta'),
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
          SendTurn(model: turnModel, text: 'Say the word: gamma'),
        );
        created.add(accepted.chatId);
        // Answered and on the server: the stored copy has the placeholder
        // from the start, and a rating needs the answer.
        await _waitFor(
          () async =>
              !turns.activeChatIds.contains(accepted.chatId) &&
              (await _messagesOf(runtime, accepted.chatId)).any(
                (m) =>
                    m.id == accepted.assistantMessageId && m.content.isNotEmpty,
              ),
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
        // a small model answers in less than one. A pull between the
        // placeholder and the answer stored the placeholder, the equal
        // timestamp made every later pull a no-op, and the answer never
        // reached the transcript -- about half the time, and only with a
        // window refetching alongside, which is what this loop is.
        final events = EventBus();
        final turns = TurnsService(runtime.container, events);
        addTearDown(turns.dispose);
        final chats = ChatsService(runtime.container, events: events);
        final accepted = await turns.send(
          SendTurn(model: turnModel, text: 'Reply with exactly the word: pong'),
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
          SendTurn(model: turnModel, text: 'Say the word: alpha'),
        );
        created.add(accepted.chatId);

        final seen = <String>[];
        final payloads = <String, Map<String, dynamic>>{};
        events.attach('probe', (envelope) {
          seen.add(envelope.event);
          payloads[envelope.event] = envelope.payload;
        });
        subscribeWindow(events, turns, 'probe', <String>[accepted.chatId]);
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
          SendTurn(model: turnModel, text: 'Say the word: epsilon'),
        );
        created.add(accepted.chatId);
        subscribeWindow(events, turns, 'probe', <String>[accepted.chatId]);
        await _waitFor(
          () => seen.contains(ConduitEvents.chatsChanged),
          seconds: 90,
        );

        final chats = ChatsService(runtime.container);
        // Regenerating keeps it first: it is still the conversation most
        // recently touched. A second on, so it cannot tie with the chat the
        // test before made.
        await _nextSecond();
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
          SendTurn(model: turnModel, text: 'Say the word: gamma'),
        );
        created.add(accepted.chatId);
        subscribeWindow(events, turns, 'probe', <String>[accepted.chatId]);
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

        // The overview sees both branches, and can go back to the first:
        // its question and answer become the transcript again.
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
            SendTurn(
              model: turnModel,
              text: 'My favourite colour is teal. Reply with just: noted.',
              temporary: true,
            ),
          );
          expect(first.chatId, startsWith('local:'));
          subscribeWindow(events, turns, 'probe', <String>[first.chatId]);
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
              model: turnModel,
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
          SendTurn(model: turnModel, text: 'Say the word: beta'),
        );
        created.add(accepted.chatId);
        subscribeWindow(events, turns, 'probe', <String>[accepted.chatId]);
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

      // The daemon as the client. The test server's own OpenAI-compatible
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
        final model = DirectModelId.encode(profileId, turnModel);
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
          subscribeWindow(events, turns, 'probe', <String>[accepted.chatId]);
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

        // Regenerated as the core does for a direct chat: the answer keeps
        // its id and the old text is still there as a version of it.
        final again = await answered(
          SendTurn(text: '', model: model),
          regenerate: RegenerateTurn(
            chatId: local.chatId,
            messageId: followUp.assistantMessageId,
          ),
        );
        final branched = (await chats.get(local.chatId))!;
        expect(branched.messages, hasLength(4));
        expect(branched.messages.last.id, again.assistantMessageId);
        expect(branched.messages.last.versions, isNotEmpty);

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

      // A direct connection kept in the Open WebUI account. Open WebUI
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
            manualModelIds: <String>[turnModel],
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
        subscribeWindow(events, turns, 'probe', <String>[accepted.chatId]);
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
        // Skipped: 0.13.4 moved these into Tether (Tether device follow-up).
      }, skip: _movedToTether, timeout: const Timeout(Duration(minutes: 4)));

      // Notes, stored as markdown and edited as Quill ops.
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

      // A note's AI title and enhancement, from a model on the server.
      // Nothing is saved, so nothing is left behind.
      test('titles and enhances a note with a model', () async {
        final notes = NotesService(runtime.container);
        const ops = <Map<String, dynamic>>[
          <String, dynamic>{
            'insert': 'buy milk, eggs and bread; call the plumber\n',
          },
        ];
        final title = await notes.generateTitle(
          NoteAi(ops: ops, model: turnModel),
        );
        expect(title.title, isNotEmpty);
        final body = await notes.enhance(NoteAi(ops: ops, model: turnModel));
        expect(body.ops, isNotEmpty);
        expect(
          body.ops.map((op) => '${op['insert']}').join().toLowerCase(),
          contains('milk'),
        );
      }, timeout: const Timeout(Duration(minutes: 3)));

      // A file attached to a note, as a recording is. The note and the
      // file are deleted afterwards, straight through the API.
      test('attaches a file to a note and takes it off again', () async {
        final api = runtime.container.read(apiServiceProvider)!;
        final notes = NotesService(runtime.container);
        final created = await notes.save(
          NoteSave(title: 'Live note ${DateTime.now().millisecondsSinceEpoch}'),
        );
        final id = created.summary.id;
        final uploaded = await FilesService(runtime.container).upload(
          session: FilesService(runtime.container).session(),
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
        expect(attached.files.single.name, 'live-recording.webm');
        // An older server keeps the descriptor with its type; 0.12.5 and
        // later keep a link in the content, which names the file only.
        expect(attached.files.single.contentType, anyOf('audio/webm', isNull));

        // On the server once the outbox drains: in the note's file list on
        // an older server, as a link in its content on 0.12.5 and later.
        Future<List<Object?>> serverFiles() async {
          final raw = await api.getNoteById(id);
          final data = Map<String, dynamic>.from(
            (raw['data'] as Map?) ?? const <String, dynamic>{},
          );
          return <Object?>[
            for (final file in (data['files'] as List?) ?? const <Object?>[])
              (file as Map?)?['id'],
            for (final link in noteFileLinksInMarkdown(
              notePageMarkdown(data, kNoteMainPageId),
            ))
              link.id,
          ];
        }

        await _waitFor(
          () async => (await serverFiles()).contains(uploaded.id),
          seconds: 30,
        );
        expect(await serverFiles(), contains(uploaded.id));

        final detached = await notes.detach(
          NoteDetach(noteId: id, fileId: uploaded.id),
        );
        expect(detached.files, isEmpty);
        await _waitFor(() async => (await serverFiles()).isEmpty, seconds: 30);
        expect(await serverFiles(), isEmpty);
      }, timeout: const Timeout(Duration(minutes: 2)));

      // The notes list's access flags and time groups.
      test(
        'summarizes notes with their group and what the account may do',
        () async {
          final notes = NotesService(runtime.container);
          final list = (await notes.list('')).notes;
          expect(list, isNotEmpty);
          // The admin's own notes: editable; sharing follows the server.
          expect(list.every((n) => n.canEdit), isTrue);
          expect(list.every((n) => n.owner == null), isTrue);
          // Seeded today, so today's group.
          expect(list.any((n) => n.section == NoteSection.today), isTrue);
        },
      );

      // A note with pages (Open WebUI 0.12.5), seeded: each page reads and
      // saves on its own, and a file the page gained after the editor
      // loaded it is kept by the save (the phone's link merge).
      test('reads and saves a page, keeping a file the page gained', () async {
        final paged = credentials!.values['OWUI_PAGED_NOTE'];
        if (paged == null) {
          markTestSkipped('the seed has no paged note');
          return;
        }
        final notes = NotesService(runtime.container);
        final opened = (await notes.get(paged))!;
        expect(opened.pageId, kNoteMainPageId);
        expect(
          opened.pages.map((p) => p.title),
          containsAll(<String>['Day one', 'Day two', 'Evening walk']),
        );
        expect(
          opened.pages.firstWhere((p) => p.title == 'Evening walk').depth,
          1,
        );
        final dayTwo = opened.pages.firstWhere((p) => p.title == 'Day two').id;
        final page = (await notes.get(paged, pageId: dayTwo))!;
        expect(page.pageId, dayTwo);
        expect(page.markdown, contains('Rain until noon'));
        // An unknown page reads as the main page.
        expect((await notes.get(paged, pageId: 'gone'))!.pageId, 'main');

        final uploaded = await FilesService(runtime.container).upload(
          name: 'live-page.txt',
          bytes: Uint8List.fromList('A synthetic page file.'.codeUnits),
          contentType: 'text/plain',
          session: FilesService(runtime.container).session(),
        );
        final api = runtime.container.read(apiServiceProvider)!;
        addTearDown(() async {
          try {
            await api.deleteFile(uploaded.id);
          } on Object catch (error) {
            stderr.writeln('could not delete the page test file: $error');
          }
        });
        // Attached to the page while the editor holds it as it loaded.
        await notes.attach(
          NoteAttach(
            noteId: paged,
            file: NoteFile(id: uploaded.id, name: 'live-page.txt'),
            pageId: dayTwo,
          ),
        );
        final saved = await notes.save(
          NoteSave(
            id: paged,
            title: opened.summary.title,
            pageId: dayTwo,
            ops: const <Map<String, dynamic>>[
              <String, dynamic>{'insert': 'Rain all day.\n'},
            ],
            baseOps: page.ops,
          ),
        );
        expect(saved.pageId, dayTwo);
        expect(saved.markdown, contains('Rain all day.'));
        expect(
          noteFileLinksInMarkdown(saved.markdown).map((l) => l.id),
          contains(uploaded.id),
        );
        // The other pages are untouched.
        expect(
          (await notes.get(paged))!.markdown,
          contains('Notes from the spring field trip.'),
        );

        // Put back as seeded: the text, and the file taken out.
        await notes.save(
          NoteSave(
            id: paged,
            title: opened.summary.title,
            pageId: dayTwo,
            ops: page.ops,
            baseOps: saved.ops,
          ),
        );
        final restored = (await notes.get(paged, pageId: dayTwo))!;
        expect(restored.markdown, contains('Rain until noon'));
        expect(
          noteFileLinksInMarkdown(restored.markdown).map((l) => l.id),
          isNot(contains(uploaded.id)),
        );
      }, timeout: const Timeout(Duration(minutes: 2)));

      // A note deleted while its editor still had text to save: the text
      // is kept as a new note, as the phone's editor recovers it.
      test('keeps the draft of a deleted note as a new note', () async {
        final api = runtime.container.read(apiServiceProvider)!;
        final notes = NotesService(runtime.container);
        final title = 'Live recovery ${DateTime.now().millisecondsSinceEpoch}';
        final created = await notes.save(
          NoteSave(
            title: title,
            ops: const <Map<String, dynamic>>[
              <String, dynamic>{'insert': 'First draft\n'},
            ],
          ),
        );
        final id = created.summary.id;
        // The editor has it open.
        expect(await notes.get(id), isNotNull);
        await notes.delete(id);
        final kept = await notes.save(
          NoteSave(
            id: id,
            title: title,
            ops: const <Map<String, dynamic>>[
              <String, dynamic>{'insert': 'Second draft\n'},
            ],
            baseOps: created.ops,
          ),
        );
        expect(kept.recoveredFrom, id);
        expect(kept.summary.id, isNot(id));
        expect(kept.summary.title, title);
        expect(kept.markdown, contains('Second draft'));
        // Kept through the outbox under a `local:` id. Once the server has
        // created it, that id still opens it, answered under the server's
        // id (the editor that holds the local one follows).
        expect(kept.summary.id, startsWith('local:'));
        await _waitFor(() async {
          final now = await notes.get(kept.summary.id);
          return now != null && !now.summary.id.startsWith('local:');
        }, seconds: 30);
        final synced = (await notes.get(kept.summary.id))!;
        expect(synced.markdown, contains('Second draft'));
        expect(synced.summary.title, title);
        addTearDown(() async {
          await notes.delete(synced.summary.id);
          await _waitFor(
            () async => (await notes.get(synced.summary.id)) == null,
            seconds: 30,
          );
          final (listed, _) = await api.getNotes();
          for (final note in listed) {
            final noteId = note['id'];
            if (note['title'] == title && noteId is String) {
              try {
                await api.deleteNote(noteId);
              } on Object catch (error) {
                stderr.writeln('could not delete recovery note: $error');
              }
            }
          }
        });
      }, timeout: const Timeout(Duration(minutes: 2)));

      // A recording made in a note: kept on this computer, uploaded and
      // attached through the core's controller (as the phone's recorder).
      test('keeps, uploads and attaches a recording to a note', () async {
        final directory = Directory.systemTemp.createTempSync('notes-audio');
        addTearDown(() => directory.deleteSync(recursive: true));
        final events = EventBus();
        final notes = NotesService(
          runtime.container,
          events: events,
          paths: DaemonDirectories.create(directory.path),
        );
        addTearDown(notes.dispose);
        final api = runtime.container.read(apiServiceProvider)!;
        final created = await notes.save(
          NoteSave(
            title: 'Live recording ${DateTime.now().millisecondsSinceEpoch}',
          ),
        );
        final id = created.summary.id;
        addTearDown(() async {
          try {
            await api.deleteNote(id);
          } on Object catch (error) {
            stderr.writeln('could not delete the recording note: $error');
          }
        });
        // One second of 16 kHz silence, as a WAV file.
        final wav = File('${directory.path}/recording.wav')
          ..writeAsBytesSync(_silentWav(16000));
        final added = await notes.addRecording(
          NoteRecordingAdd(noteId: id, path: wav.path),
        );
        expect(added.recordings, isNotEmpty);
        // While it waits, the window can play it from this computer
        // (`/recordings/{id}?noteId=`); once uploaded it no longer waits.
        try {
          final waiting = await notes.waitingRecording(
            id,
            added.recordings.first.id,
          );
          expect(waiting.contentType, 'audio/wav');
          expect(waiting.bytes, isNotEmpty);
        } on RpcError catch (error) {
          expect(error.code, ConduitErrorCodes.notFound);
        }
        Future<List<NoteFileLink>> links() async {
          final note = await notes.get(id);
          return noteFileLinksInMarkdown(note?.markdown ?? '');
        }

        await _waitFor(
          () async => (await links()).any((l) => l.name.endsWith('.wav')),
          seconds: 60,
        );
        expect((await links()).map((l) => l.name), contains(endsWith('.wav')));
        await _waitFor(
          () async => (await notes.recordings(id)).recordings.isEmpty,
          seconds: 30,
        );
        expect((await notes.recordings(id)).recordings, isEmpty);
      }, timeout: const Timeout(Duration(minutes: 2)));

      // Channels. This run's own channel, deleted at the end.
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
        // The replies, without the message they answer.
        expect(thread.messages.map((m) => m.id), <String>[reply.id]);

        final edited = await channels.editMessage(
          ChannelMessageEdit(
            channelId: channel.id,
            messageId: posted.id,
            content: 'Deploy is done.',
          ),
        );
        expect(edited.content, 'Deploy is done.');

        expect((await channels.members(channel.id)).users, isNotEmpty);

        // Its pane: a group the user made, whose members they manage.
        final details = await channels.open(channel.id);
        expect(details.channel.kind, ChannelKind.group);
        expect(details.channel.title, name);
        expect(details.canManageMembers, isTrue);
        final page = await channels.memberPage(
          ChannelMemberQuery(channelId: channel.id),
        );
        expect(page.phase, ChannelMemberListPhase.ready);
        expect(page.canManage, isTrue);
        expect(page.members.where((m) => m.me), hasLength(1));
        // Notify for mentions only, and back.
        var listed = await channels.setMuted(
          ChannelMute(id: channel.id, muted: true),
        );
        expect(
          listed.channels.firstWhere((c) => c.id == channel.id).muted,
          isTrue,
        );
        listed = await channels.setMuted(
          ChannelMute(id: channel.id, muted: false),
        );
        expect(
          listed.channels.firstWhere((c) => c.id == channel.id).muted,
          isFalse,
        );

        await channels.deleteMessage(
          ChannelMessageRef(channelId: channel.id, messageId: posted.id),
        );
        messages = (await channels.messages(
          ChannelMessagesQuery(channelId: channel.id),
        )).messages;
        expect(messages.map((m) => m.id), isNot(contains(posted.id)));

        // Edited by its manager.
        final renamed = await channels.save(
          ChannelEdit(id: channel.id, name: '$name-renamed'),
        );
        expect(renamed.channels.map((c) => c.name), contains('$name-renamed'));

        final after = await channels.delete(channel.id);
        deleted = true;
        expect(after.channels.map((c) => c.id), isNot(contains(channel.id)));
      }, timeout: const Timeout(Duration(minutes: 2)));

      // The seeded group with the second user: `@` offers its members, and
      // the members sheet adds and removes them.
      test('mentions and members of the seeded group', () async {
        final channelId = credentials!.values['OWUI_CHANNEL'];
        final second = credentials.values['OWUI_SECOND_NAME'];
        if (channelId == null || second == null) {
          markTestSkipped('no seeded group (owui.sh reset)');
          return;
        }
        final channels = ChannelsService(runtime.container);
        final details = await channels.open(channelId);
        expect(details.channel.unread, 0);
        final mentions = await channels.mentions(
          ChannelMentionQuery(
            channelId: channelId,
            query: second.substring(0, 3),
          ),
        );
        expect(mentions.users.map((u) => u.name), contains(second));
        var page = await channels.memberPage(
          ChannelMemberQuery(channelId: channelId),
        );
        final riley = page.members.firstWhere((m) => m.name == second);
        expect(page.canManage, isTrue);
        var change = await channels.removeMember(
          ChannelMemberRemove(channelId: channelId, userId: riley.id),
        );
        expect(change.result, ChannelMemberChangeResult.done);
        expect(change.page.members.map((m) => m.id), isNot(contains(riley.id)));
        change = await channels.addMembers(
          ChannelMembersAdd(channelId: channelId, userIds: <String>[riley.id]),
        );
        expect(change.result, ChannelMemberChangeResult.done);
        expect(change.page.members.map((m) => m.id), contains(riley.id));
        page = await channels.memberPage(
          ChannelMemberQuery(channelId: channelId, query: 'zzz-nobody'),
        );
        expect(page.members, isEmpty);
      }, timeout: const Timeout(Duration(minutes: 2)));

      // A terminal. A fake terminal server on this computer, added to
      // the account's settings as a direct server for the length of the
      // test and taken out again at the end.
      test(
        'a terminal: servers, files, ports, a shell and a preview',
        () async {
          final api = runtime.container.read(apiServiceProvider)!;
          final fake = await FakeTerminalServer.start(
            key: 'live-${DateTime.now().millisecondsSinceEpoch}',
          );
          Future<void> editServers(
            List<dynamic> Function(List<dynamic> servers) edit,
          ) => api.serializeUserSettingsMutation(() async {
            final settings = await api.getUserSettings();
            final ui = Map<String, dynamic>.from(
              (settings['ui'] as Map?) ?? const <String, dynamic>{},
            );
            ui['terminalServers'] = edit(
              List<dynamic>.from((ui['terminalServers'] as List?) ?? const []),
            );
            await api.updateUserSettings(<String, dynamic>{
              ...settings,
              'ui': ui,
            });
          });
          addTearDown(() async {
            try {
              await editServers(
                (servers) => [
                  for (final s in servers)
                    if (s is! Map || s['url'] != fake.url) s,
                ],
              );
            } on Object catch (error) {
              stderr.writeln('could not remove the test terminal: $error');
            }
            await fake.close();
          });
          await editServers(
            (servers) => [
              ...servers,
              <String, dynamic>{
                'url': fake.url,
                'key': fake.key,
                'name': 'Live fake terminal',
                'enabled': false,
                'config': <String, dynamic>{'enable': true},
              },
            ],
          );

          final terminals = TerminalsService(runtime.container);
          addTearDown(terminals.dispose);
          final listed = await terminals.servers('');
          final mine = listed.servers.singleWhere((s) => s.id == fake.url);
          expect(mine.kind, 'direct');
          expect(mine.name, 'Live fake terminal');
          final selected = await terminals.select(fake.url);
          expect(selected.selectedId, fake.url);

          final attached = await terminals.attach(
            TerminalAttach(serverId: fake.url),
          );
          expect(attached.supported, isTrue);
          expect(attached.cwd, '/work/');
          final handle = attached.handle;

          var listing = await terminals.list(
            TerminalPath(handle: handle, path: '/work'),
          );
          expect(listing.path, '/work/');
          expect(listing.entries.map((e) => e.name), <String>['notes.txt']);
          final read = await terminals.read(
            TerminalPath(handle: handle, path: '/work/notes.txt'),
          );
          expect(read.text, 'hello from the terminal\n');
          final saved = await terminals.download(
            TerminalPath(handle: handle, path: '/work/notes.txt'),
          );
          expect(utf8.decode(base64Decode(saved.base64!)), read.text);

          await terminals.upload(
            handle: handle,
            directory: '/work/',
            name: 'up.txt',
            bytes: utf8.encode('uploaded'),
          );
          await terminals.fileAction(
            TerminalFileAction(
              handle: handle,
              op: TerminalFileOp.mkdir,
              path: '/work/src',
            ),
          );
          listing = await terminals.list(
            TerminalPath(handle: handle, path: '/work/'),
          );
          // Folders first.
          expect(listing.entries.map((e) => e.name), <String>[
            'src',
            'notes.txt',
            'up.txt',
          ]);
          expect(listing.entries.first.directory, isTrue);
          expect(utf8.decode(fake.files['/work/up.txt']!), 'uploaded');
          await terminals.fileAction(
            TerminalFileAction(
              handle: handle,
              op: TerminalFileOp.move,
              path: '/work/up.txt',
              destination: '/work/src/up.txt',
            ),
          );
          await terminals.fileAction(
            TerminalFileAction(
              handle: handle,
              op: TerminalFileOp.delete,
              path: '/work/src/',
            ),
          );
          expect(fake.files.keys, <String>['/work/', '/work/notes.txt']);

          final ports = await terminals.ports(handle);
          expect(ports.ports.single.port, 3000);
          expect(ports.ports.single.process, 'node');
          // The page's scope, as mobile's sidebar terminal uses.
          expect(fake.sessionIds, contains('sidebar-terminal'));

          // The shell: the daemon authenticates, then it is a pipe.
          final tunnelServer = await shelf_io.serve(
            webSocketHandler(
              (WebSocketChannel socket, String? _) =>
                  unawaited(terminals.tunnel(handle, socket)),
            ),
            InternetAddress.loopbackIPv4,
            0,
          );
          addTearDown(() => tunnelServer.close(force: true));
          final window = WebSocketChannel.connect(
            Uri.parse('ws://127.0.0.1:${tunnelServer.port}'),
          );
          final output = StreamIterator(window.stream);
          Future<String> next() async {
            expect(
              await output.moveNext().timeout(const Duration(seconds: 10)),
              isTrue,
            );
            final message = output.current;
            return message is String
                ? message
                : utf8.decode(message as List<int>);
          }

          expect(await next(), 'ready\r\n');
          expect(fake.authFrames.single, <String, dynamic>{
            'type': 'auth',
            'token': fake.key,
          });
          window.sink.add(
            jsonEncode(<String, dynamic>{
              'type': 'resize',
              'cols': 100,
              'rows': 30,
            }),
          );
          window.sink.add(utf8.encode('ls\r'));
          expect(await next(), 'echo:ls\r');
          expect(fake.controlFrames.single['type'], 'resize');
          await window.sink.close();

          // A port, through a listener of its own that wants its key first.
          final preview = await terminals.previewPort(
            TerminalPortRef(handle: handle, port: 3000),
          );
          final entry = Uri.parse(preview.url);
          final client = HttpClient();
          addTearDown(() => client.close(force: true));
          final refused = await (await client.getUrl(entry.replace(path: '/')))
              .close();
          expect(refused.statusCode, HttpStatus.forbidden);
          await refused.drain<void>();
          final first = await client.getUrl(entry);
          first.followRedirects = false;
          final keyed = await first.close();
          expect(keyed.statusCode, HttpStatus.found);
          final cookie = keyed.cookies.single;
          await keyed.drain<void>();
          final page = await client.getUrl(entry.replace(path: '/app'));
          page.cookies.add(cookie);
          final shown = await page.close();
          expect(shown.statusCode, HttpStatus.ok);
          expect(
            await utf8.decoder.bind(shown).join(),
            '<h1>preview of /app</h1>',
          );
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );

      // The server's own terminal (owui.sh's fake Open Terminal, "Build
      // box"): live changes through its events socket, a preview that lands
      // on a page, and the Computer relay putting the token in.
      test(
        "the server's terminal: live changes, a preview, Computer",
        () async {
          final events = EventBus();
          final portsSeen = Completer<TerminalChanged>();
          var filesSeen = Completer<void>();
          var count = 0;
          events
            ..attach('window', (e) {
              if (e.event != ConduitEvents.terminalChanged) return;
              count++;
              final changed = TerminalChanged.fromJson(e.payload);
              if (changed.ports != null && !portsSeen.isCompleted) {
                portsSeen.complete(changed);
              }
              if (changed.files && !filesSeen.isCompleted) {
                filesSeen.complete();
              }
            })
            ..subscribe(
              'window',
              EventSubscription(
                events: <String>[ConduitEvents.terminalChanged],
              ),
            );
          final terminals = TerminalsService(runtime.container, events: events);
          addTearDown(terminals.dispose);
          final listed = await terminals.servers('');
          final box = listed.servers.where((s) => s.id == 'buildbox');
          if (box.isEmpty) {
            markTestSkipped('the server runs without the fake terminal');
            return;
          }
          final previous = listed.selectedId;
          addTearDown(() => terminals.select(previous));
          await terminals.select('buildbox');
          final attached = await terminals.attach(
            const TerminalAttach(serverId: 'buildbox'),
          );
          final handle = attached.handle;
          final watching = terminals.watch(
            TerminalWatch(handle: handle, path: '/home/demo'),
          );
          expect(watching.live, isTrue);
          expect((await portsSeen.future).ports!.single.port, 5173);
          final folder =
              '/home/demo/live-${DateTime.now().millisecondsSinceEpoch}';
          // Only the folder's own change counts: the wait starts here.
          filesSeen = Completer<void>();
          await terminals.fileAction(
            TerminalFileAction(
              handle: handle,
              op: TerminalFileOp.mkdir,
              path: folder,
            ),
          );
          addTearDown(() async {
            try {
              await terminals.fileAction(
                TerminalFileAction(
                  handle: handle,
                  op: TerminalFileOp.delete,
                  path: folder,
                ),
              );
            } on RpcError {
              // Gone already, or the handle went with the test's end.
            }
          });
          await filesSeen.future;
          await terminals.fileAction(
            TerminalFileAction(
              handle: handle,
              op: TerminalFileOp.delete,
              path: folder,
            ),
          );

          // The preview lands on the page asked for; a request with Open
          // WebUI's proxy prefix in it loses the prefix.
          final preview = await terminals.previewPort(
            TerminalPortRef(handle: handle, port: 5173),
          );
          expect(preview.scripts, isNotEmpty);
          final client = HttpClient();
          addTearDown(() => client.close(force: true));
          final entry = Uri.parse(preview.url);
          final first = await client.getUrl(
            entry.replace(queryParameters: <String, String>{'to': '/about'}),
          );
          first.followRedirects = false;
          final keyed = await first.close();
          expect(keyed.headers.value('location'), '/about');
          final cookie = keyed.cookies.single;
          await keyed.drain<void>();
          final about = await client.getUrl(entry.replace(path: '/about'));
          about.cookies.add(cookie);
          final shown = await about.close();
          expect(
            await utf8.decoder.bind(shown).join(),
            contains('About the Log'),
          );
          final style = await client.getUrl(
            entry.replace(
              path: '/api/v1/terminals/buildbox/proxy/5173/style.css',
            ),
          );
          style.cookies.add(cookie);
          final css = await style.close();
          expect(css.statusCode, HttpStatus.ok);
          expect(await utf8.decoder.bind(css).join(), contains('font:'));

          await terminals.detach(handle);
          final before = count;
          await terminals.detach(handle);
          expect(count, before);

          // Computer: the desktop streams through a relay that holds the
          // token; the viewer's own auth carries none.
          final computer = ComputerRpcService(runtime.container);
          addTearDown(computer.dispose);
          // A chat the server holds: Open WebUI 0.13.4 refuses a terminal
          // request naming a saved chat it cannot find.
          final computerChat = await runtime.container
              .read(apiServiceProvider)!
              .createConversation(
                title: 'live-computer-chat',
                messages: const <ChatMessage>[],
              );
          created.add(computerChat.id);
          final chatId = computerChat.id;
          final status = await computer.status(chatId);
          expect(status.enabled, isTrue);
          expect(status.desktop, isTrue);
          expect((await computer.status('')).desktop, isFalse);
          final view = await computer.open(
            ComputerOpen(chatId: chatId, surface: ComputerSurfaceKind.desktop),
          );
          expect(view.state, ComputerViewState.live);
          expect(view.transport, 'frames');
          final socket = await WebSocket.connect(
            view.streamUrl!,
            headers: <String, String>{'origin': 'http://127.0.0.1'},
          );
          addTearDown(socket.close);
          socket.add(
            jsonEncode(<String, String>{
              'type': 'auth',
              'token': '',
              'chat_id': chatId,
            }),
          );
          final frame = jsonDecode(
            await socket.first.timeout(const Duration(seconds: 10)) as String,
          ) as Map<String, dynamic>;
          expect(frame['type'], 'frame');
          await computer.close(view.handle!);
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );

      // The Build box's coding agents (its fake `/agents`): listed with the
      // terminal chosen, their controls, and the default model back once
      // the terminal is turned off.
      test(
        "the terminal's coding agents as models",
        () async {
          final terminals = TerminalsService(runtime.container);
          addTearDown(terminals.dispose);
          final listed = await terminals.servers('');
          if (!listed.servers.any((s) => s.id == 'buildbox')) {
            markTestSkipped('the server runs without the fake terminal');
            return;
          }
          final service = ModelsService(runtime.container, events: EventBus());
          // Open WebUI 0.13.4 keeps an agent's model to letters, digits, `_`
          // and `-` in its id, adding a hash of the name when that changed it
          // (`utils/agents/session.py`); older releases use the name as is.
          const codexIds = {
            'agent:buildbox:codex:gpt-5.1',
            'agent:buildbox:codex:gpt-5-1-e7ee8b01',
          };
          final before = (await service.list()).selectedId;
          final previous = listed.selectedId;
          addTearDown(() async {
            await terminals.select(previous);
            if (before != null) await service.select(before);
          });
          await terminals.select('buildbox');
          final offered = await service.list();
          final codex = offered.agents
              .map((a) => a.id)
              .firstWhere(codexIds.contains, orElse: () => '');
          expect(codex, isIn(codexIds));
          final agent = offered.agents.firstWhere((a) => a.id == codex);
          expect(agent.name, 'Codex · gpt-5.1');
          expect(agent.agent?.terminalName, 'Build box');
          // A temporary chat is offered none.
          expect(
            (await service.list(const ModelListQuery(temporary: true))).agents,
            isEmpty,
          );

          final picked = await service.select(codex);
          expect(picked.selectedId, codex);
          final options = await service.options(const ModelOptionsQuery());
          expect(options.modelId, codex);
          expect(options.reasoning.visible, isFalse);
          final controls = await service.controls(const ModelControlsQuery());
          expect(controls.controls.map((c) => c.key), [
            'reasoning_effort',
            'service_tier',
          ]);

          // As a window does: the model, then the agent again.
          final plain = offered.models.first.id;
          await service.select(plain);
          expect((await service.options(const ModelOptionsQuery())).modelId,
              plain);
          expect((await service.select(codex)).selectedId, codex);

          final cleared = await terminals.select(null);
          expect(cleared.selectedId, isNull);
          await _waitFor(
            () async =>
                !((await currentModel(runtime.container))?.id ?? codex)
                    .startsWith('agent:'),
            seconds: 15,
          );
          final after = await service.list();
          expect(after.selectedId, isNot(startsWith('agent:')));
          expect(after.agents, isEmpty);
          expect((await terminals.servers('')).selectedId, isNull);
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );

      // Dictation and speech. The server transcribes a recording: the local
      // server's speech-to-text is the fake model, which answers every
      // recording with the same synthetic sentence, so a tone checks the
      // route. (CONDUIT_SPEECH_SAMPLE's real sentence is for the local
      // Whisper tests, which do hear it.)
      test('transcribes a recording and makes speech jobs', () async {
        final voice = VoiceService(runtime.container);
        final settings = await voice.settings();
        expect(settings.splitOn, isNotEmpty);
        if (!settings.serverStt) {
          markTestSkipped('the server does not transcribe');
          return;
        }
        final transcript = await voice.transcribe(
          _toneWav(),
          contentType: 'audio/wav',
        );
        expect(transcript.text, 'A synthetic transcript from the fake model.');

        final job = await voice.speak(const VoiceSpeak(text: 'Hello there.'));
        expect(job.jobId, startsWith('tts-'));
        await expectLater(
          voice.audio('tts-unknown'),
          throwsA(
            isA<RpcError>().having(
              (e) => e.code,
              'code',
              ConduitErrorCodes.notFound,
            ),
          ),
        );
        if (settings.serverTts) {
          final audio = await voice.audio(job.jobId);
          expect(audio.bytes, isNotEmpty);
          expect(audio.contentType, startsWith('audio/'));
        }
      }, timeout: const Timeout(Duration(minutes: 2)));

      // Dictation: the server's engine for an Open WebUI model, and a
      // recording kept with a new chat's draft, transcribed from there.
      test(
        'dictates through the model\'s server and keeps the recording',
        () async {
          final voice = VoiceService(runtime.container);
          final dictation = DictationService(runtime.container, voice: voice);
          final status = await dictation.status(const DictationTarget());
          if (!status.serverAvailable) {
            markTestSkipped('the server does not transcribe');
            return;
          }
          expect(status.serverSource, 'openWebUi');
          final heard = await dictation.transcribe(
            _toneWav(),
            contentType: 'audio/wav',
            engine: 'server',
          );
          expect(heard.text, isNotEmpty);

          final recordings = RecordingsService(
            drafts: DraftsService(
              runtime.container,
              temporary: TemporaryChats(),
            ),
            dictation: dictation,
          );
          const target = RecordingTarget(folderId: 'live-dictation');
          final id = (await recordings.begin(target, sessionId: 'live')).id!;
          addTearDown(
            () => recordings.discard(
              RecordingRef(id: id, folderId: 'live-dictation'),
            ),
          );
          final tone = _toneWav();
          await recordings.append(
            RecordingChunk(id: id, pcm: base64Encode(tone.sublist(44))),
          );
          await recordings.close(RecordingRef(id: id));
          final transcript = await recordings.transcribe(
            RecordingTranscribe(id: id, folderId: 'live-dictation'),
          );
          expect(transcript.text, isNotEmpty);
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );

      // Settings parity: the account's profile, its memories and
      // system prompt, a model's prompt, the composer's pills, Chat Data
      // Controls and the socket's health. Every change is put back.
      group('settings parity', () {
        test('edits the profile and puts it back', () async {
          final profile = ProfileService(runtime.container);
          final before = await profile.get();
          expect(before.email, credentials!.email);
          expect(before.name, isNotEmpty);
          final edited = await profile.update(
            ProfileEdit(
              bio: 'Keeps bees on a quiet roof.',
              gender: 'beekeeper',
              dateOfBirth: '1991-02-03',
            ),
          );
          addTearDown(() async {
            await profile.update(
              ProfileEdit(
                name: before.name,
                bio: before.bio,
                gender: before.gender,
                dateOfBirth: before.dateOfBirth,
                clear: <String>[
                  if (before.bio == null) 'bio',
                  if (before.gender == null) 'gender',
                  if (before.dateOfBirth == null) 'dateOfBirth',
                ],
              ),
            );
          });
          expect(edited.bio, 'Keeps bees on a quiet roof.');
          expect(edited.gender, 'beekeeper');
          expect(edited.dateOfBirth, '1991-02-03');
          await expectLater(
            profile.update(const ProfileEdit(name: '  ')),
            throwsA(
              isA<RpcError>().having(
                (e) => e.code,
                'code',
                ConduitErrorCodes.invalidParams,
              ),
            ),
          );

          // The initials as the photo, then none.
          final withInitials = await profile.setImage(
            const ProfileImageEdit(initials: true),
          );
          expect(withInitials.image, startsWith('data:image/png;base64,'));
          final removed = await profile.removeImage();
          expect(removed.image, isNull);
          final restored = await profile.update(ProfileEdit(name: before.name));
          expect(restored.name, before.name);
        });

        // Notifications parity: the settings, mirrored to the account
        // where the phone mirrors them, and core's decision per notification.
        test(
          'notification settings and the decision per notification',
          () async {
            final service = NotificationsService(runtime.container);
            final start = service.get();
            expect(start.synced, isTrue);
            // The desktop's host default: on until the user or server says.
            expect(start.enabled, isTrue);
            addTearDown(
              () => service.set(
                NotificationSettingsPatch(
                  soundAlways: start.soundAlways,
                  inAppBanner: start.inAppBanner,
                  mentionsOnly: start.mentionsOnly,
                ),
              ),
            );
            final set = await service.set(
              const NotificationSettingsPatch(
                soundAlways: true,
                inAppBanner: false,
                mentionsOnly: true,
              ),
            );
            expect(set.soundAlways, isTrue);
            expect(set.inAppBanner, isFalse);
            expect(set.mentionsOnly, isTrue);
            // Sound Always reached the account (Open WebUI's `ui` settings).
            final api = runtime.container.read(apiServiceProvider)!;
            var mirrored = false;
            for (var i = 0; i < 20 && !mirrored; i++) {
              final settings = await api.getUserSettings();
              final ui = settings['ui'];
              mirrored = ui is Map && ui['notificationSoundAlways'] == true;
              if (!mirrored) {
                await Future<void>.delayed(const Duration(milliseconds: 100));
              }
            }
            expect(mirrored, isTrue);

            // In front with the banner off: silent, with the cue.
            final front = service.route(
              const NotificationRouteParams(
                kind: NotifyKind.answer,
                foreground: true,
              ),
            );
            expect(front.surface, NotifySurface.silent);
            expect(front.cue, isTrue);
            // Behind: a system notification with its sound.
            final behind = service.route(
              const NotificationRouteParams(kind: NotifyKind.answer),
            );
            expect(behind.surface, NotifySurface.system);
            expect(behind.systemSound, isTrue);
            // Mentions only: a plain channel message stays quiet, a mention
            // and a direct message notify.
            expect(
              service
                  .route(
                    const NotificationRouteParams(
                      kind: NotifyKind.channelMessage,
                    ),
                  )
                  .surface,
              NotifySurface.suppressed,
            );
            expect(
              service
                  .route(
                    const NotificationRouteParams(
                      kind: NotifyKind.channelMessage,
                      mention: true,
                    ),
                  )
                  .surface,
              NotifySurface.system,
            );
            expect(
              service
                  .route(
                    const NotificationRouteParams(
                      kind: NotifyKind.channelMessage,
                      direct: true,
                    ),
                  )
                  .surface,
              NotifySurface.system,
            );
          },
        );

        test('adds, tests, edits and deletes a webhook destination', () async {
          final webhooks = WebhooksService(runtime.container);
          final start = await webhooks.list();
          expect(start.available, isTrue);
          expect(start.failed, isFalse);
          expect(start.events, isNotEmpty);
          final base = credentials!.values['FAKE_OPENAI_URL']!.replaceFirst(
            RegExp(r'/v1/?$'),
            '',
          );
          final created = await webhooks.create(
            WebhookCreate(
              owner: start.owner,
              url: '$base/webhook/live-n6',
              name: 'live-n6-hook',
              events: <String>[start.events.first.event],
            ),
          );
          final hook = created.items.firstWhere((h) => h.id == 'live-n6-hook');
          addTearDown(() async {
            final now = await webhooks.list();
            if (now.items.any((h) => h.id == hook.id)) {
              await webhooks.delete(WebhookRef(owner: now.owner, id: hook.id));
            }
          });
          expect(hook.enabled, isTrue);
          expect(hook.events, <String>[start.events.first.event]);
          expect(hook.maskedUrl, isNotNull);
          expect(hook.maskedUrl, isNot(contains('live-n6')));

          // Test: the server delivers one notification to the receiver.
          final log = File(credentials.values['FAKE_MODEL_LOG']!);
          final before = log.existsSync() ? log.readAsLinesSync().length : 0;
          await webhooks.test(WebhookRef(owner: created.owner, id: hook.id));
          var delivered = false;
          for (var i = 0; i < 50 && !delivered; i++) {
            final lines = log.readAsLinesSync().skip(before);
            delivered = lines.any((l) => l.contains('/webhook/live-n6'));
            if (!delivered) {
              await Future<void>.delayed(const Duration(milliseconds: 100));
            }
          }
          expect(delivered, isTrue);

          final edited = await webhooks.update(
            WebhookUpdate(
              owner: created.owner,
              id: hook.id,
              enabled: false,
              delivery: 'always',
            ),
          );
          final after = edited.items.firstWhere((h) => h.id == hook.id);
          expect(after.enabled, isFalse);
          expect(after.delivery, 'always');
          final made = await webhooks.makeDefault(
            WebhookRef(owner: edited.owner, id: hook.id),
          );
          expect(made.items.firstWhere((h) => h.id == hook.id).isDefault, true);
          // An owner that was never handed out is refused.
          await expectLater(
            webhooks.delete(WebhookRef(owner: 'w-none', id: hook.id)),
            throwsA(isA<RpcError>()),
          );
          final deleted = await webhooks.delete(
            WebhookRef(owner: made.owner, id: hook.id),
          );
          expect(deleted.items.any((h) => h.id == hook.id), isFalse);
        });

        test('a personal tool server runs its tool here, and is edited and '
            'deleted', () async {
          final integrations = IntegrationsService(runtime.container);
          final start = await integrations.list();
          expect(start.access, PersonalAccess.allowed);
          final base = credentials!.values['FAKE_OPENAI_URL']!.replaceFirst(
            RegExp(r'/v1/?$'),
            '',
          );
          const draft = PersonalConnectionDraft(
            name: 'Live Buoys',
            url: 'http://127.0.0.1:9/personal',
            path: 'openapi.json',
            authType: 'none',
          );
          // A form problem is the URL's.
          await expectLater(
            integrations.save(
              PersonalConnectionSave(
                owner: start.owner,
                kind: PersonalKind.toolServer,
                op: PersonalEditOp.add,
                draft: draft.copyWith(url: 'not a url'),
              ),
            ),
            throwsA(
              isA<RpcError>().having((e) => e.args['url'], 'url', 'urlInvalid'),
            ),
          );
          // Unreachable, then reachable with one operation.
          final unreachable = await integrations.test(
            PersonalConnectionTest(
              owner: start.owner,
              kind: PersonalKind.toolServer,
              draft: draft,
            ),
          );
          expect(unreachable.ok, isFalse);
          final good = draft.copyWith(url: '$base/personal');
          final probed = await integrations.test(
            PersonalConnectionTest(
              owner: start.owner,
              kind: PersonalKind.toolServer,
              draft: good,
            ),
          );
          expect(probed.ok, isTrue);
          expect(probed.operationCount, 1);

          final added = await integrations.save(
            PersonalConnectionSave(
              owner: start.owner,
              kind: PersonalKind.toolServer,
              op: PersonalEditOp.add,
              draft: good,
            ),
          );
          final server = added.toolServers.firstWhere(
            (s) => s.name == 'Live Buoys',
          );
          addTearDown(() async {
            final now = await integrations.list();
            for (final s in now.toolServers.where(
              (s) => s.name.startsWith('Live Buoys'),
            )) {
              await integrations.save(
                PersonalConnectionSave(
                  owner: now.owner,
                  kind: PersonalKind.toolServer,
                  op: PersonalEditOp.remove,
                  identity: s.identity,
                ),
              );
            }
          });
          expect(server.endpoint, '$base/personal');
          expect(server.enabled, isTrue);

          // The composer offers it, and a turn that chooses it runs its
          // tool here: the answer quotes the reading.
          final options = await ComposerService(runtime.container).options();
          final tool = options.tools.firstWhere((t) => t.name == 'Live Buoys');
          expect(tool.id, startsWith('direct_server:'));
          final log = File(credentials.values['FAKE_MODEL_LOG']!);
          final before = log.existsSync() ? log.readAsLinesSync().length : 0;
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
            SendTurn(
              model: turnModel,
              text: 'What does the buoy say?',
              toolIds: <String>[tool.id],
            ),
          );
          created.add(accepted.chatId);
          subscribeWindow(events, turns, 'probe', <String>[accepted.chatId]);
          final deadline = DateTime.now().add(const Duration(seconds: 90));
          while (DateTime.now().isBefore(deadline) &&
              !seen.contains(ConduitEvents.turnCompleted) &&
              !seen.contains(ConduitEvents.turnFailed)) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
          expect(
            seen,
            contains(ConduitEvents.turnCompleted),
            reason: 'failed: ${payloads[ConduitEvents.turnFailed]}',
          );
          final completed = TurnCompleted.fromJson(
            payloads[ConduitEvents.turnCompleted]!,
          );
          expect(completed.text, contains('North Mole buoy reads 0.8 m'));
          final calls = log
              .readAsLinesSync()
              .skip(before)
              .where((l) => l.contains('"personal_tool"'));
          expect(calls, isNotEmpty);

          // Switched off, renamed, deleted.
          final off = await integrations.save(
            PersonalConnectionSave(
              owner: added.owner,
              kind: PersonalKind.toolServer,
              op: PersonalEditOp.setEnabled,
              identity: server.identity,
              enabled: false,
            ),
          );
          expect(
            off.toolServers
                .firstWhere((s) => s.identity == server.identity)
                .enabled,
            isFalse,
          );
          final renamed = await integrations.save(
            PersonalConnectionSave(
              owner: off.owner,
              kind: PersonalKind.toolServer,
              op: PersonalEditOp.patch,
              identity: server.identity,
              draft: good.copyWith(
                name: 'Live Buoys East',
                keyMode: PersonalKeyMode.keep,
                enabled: false,
              ),
            ),
          );
          final east = renamed.toolServers.firstWhere(
            (s) => s.name == 'Live Buoys East',
          );
          final removed = await integrations.save(
            PersonalConnectionSave(
              owner: renamed.owner,
              kind: PersonalKind.toolServer,
              op: PersonalEditOp.remove,
              identity: east.identity,
            ),
          );
          expect(
            removed.toolServers.any((s) => s.name.startsWith('Live Buoys')),
            isFalse,
          );
          // Skipped: 0.13.4 moved these into Tether (Tether device follow-up).
        }, skip: _movedToTether, timeout: const Timeout(Duration(minutes: 3)));

        test('adds, edits and deletes a memory', () async {
          final memories = MemoriesService(runtime.container);
          final start = await memories.list();
          expect(start.available, isTrue);
          final added = await memories.add(
            const MemoryEdit(content: 'Waters the ferns on Sundays.'),
          );
          final memory = added.items.firstWhere(
            (m) => m.content == 'Waters the ferns on Sundays.',
          );
          addTearDown(() async {
            final now = await memories.list();
            if (now.items.any((m) => m.id == memory.id)) {
              await memories.delete(MemoryRef(id: memory.id));
            }
          });
          expect(memory.type, 'user');
          final edited = await memories.update(
            MemoryEdit(
              id: memory.id,
              content: 'Waters the ferns on Sundays and Thursdays.',
              path: 'home/plants',
            ),
          );
          final updated = edited.items.firstWhere((m) => m.id == memory.id);
          expect(updated.content, 'Waters the ferns on Sundays and Thursdays.');
          expect(updated.path, 'home/plants');
          final deleted = await memories.delete(MemoryRef(id: memory.id));
          expect(deleted.items.any((m) => m.id == memory.id), isFalse);
          expect(deleted.items.length, start.items.length);

          // The Memory setting round-trips, and is put back however the
          // test ends.
          addTearDown(
            () => memories.setEnabled(MemoryToggle(enabled: start.enabled)),
          );
          final toggled = await memories.setEnabled(
            MemoryToggle(enabled: !start.enabled),
          );
          expect(toggled.enabled, !start.enabled);
          final back = await memories.setEnabled(
            MemoryToggle(enabled: start.enabled),
          );
          expect(back.enabled, start.enabled);
        });

        test("the account's system prompt and a model's prompt", () async {
          final settings = CoreSettingsService(runtime.container);
          final before = await settings.getAccount();
          expect(before.available, isTrue);
          addTearDown(
            () => settings.setAccount(
              AccountSettingsPatch(systemPrompt: before.systemPrompt ?? ''),
            ),
          );
          final set = await settings.setAccount(
            const AccountSettingsPatch(systemPrompt: 'Answer like a gardener.'),
          );
          expect(set.systemPrompt, 'Answer like a gardener.');
          final cleared = await settings.setAccount(
            const AccountSettingsPatch(systemPrompt: ''),
          );
          expect(cleared.systemPrompt, isNull);

          // The seeded admin has a saved record for the fake model.
          final prompt = await settings.modelPrompt(
            ModelPromptRef(modelId: turnModel),
          );
          expect(prompt.editable, isTrue);
          expect(prompt.writable, isTrue);

          final pills = await settings.quickPills();
          expect(pills.options.take(2).map((o) => o.id), <String>[
            'web',
            'image',
          ]);
          final about = await settings.about();
          expect(about.server, isTrue);
          expect(about.serverVersion, isNotEmpty);
        });

        test(
          'Chat Data Controls count, export and read back a backup',
          () async {
            final data = DataService(runtime.container);
            // Sync first: the counts are of the chats stored here.
            final summary = await data.sync();
            expect(summary.available, isTrue);
            expect(summary.serverChats, greaterThan(0));
            expect(summary.canExport, isTrue);
            final file = File('${temporary.path}/library.json');
            final exported = await data.export(
              DataExportRequest(path: file.path),
            );
            expect(exported.failure, isNull);
            expect(exported.count, greaterThan(0));
            final chats = jsonDecode(file.readAsStringSync()) as List<dynamic>;
            expect(chats.length, exported.count);
            // Nothing left beside it.
            expect(
              temporary.listSync().where((f) => f.path.contains('.partial')),
              isEmpty,
            );
            final preview = await data.previewImport(
              DataImportRequest(path: file.path),
            );
            expect(preview.failure, isNull);
            expect(preview.count, exported.count);
            expect(preview.messages, greaterThan(0));

            final health = data.connection();
            expect(health.available, isTrue);
            expect(health.transport, isNotEmpty);
          },
        );
      });

      // The workspace. Everything is named for this run and deleted
      // at the end, straight through the API if a step fails first.
      group('workspace', () {
        late WorkspaceService workspace;
        late List<String> heard;
        final stamp = DateTime.now().millisecondsSinceEpoch;
        // Deletions still owed, by what they delete; a test that deletes its
        // own item takes its entry out.
        final cleanups = <String, Future<void> Function()>{};

        setUpAll(() {
          final events = EventBus();
          heard = <String>[];
          events.attach('window', (envelope) => heard.add(envelope.event));
          workspace = WorkspaceService(runtime.container, events: events);
        });

        tearDownAll(() async {
          for (final cleanup in cleanups.values.toList().reversed) {
            try {
              await cleanup();
            } on Object catch (error) {
              stderr.writeln('could not clean up a workspace test: $error');
            }
          }
        });

        test('says what the user may manage', () async {
          final access = await workspace.capabilities();
          expect(access.prompts.manage, isTrue);
          expect(access.models.manage, isTrue);
        });

        test(
          'a prompt: saved, versioned, diffed, exported, imported',
          () async {
            final api = runtime.container.read(apiServiceProvider)!;
            final command = 'live-prompt-$stamp';
            final created = await workspace.save(
              WorkspaceSave(
                create: true,
                detail: WorkspaceDetail(
                  kind: WorkspaceKind.prompts,
                  prompt: WorkspacePromptDto(
                    command: '/$command',
                    name: 'Live prompt',
                    content: 'Say hello to {{USER_NAME}}.',
                    tags: const <String>['live'],
                  ),
                ),
              ),
            );
            final id = created.prompt!.id;
            cleanups['prompt'] = () => api.deletePrompt(id);
            expect(created.prompt!.command, command);
            expect(heard, contains(ConduitEvents.workspaceChanged));

            final page = await workspace.list(
              WorkspaceQuery(kind: WorkspaceKind.prompts, query: command),
            );
            expect(page.items.map((i) => i.id), contains(id));
            expect(
              page.items.firstWhere((i) => i.id == id).subtitle,
              '/$command',
            );

            // Versions are ordered by when they were made.
            await _nextSecond();
            final updated = await workspace.save(
              WorkspaceSave(
                detail: created.copyWith(
                  prompt: created.prompt!.copyWith(
                    content: 'Say hello warmly to {{USER_NAME}}.',
                    commitMessage: 'Warmer',
                  ),
                ),
              ),
            );
            expect(updated.prompt!.content, contains('warmly'));

            final history = await workspace.promptHistory(id);
            expect(history.versions.length, greaterThanOrEqualTo(2));
            final newest = history.versions.first;
            final oldest = history.versions.last;
            expect(newest.production, isTrue);
            expect(newest.commitMessage, 'Warmer');
            final diff = await workspace.promptDiff(
              WorkspacePromptDiffQuery(
                promptId: id,
                fromId: oldest.id,
                toId: newest.id,
              ),
            );
            expect(diff.lines.join('\n'), contains('warmly'));

            final restored = await workspace.promptSetVersion(
              WorkspacePromptVersionRef(promptId: id, versionId: oldest.id),
            );
            expect(restored.prompt!.content, isNot(contains('warmly')));

            // A rename alone makes no new version.
            final renamed = await workspace.save(
              WorkspaceSave(
                metadataOnly: true,
                detail: restored.copyWith(
                  prompt: restored.prompt!.copyWith(
                    name: 'Live prompt renamed',
                  ),
                ),
              ),
            );
            expect(renamed.prompt!.name, 'Live prompt renamed');
            expect(
              (await workspace.promptHistory(id)).versions,
              hasLength(history.versions.length),
            );

            final exported = await workspace.export(
              WorkspaceExportQuery(kind: WorkspaceKind.prompts, id: id),
            );
            expect(exported.filename, '$command.json');
            final items = jsonDecode(exported.text!) as List;
            expect((items.single as Map)['command'], command);

            // The same file again clashes on the command; renamed, it goes in.
            final clash = await workspace.import(
              WorkspaceImport(
                kind: WorkspaceKind.prompts,
                text: exported.text!,
              ),
            );
            expect(clash.imported, 0);
            expect(clash.failed, hasLength(1));
            final copy = '$command-copy';
            final imported = await workspace.import(
              WorkspaceImport(
                kind: WorkspaceKind.prompts,
                text: exported.text!.replaceAll(command, copy),
              ),
            );
            expect(imported.imported, 1);
            final copies = await workspace.list(
              WorkspaceQuery(kind: WorkspaceKind.prompts, query: copy),
            );
            final copyId = copies.items
                .singleWhere((i) => i.subtitle == '/$copy')
                .id;
            cleanups['prompt copy'] = () => api.deletePrompt(copyId);

            await workspace.delete(
              WorkspaceRef(kind: WorkspaceKind.prompts, id: copyId),
            );
            cleanups.remove('prompt copy');
            await workspace.delete(
              WorkspaceRef(kind: WorkspaceKind.prompts, id: id),
            );
            cleanups.remove('prompt');
            final after = await workspace.list(
              WorkspaceQuery(kind: WorkspaceKind.prompts, query: command),
            );
            expect(after.items, isEmpty);
          },
          timeout: const Timeout(Duration(minutes: 2)),
        );

        test('a model: saved over a base, kept whole, toggled', () async {
          final api = runtime.container.read(apiServiceProvider)!;
          final options = await workspace.modelOptions();
          expect(options.baseModels, isNotEmpty);
          final base = options.baseModels.first.id;
          final id = 'live-model-$stamp';
          cleanups['model'] = () async => api.deleteWorkspaceModel(id);
          final created = await workspace.save(
            WorkspaceSave(
              create: true,
              detail: WorkspaceDetail(
                kind: WorkspaceKind.models,
                model: WorkspaceModelDto(
                  id: id,
                  name: 'Live model',
                  baseModelId: base,
                  description: 'Made by a test',
                  system: 'Answer in one word.',
                  suggestionPrompts: const <String>['Hello'],
                  capabilities: const <String, bool>{'vision': true},
                  terminalId: 'buildbox',
                  builtinTools: const <String, dynamic>{
                    'time': false,
                    'memory': true,
                  },
                  imageUrl: 'https://pictures.example/gull.png',
                  params: const <String, dynamic>{'temperature': 0.2},
                ),
              ),
            ),
          );
          final model = created.model!;
          expect(model.baseModelId, base);
          expect(model.system, 'Answer in one word.');
          expect(model.capabilities['vision'], isTrue);
          expect(model.params['temperature'], 0.2);
          expect(model.terminalId, 'buildbox');
          expect(model.builtinTools, {'time': false, 'memory': true});
          // Another site's picture is never fetched for the window.
          expect(model.imageSource, WorkspaceImageSource.remote);
          final raw0 = (await api.getWorkspaceModel(id))!;
          expect(raw0.meta['terminalId'], 'buildbox');
          expect(raw0.meta['builtinTools'], {'time': false, 'memory': true});

          // A key this editor does not show survives a save through it.
          final raw = (await api.getWorkspaceModel(id))!;
          await api.updateWorkspaceModel(
            WorkspaceModelForm(
              id: id,
              name: raw.name,
              baseModelId: raw.baseModelId,
              meta: <String, dynamic>{...raw.meta, 'live_marker': 'kept'},
              params: raw.params,
              isActive: raw.isActive,
            ),
          );
          final renamed = await workspace.save(
            WorkspaceSave(
              detail: (await workspace.get(
                WorkspaceRef(kind: WorkspaceKind.models, id: id),
              )).copyWith(model: model.copyWith(name: 'Live model renamed')),
            ),
          );
          expect(renamed.model!.name, 'Live model renamed');
          expect(
            (await api.getWorkspaceModel(id))!.meta['live_marker'],
            'kept',
          );
          final toggled = await workspace.toggle(
            WorkspaceRef(kind: WorkspaceKind.models, id: id),
          );
          expect(toggled.active, isFalse);
          final exported = await workspace.export(
            WorkspaceExportQuery(kind: WorkspaceKind.models, id: id),
          );
          expect(
            ((jsonDecode(exported.text!) as List).single as Map)['id'],
            id,
          );

          await workspace.delete(
            WorkspaceRef(kind: WorkspaceKind.models, id: id),
          );
          cleanups.remove('model');
          await expectLater(
            workspace.get(WorkspaceRef(kind: WorkspaceKind.models, id: id)),
            throwsA(
              isA<RpcError>().having(
                (e) => e.code,
                'code',
                ConduitErrorCodes.notFound,
              ),
            ),
          );
        }, timeout: const Timeout(Duration(minutes: 2)));

        test('a tool: saved, valves read and written, exported', () async {
          final api = runtime.container.read(apiServiceProvider)!;
          final id = 'live_tool_$stamp';
          cleanups['tool'] = () => api.deleteTool(id);
          final created = await workspace.save(
            WorkspaceSave(
              create: true,
              detail: WorkspaceDetail(
                kind: WorkspaceKind.tools,
                tool: WorkspaceToolDto(
                  id: id,
                  name: 'Live tool',
                  description: 'Echoes',
                  content: _liveToolSource,
                ),
              ),
            ),
          );
          expect(created.tool!.functions, contains('echo'));
          expect(created.tool!.hasValves, isTrue);
          expect(created.tool!.description, 'Echoes');

          final valves = await workspace.valves(
            WorkspaceValvesQuery(toolId: id),
          );
          expect((valves.schema['properties'] as Map).keys, contains('limit'));
          final saved = await workspace.saveValves(
            valves.copyWith(values: <String, dynamic>{'limit': 7}),
          );
          expect(saved.values['limit'], 7);

          final exported = await workspace.export(
            WorkspaceExportQuery(kind: WorkspaceKind.tools, id: id),
          );
          expect(exported.text, contains('class Tools'));

          await expectLater(
            workspace.toolFromUrl('http://169.254.169.254/latest'),
            throwsA(isA<RpcError>()),
          );

          await workspace.delete(
            WorkspaceRef(kind: WorkspaceKind.tools, id: id),
          );
          cleanups.remove('tool');
        }, timeout: const Timeout(Duration(minutes: 2)));

        test('a skill: saved, toggled, exported and imported', () async {
          final access = await workspace.capabilities();
          if (!access.skills.manage) {
            markTestSkipped('this server has no skills');
            return;
          }
          final api = runtime.container.read(apiServiceProvider)!;
          final id = 'live-skill-$stamp';
          cleanups['skill'] = () async => api.deleteWorkspaceSkill(id);
          final created = await workspace.save(
            WorkspaceSave(
              create: true,
              detail: WorkspaceDetail(
                kind: WorkspaceKind.skills,
                skill: WorkspaceSkillDto(
                  id: id,
                  name: 'Live skill',
                  description: 'Tidies',
                  content: 'Tidy the text.',
                ),
              ),
            ),
          );
          expect(created.skill!.content, 'Tidy the text.');
          final toggled = await workspace.toggle(
            WorkspaceRef(kind: WorkspaceKind.skills, id: id),
          );
          expect(toggled.active, isFalse);
          final exported = await workspace.export(
            const WorkspaceExportQuery(kind: WorkspaceKind.skills),
          );
          expect(exported.text, contains(id));
          await workspace.delete(
            WorkspaceRef(kind: WorkspaceKind.skills, id: id),
          );

          final copy = jsonEncode(<Map<String, dynamic>>[
            <String, dynamic>{
              'id': id,
              'name': 'Live skill',
              'content': 'Tidy the text.',
            },
          ]);
          final imported = await workspace.import(
            WorkspaceImport(kind: WorkspaceKind.skills, text: copy),
          );
          expect(imported.imported, 1);
          await workspace.delete(
            WorkspaceRef(kind: WorkspaceKind.skills, id: id),
          );
          cleanups.remove('skill');
        }, timeout: const Timeout(Duration(minutes: 2)));

        test('a knowledge base: folders, files, export, reset', () async {
          final api = runtime.container.read(apiServiceProvider)!;
          final created = await workspace.save(
            WorkspaceSave(
              create: true,
              detail: WorkspaceDetail(
                kind: WorkspaceKind.knowledge,
                knowledge: WorkspaceKnowledgeDto(
                  name: 'Live knowledge $stamp',
                  description: 'Made by a test',
                ),
              ),
            ),
          );
          final id = created.knowledge!.id;
          cleanups['knowledge'] = () => api.deleteKnowledgeBase(id);

          final uploaded = await FilesService(runtime.container).upload(
            session: FilesService(runtime.container).session(),
            name: 'live-notes-$stamp.txt',
            bytes: Uint8List.fromList(
              utf8.encode('The deploy password rotates every Tuesday.'),
            ),
            contentType: 'text/plain',
          );
          cleanups['file'] = () => api.deleteFile(uploaded.id);

          var files = await workspace.attachFiles(
            WorkspaceFilesAttach(
              knowledgeId: id,
              fileIds: <String>[uploaded.id],
            ),
          );
          Future<bool> listed() async {
            files = await workspace.files(WorkspaceFilesQuery(knowledgeId: id));
            return files.files.any((f) => f.id == uploaded.id);
          }

          await _waitFor(listed, seconds: 60);
          expect(await listed(), isTrue);

          files = await workspace.directoryAction(
            WorkspaceDirectoryAction(
              knowledgeId: id,
              op: WorkspaceDirectoryOp.create,
              name: 'Guides',
            ),
          );
          final folder = files.directories.singleWhere(
            (d) => d.name == 'Guides',
          );
          files = await workspace.fileAction(
            WorkspaceFileAction(
              knowledgeId: id,
              fileId: uploaded.id,
              op: WorkspaceFileOp.move,
              directoryId: folder.id,
            ),
          );
          expect(files.files.map((f) => f.id), isNot(contains(uploaded.id)));
          files = await workspace.files(
            WorkspaceFilesQuery(knowledgeId: id, directoryId: folder.id),
          );
          expect(files.files.map((f) => f.id), contains(uploaded.id));
          expect(files.breadcrumbs.last.id, folder.id);

          files = await workspace.fileAction(
            WorkspaceFileAction(
              knowledgeId: id,
              fileId: uploaded.id,
              op: WorkspaceFileOp.rename,
              filename: 'renamed-$stamp.txt',
            ),
          );
          expect(
            files.files.singleWhere((f) => f.id == uploaded.id).filename,
            'renamed-$stamp.txt',
          );

          final zip = await workspace.export(
            WorkspaceExportQuery(kind: WorkspaceKind.knowledge, id: id),
          );
          expect(zip.mimeType, 'application/zip');
          expect(base64Decode(zip.base64!).take(2), <int>[0x50, 0x4b]);

          files = await workspace.fileAction(
            WorkspaceFileAction(
              knowledgeId: id,
              fileId: uploaded.id,
              op: WorkspaceFileOp.remove,
            ),
          );
          expect(files.files, isEmpty);
          files = await workspace.directoryAction(
            WorkspaceDirectoryAction(
              knowledgeId: id,
              op: WorkspaceDirectoryOp.delete,
              directoryId: folder.id,
            ),
          );
          files = await workspace.files(WorkspaceFilesQuery(knowledgeId: id));
          expect(files.directories, isEmpty);

          final reset = await workspace.knowledgeReset(id);
          expect(reset.knowledge!.fileCount, 0);
          await workspace.delete(
            WorkspaceRef(kind: WorkspaceKind.knowledge, id: id),
          );
          cleanups.remove('knowledge');
        }, timeout: const Timeout(Duration(minutes: 3)));

        test(
          'the desktop editors: duplicate, typed valves, a tool switched off, '
          'limits, uploads and text files, and access through access.*',
          () async {
            final api = runtime.container.read(apiServiceProvider)!;
            final access = AccessService(
              runtime.container,
              workspace: workspace,
            );

            // A prompt and its copy, named as the phone's Duplicate names it.
            final command = 'live-dup-$stamp';
            final prompt = await workspace.save(
              WorkspaceSave(
                create: true,
                detail: WorkspaceDetail(
                  kind: WorkspaceKind.prompts,
                  prompt: WorkspacePromptDto(
                    command: command,
                    name: 'Live duplicate',
                    content: 'Say hello.',
                  ),
                ),
              ),
            );
            final promptId = prompt.prompt!.id;
            cleanups['dup-prompt'] = () => api.deletePrompt(promptId);
            final copy = await workspace.duplicate(
              WorkspaceDuplicate(kind: WorkspaceKind.prompts, id: promptId),
            );
            final copyId = copy.prompt!.id;
            cleanups['dup-copy'] = () => api.deletePrompt(copyId);
            expect(copy.prompt!.command, '$command-copy');
            expect(copy.prompt!.name, 'Live duplicate (copy)');
            expect(copy.prompt!.content, 'Say hello.');
            expect(copy.grants, isEmpty);

            // Share it with the seeded group as an editor, and every user.
            final groups = await access.principals(
              const AccessPrincipalQuery(),
            );
            final group = groups.items.firstWhere((p) => p.type == 'group');
            final shared = await access.set(
              AccessEdit(
                kind: AccessResourceKind.prompt,
                id: copyId,
                grants: <AccessGrantDto>[
                  AccessGrantDto(
                    principalType: 'group',
                    principalId: group.id,
                    write: true,
                  ),
                ],
                audience: AccessAudience.public,
              ),
            );
            expect(shared.canEdit, isTrue);
            expect(shared.audience, AccessAudience.public);
            final granted = shared.grants.single;
            expect(granted.principalId, group.id);
            expect(granted.write, isTrue);
            expect(granted.name, group.name);
            final read = await access.get(
              AccessRef(kind: AccessResourceKind.prompt, id: copyId),
            );
            expect(read.grants.single.write, isTrue);
            final private = await access.set(
              AccessEdit(
                kind: AccessResourceKind.prompt,
                id: copyId,
                audience: AccessAudience.private,
              ),
            );
            expect(private.grants, isEmpty);
            expect(private.audience, AccessAudience.private);

            await workspace.delete(
              WorkspaceRef(kind: WorkspaceKind.prompts, id: copyId),
            );
            cleanups.remove('dup-copy');
            await workspace.delete(
              WorkspaceRef(kind: WorkspaceKind.prompts, id: promptId),
            );
            cleanups.remove('dup-prompt');

            // A tool: valves typed from the form's text, switched off.
            final toolId = 'live_typed_$stamp';
            cleanups['typed-tool'] = () => api.deleteTool(toolId);
            await workspace.save(
              WorkspaceSave(
                create: true,
                detail: WorkspaceDetail(
                  kind: WorkspaceKind.tools,
                  tool: WorkspaceToolDto(
                    id: toolId,
                    name: 'Live typed',
                    content: _liveToolSource,
                  ),
                ),
              ),
            );
            final valves = await workspace.valves(
              WorkspaceValvesQuery(toolId: toolId),
            );
            final limit = valves.fields.singleWhere((f) => f.key == 'limit');
            expect(limit.type, ValveFieldType.integer);
            final typed = await workspace.saveValves(
              WorkspaceValves(
                toolId: toolId,
                edits: const <ValveEdit>[
                  ValveEdit(key: 'limit', isDefault: false, text: '9'),
                ],
              ),
            );
            expect(typed.values['limit'], 9);
            expect(typed.fields.singleWhere((f) => f.key == 'limit').text, '9');
            final listedTool = await workspace.list(
              WorkspaceQuery(kind: WorkspaceKind.tools, query: 'Live typed'),
            );
            final row = listedTool.items.singleWhere((i) => i.id == toolId);
            expect(row.functionCount, greaterThan(0));
            if (row.active != null) {
              final off = await workspace.toggle(
                WorkspaceRef(kind: WorkspaceKind.tools, id: toolId),
              );
              expect(off.active, isFalse);
            }
            final toolCopy = await workspace.duplicate(
              WorkspaceDuplicate(
                kind: WorkspaceKind.tools,
                id: toolId,
                suffix: '(Clone)',
              ),
            );
            expect(toolCopy.tool!.id, '${toolId}_clone');
            await workspace.delete(
              WorkspaceRef(kind: WorkspaceKind.tools, id: toolCopy.tool!.id),
            );
            await workspace.delete(
              WorkspaceRef(kind: WorkspaceKind.tools, id: toolId),
            );
            cleanups.remove('typed-tool');

            // A knowledge base with limits, a fresh upload and a text file.
            final base = await workspace.save(
              WorkspaceSave(
                create: true,
                detail: WorkspaceDetail(
                  kind: WorkspaceKind.knowledge,
                  knowledge: WorkspaceKnowledgeDto(
                    name: 'Live limits $stamp',
                    maxFileCount: 5,
                  ),
                ),
              ),
            );
            final baseId = base.knowledge!.id;
            cleanups['limits'] = () => api.deleteKnowledgeBase(baseId);
            expect(base.knowledge!.maxFileCount, 5);
            final changed = await workspace.save(
              WorkspaceSave(
                detail: base.copyWith(
                  knowledge: base.knowledge!.copyWith(
                    maxFileCount: 6,
                    maxFileSize: 2,
                  ),
                ),
              ),
            );
            expect(changed.knowledge!.maxFileCount, 6);
            expect(changed.knowledge!.maxFileSize, 2);

            final uploaded = await FilesService(runtime.container).upload(
              session: FilesService(runtime.container).session(),
              name: 'live-fresh-$stamp.md',
              bytes: Uint8List.fromList(utf8.encode('# Fresh\n\nBeans.')),
              contentType: 'text/markdown',
            );
            var files = await workspace.attachFiles(
              WorkspaceFilesAttach(
                knowledgeId: baseId,
                fileIds: <String>[uploaded.id],
                uploaded: true,
              ),
            );
            expect(files.files.map((f) => f.id), contains(uploaded.id));
            files = await workspace.addText(
              WorkspaceTextFile(
                knowledgeId: baseId,
                filename: 'typed-$stamp',
                content: 'Water the beans at dawn.',
              ),
            );
            expect(
              files.files.map((f) => f.filename),
              contains('typed-$stamp.txt'),
            );
            await workspace.delete(
              WorkspaceRef(kind: WorkspaceKind.knowledge, id: baseId),
            );
            cleanups.remove('limits');
          },
          timeout: const Timeout(Duration(minutes: 3)),
        );
      });

      group('chat and folder settings', () {
        late ChatsService chats;
        late ChatSettingsService settings;

        setUpAll(() async {
          chats = ChatsService(runtime.container);
          settings = ChatSettingsService(runtime.container);
          // Run alone, the group can start before the first sync landed.
          await _waitFor(() async {
            final listed = await chats.list();
            return listed.chats.isNotEmpty && listed.folders.isNotEmpty;
          }, seconds: 30);
        });

        test(
          'saves a chat\'s prompt and parameters, then inherits again',
          () async {
            final listed = await chats.list();
            final chat = listed.chats.firstWhere(
              (c) => c.folderId == null && !c.readOnly,
            );
            final opened = await settings.get(
              ChatSettingsQuery(chatId: chat.id, modelId: turnModel),
            );
            expect(opened.canEditParameters, isTrue);
            expect(
              opened.parameters.map((f) => f.key),
              containsAll(<String>['temperature', 'seed', 'stop']),
            );

            // A bad value is marked and nothing is written.
            final bad = await settings.save(
              ChatSettingsEdit(
                chatId: chat.id,
                modelId: turnModel,
                fields: const <ChatSettingFieldEdit>[
                  ChatSettingFieldEdit(
                    key: 'temperature',
                    mode: ChatSettingMode.custom,
                    text: '9',
                  ),
                ],
              ),
            );
            expect(bad.saved, isFalse);
            expect(
              bad.parameters.firstWhere((f) => f.key == 'temperature').error,
              ChatSettingError.outOfRange,
            );

            final saved = await settings.save(
              ChatSettingsEdit(
                chatId: chat.id,
                modelId: turnModel,
                fields: const <ChatSettingFieldEdit>[
                  ChatSettingFieldEdit(
                    key: 'system',
                    mode: ChatSettingMode.custom,
                    text: 'Answer like a ship captain.',
                  ),
                  ChatSettingFieldEdit(
                    key: 'temperature',
                    mode: ChatSettingMode.custom,
                    text: '0.3',
                  ),
                  ChatSettingFieldEdit(
                    key: 'seed',
                    mode: ChatSettingMode.custom,
                    text: '7',
                  ),
                ],
              ),
            );
            expect(saved.saved, isTrue);
            expect(saved.params['temperature'], 0.3);
            expect(saved.params['seed'], 7);
            expect(saved.params['system'], 'Answer like a ship captain.');
            final again = await settings.get(
              ChatSettingsQuery(chatId: chat.id, modelId: turnModel),
            );
            expect(again.systemPrompt.mode, ChatSettingMode.custom);
            expect(
              again.parameters.firstWhere((f) => f.key == 'seed').text,
              '7',
            );

            // Your Default for one, then Reset All.
            final one = await settings.save(
              ChatSettingsEdit(
                chatId: chat.id,
                modelId: turnModel,
                fields: const <ChatSettingFieldEdit>[
                  ChatSettingFieldEdit(
                    key: 'seed',
                    mode: ChatSettingMode.inherit,
                  ),
                ],
              ),
            );
            expect(one.params.containsKey('seed'), isFalse);
            expect(one.params['temperature'], 0.3);
            final reset = await settings.save(
              ChatSettingsEdit(
                chatId: chat.id,
                modelId: turnModel,
                fields: <ChatSettingFieldEdit>[
                  const ChatSettingFieldEdit(
                    key: 'system',
                    mode: ChatSettingMode.inherit,
                  ),
                  for (final field in opened.parameters)
                    ChatSettingFieldEdit(
                      key: field.key,
                      mode: ChatSettingMode.inherit,
                    ),
                ],
              ),
            );
            expect(reset.params, isEmpty);
          },
          timeout: const Timeout(Duration(minutes: 2)),
        );

        test('keeps a new chat\'s settings in its draft', () async {
          final draft = await settings.save(
            ChatSettingsEdit(
              modelId: turnModel,
              fields: const <ChatSettingFieldEdit>[
                ChatSettingFieldEdit(
                  key: 'max_tokens',
                  mode: ChatSettingMode.custom,
                  text: '64',
                ),
              ],
            ),
          );
          expect(draft.chatId, isNull);
          expect(draft.params, <String, dynamic>{'max_tokens': 64});
          final reopened = await settings.get(
            ChatSettingsQuery(modelId: turnModel, draft: draft.params),
          );
          expect(
            reopened.parameters.firstWhere((f) => f.key == 'max_tokens').mode,
            ChatSettingMode.custom,
          );
        });

        test('pins a model and offers reasoning effort', () async {
          final pinned = await models.setPinned(
            SetModelPinned(id: turnModel, pinned: true),
          );
          expect(
            pinned.models.firstWhere((m) => m.id == turnModel).pinned,
            isTrue,
          );
          expect(pinned.featuredIds, contains(turnModel));
          final unpinned = await models.setPinned(
            SetModelPinned(id: turnModel, pinned: false),
          );
          expect(
            unpinned.models.firstWhere((m) => m.id == turnModel).pinned,
            isFalse,
          );

          final options = await models.options(
            ModelOptionsQuery(modelId: turnModel),
          );
          expect(options.reasoning.visible, isTrue);
          expect(options.reasoning.options.first, 'automatic');
          final picked = await models.setReasoningEffort(
            SetReasoningEffort(modelId: turnModel, effort: 'high'),
          );
          expect(picked.reasoning.current, 'high');
          expect(picked.draft, <String, dynamic>{'reasoning_effort': 'high'});
          final back = await models.setReasoningEffort(
            SetReasoningEffort(modelId: turnModel, effort: 'automatic'),
          );
          expect(back.reasoning.current, 'automatic');
        });

        test('reads and writes a tool\'s personal valves', () async {
          final toolId = credentials!.values['OWUI_VALVE_TOOL'];
          if (toolId == null) {
            markTestSkipped('the seed has no valve tool (owui.sh reset)');
            return;
          }
          final valves = ValvesService(runtime.container);
          final targets = await valves.targets(
            ValveTargetsQuery(modelId: turnModel, toolIds: <String>[toolId]),
          );
          final target = targets.targets.single;
          expect(target.kind, ValveTargetKind.tool);
          final doc = await valves.get(
            ValvesRef(kind: target.kind, id: target.id, label: target.label),
          );
          expect(doc.phase, ValvesPhase.ready);
          final units = doc.fields.firstWhere((f) => f.key == 'units');
          expect(units.type, ValveFieldType.choice);
          expect(units.options, <String>['metric', 'imperial']);
          expect(
            doc.fields.firstWhere((f) => f.key == 'show_wind').type,
            ValveFieldType.boolean,
          );
          final saved = await valves.save(
            ValvesSave(
              kind: target.kind,
              id: target.id,
              values: const <ValveEdit>[
                ValveEdit(key: 'units', isDefault: false, text: 'imperial'),
                ValveEdit(key: 'show_wind', isDefault: false, text: 'true'),
              ],
            ),
          );
          expect(
            saved.fields.firstWhere((f) => f.key == 'units').text,
            'imperial',
          );
          expect(
            saved.fields.firstWhere((f) => f.key == 'show_wind').text,
            'true',
          );
          final cleared = await valves.save(
            ValvesSave(
              kind: target.kind,
              id: target.id,
              values: const <ValveEdit>[
                ValveEdit(key: 'units'),
                ValveEdit(key: 'show_wind'),
              ],
            ),
          );
          expect(
            cleared.fields.firstWhere((f) => f.key == 'units').isDefault,
            isTrue,
          );
        }, timeout: const Timeout(Duration(minutes: 2)));

        test('a folder: prompt, models, icon and sharing', () async {
          final folders = FolderSettingsService(runtime.container);
          final access = AccessService(runtime.container);
          final listed = await chats.list();
          final folder = listed.folders.firstWhere(
            (f) => !f.shared && f.name == 'Recipes',
          );
          final before = await folders.get(folder.id);
          expect(before.canWrite, isTrue);
          expect(before.iconChoices, isNotEmpty);

          final updated = await folders.update(
            FolderUpdate(
              id: folder.id,
              icon: 'books',
              systemPrompt: 'Give quantities in grams.',
              modelIds: <String>[turnModel],
            ),
          );
          expect(updated.icon, 'books');
          expect(updated.systemPrompt, 'Give quantities in grams.');
          expect(updated.modelIds, <String>[turnModel]);
          final draft = await folders.draftModel(folder.id);
          expect(draft.modelIds, <String>[turnModel]);
          expect(
            (await chats.list()).folders
                .firstWhere((f) => f.id == folder.id)
                .icon,
            '📚',
          );

          // Shared with the second user, who may edit it, then not.
          final second = credentials!.values['OWUI_SECOND_NAME'];
          if (second != null) {
            final people = await access.principals(
              AccessPrincipalQuery(query: second.split(' ').first),
            );
            final riley = people.items.firstWhere((p) => p.type == 'user');
            var state = await access.get(
              AccessRef(kind: AccessResourceKind.folder, id: folder.id),
            );
            expect(state.canEdit, isTrue);
            expect(state.allowPublic, isFalse);
            state = await access.set(
              AccessEdit(
                kind: AccessResourceKind.folder,
                id: folder.id,
                grants: <AccessGrantDto>[
                  AccessGrantDto(principalId: riley.id, write: true),
                ],
              ),
            );
            final grant = state.grants.single;
            expect(grant.principalId, riley.id);
            expect(grant.write, isTrue);
            expect(grant.name, second);
            state = await access.set(
              AccessEdit(kind: AccessResourceKind.folder, id: folder.id),
            );
            expect(state.grants, isEmpty);
          }

          final restored = await folders.update(
            FolderUpdate(
              id: folder.id,
              icon: '',
              systemPrompt: before.systemPrompt,
              modelIds: before.modelIds,
            ),
          );
          expect(restored.icon, isNull);
          expect(restored.systemPrompt, before.systemPrompt);
        }, timeout: const Timeout(Duration(minutes: 2)));
      });

      group('calendar and scheduled tasks', () {
        late CalendarService calendar;
        late AutomationsService tasks;
        final stamp = DateTime.now().millisecondsSinceEpoch;

        setUpAll(() {
          calendar = CalendarService(runtime.container, events: EventBus());
          tasks = AutomationsService(
            runtime.container,
            events: EventBus(),
            pollInterval: const Duration(seconds: 1),
            pollLimit: 90,
          );
        });

        tearDownAll(() {
          calendar.dispose();
          tasks.dispose();
        });

        /// Every item of [agenda] titled [title].
        List<CalendarItemDto> titled(CalendarAgenda agenda, String title) => [
          for (final day in agenda.days)
            for (final item in day.items)
              if (item.title == title) item,
        ];

        CalendarWallTime tomorrowAt(CalendarAgenda agenda, int hour) {
          final today = agenda.today!;
          final day = DateTime(
            today.year,
            today.month,
            today.day,
          ).add(const Duration(days: 1));
          return CalendarWallTime(
            year: day.year,
            month: day.month,
            day: day.day,
            hour: hour,
          );
        }

        test('creates, edits, answers and deletes an event', () async {
          var agenda = await calendar.agenda(
            const CalendarAgendaQuery(refresh: true),
          );
          expect(agenda.failure, isNull);
          expect(agenda.available, isTrue);
          expect(agenda.canCreate, isTrue);
          expect(agenda.calendars.where((c) => c.writable), isNotEmpty);
          // The admin may use scheduled tasks: their calendar is listed.
          expect(agenda.calendars.where((c) => c.scheduled), hasLength(1));

          final title = 'Live seed swap $stamp';
          final opened = await calendar.editor(const CalendarEditorOpen());
          expect(opened.isNew, isTrue);
          expect(opened.fields.calendarId, isNotEmpty);
          final start = tomorrowAt(agenda, 10).copyWith(minute: 30);
          final empty = await calendar.save(
            CalendarDraftEdit(token: opened.token, fields: opened.fields),
          );
          expect(empty.saved, isFalse);
          expect(empty.issues, contains('titleRequired'));

          // Moving the start past the end takes the end along.
          final moved = await calendar.checkDraft(
            CalendarDraftEdit(
              token: opened.token,
              fields: opened.fields.copyWith(
                title: title,
                start: start.copyWith(hour: 9, minute: 0),
                end: start.copyWith(hour: 10, minute: 0),
              ),
              movedStart: start,
            ),
          );
          expect(moved.fields.start, start);
          expect(moved.fields.end, start.copyWith(hour: 11));
          expect(moved.issues, isEmpty);
          expect(moved.changed, isTrue);

          final me = runtime.container.read(currentUserProvider2)!.id;
          final saved = await calendar.save(
            CalendarDraftEdit(
              token: opened.token,
              fields: moved.fields.copyWith(
                location: 'Community hall',
                attendees: [CalendarAttendeeDto(userId: me, name: 'Me')],
              ),
            ),
          );
          expect(saved.saved, isTrue);
          agenda = await calendar.agenda(const CalendarAgendaQuery());
          final item = titled(agenda, title).single;
          expect(item.location, 'Community hall');
          expect(item.time.kind, 'range');
          expect(item.time.start, start);
          expect(item.editable, isTrue);
          expect(item.invited, isTrue);
          expect(item.answer, 'pending');
          addTearDown(() async {
            final now = await calendar.agenda(
              const CalendarAgendaQuery(today: true),
            );
            for (final left in titled(now, '$title (moved)')) {
              await calendar.deleteEvent(CalendarItemRef(key: left.key));
            }
          });

          final detail = await calendar.event(CalendarItemRef(key: item.key));
          expect(detail.status, 'fresh');
          expect(detail.canEdit, isTrue);
          expect(detail.attendeeCount, 1);

          final answered = await calendar.respond(
            CalendarRsvpEdit(key: item.key, answer: 'tentative'),
          );
          expect(answered.item.answer, 'tentative');

          final editing = await calendar.editor(
            CalendarEditorOpen(key: item.key),
          );
          expect(editing.isNew, isFalse);
          expect(editing.fields.title, title);
          final untouched = await calendar.checkDraft(
            CalendarDraftEdit(token: editing.token, fields: editing.fields),
          );
          expect(untouched.changed, isFalse);
          final renamed = await calendar.save(
            CalendarDraftEdit(
              token: editing.token,
              fields: editing.fields.copyWith(title: '$title (moved)'),
            ),
          );
          expect(renamed.saved, isTrue);
          agenda = await calendar.agenda(const CalendarAgendaQuery());
          expect(titled(agenda, title), isEmpty);
          final again = titled(agenda, '$title (moved)').single;
          // An edit keeps the answer the account gave.
          expect(again.answer, 'tentative');

          // The next page does not hold it; Today brings it back.
          final later = await calendar.agenda(
            const CalendarAgendaQuery(shift: 1),
          );
          expect(titled(later, '$title (moved)'), isEmpty);
          expect(later.firstDay, isNot(agenda.firstDay));
          final back = await calendar.agenda(
            const CalendarAgendaQuery(today: true),
          );
          expect(titled(back, '$title (moved)'), hasLength(1));

          final afterDelete = await calendar.deleteEvent(
            CalendarItemRef(key: again.key),
          );
          expect(titled(afterDelete, '$title (moved)'), isEmpty);
        }, timeout: const Timeout(Duration(minutes: 2)));

        test('edits a daily series from one of its days', () async {
          var agenda = await calendar.agenda(
            const CalendarAgendaQuery(today: true),
          );
          final title = 'Live watering $stamp';
          final opened = await calendar.editor(const CalendarEditorOpen());
          final start = tomorrowAt(agenda, 7);
          final saved = await calendar.save(
            CalendarDraftEdit(
              token: opened.token,
              fields: opened.fields.copyWith(
                title: title,
                start: start,
                end: start.copyWith(minute: 30),
                repeat: 'daily',
              ),
            ),
          );
          expect(saved.saved, isTrue);
          agenda = await calendar.agenda(const CalendarAgendaQuery());
          final days = titled(agenda, title);
          expect(days.length, greaterThan(3));
          expect(days.every((d) => d.recurring), isTrue);
          addTearDown(() async {
            final now = await calendar.agenda(const CalendarAgendaQuery());
            final left = [
              ...titled(now, title),
              ...titled(now, '$title, earlier'),
            ];
            if (left.isNotEmpty) {
              await calendar.deleteEvent(CalendarItemRef(key: left.first.key));
            }
          });

          final third = days[2];
          final detail = await calendar.event(CalendarItemRef(key: third.key));
          expect(detail.repeat, 'daily');
          final editing = await calendar.editor(
            CalendarEditorOpen(key: third.key),
          );
          expect(editing.series, isTrue);
          // The series starts where it was made, not on the third day.
          expect(editing.fields.start, start);
          final renamed = await calendar.save(
            CalendarDraftEdit(
              token: editing.token,
              fields: editing.fields.copyWith(title: '$title, earlier'),
            ),
          );
          expect(renamed.saved, isTrue);
          agenda = await calendar.agenda(const CalendarAgendaQuery());
          expect(titled(agenda, title), isEmpty);
          expect(titled(agenda, '$title, earlier').length, days.length);
        }, timeout: const Timeout(Duration(minutes: 2)));

        test('hides and shows a calendar', () async {
          final agenda = await calendar.agenda(const CalendarAgendaQuery());
          expect(agenda.filterable, isTrue);
          final scheduled = agenda.calendars.firstWhere((c) => c.scheduled);
          final hidden = await calendar.setVisible(
            CalendarVisibility(calendarId: scheduled.id, visible: false),
          );
          expect(
            hidden.calendars.firstWhere((c) => c.id == scheduled.id).visible,
            isFalse,
          );
          final shown = await calendar.setVisible(
            CalendarVisibility(calendarId: scheduled.id, visible: true),
          );
          expect(shown.calendars.every((c) => c.visible), isTrue);
        });

        test('runs a task now and finds its run, then deletes it', () async {
          final listed = await tasks.list(const AutomationQuery(refresh: true));
          expect(listed.failure, isNull);
          expect(listed.available, isTrue);

          final name = 'Live digest $stamp';
          final opened = await tasks.editor(const AutomationEditorOpen());
          expect(opened.isNew, isTrue);
          expect(opened.models?.map((m) => m.id), contains(turnModel));
          final weekly = await tasks.checkDraft(
            AutomationDraftEdit(
              token: opened.token,
              fields: opened.fields,
              chooseKind: 'weekly',
            ),
          );
          expect(weekly.fields.schedule.kind, 'weekly');
          expect(weekly.fields.schedule.days, hasLength(1));
          expect(weekly.issues, containsAll(['nameRequired', 'modelRequired']));
          // A typed rule the controls can write reads back as their kind.
          final typed = await tasks.checkDraft(
            AutomationDraftEdit(
              token: opened.token,
              fields: weekly.fields.copyWith(
                schedule: const AutomationScheduleDto(
                  kind: 'custom',
                  rrule: 'RRULE:FREQ=DAILY;BYHOUR=6;BYMINUTE=45',
                ),
              ),
            ),
          );
          expect(typed.fields.schedule.kind, 'daily');
          expect(typed.fields.schedule.hour, 6);

          final saved = await tasks.save(
            AutomationDraftEdit(
              token: opened.token,
              fields: typed.fields.copyWith(
                name: name,
                prompt: 'Say the word: kestrel',
                modelId: turnModel,
              ),
            ),
          );
          expect(saved.failure, isNull);
          expect(saved.saved, isTrue);
          final id = saved.id!;
          addTearDown(() async {
            try {
              await tasks.delete(AutomationRef(id: id));
            } on RpcError {
              // Deleted by the test.
            }
          });

          final list = await tasks.list(const AutomationQuery(query: ''));
          final row = list.items.firstWhere((t) => t.id == id);
          expect(row.active, isTrue);
          expect(row.schedule.kind, 'daily');
          expect(row.nextRunAt, isNotNull);

          final detail = await tasks.get(AutomationRef(id: id));
          expect(detail.prompt, 'Say the word: kestrel');
          expect(detail.target, 'chat');
          expect(detail.nextRuns, isNotEmpty);

          final started = await tasks.run(AutomationRef(id: id));
          expect(started.phase, anyOf('waiting', 'finished'));
          var progress = started;
          for (var i = 0; i < 120 && progress.phase == 'waiting'; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 500));
            progress = tasks.runState(AutomationRef(id: id));
          }
          expect(progress.phase, 'finished', reason: '${progress.failure}');
          final chatId = progress.run?.resultChatId;
          expect(chatId, isNotNull);
          created.add(chatId!);

          final history = await tasks.runs(AutomationRunsQuery(id: id));
          expect(history.items.first.id, progress.run!.id);

          // The run is on the calendar's scheduled-tasks calendar.
          final agenda = await calendar.agenda(
            const CalendarAgendaQuery(today: true),
          );
          final entries = [
            for (final day in agenda.days)
              for (final item in day.items)
                if (item.runId == progress.run!.id) item,
          ];
          expect(entries, hasLength(1));
          expect(entries.single.resultChatId, chatId);
          expect(entries.single.scheduledState, 'finished');

          final paused = await tasks.setActive(
            AutomationToggle(id: id, active: false),
          );
          expect(paused.summary.active, isFalse);
          expect(paused.nextRuns, isEmpty);
          final pausedList = await tasks.list(
            const AutomationQuery(status: 'paused'),
          );
          expect(pausedList.items.map((t) => t.id), contains(id));

          final left = await tasks.delete(AutomationRef(id: id));
          expect(left.items.map((t) => t.id), isNot(contains(id)));
          await tasks.list(const AutomationQuery(status: 'all'));
        }, timeout: const Timeout(Duration(minutes: 3)));
      });
    },
  );
}

/// A tool with one function and one valve, for the workspace test.
const String _liveToolSource = """
\"\"\"
title: Live Tool
\"\"\"
from pydantic import BaseModel, Field


class Tools:
    class Valves(BaseModel):
        limit: int = Field(default=3, description="How many")

    def __init__(self):
        self.valves = self.Valves()

    def echo(self, text: str) -> str:
        \"\"\"Echo the text back.\"\"\"
        return text
""";

/// Polls [condition] until it holds or [seconds] elapse.
///
/// Waits into the next whole second.
///
/// Open WebUI stamps chats and prompt versions in whole seconds, and the
/// local server and its fake model do several things inside one: two
/// changes in the same second tie, so a sort cannot order them and a pull
/// by `updated_at` takes the second for one it already has.
Future<void> _nextSecond() =>
    Future<void>.delayed(const Duration(milliseconds: 1100));

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

/// [samples] of silence as a 16 kHz mono 16-bit WAV file.
List<int> _silentWav(int samples) {
  final data = samples * 2;
  final out = BytesBuilder();
  void u32(int v) =>
      out.add(<int>[v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255]);
  void u16(int v) => out.add(<int>[v & 255, (v >> 8) & 255]);
  out.add('RIFF'.codeUnits);
  u32(36 + data);
  out.add('WAVEfmt '.codeUnits);
  u32(16);
  u16(1);
  u16(1);
  u32(16000);
  u32(32000);
  u16(2);
  u16(16);
  out.add('data'.codeUnits);
  u32(data);
  out.add(List<int>.filled(data, 0));
  return out.takeBytes();
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

/// A second of 440 Hz, as a 16 kHz mono WAV.
Uint8List _toneWav() {
  const rate = 16000;
  final samples = ByteData(rate * 2);
  for (var i = 0; i < rate; i++) {
    samples.setInt16(
      i * 2,
      (sin(2 * pi * 440 * i / rate) * 8000).round(),
      Endian.little,
    );
  }
  final header = ByteData(44);
  void ascii(int at, String text) {
    for (var i = 0; i < text.length; i++) {
      header.setUint8(at + i, text.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  header.setUint32(4, 36 + rate * 2, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, 1, Endian.little);
  header.setUint32(24, rate, Endian.little);
  header.setUint32(28, rate * 2, Endian.little);
  header.setUint16(32, 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  header.setUint32(40, rate * 2, Endian.little);
  return Uint8List.fromList(<int>[
    ...header.buffer.asUint8List(),
    ...samples.buffer.asUint8List(),
  ]);
}

/// Every chat on the signed-in account, archived ones included, by id.
Future<Set<String>> _allChatIds(dynamic api) async {
  final ids = <String>{};
  for (final archived in <bool>[false, true]) {
    for (var page = 1; page < 100; page++) {
      final rows = archived
          ? await api.getArchivedChatListPageRaw(page: page)
          : await api.getChatListPageRaw(page: page);
      if (rows is! List || rows.isEmpty) break;
      for (final row in rows) {
        final id = row is Map ? row['id'] : null;
        if (id is String) ids.add(id);
      }
    }
  }
  return ids;
}

/// Why the tests of connections kept in the Open WebUI account are skipped:
/// `tool/local_owui` runs Open WebUI 0.13.4, which moved them into Tether.
const _movedToTether =
    'needs Open WebUI 0.13.3 or older: 0.13.4 moved Personal Connections and '
    'direct connections into Tether; back with the Tether device follow-up';
