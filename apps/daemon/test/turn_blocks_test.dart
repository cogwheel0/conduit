@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

import 'support/mcp_fixture.dart';
import 'support/null_sink.dart';
import 'support/thinking_openai.dart';
import 'support/window.dart';

/// The parsed answer on the wire: `turn.blocks` frames while a direct
/// connection thinks, calls an MCP tool and answers; `turn.finished` for
/// windows that do not show the chat; what a window that subscribes late is
/// sent; and the blocks `chats.get` carries, cached.
void main() {
  late Directory temporary;
  late CoreRuntime runtime;
  late McpFixture mcpServer;
  late ThinkingOpenAi provider;
  late EventBus events;
  late UiRequestsService ui;
  late TurnsService turns;
  late ChatsService chats;
  late String model;
  late String toolId;
  final windows = <String, List<EventEnvelope>>{};

  List<EventEnvelope> window(String id) =>
      windows.putIfAbsent(id, () => <EventEnvelope>[]);

  void open(String id) {
    window(id);
    events.attach(id, (envelope) {
      window(id).add(envelope);
      // Every window allows the tool, as a person would.
      if (envelope.event == ConduitEvents.uiRequest) {
        final request = UiRequest.fromJson(envelope.payload);
        ui.respond(UiResponse(requestId: request.requestId, choice: 'allow'));
      }
    });
  }

  Iterable<EventEnvelope> of(String windowId, String event) =>
      window(windowId).where((envelope) => envelope.event == event);

  List<TurnBlocks> frames(String windowId) => [
    for (final envelope in of(windowId, ConduitEvents.turnBlocks))
      TurnBlocks.fromJson(envelope.payload),
  ];

  String kinds(TurnBlocks frame) =>
      frame.blocks.map((block) => block.kind.name).join(' ');

  Future<void> until(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('timed out waiting');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  bool ended(String windowId, String messageId) => window(windowId).any(
    (envelope) =>
        (envelope.event == ConduitEvents.turnCompleted ||
            envelope.event == ConduitEvents.turnFailed) &&
        envelope.payload['messageId'] == messageId,
  );

  setUpAll(() async {
    temporary = Directory.systemTemp.createTempSync('turn-blocks-test');
    runtime = await CoreRuntime.start(
      config: BootstrapConfig(
        sessionToken: 'a' * 43,
        masterKey: base64.encode(List<int>.generate(32, (i) => i)),
        userDataDir: temporary.path,
      ),
      directories: DaemonDirectories.create(temporary.path),
      log: DaemonLog(level: 'error', sink: NullSink()),
    );
    mcpServer = await McpFixture.start(requiredToken: 'mcp-token');
    provider = await ThinkingOpenAi.start();
    final direct = DirectService(runtime.container);
    await direct.setHistory(localOnly: true);
    final saved = await direct.save(
      DirectConnectionEdit(
        name: 'Thinking',
        kind: DirectKind.openai,
        baseUrl: provider.baseUrl,
        manualModelIds: const <String>['thinking-model'],
      ),
    );
    model = DirectModelId.encode(saved.connections.single.id, 'thinking-model');
    final servers = await McpService(runtime.container).save(
      McpServerEdit(
        name: 'Fixture',
        endpoint: mcpServer.endpoint.toString(),
        auth: McpAuth.bearer,
        bearerToken: 'mcp-token',
      ),
    );
    toolId = 'local_mcp:${servers.servers.single.id}';
    events = EventBus();
    ui = UiRequestsService(events);
    turns = TurnsService(runtime.container, events, uiRequests: ui);
    chats = ChatsService(runtime.container, events: events);
  });

  tearDownAll(() async {
    await turns.dispose();
    chats.dispose();
    await provider.close();
    await mcpServer.close();
    await runtime.dispose();
    temporary.deleteSync(recursive: true);
  });

  setUp(windows.clear);

  test(
    'reasoning, then a tool call, then text, frame by frame; '
    'turn.finished reaches every window; a late window is caught up',
    () async {
      open('chat-window');
      open('bystander');
      subscribeWindow(events, turns, 'bystander', const <String>[]);
      // Each stage waits until the window has shown the one before. Frames
      // are coalesced at 60 Hz, and a busy machine's stalled event loop
      // would otherwise merge stages that follow each other closely.
      final toolCall = provider.toolCallGate = Completer<void>();
      final answer = provider.answerGate = Completer<void>();
      addTearDown(() {
        provider
          ..toolCallGate = null
          ..answerGate = null;
        if (!toolCall.isCompleted) toolCall.complete();
        if (!answer.isCompleted) answer.complete();
      });

      final accepted = await turns.send(
        SendTurn(model: model, text: 'When is high water?', toolIds: [toolId]),
      );
      subscribeWindow(events, turns, 'chat-window', <String>[accepted.chatId]);

      // A window that arrives while the answer is being written is sent the
      // answer so far, parsed.
      await until(
        () => frames('chat-window').any((f) => kinds(f).contains('reasoning')),
      );
      open('mid-window');
      subscribeWindow(events, turns, 'mid-window', <String>[accepted.chatId]);
      expect(of('mid-window', ConduitEvents.turnDelta), hasLength(1));
      final caughtUp = frames('mid-window').single;
      expect(caughtUp.messageId, accepted.assistantMessageId);
      expect(kinds(caughtUp), startsWith('reasoning'));

      // Thinking shows, then the tool call, then the text.
      bool thinkingFrame(TurnBlocks f) =>
          f.blocks.isNotEmpty &&
          f.blocks.first.kind == MessageBlockKind.reasoning &&
          f.blocks.first.pending == true;
      await until(() => frames('chat-window').any(thinkingFrame));
      toolCall.complete();
      await until(
        () => frames('chat-window').any((f) => kinds(f).contains('toolCalls')),
      );
      answer.complete();
      await until(() => ended('chat-window', accepted.assistantMessageId));
      final seen = frames('chat-window');
      for (final frame in seen) {
        expect(frame.chatId, accepted.chatId);
        expect(frame.messageId, accepted.assistantMessageId);
      }

      // Every frame is the answer so far, however many frames there were:
      // the start of reasoning, tool call, text, in that order, and never
      // fewer blocks than the frame before.
      final trail = seen.map(kinds).join('\n');
      const order = <String>['reasoning', 'toolCalls', 'text'];
      var grown = 0;
      for (final frame in seen) {
        final names = [for (final block in frame.blocks) block.kind.name];
        expect(names, order.take(names.length).toList(), reason: trail);
        expect(names.length, greaterThanOrEqualTo(grown), reason: trail);
        grown = names.length;
      }

      // The answer grew in order: thinking first, then the tool, then text,
      // each in frames of its own.
      int firstWith(bool Function(TurnBlocks frame) test) =>
          seen.indexWhere(test);
      final thinking = firstWith(thinkingFrame);
      final calling = firstWith((f) => kinds(f).contains('toolCalls'));
      final answering = firstWith((f) => kinds(f).contains('text'));
      expect(thinking, isNonNegative, reason: trail);
      expect(calling, greaterThan(thinking), reason: trail);
      expect(answering, greaterThan(calling), reason: trail);

      // The last frame is the whole answer, sent before the turn's end.
      final last = seen.last;
      expect(kinds(last), 'reasoning toolCalls text');
      final reasoning = last.blocks[0];
      expect(reasoning.done, isTrue);
      expect(reasoning.pending, isFalse);
      // The core writes reasoning as a quote, as Open WebUI does.
      expect(reasoning.body, '> ${ThinkingOpenAi.reasoning}');
      expect(reasoning.title, isNot(ReasoningTitle.thinking));
      final call = last.blocks[1].calls!.single;
      expect(call.name, contains('echo'));
      expect(call.done, isTrue);
      expect(call.arguments, contains('tide'));
      // Prose dollars are escaped for a plain markdown renderer.
      expect(last.blocks[2].markdown, startsWith('The tool says'));
      expect(last.blocks[2].markdown, endsWith(r'costs \$5.'));
      final names = window('chat-window').map((e) => e.event).toList();
      expect(
        names.lastIndexOf(ConduitEvents.turnBlocks),
        lessThan(names.indexOf(ConduitEvents.turnCompleted)),
      );

      // turn.finished went to every window, the bystander included, which
      // heard nothing about the chat itself.
      for (final windowId in <String>['chat-window', 'bystander']) {
        final finished = TurnFinished.fromJson(
          of(windowId, ConduitEvents.turnFinished).single.payload,
        );
        expect(finished.chatId, accepted.chatId);
        expect(finished.messageId, accepted.assistantMessageId);
        expect(finished.ok, isTrue);
        expect(finished.code, isNull);
      }
      expect(window('bystander').where((e) => e.scope != null), isEmpty);

      // A window that adds the chat after it finished is sent its final
      // blocks and its end.
      open('late-window');
      subscribeWindow(events, turns, 'late-window', <String>[accepted.chatId]);
      expect(window('late-window').map((e) => e.event), <String>[
        ConduitEvents.turnBlocks,
        ConduitEvents.turnCompleted,
      ]);
      expect(frames('late-window').single, last);
    },
  );

  test('chats.get carries each answer\'s blocks, parsed once', () async {
    open('chat-window');
    final accepted = await turns.send(
      SendTurn(model: model, text: 'And low water?', toolIds: [toolId]),
    );
    subscribeWindow(events, turns, 'chat-window', <String>[accepted.chatId]);
    await until(() => ended('chat-window', accepted.assistantMessageId));
    await until(() => turns.activeChatIds.isEmpty);

    final missesBefore = chats.blocks.misses;
    final detail = (await chats.get(accepted.chatId))!;
    final question = detail.messages.firstWhere((m) => m.role == 'user');
    final answer = detail.messages.firstWhere(
      (m) => m.id == accepted.assistantMessageId,
    );
    expect(question.blocks, isEmpty);
    // The blocks follow the stored copy, which keeps a direct answer's
    // reasoning beside its tool call and text (fix/direct-reasoning-persist),
    // so reopening shows what the live turn ended on.
    expect(answer.blocks.map((b) => b.kind), <MessageBlockKind>[
      MessageBlockKind.reasoning,
      MessageBlockKind.toolCalls,
      MessageBlockKind.text,
    ]);
    expect(
      answer.blocks.map((b) => b.kind),
      frames('chat-window').last.blocks.map((b) => b.kind),
    );
    expect(answer.blocks.last, frames('chat-window').last.blocks.last);
    expect(chats.blocks.misses, greaterThan(missesBefore));

    // Opening it again parses nothing.
    final hitsBefore = chats.blocks.hits;
    final missesAfterFirst = chats.blocks.misses;
    final again = (await chats.get(accepted.chatId))!;
    expect(chats.blocks.misses, missesAfterFirst);
    expect(chats.blocks.hits, greaterThan(hitsBefore));
    expect(
      again.messages
          .firstWhere((m) => m.id == accepted.assistantMessageId)
          .blocks,
      answer.blocks,
    );
  });

  test('a failed turn tells every window, with its code', () async {
    open('chat-window');
    open('bystander');
    subscribeWindow(events, turns, 'bystander', const <String>[]);
    final accepted = await turns.send(SendTurn(model: model, text: 'fail'));
    subscribeWindow(events, turns, 'chat-window', <String>[accepted.chatId]);
    await until(() => of('bystander', ConduitEvents.turnFinished).isNotEmpty);
    final finished = TurnFinished.fromJson(
      of('bystander', ConduitEvents.turnFinished).single.payload,
    );
    expect(finished.chatId, accepted.chatId);
    expect(finished.messageId, accepted.assistantMessageId);
    expect(finished.ok, isFalse);
    expect(finished.code, ConduitErrorCodes.serverError);
    expect(window('bystander').where((e) => e.scope != null), isEmpty);
    // The chat's own window hears why, and the final blocks first: the
    // error banner.
    await until(() => ended('chat-window', accepted.assistantMessageId));
    expect(of('chat-window', ConduitEvents.turnFailed), hasLength(1));
    final last = frames('chat-window').last;
    expect(last.blocks.last.kind, MessageBlockKind.error);
    expect(last.blocks.last.error, contains('scripted refusal'));
  });
}
