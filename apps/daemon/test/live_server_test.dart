@TestOn('vm')
library;

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

      tearDownAll(() async {
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
    },
  );
}
