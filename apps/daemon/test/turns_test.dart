@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show
        chatMessagesProvider,
        chatSessionRegistryProvider,
        isChatStreamingProvider;
import 'package:conduit_core/features/chat/providers/openwebui_chat_prompt_provider.dart';
import 'package:conduit_core/features/chat/services/chat_draft_queue.dart'
    show chatDraftQueueAdmissionWaitProvider;
import 'package:conduit_core/features/terminal/providers/terminal_providers.dart'
    show terminalDisplayFileProvider;
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:conduitd/src/chat_prompts_service.dart';
import 'package:test/test.dart';

import 'support/null_sink.dart';
import 'support/scripted_openai.dart';
import 'support/window.dart';

/// `turns.*` over the core's chat library, against a direct connection to a
/// scripted provider: several chats answering at once, each window hearing
/// only its own chat, stop, regenerate, edit, rate, a refusal, and a window
/// that arrives mid-answer.
void main() {
  late Directory temporary;
  late CoreRuntime runtime;
  late ScriptedOpenAi provider;
  late EventBus events;
  late TurnsService turns;
  late ChatsService chats;
  late UiRequestsService ui;
  late ChatPromptsService prompts;
  late String model;
  final windows = <String, List<EventEnvelope>>{};
  final previousLinger = TurnsService.lingerAfterTurn;

  List<EventEnvelope> window(String id) =>
      windows.putIfAbsent(id, () => <EventEnvelope>[]);

  void open(String id) {
    window(id);
    events.attach(id, (envelope) => window(id).add(envelope));
  }

  Iterable<EventEnvelope> of(String windowId, String event) =>
      window(windowId).where((envelope) => envelope.event == event);

  Future<void> until(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('timed out waiting');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  bool ended(String windowId, String messageId) => window(windowId).any(
    (envelope) =>
        (envelope.event == ConduitEvents.turnCompleted ||
            envelope.event == ConduitEvents.turnFailed) &&
        envelope.payload['messageId'] == messageId,
  );

  setUpAll(() async {
    TurnsService.lingerAfterTurn = const Duration(milliseconds: 300);
    temporary = Directory.systemTemp.createTempSync('turns-test');
    runtime = await CoreRuntime.start(
      config: BootstrapConfig(
        sessionToken: 'a' * 43,
        masterKey: base64.encode(List<int>.generate(32, (i) => i)),
        userDataDir: temporary.path,
      ),
      directories: DaemonDirectories.create(temporary.path),
      log: DaemonLog(level: 'error', sink: NullSink()),
    );
    provider = await ScriptedOpenAi.start();
    final direct = DirectService(runtime.container);
    await direct.setPreferred(preferred: true);
    await direct.setHistory(localOnly: true);
    final saved = await direct.save(
      DirectConnectionEdit(
        name: 'Scripted',
        kind: DirectKind.openai,
        baseUrl: provider.baseUrl,
        manualModelIds: const <String>['scripted-model'],
      ),
    );
    model = DirectModelId.encode(saved.connections.single.id, 'scripted-model');
    events = EventBus();
    ui = UiRequestsService(events);
    prompts = ChatPromptsService(events);
    turns = TurnsService(
      runtime.container,
      events,
      uiRequests: ui,
      chatPrompts: prompts,
    );
    chats = ChatsService(runtime.container, events: events);
  });

  tearDownAll(() async {
    TurnsService.lingerAfterTurn = previousLinger;
    await turns.dispose();
    chats.dispose();
    await provider.close();
    await runtime.dispose();
    temporary.deleteSync(recursive: true);
  });

  setUp(() => windows.clear());

  test('two chats answer at once, each heard only by its own window', () async {
    open('window-a');
    open('window-b');
    final a = await turns.send(
      SendTurn(model: model, text: 'hold:a alpha beta gamma'),
    );
    final b = await turns.send(
      SendTurn(model: model, text: 'hold:b one two three'),
    );
    expect(a.chatId, isNot(b.chatId));
    expect(a.chatId, startsWith('direct-local:'));
    subscribeWindow(events, turns, 'window-a', <String>[a.chatId]);
    subscribeWindow(events, turns, 'window-b', <String>[b.chatId]);

    // Both are running at the same time, each in its own scope.
    expect(turns.activeChatIds, containsAll(<String>[a.chatId, b.chatId]));
    expect(
      runtime.container.read(chatSessionRegistryProvider).scopes.length,
      greaterThanOrEqualTo(2),
    );
    await until(
      () =>
          (turns.progress(a.chatId)?.text.contains('gamma') ?? false) &&
          (turns.progress(b.chatId)?.text.contains('three') ?? false),
    );

    provider.release('b');
    await until(() => ended('window-b', b.assistantMessageId));
    // A is still answering after B has finished.
    expect(turns.activeChatIds, contains(a.chatId));
    expect(turns.activeChatIds, isNot(contains(b.chatId)));
    provider.release('a');
    await until(() => ended('window-a', a.assistantMessageId));

    for (final (windowId, accepted, words)
        in <(String, SendTurnAccepted, String)>[
          ('window-a', a, 'alpha beta gamma'),
          ('window-b', b, 'one two three'),
        ]) {
      final heard = window(windowId).where((e) => e.scope != null).toList();
      expect(heard, isNotEmpty);
      // Every scoped event this window heard was about its own chat.
      expect(heard.map((e) => e.scope).toSet(), <String>{accepted.chatId});
      expect(heard.map((e) => e.payload['messageId']).toSet(), <String>{
        accepted.assistantMessageId,
      });
      final completed = TurnCompleted.fromJson(
        of(windowId, ConduitEvents.turnCompleted).single.payload,
      );
      expect(completed.text, words);
    }

    // Stored, each with its own answer.
    await until(() => turns.activeChatIds.isEmpty);
    final storedA = await chats.get(a.chatId);
    final storedB = await chats.get(b.chatId);
    expect(storedA!.messages.map((m) => m.content), <String>[
      'hold:a alpha beta gamma',
      'alpha beta gamma',
    ]);
    expect(storedB!.messages.map((m) => m.content), <String>[
      'hold:b one two three',
      'one two three',
    ]);
  });

  test(
    'a window that subscribes mid-answer is sent the answer so far',
    () async {
      open('early');
      final accepted = await turns.send(
        SendTurn(model: model, text: 'hold:mid first second third'),
      );
      subscribeWindow(events, turns, 'early', <String>[accepted.chatId]);
      await until(
        () => turns.progress(accepted.chatId)?.text.contains('third') ?? false,
      );

      open('late');
      subscribeWindow(events, turns, 'late', <String>[accepted.chatId]);
      final snapshot = TurnDelta.fromJson(
        of('late', ConduitEvents.turnDelta).single.payload,
      );
      expect(snapshot.chatId, accepted.chatId);
      expect(snapshot.messageId, accepted.assistantMessageId);
      expect(snapshot.text, 'first second third');

      provider.release('mid');
      await until(() => ended('late', accepted.assistantMessageId));
      // The window that was there from the start heard deltas, coalesced.
      expect(of('early', ConduitEvents.turnDelta), isNotEmpty);
    },
  );

  test(
    'a window that subscribes after a quick answer is sent its end',
    () async {
      open('slow-window');
      final accepted = await turns.send(SendTurn(model: model, text: 'quick'));
      await until(() => turns.progress(accepted.chatId) == null);
      subscribeWindow(events, turns, 'slow-window', <String>[accepted.chatId]);
      final completed = TurnCompleted.fromJson(
        of('slow-window', ConduitEvents.turnCompleted).single.payload,
      );
      expect(completed.text, 'Answer to: quick');
      // Not again for a window that already has the chat.
      subscribeWindow(events, turns, 'slow-window', <String>[accepted.chatId]);
      expect(of('slow-window', ConduitEvents.turnCompleted), hasLength(1));
    },
  );

  test('stop keeps what arrived and ends the turn', () async {
    open('stopper');
    final accepted = await turns.send(
      SendTurn(model: model, text: 'hold:stop partial answer'),
    );
    subscribeWindow(events, turns, 'stopper', <String>[accepted.chatId]);
    await until(
      () => turns.progress(accepted.chatId)?.text.contains('answer') ?? false,
    );

    await turns.stop(accepted.chatId);
    await until(() => ended('stopper', accepted.assistantMessageId));
    expect(turns.activeChatIds, isNot(contains(accepted.chatId)));
    final end = window('stopper').lastWhere(
      (e) =>
          e.event == ConduitEvents.turnCompleted ||
          e.event == ConduitEvents.turnFailed,
    );
    expect(end.payload['messageId'], accepted.assistantMessageId);
    final text = end.event == ConduitEvents.turnCompleted
        ? end.payload['text']
        : end.payload['partialText'];
    expect(text, contains('partial'));
    // Stopping again, with nothing running, is not an error.
    await turns.stop(accepted.chatId);
    provider.release('stop');
  });

  test(
    'Stop ends an answer left generating with nothing behind it, and the '
    'chat takes the next message',
    () async {
      open('stranded');
      final first = await turns.send(SendTurn(model: model, text: 'brief'));
      subscribeWindow(events, turns, 'stranded', <String>[first.chatId]);
      await until(() => ended('stranded', first.assistantMessageId));
      // What an earlier build could leave (a request that never went out):
      // the answer still marked as generating, with no run behind it.
      final scope = await turns.holdScope(first.chatId);
      var held = true;
      addTearDown(() {
        if (held) turns.releaseScope(first.chatId);
      });
      scope
          .read(chatMessagesProvider.notifier)
          .updateLastMessageWithFunction((m) => m.copyWith(isStreaming: true));
      expect(scope.read(isChatStreamingProvider), isTrue);
      expect(turns.activeChatIds, isNot(contains(first.chatId)));
      await expectLater(
        turns.send(
          SendTurn(model: model, chatId: first.chatId, text: 'still there?'),
        ),
        throwsA(
          isA<RpcError>().having(
            (e) => e.code,
            'code',
            ConduitErrorCodes.conflict,
          ),
        ),
      );
      final heard = of('stranded', ConduitEvents.chatsChanged).length;

      await turns.stop(first.chatId);
      expect(scope.read(isChatStreamingProvider), isFalse);
      expect(scope.read(chatMessagesProvider).last.isStreaming, isFalse);
      // The windows read the chat again: Send is back.
      expect(
        of('stranded', ConduitEvents.chatsChanged).length,
        greaterThan(heard),
      );
      held = false;
      turns.releaseScope(first.chatId);
      final next = await turns.send(
        SendTurn(model: model, chatId: first.chatId, text: 'still there?'),
      );
      await until(() => ended('stranded', next.assistantMessageId));
    },
  );

  test('a second turn in a busy chat is refused', () async {
    final accepted = await turns.send(
      SendTurn(model: model, text: 'hold:busy still going'),
    );
    await expectLater(
      turns.send(
        SendTurn(model: model, chatId: accepted.chatId, text: 'and this?'),
      ),
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.conflict,
        ),
      ),
    );
    open('busy');
    subscribeWindow(events, turns, 'busy', <String>[accepted.chatId]);
    provider.release('busy');
    await until(() => ended('busy', accepted.assistantMessageId));
  });

  test('a follow-up is sent with the conversation so far', () async {
    open('follow');
    final first = await turns.send(SendTurn(model: model, text: 'first'));
    subscribeWindow(events, turns, 'follow', <String>[first.chatId]);
    await until(() => ended('follow', first.assistantMessageId));
    final second = await turns.send(
      SendTurn(model: model, chatId: first.chatId, text: 'second'),
    );
    expect(second.chatId, first.chatId);
    await until(() => ended('follow', second.assistantMessageId));
    final sent = provider.requests.last
        .where((m) => m['role'] != 'system')
        .map((m) => m['content'])
        .toList();
    expect(sent, <Object?>['first', 'Answer to: first', 'second']);
  });

  test('regenerate answers again as a new version', () async {
    open('regen');
    final first = await turns.send(SendTurn(model: model, text: 'regen me'));
    subscribeWindow(events, turns, 'regen', <String>[first.chatId]);
    await until(() => ended('regen', first.assistantMessageId));

    final again = await turns.regenerate(
      RegenerateTurn(chatId: first.chatId, messageId: first.assistantMessageId),
    );
    expect(again.chatId, first.chatId);
    expect(again.userMessageId, first.userMessageId);
    final completed = of('regen', ConduitEvents.turnCompleted).length;
    await until(
      () => of('regen', ConduitEvents.turnCompleted).length > completed,
    );
    expect(
      of('regen', ConduitEvents.turnStarted).last.payload['messageId'],
      again.assistantMessageId,
    );

    await until(() => turns.activeChatIds.isEmpty);
    final stored = await chats.get(first.chatId);
    final answer = stored!.messages.last;
    expect(answer.id, again.assistantMessageId);
    expect(answer.content, 'Answer to: regen me');
    // The first answer is still reachable, as another version: a direct
    // chat keeps it on the answer's versions, as mobile does.
    expect(answer.versions, isNotEmpty);
  });

  test('regenerate and edit refuse what they cannot act on', () async {
    open('refuse');
    final first = await turns.send(SendTurn(model: model, text: 'subject'));
    subscribeWindow(events, turns, 'refuse', <String>[first.chatId]);
    await until(() => ended('refuse', first.assistantMessageId));
    await expectLater(
      turns.regenerate(
        RegenerateTurn(chatId: first.chatId, messageId: 'no-such-message'),
      ),
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.notFound,
        ),
      ),
    );
    await expectLater(
      turns.edit(
        EditTurn(
          chatId: first.chatId,
          messageId: first.assistantMessageId,
          text: 'not a question',
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
  });

  test('edit asks the new question beside the old one', () async {
    open('edit');
    final first = await turns.send(
      SendTurn(model: model, text: 'old question'),
    );
    subscribeWindow(events, turns, 'edit', <String>[first.chatId]);
    await until(() => ended('edit', first.assistantMessageId));

    final edited = await turns.edit(
      EditTurn(
        chatId: first.chatId,
        messageId: first.userMessageId,
        text: 'new question',
      ),
    );
    expect(edited.chatId, first.chatId);
    expect(edited.userMessageId, isNot(first.userMessageId));
    await until(() => ended('edit', edited.assistantMessageId));
    final completed = TurnCompleted.fromJson(
      of('edit', ConduitEvents.turnCompleted).last.payload,
    );
    expect(completed.text, 'Answer to: new question');

    await until(() => turns.activeChatIds.isEmpty);
    final stored = await chats.get(first.chatId);
    expect(stored!.messages.map((m) => m.content), <String>[
      'new question',
      'Answer to: new question',
    ]);
  });

  test('a refused turn fails with the provider\'s words', () async {
    open('fails');
    final accepted = await turns.send(SendTurn(model: model, text: 'fail'));
    subscribeWindow(events, turns, 'fails', <String>[accepted.chatId]);
    await until(() => ended('fails', accepted.assistantMessageId));
    final failed = TurnFailed.fromJson(
      of('fails', ConduitEvents.turnFailed).single.payload,
    );
    expect(failed.chatId, accepted.chatId);
    expect(failed.messageId, accepted.assistantMessageId);
    expect(failed.code, ConduitErrorCodes.serverError);
    expect(failed.args['detail'], contains('scripted refusal'));
    expect(of('fails', ConduitEvents.turnCompleted), isEmpty);
  });

  test('rating needs a stored chat on an Open WebUI account', () async {
    await expectLater(
      turns.rate(
        const RateTurn(chatId: 'local:anything', messageId: 'm', rating: 1),
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
      turns.rate(const RateTurn(chatId: 'chat', messageId: 'm', rating: 3)),
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.invalidParams,
        ),
      ),
    );
    // A direct-only daemon has no account to record it on.
    await expectLater(
      turns.rate(const RateTurn(chatId: 'chat', messageId: 'm', rating: 1)),
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.unauthenticated,
        ),
      ),
    );
  });

  test('a prompt or file raised in a chat reaches its windows', () async {
    open('prompted');
    final accepted = await turns.send(
      SendTurn(model: model, text: 'hold:prompt thinking'),
    );
    subscribeWindow(events, turns, 'prompted', <String>[accepted.chatId]);
    final scope = runtime.container
        .read(chatSessionRegistryProvider)
        .scopes
        .singleWhere((s) => s.conversation?.id == accepted.chatId);

    // A confirmation Open WebUI raised over the socket, as the core holds
    // it for the chat on screen.
    Object? acknowledged;
    scope.container
        .read(openWebUiLivePromptProvider.notifier)
        .handleSocketRequest(
          conversationId: accepted.chatId,
          type: 'confirmation',
          data: const {
            'title': 'Delete the draft?',
            'message': 'It cannot return.',
          },
          acknowledge: (response) => acknowledged = response,
        );
    // It docks in its chat (`chatPrompts.changed`), not as a `ui.request`.
    await until(
      () => of('prompted', ConduitEvents.chatPromptsChanged).isNotEmpty,
    );
    final asked = ChatPromptState.fromJson(
      of('prompted', ConduitEvents.chatPromptsChanged).last.payload,
    ).prompt!;
    expect(asked.kind, ChatPromptKind.confirmation);
    expect(asked.title, 'Delete the draft?');
    expect(asked.message, 'It cannot return.');
    expect(of('prompted', ConduitEvents.uiRequest), isEmpty);
    expect(
      (await prompts.get(ChatPromptRef(chatId: accepted.chatId))).prompt?.id,
      asked.id,
    );
    final decided = await prompts.decide(
      ChatPromptDecision(
        chatId: accepted.chatId,
        promptId: asked.id,
        approved: true,
      ),
    );
    expect(decided.accepted, isTrue);
    await until(() => acknowledged != null);
    expect(acknowledged, isTrue);
    // Answered, its card goes from every window.
    await until(
      () =>
          ChatPromptState.fromJson(
            of('prompted', ConduitEvents.chatPromptsChanged).last.payload,
          ).prompt ==
          null,
    );

    // A file the model's terminal tool asked to show.
    scope.container.read(terminalDisplayFileProvider.notifier).handleEvent(
      'terminal:display_file',
      const {'path': '/work/notes.md'},
    );
    final shown = TerminalDisplayFile.fromJson(
      of('prompted', ConduitEvents.terminalDisplayFile).single.payload,
    );
    expect(shown.chatId, accepted.chatId);
    expect(shown.path, '/work/notes.md');

    provider.release('prompt');
    await until(() => ended('prompted', accepted.assistantMessageId));
  });

  test('a finished chat lets its scope go', () async {
    open('linger');
    final accepted = await turns.send(SendTurn(model: model, text: 'brief'));
    subscribeWindow(events, turns, 'linger', <String>[accepted.chatId]);
    await until(() => ended('linger', accepted.assistantMessageId));
    await until(
      () => runtime.container.read(chatSessionRegistryProvider).scopes.isEmpty,
    );
    // And the chat opens again in a new one for its next turn.
    final next = await turns.send(
      SendTurn(model: model, chatId: accepted.chatId, text: 'again'),
    );
    await until(() => ended('linger', next.assistantMessageId));
  });

  test('a temporary chat being saved takes no second save and no turn',
      () async {
    open('saving');
    final chat = await turns.send(
      SendTurn(model: model, text: 'keep me', temporary: true),
    );
    subscribeWindow(events, turns, 'saving', <String>[chat.chatId]);
    await until(() => ended('saving', chat.assistantMessageId));
    final first = turns.saveTemporary(chat.chatId);
    final second = turns.saveTemporary(chat.chatId);
    final sending = turns.send(
      SendTurn(model: model, chatId: chat.chatId, text: 'and this'),
    );
    final conflict = throwsA(
      isA<RpcError>().having((e) => e.code, 'code', ConduitErrorCodes.conflict),
    );
    await expectLater(second, conflict);
    await expectLater(sending, conflict);
    // This account has no Open WebUI server to save to.
    await expectLater(first, throwsA(isA<RpcError>()));
  });

  test('a chat whose messages are being deleted takes no turn meanwhile',
      () async {
    open('deleting');
    final chat = await turns.send(SendTurn(model: model, text: 'drop this'));
    subscribeWindow(events, turns, 'deleting', <String>[chat.chatId]);
    await until(() => ended('deleting', chat.assistantMessageId));
    final deleting = turns.deleteMessages(
      DeleteMessages(
        chatId: chat.chatId,
        messageIds: <String>[chat.assistantMessageId],
      ),
    );
    final sending = turns.send(
      SendTurn(model: model, chatId: chat.chatId, text: 'and this'),
    );
    await expectLater(
      sending,
      throwsA(
        isA<RpcError>().having((e) => e.code, 'code', ConduitErrorCodes.conflict),
      ),
    );
    await deleting;
  });

  // The queue's batch is the core's own send: it can come while a delete
  // is out, and a delete the server refuses puts the transcript back as it
  // was before, without the batch. So the core's admission wait holds the
  // batch until the delete is done (the send itself needs an Open WebUI
  // outbox, which this harness has not).
  test('a queued batch waits for a delete that is out', () async {
    // Queued drafts keep a chat's scope open; this test queues none, so its
    // scope stays for the batch's settle.
    final linger = TurnsService.lingerAfterTurn;
    TurnsService.lingerAfterTurn = const Duration(seconds: 10);
    addTearDown(() => TurnsService.lingerAfterTurn = linger);
    open('deleting-queue');
    final chat = await turns.send(SendTurn(model: model, text: 'drop this'));
    subscribeWindow(events, turns, 'deleting-queue', <String>[chat.chatId]);
    await until(() => ended('deleting-queue', chat.assistantMessageId));
    final scope = runtime.container
        .read(chatSessionRegistryProvider)
        .scopes
        .lastWhere((s) => s.conversation?.id == chat.chatId);
    var deleted = false;
    final deleting = turns
        .deleteMessages(
          DeleteMessages(
            chatId: chat.chatId,
            messageIds: <String>[chat.assistantMessageId],
          ),
        )
        .whenComplete(() => deleted = true);
    // The delete is admitted, and waits for a quiet transcript (at least
    // half a second) when the batch asks to go.
    await Future<void>.delayed(const Duration(milliseconds: 10));
    var deletedFirst = false;
    final admitted = scope.container
        .read(chatDraftQueueAdmissionWaitProvider)()!
        .then((_) => deletedFirst = deleted);
    expect(await deleting, 1);
    await admitted;
    expect(deletedFirst, isTrue, reason: 'the batch went while the delete was out');
  });

  test('a merge naming one answer twice is refused', () async {
    await expectLater(
      turns.merge(
        const MergeTurn(
          chatId: 'any-chat',
          messageId: 'answer-a',
          targetId: 'answer-a',
          sourceIds: <String>['answer-a', 'answer-a'],
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
  });

  test('a comparison is judged by its own models, not `model`', () async {
    // The models compared are what count; this direct chat cannot compare,
    // and says so, rather than refusing a `model` it never runs.
    await expectLater(
      turns.send(
        SendTurn(
          model: DirectModelId.encode('missing', 'model'),
          compareModels: <String>[model, model],
          text: 'compare these',
        ),
      ),
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.unsupported,
        ),
      ),
    );
  });

  test('an unknown model is refused rather than guessed', () async {
    await expectLater(
      turns.send(
        SendTurn(model: DirectModelId.encode('missing', 'model'), text: 'hi'),
      ),
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.notFound,
        ),
      ),
    );
  });
}
