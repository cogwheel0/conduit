@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:conduit_core/features/librechat/providers/librechat_providers.dart'
    show libreChatApiServiceProvider;
import 'package:conduit_core/features/chat/server_speech/server_speech.dart'
    show ServerSpeechSource;
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

import 'support/local_librechat.dart';
import 'support/local_owui.dart';
import 'support/null_sink.dart';
import 'support/window.dart';

/// Drives the daemon's LibreChat support against the fake LibreChat server
/// (`tool/local_librechat/librechat.sh start`), with its invented accounts.
/// Without its env file the group is skipped, so a clean clone and CI pass.
///
/// The tests run in order and share one signed-in daemon, as a window would:
/// sign in with two-step verification, then the chat list, a turn, the
/// list's actions, memories, a share link, and signing out.
void main() {
  final server = LocalLibreChat.read();

  group(
    'against the fake LibreChat',
    skip: server == null
        ? 'no fake LibreChat env file (tool/local_librechat/librechat.sh start)'
        : null,
    () {
      late Directory temporary;
      late CoreRuntime runtime;
      late EventBus events;
      late AccountsService accounts;
      late LibreChatService libreChat;
      late ChatsService chats;
      late ModelsService models;
      late TurnsService turns;
      late UiRequestsService uiRequests;

      setUpAll(() async {
        await server!.reset();
        temporary = Directory.systemTemp.createTempSync('conduitd-librechat');
        final config = BootstrapConfig(
          sessionToken: 'a' * 43,
          masterKey: base64.encode(List<int>.generate(32, (i) => i)),
          userDataDir: temporary.path,
        );
        // CONDUIT_TEST_LOG=<file> keeps the daemon's debug log of the run.
        final logPath = Platform.environment['CONDUIT_TEST_LOG'];
        final log = logPath == null
            ? DaemonLog(level: 'error', sink: NullSink())
            : DaemonLog(level: 'debug', sink: File(logPath).openWrite());
        runtime = await CoreRuntime.start(
          config: config,
          directories: DaemonDirectories.create(temporary.path),
          log: log,
        );
        if (logPath != null) DebugLogger.sink = DaemonLogSink(log);
        events = EventBus();
        uiRequests = UiRequestsService(events);
        runtime.uiRequests.attach(uiRequests);
        turns = TurnsService(runtime.container, events, uiRequests: uiRequests);
        accounts = AccountsService(
          runtime.container,
          events: events,
          turns: turns,
        );
        libreChat = LibreChatService(
          runtime.container,
          events: events,
          accounts: accounts,
        );
        chats = ChatsService(runtime.container, events: events);
        chats.turns = turns;
        models = ModelsService(runtime.container, events: events);
      });

      tearDownAll(() async {
        await turns.dispose();
        await runtime.dispose();
        temporary.deleteSync(recursive: true);
      });

      test('recognises a LibreChat server, and says when it is not one', () async {
        final found = await libreChat.probe(LibreChatProbe(url: server!.url));
        expect(found.outcome, LibreChatProbeOutcome.found);
        expect(found.server!.title, 'Harbour LibreChat');
        expect(found.server!.passwordSignIn, isTrue);
        expect(
          found.server!.ssoProviders.map((p) => (p.kind, p.label)),
          [('openid', 'Harbour ID')],
        );

        final nothing = await libreChat.probe(
          const LibreChatProbe(url: 'http://127.0.0.1:9'),
        );
        expect(nothing.outcome, LibreChatProbeOutcome.unreachable);
        final invalid = await libreChat.probe(const LibreChatProbe(url: ' '));
        expect(invalid.outcome, LibreChatProbeOutcome.invalidAddress);
        // An Open WebUI server is told apart, to be added as one.
        final owui = LocalOwui.read();
        if (owui != null) {
          final other = await libreChat.probe(LibreChatProbe(url: owui.url));
          expect(other.outcome, LibreChatProbeOutcome.openWebUi);
        }
      });

      test('signs in with a password and an authenticator code', () async {
        final wrong = await libreChat.signIn(
          LibreChatSignIn(
            url: server!.url,
            email: server.twoFactorEmail,
            password: 'not-the-password',
          ),
        );
        expect(wrong.outcome, LibreChatSignInOutcome.rejected);
        expect(wrong.serverMessage, 'Incorrect password.');

        final first = await libreChat.signIn(
          LibreChatSignIn(
            url: server.url,
            email: server.twoFactorEmail,
            password: server.twoFactorPassword,
          ),
        );
        expect(first.outcome, LibreChatSignInOutcome.twoFactorRequired);
        expect(first.flowId, isNotNull);

        final badCode = await libreChat.verify(
          LibreChatVerify(flowId: first.flowId!, code: '000000'),
        );
        expect(badCode.outcome, LibreChatSignInOutcome.invalidCode);

        final done = await libreChat.verify(
          LibreChatVerify(flowId: first.flowId!, code: server.twoFactorCode),
        );
        expect(done.outcome, LibreChatSignInOutcome.signedIn);
        expect(done.accountId, startsWith('librechat:'));

        final list = await accounts.list();
        expect(list.primary, PrimaryAccount.libreChat);
        expect(list.activeAccountId, isNull);
        expect(list.activeLibreChatAccountId, done.accountId);
        expect(list.libreChatSession, LibreChatSessionPhase.signedIn);
        expect(list.libreChatAccounts, hasLength(1));
        final account = list.libreChatAccounts.single;
        expect(account.title, 'Harbour LibreChat');
        expect(account.user?.name, 'Rowan Vale');
        expect(account.hasSession && account.isActive, isTrue);

        // A used flow is gone.
        final again = await libreChat.verify(
          LibreChatVerify(flowId: first.flowId!, code: server.twoFactorCode),
        );
        expect(again.outcome, LibreChatSignInOutcome.expired);
      });

      test('lists the account\'s chats from its server', () async {
        final list = await _until(
          () => chats.list(),
          (list) => list.chats.any((c) => c.title == 'Tide table questions'),
        );
        final titles = {for (final chat in list.chats) chat.title: chat};
        expect(titles.keys, contains('Harbour lights schedule'));
        expect(titles['Harbour lights schedule']!.pinned, isTrue);
        expect(titles.keys, isNot(contains('Kite festival plan')));
      });

      test('searches the account\'s chats', () async {
        final results = await _until(
          () => chats.search(const ChatSearchQuery(query: 'spring tide')),
          (r) => r.hits.isNotEmpty,
        );
        expect(results.complete, isTrue);
        expect(
          results.hits.map((h) => h.title),
          contains('Tide table questions'),
        );
      });

      test('offers its specs, agents and endpoint models', () async {
        final list = await _until(
          () => models.list(),
          (list) => list.models.any((m) => m.name == 'Tidewatch'),
        );
        final names = list.models.map((m) => m.name).toList();
        expect(
          names,
          containsAll(<String>[
            'Quick Notes',
            'Deep Research',
            'Tidewatch',
            'Ledger Helper',
            'harbour-small',
          ]),
        );
        printOnFailure('$list');
        // Mobile's picker layout: the specs and agents on top, the endpoint
        // models in their sections under More Models.
        final byId = {for (final m in list.models) m.id: m.name};
        expect(
          list.featuredIds.map((id) => byId[id]),
          containsAll(<String>['Quick Notes', 'Tidewatch']),
        );
        expect(list.moreSections.map((s) => s.label), contains('Harbour'));
      });

      test('sends a turn with a spec and streams the answer', () async {
        final spec = (await models.list()).models.firstWhere(
          (m) => m.name == 'Quick Notes',
        );
        final seen = <String>[];
        final payloads = <String, Map<String, dynamic>>{};
        events.attach('probe', (envelope) {
          seen.add(envelope.event);
          payloads[envelope.event] = envelope.payload;
        });
        addTearDown(() => events.detach('probe'));
        final accepted = await turns.send(
          SendTurn(model: spec.id, text: 'Tell me about lighthouse keepers'),
        );
        subscribeWindow(events, turns, 'probe', <String>[accepted.chatId]);
        await _waitFor(
          () => seen.contains(ConduitEvents.turnFinished),
          reason: () => 'events: $seen',
        );
        expect(
          seen,
          contains(ConduitEvents.turnCompleted),
          reason: 'failed: ${payloads[ConduitEvents.turnFailed]}',
        );
        final completed = TurnCompleted.fromJson(
          payloads[ConduitEvents.turnCompleted]!,
        );
        expect(completed.text, contains('Quick Notes answers'));
        final state = await server!.state();
        final start = (state['turns'] as List).last as Map;
        expect((start['start'] as Map)['spec'], 'quick-notes');

        final list = await _until(
          () => chats.list(),
          (list) => list.chats.any((c) => c.title == 'Tell me about lighthouse'),
        );
        expect(list.chats.first.title, 'Tell me about lighthouse');
        // The windows were told the server's ids, which the stored chat
        // keeps: its live rows and the stored ones are the same messages.
        final stored = (await chats.get(accepted.chatId))!;
        expect(
          stored.messages.map((m) => m.id),
          containsAll(<String>[
            accepted.userMessageId,
            accepted.assistantMessageId,
          ]),
        );
        expect(completed.messageId, accepted.assistantMessageId);
      }, timeout: const Timeout(Duration(minutes: 2)));

      /// Sends [text] in a new chat with [modelName], answering each
      /// `ui.request` with [answer], and waits for the turn to end. Returns
      /// the chat, the answer's id and the events seen.
      Future<
        ({String chatId, String messageId, List<EventEnvelope> seen})
      >
      runTurn(
        String text, {
        String modelName = 'harbour-small',
        UiResponse? Function(UiRequest request)? answer,
        Future<void> Function(String chatId)? whileRunning,
        List<String> toolIds = const <String>[],
      }) async {
        final model = (await models.list()).models.firstWhere(
          (m) => m.name == modelName,
        );
        final seen = <EventEnvelope>[];
        events.attach('probe', (envelope) {
          seen.add(envelope);
          if (envelope.event == ConduitEvents.uiRequest && answer != null) {
            final request = UiRequest.fromJson(envelope.payload);
            final response = answer(request);
            if (response != null) {
              Future<void>.delayed(
                const Duration(milliseconds: 50),
                () => uiRequests.respond(response),
              );
            }
          }
        });
        addTearDown(() => events.detach('probe'));
        final accepted = await turns.send(
          SendTurn(model: model.id, text: text, toolIds: toolIds),
        );
        subscribeWindow(events, turns, 'probe', <String>[accepted.chatId]);
        if (whileRunning != null) await whileRunning(accepted.chatId);
        await _waitFor(
          () => seen.any((e) => e.event == ConduitEvents.turnFinished),
          reason: () => 'events: ${seen.map((e) => e.event).toList()}',
        );
        return (
          chatId: accepted.chatId,
          messageId: accepted.assistantMessageId,
          seen: seen,
        );
      }

      String completedText(List<EventEnvelope> seen) => TurnCompleted.fromJson(
        seen.lastWhere((e) => e.event == ConduitEvents.turnCompleted).payload,
      ).text;

      test('asks to approve a paused tool call, and goes on', () async {
        final asked = <UiRequest>[];
        final run = await runTurn(
          'Please approve the tide lookup',
          answer: (request) {
            asked.add(request);
            return UiResponse(requestId: request.requestId, choice: 'allow');
          },
        );
        expect(asked, hasLength(1));
        expect(asked.single.kind, UiRequestKind.toolApproval);
        expect(asked.single.messageCode, 'librechat.toolApproval');
        expect(asked.single.messageArgs['title'], 'lookup_tide_mcp_harbour_docs');
        expect(asked.single.detail['arguments'], contains('Port Wren'));
        expect(completedText(run.seen), contains('06:40'));
        final state = await server!.state();
        final resume = (state['turns'] as List)
            .cast<Map<String, dynamic>>()
            .lastWhere((t) => t.containsKey('resume'))['resume'] as Map;
        expect(
          (resume['decisions'] as List).single,
          containsPair('decision', 'approve'),
        );
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('puts an agent\'s question to the user, and answers it', () async {
        final asked = <UiRequest>[];
        final run = await runTurn(
          'Please ask me which harbour',
          answer: (request) {
            asked.add(request);
            return UiResponse(
              requestId: request.requestId,
              choice: 'answer',
              text: 'Gull Haven',
            );
          },
        );
        expect(asked.single.kind, UiRequestKind.libreChatQuestion);
        expect(asked.single.detail['question'], 'Which harbour do you mean?');
        expect(
          (asked.single.detail['options'] as List).map((o) => (o as Map)['label']),
          ['Port Wren', 'Gull Haven'],
        );
        expect(completedText(run.seen), contains('You chose Gull Haven'));
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('stops a reply, keeping what it wrote', () async {
        final run = await runTurn(
          'Tell me a long story about the harbour',
          whileRunning: (chatId) async {
            await Future<void>.delayed(const Duration(seconds: 2));
            await turns.stop(chatId);
          },
        );
        final finished = TurnFinished.fromJson(
          run.seen.lastWhere((e) => e.event == ConduitEvents.turnFinished).payload,
        );
        expect(finished.chatId, run.chatId);
        final state = await server!.state();
        final aborted = (state['conversations'] as List)
            .cast<Map<String, dynamic>>()
            .any((c) => c['conversationId'] == run.chatId);
        expect(aborted, isTrue);
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('regenerates an answer', () async {
        final first = await runTurn('Name a quiet cove');
        final regenerated = <EventEnvelope>[];
        events.attach('probe2', regenerated.add);
        addTearDown(() => events.detach('probe2'));
        subscribeWindow(events, turns, 'probe2', <String>[first.chatId]);
        final chat = await chats.get(first.chatId);
        final answer = chat!.messages.lastWhere((m) => m.role == 'assistant');
        final accepted = await turns.regenerate(
          RegenerateTurn(chatId: first.chatId, messageId: answer.id),
        );
        await _waitFor(
          () => regenerated.any((e) => e.event == ConduitEvents.turnFinished),
          reason: () => 'events: ${regenerated.map((e) => e.event).toList()}',
        );
        expect(
          regenerated.where((e) => e.event == ConduitEvents.turnFailed),
          isEmpty,
        );
        final state = await server!.state();
        final last = ((state['turns'] as List).last as Map)['start'] as Map;
        expect(last['isRegenerate'], isTrue);
        // The stored chat shows the new answer, the old one among its
        // versions.
        final after = await _until(
          () => chats.get(first.chatId),
          (c) => c!.messages.where((m) => m.role == 'assistant').length == 1,
        );
        final shown = after!.messages.lastWhere((m) => m.role == 'assistant');
        // The windows were told the id the chat keeps for it.
        expect(accepted.assistantMessageId, shown.id);
        final started = regenerated
            .where((e) => e.event == ConduitEvents.turnStarted)
            .map((e) => TurnStarted.fromJson(e.payload));
        expect(started.map((s) => s.messageId), everyElement(shown.id));
        printOnFailure(
          [for (final m in after.messages) '${m.role} ${m.id} ${m.versions.length}']
              .join('\n'),
        );
        expect(shown.id, isNot(answer.id));
        expect(shown.versions, isNotEmpty);
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('renames, pins, archives, duplicates and deletes on the server', () async {
        String idOf(ChatList list, String title) =>
            list.chats.firstWhere((c) => c.title == title).id;
        var list = await chats.list();
        final shed = idOf(list, 'Garden shed paint colours');

        await chats.rename(shed, 'Shed colours');
        await chats.setPinned(shed, value: true);
        Map<String, dynamic> serverCopy(Map<String, dynamic> state) =>
            (state['conversations'] as List)
                .cast<Map<String, dynamic>>()
                .firstWhere((c) => c['conversationId'] == shed);
        await _waitFor(() async {
          final copy = serverCopy(await server!.state());
          return copy['title'] == 'Shed colours' && copy['pinned'] == true;
        });

        final copy = await libreChat.duplicate(ChatRef(id: shed));
        expect(copy.chatId, isNot(shed));
        list = await _until(
          () => chats.list(),
          (list) => list.chats.any((c) => c.id == copy.chatId),
        );

        await chats.setArchived(shed, value: true);
        await _waitFor(
          () async => serverCopy(await server!.state())['isArchived'] == true,
        );

        await chats.delete(copy.chatId);
        await _waitFor(() async {
          final state = await server!.state();
          return !(state['conversations'] as List).any(
            (c) => (c as Map)['conversationId'] == copy.chatId,
          );
        });
        list = await chats.list();
        expect(list.chats.map((c) => c.id), isNot(contains(copy.chatId)));
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('branches a chat at a message, on the server', () async {
        final list = await chats.list();
        final tides = list.chats.firstWhere(
          (c) => c.title == 'Tide table questions',
        );
        final detail = (await chats.get(tides.id))!;
        // The first answer: the copy keeps its question and it.
        final first = detail.messages.firstWhere((m) => m.role == 'assistant');
        final fork = await chats.fork(
          ForkChat(chatId: tides.id, messageId: first.id),
        );
        expect(fork.chatId, isNot(tides.id));
        final copy = await _until(
          () => chats.get(fork.chatId),
          (c) => c != null && c.messages.length == 2,
        );
        expect(copy!.messages.map((m) => m.role), ['user', 'assistant']);
        await chats.delete(fork.chatId);
      });

      test('reads, adds and deletes memories', () async {
        var memories = await libreChat.memories();
        expect(memories.enabled, isTrue);
        expect(memories.canCreate && memories.canUpdate, isTrue);
        expect(
          memories.memories.map((m) => m.key),
          containsAll(<String>['favourite_tea', 'home_harbour']),
        );
        memories = await libreChat.saveMemory(
          const LibreChatMemoryEdit(key: 'boat_name', value: 'The Gannet'),
        );
        expect(memories.memories.map((m) => m.key), contains('boat_name'));
        memories = await libreChat.saveMemory(
          const LibreChatMemoryEdit(
            originalKey: 'boat_name',
            key: 'boat_name',
            value: 'The Grey Gannet',
          ),
        );
        expect(
          memories.memories.firstWhere((m) => m.key == 'boat_name').value,
          'The Grey Gannet',
        );
        memories = await libreChat.deleteMemory(
          const LibreChatMemoryRef(key: 'boat_name'),
        );
        expect(memories.memories.map((m) => m.key), isNot(contains('boat_name')));
        memories = await libreChat.setMemoriesEnabled(
          const LibreChatMemoryToggle(enabled: false),
        );
        expect(memories.enabled, isFalse);
        await libreChat.setMemoriesEnabled(
          const LibreChatMemoryToggle(enabled: true),
        );
      });

      test('offers tools and MCP servers for an endpoint model only', () async {
        final all = (await models.list()).models;
        final endpoint = all.firstWhere((m) => m.name == 'harbour-small');
        final agent = all.firstWhere((m) => m.name == 'Tidewatch');
        final tools = await libreChat.composer(
          LibreChatComposerTarget(modelId: endpoint.id),
        );
        expect(tools.libreChat, isTrue);
        expect(tools.webSearchToolId, 'librechat:web_search');
        expect(tools.codeInterpreterToolId, 'librechat:execute_code');
        expect(tools.prompts, isTrue);
        expect(
          {for (final s in tools.mcpServers) s.name: s.needsConnection},
          {'harbour_docs': false, 'ledger_sync': true},
        );
        expect(tools.webUrl, server!.url);
        final agentTools = await libreChat.composer(
          LibreChatComposerTarget(modelId: agent.id),
        );
        expect(agentTools.webSearchToolId, isNull);
        expect(agentTools.prompts, isTrue);
      });

      test('speaks and transcribes through the LibreChat server', () async {
        final spec = (await models.list()).models.firstWhere(
          (m) => m.name == 'Quick Notes',
        );
        final speech = await SpeechService.speechForModel(
          runtime.container,
          spec.id,
        );
        expect(speech?.source, ServerSpeechSource.libreChat);
        expect(speech!.canTranscribe && speech.canSynthesize, isTrue);
        final text = await speech.transcribe(
          Uint8List.fromList(List<int>.filled(32, 0)),
          fileName: 'clip.wav',
          mimeType: 'audio/wav',
        );
        expect(text, 'Harbour lights at dusk');
        final spoken = await speech.synthesize('Lights on at dusk');
        expect(spoken.bytes, isNotEmpty);
      });

      test('refuses a temporary chat, which LibreChat would keep', () async {
        final model = (await models.list()).models.firstWhere(
          (m) => m.name == 'harbour-small',
        );
        await expectLater(
          turns.send(
            SendTurn(model: model.id, text: 'Keep this off the record', temporary: true),
          ),
          throwsA(
            isA<RpcError>().having(
              (e) => e.args['reason'],
              'reason',
              'libreChatTemporaryChat',
            ),
          ),
        );
      });

      test('shares a chat by link', () async {
        final list = await chats.list();
        final harbour = list.chats.firstWhere(
          (c) => c.title == 'Harbour lights schedule',
        );
        final share = await chats.share(
          ShareChat(id: harbour.id, publish: true),
        );
        expect(share.url, startsWith('${server!.url}/share/'));
        final state = await server.state();
        expect((state['shares'] as Map).values.single['conversationId'], harbour.id);
        await chats.unshare(harbour.id);
        expect(((await server.state())['shares'] as Map), isEmpty);
      });

      test('fills a prompt\'s blanks, LibreChat\'s way', () async {
        final prompts = PromptsService(runtime.container);
        final list = await prompts.list();
        expect(
          list.prompts.map((p) => p.command),
          containsAll(<String>['/pack', '/tone', '/summary']),
        );
        final form = await prompts.render(const RenderPrompt(command: '/tone'));
        expect(form.inputs.map((i) => i.name), ['tone', 'text']);
        final tone = form.inputs.first;
        expect(tone.options, ['friendly', 'formal', 'playful']);
        expect(tone.defaultValue, 'friendly');
        final filled = await prompts.render(
          const RenderPrompt(
            command: '/tone',
            values: <String, String>{'tone': 'playful', 'text': 'Tide is out'},
          ),
        );
        expect(filled.content, 'Rewrite this in a playful tone: Tide is out');
        final plain = await prompts.render(
          const RenderPrompt(command: '/summary'),
        );
        expect(plain.inputs, isEmpty);
        expect(plain.content, 'Summarise today in three bullet points.');
      });

      test('reports what the LibreChat role may use', () async {
        final capabilities = CapabilitiesService(runtime.container);
        addTearDown(capabilities.dispose);
        await _waitFor(() => capabilities.current.libreChat != null);
        final features = capabilities.current.libreChat!;
        expect(features.memories && features.prompts, isTrue);
        expect(features.sharedLinks && features.agents, isTrue);
        expect(capabilities.current.notes, isFalse);
        expect(capabilities.current.channels, isFalse);
      });

      test('a session that ended asks for a sign-in, from its server', () async {
        final before = (await accounts.list()).activeLibreChatAccountId;
        await server!.endSessions();
        // The next request finds the token refused and the refresh too.
        try {
          await runtime.container
              .read(libreChatApiServiceProvider)!
              .currentUser();
        } on Object {
          // Refused: the session is over.
        }
        final ended = await _until(
          () => accounts.list(),
          (list) => list.libreChatSession == LibreChatSessionPhase.needsSignIn,
        );
        expect(ended.libreChatSession, LibreChatSessionPhase.needsSignIn);
        expect(ended.primary, PrimaryAccount.libreChat);
        expect(ended.libreChatAccounts.single.hasSession, isFalse);

        // Signed in again with a backup code: the same account, its chats
        // kept.
        final first = await libreChat.signIn(
          LibreChatSignIn(
            url: server.url,
            email: server.twoFactorEmail,
            password: server.twoFactorPassword,
          ),
        );
        final done = await libreChat.verify(
          LibreChatVerify(
            flowId: first.flowId!,
            code: server.backupCode,
            backupCode: true,
          ),
        );
        expect(done.outcome, LibreChatSignInOutcome.signedIn);
        expect(done.accountId, before);
        expect(
          (await accounts.list()).libreChatSession,
          LibreChatSessionPhase.signedIn,
        );
      });

      test('signs in with single sign-on as another account', () async {
        final plan = await libreChat.ssoStart(
          LibreChatSsoStart(url: server!.url, provider: 'openid'),
        );
        expect(plan.startUrl, '${server.url}/oauth/openid');
        expect(plan.serverOrigins, [server.url]);
        final cookies = await _signInAtProvider(plan.startUrl);
        expect(cookies.keys, contains('refreshToken'));
        final done = await libreChat.completeSso(
          LibreChatSsoCompletion(
            url: server.url,
            cookies: cookies,
            startId: plan.startId,
          ),
        );
        expect(done.outcome, LibreChatSignInOutcome.signedIn);
        final list = await accounts.list();
        expect(list.libreChatAccounts, hasLength(2));
        expect(
          list.libreChatAccounts
              .firstWhere((a) => a.id == list.activeLibreChatAccountId)
              .user
              ?.name,
          'Sage Ito',
        );
        // A fresh start that comes back with no cookies (the window closed
        // before the server set them).
        final again = await libreChat.ssoStart(
          LibreChatSsoStart(url: server.url, provider: 'openid'),
        );
        final unfinished = await libreChat.completeSso(
          LibreChatSsoCompletion(url: server.url, startId: again.startId),
        );
        expect(unfinished.outcome, LibreChatSignInOutcome.ssoUnfinished);
      });

      test('switches between LibreChat accounts', () async {
        final list = await accounts.list();
        final rowan = list.libreChatAccounts.firstWhere(
          (a) => a.user?.name == 'Rowan Vale',
        );
        final result = await accounts.switchTo(
          AccountRef(accountId: rowan.id),
        );
        expect(result.outcome, AccountChangeOutcome.done);
        expect(result.accounts.activeLibreChatAccountId, rowan.id);
        final chats0 = await _until(
          () => chats.list(),
          (list) => list.chats.any((c) => c.title == 'Tide table questions'),
        );
        expect(chats0.chats.map((c) => c.title), contains('Tide table questions'));
      });

      test('adds an Open WebUI account beside LibreChat, and back', () async {
        final auth = AuthService(runtime.container);
        final lc = (await accounts.list()).activeLibreChatAccountId!;
        final owui = LocalOwui.read();
        final url = owui?.url ?? 'http://127.0.0.1:9';
        // Cancelled: the LibreChat account owns the chats again.
        var added = await accounts.add(
          AddAccount(server: ServerDraft(name: 'Lab', url: url)),
        );
        expect(added.outcome, AccountChangeOutcome.needsSignIn);
        expect(added.accounts.addingAccount, isTrue);
        expect(added.accounts.activeAccountId, isNotNull);
        final cancelled = await accounts.cancelAdd();
        expect(cancelled.accounts.addingAccount, isFalse);
        expect(cancelled.accounts.primary, PrimaryAccount.libreChat);
        expect(cancelled.accounts.activeLibreChatAccountId, lc);
        expect(cancelled.accounts.accounts, isEmpty);
        if (owui == null) return;
        // Signed in: Open WebUI owns the chats; switching back is a switch.
        added = await accounts.add(
          AddAccount(server: ServerDraft(name: 'Lab', url: url)),
        );
        final snapshot = await auth.loginWithPassword(
          PasswordLogin(username: owui.email, password: owui.password),
        );
        expect(snapshot.isAuthenticated, isTrue);
        final owned = await _until(
          () => accounts.list(),
          (list) => list.primary == PrimaryAccount.openWebUi,
        );
        expect(owned.primary, PrimaryAccount.openWebUi);
        expect(owned.addingAccount, isFalse);
        expect(owned.activeAccountId, isNotNull);
        final back = await accounts.switchTo(AccountRef(accountId: lc));
        expect(back.outcome, AccountChangeOutcome.done);
        expect(back.accounts.primary, PrimaryAccount.libreChat);
        expect(back.accounts.activeAccountId, isNull);
        // The Open WebUI account goes again, so the hand-over below is
        // LibreChat's alone.
        final owuiId = back.accounts.accounts.single.id;
        await accounts.remove(AccountRef(accountId: owuiId, force: true));
        expect(
          (await accounts.list()).primary,
          PrimaryAccount.libreChat,
        );
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('signs out, handing the chats to the account used last', () async {
        final first = await accounts.signOut(const AccountSignOut());
        expect(first.outcome, AccountChangeOutcome.done);
        expect(first.accounts.libreChatAccounts, hasLength(1));
        expect(first.accounts.primary, PrimaryAccount.libreChat);
        expect(
          first.accounts.libreChatAccounts.single.user?.name,
          'Sage Ito',
        );
        final last = await accounts.signOut(const AccountSignOut());
        expect(last.accounts.libreChatAccounts, isEmpty);
        expect(last.accounts.libreChatSession, LibreChatSessionPhase.none);
      });
    },
  );
}

/// Asks [read] until [done] holds, for up to 20 s; the last answer either way.
Future<T> _until<T>(
  Future<T> Function() read,
  bool Function(T value) done,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  var value = await read();
  while (!done(value) && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    value = await read();
  }
  return value;
}

Future<void> _waitFor(
  Object Function() condition, {
  Duration timeout = const Duration(seconds: 30),
  String Function()? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final value = condition();
    if (value == true || (value is Future && await value == true)) return;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  fail('timed out waiting${reason == null ? '' : ': ${reason()}'}');
}

/// Signs in at the fake's stand-in OpenID provider as a browser would --
/// following redirects and keeping cookies -- from [startUrl] up to the
/// server's web app, which a sign-in window would stop at. The cookies the
/// server set, by name.
Future<Map<String, String>> _signInAtProvider(String startUrl) async {
  final client = HttpClient();
  final jar = <String, String>{};
  try {
    Future<HttpClientResponse> go(String method, Uri url) async {
      final request = await client.openUrl(method, url)
        ..followRedirects = false;
      if (jar.isNotEmpty) {
        request.headers.set(
          'cookie',
          jar.entries.map((e) => '${e.key}=${e.value}').join('; '),
        );
      }
      final response = await request.close();
      for (final cookie in response.cookies) {
        jar[cookie.name] = cookie.value;
      }
      return response;
    }

    var url = Uri.parse(startUrl);
    var method = 'GET';
    for (var hop = 0; hop < 8; hop++) {
      final response = await go(method, url);
      final body = await response.transform(utf8.decoder).join();
      final location = response.headers.value('location');
      if (location != null) {
        url = url.resolve(location);
        method = 'GET';
        // The server's web app: the sign-in is done.
        if (url.path.startsWith('/c/')) break;
        continue;
      }
      // The provider's page: press Continue.
      if (body.contains('id="approve"')) {
        url = url.resolve('/fake-idp/approve');
        method = 'POST';
        continue;
      }
      break;
    }
    return jar;
  } finally {
    client.close(force: true);
  }
}
