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

/// A direct turn that calls an MCP tool (M4), end to end over real HTTP: a
/// fake OpenAI-compatible provider asks for the tool, the daemon asks a
/// window for approval, runs the tool on a real MCP server and hands the
/// result back to the provider for the answer.
void main() {
  late Directory temporary;
  late CoreRuntime runtime;
  late McpFixture mcpServer;
  late _FakeProvider provider;
  late EventBus events;
  late UiRequestsService ui;
  late TurnsService turns;
  late String model;
  late String toolId;

  /// What the "window" answers to each approval; null leaves it waiting.
  String? answer = 'allow';
  final asked = <UiRequest>[];
  final completed = <TurnCompleted>[];
  final failed = <TurnFailed>[];

  setUpAll(() async {
    temporary = Directory.systemTemp.createTempSync('direct-mcp-turn-test');
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
    provider = await _FakeProvider.start();

    final direct = DirectService(runtime.container);
    await direct.setHistory(localOnly: true);
    final connections = await direct.save(
      DirectConnectionEdit(
        name: 'Fake',
        kind: DirectKind.openai,
        baseUrl: provider.baseUrl,
        manualModelIds: const <String>['fake-model'],
      ),
    );
    model = DirectModelId.encode(
      connections.connections.single.id,
      'fake-model',
    );
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
    events.attach('window', (envelope) {
      switch (envelope.event) {
        case ConduitEvents.uiRequest:
          final request = UiRequest.fromJson(envelope.payload);
          asked.add(request);
          final choice = answer;
          if (choice != null) {
            ui.respond(
              UiResponse(requestId: request.requestId, choice: choice),
            );
          }
        case ConduitEvents.turnCompleted:
          completed.add(TurnCompleted.fromJson(envelope.payload));
        case ConduitEvents.turnFailed:
          failed.add(TurnFailed.fromJson(envelope.payload));
      }
    });
  });

  tearDownAll(() async {
    await turns.dispose();
    await provider.close();
    await mcpServer.close();
    await runtime.dispose();
    temporary.deleteSync(recursive: true);
  });

  Future<TurnCompleted> answered(SendTurn request) async {
    final before = completed.length + failed.length;
    final accepted = await turns.send(request);
    events.subscribe(
      'window',
      EventSubscription(scopes: <String>[accepted.chatId]),
    );
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (completed.length + failed.length == before &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(failed, isEmpty, reason: failed.map((f) => f.args).join());
    return completed.last;
  }

  test('asks before the tool runs, then answers with its result', () async {
    answer = 'allow';
    final done = await answered(
      SendTurn(model: model, text: 'Echo hi', toolIds: <String>[toolId]),
    );
    expect(asked, hasLength(1));
    expect(asked.single.kind, UiRequestKind.mcpApproval);
    expect(asked.single.messageArgs['serverName'], 'Fixture');
    expect(asked.single.detail['arguments'], contains('"value":"hi"'));
    expect(mcpServer.calls, hasLength(1));
    expect(done.text, contains('echoed: hi'));
  });

  test('"for this session" stops the asking', () async {
    asked.clear();
    answer = 'allowSession';
    await answered(
      SendTurn(model: model, text: 'Echo hi', toolIds: <String>[toolId]),
    );
    await answered(
      SendTurn(model: model, text: 'Echo hi', toolIds: <String>[toolId]),
    );
    expect(asked, hasLength(1));
    expect(mcpServer.calls, hasLength(3));
  });

  test('a denied call never reaches the server', () async {
    // A fresh daemon's worth of session approvals would allow it; this
    // turn goes to a new TurnsService to start without them.
    final fresh = TurnsService(runtime.container, events, uiRequests: ui);
    addTearDown(fresh.dispose);
    asked.clear();
    answer = 'deny';
    final before = completed.length;
    final accepted = await fresh.send(
      SendTurn(model: model, text: 'Echo hi', toolIds: <String>[toolId]),
    );
    events.subscribe(
      'window',
      EventSubscription(scopes: <String>[accepted.chatId]),
    );
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (completed.length == before &&
        failed.isEmpty &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(asked, hasLength(1));
    expect(mcpServer.calls, hasLength(3));
  });

  test('"always" is remembered on the server, and shown there', () async {
    final fresh = TurnsService(runtime.container, events, uiRequests: ui);
    addTearDown(fresh.dispose);
    asked.clear();
    answer = 'allowAlways';
    final accepted = await fresh.send(
      SendTurn(model: model, text: 'Echo hi', toolIds: <String>[toolId]),
    );
    events.subscribe(
      'window',
      EventSubscription(scopes: <String>[accepted.chatId]),
    );
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (mcpServer.calls.length < 4 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(mcpServer.calls, hasLength(4));
    final list = await McpService(runtime.container).list();
    expect(list.servers.single.approvals.map((a) => a.toolName), <String>[
      'echo',
    ]);

    // A new session is not asked.
    final another = TurnsService(runtime.container, events, uiRequests: ui);
    addTearDown(another.dispose);
    asked.clear();
    final again = await another.send(
      SendTurn(model: model, text: 'Echo hi', toolIds: <String>[toolId]),
    );
    events.subscribe(
      'window',
      EventSubscription(scopes: <String>[again.chatId]),
    );
    final until = DateTime.now().add(const Duration(seconds: 30));
    while (mcpServer.calls.length < 5 && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(asked, isEmpty);
    expect(mcpServer.calls, hasLength(5));
  });
}

/// An OpenAI-compatible chat endpoint that calls the first tool it is
/// offered with `{"value": "hi"}`, then answers with what the tool said.
final class _FakeProvider {
  _FakeProvider._(this._server);

  final HttpServer _server;

  String get baseUrl => 'http://127.0.0.1:${_server.port}/v1';

  static Future<_FakeProvider> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final provider = _FakeProvider._(server);
    server.listen(provider._handle);
    return provider;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    if (request.uri.path.endsWith('/models')) {
      await request.drain<void>();
      response.headers.contentType = ContentType.json;
      response.write(
        jsonEncode(<String, dynamic>{
          'data': [
            {'id': 'fake-model', 'object': 'model'},
          ],
        }),
      );
      await response.close();
      return;
    }
    final body =
        jsonDecode(await utf8.decodeStream(request)) as Map<String, dynamic>;
    final messages = (body['messages'] as List).cast<Map<String, dynamic>>();
    final toolResult = messages
        .where((message) => message['role'] == 'tool')
        .lastOrNull;
    response.headers.contentType = ContentType(
      'text',
      'event-stream',
      charset: 'utf-8',
    );
    void chunk(Map<String, dynamic> delta, {String? finish}) => response.write(
      'data: ${jsonEncode(<String, dynamic>{
        'id': 'c',
        'object': 'chat.completion.chunk',
        'choices': [
          {'index': 0, 'delta': delta, 'finish_reason': finish},
        ],
      })}\n\n',
    );
    if (toolResult == null && body['tools'] is List) {
      final tool = ((body['tools'] as List).first as Map)['function'] as Map;
      chunk(<String, dynamic>{
        'role': 'assistant',
        'tool_calls': [
          {
            'index': 0,
            'id': 'call_1',
            'type': 'function',
            'function': {
              'name': tool['name'],
              'arguments': jsonEncode({'value': 'hi'}),
            },
          },
        ],
      }, finish: 'tool_calls');
    } else {
      final said = toolResult == null
          ? 'no tool'
          : 'echoed: ${_text(toolResult['content'])}';
      chunk(<String, dynamic>{'role': 'assistant', 'content': said});
      chunk(<String, dynamic>{}, finish: 'stop');
    }
    response.write('data: [DONE]\n\n');
    await response.close();
  }

  static String _text(Object? content) => switch (content) {
    final String text => text,
    final List<Object?> parts =>
      parts
          .map((part) => part is Map ? '${part['text'] ?? ''}' : '$part')
          .join(),
    _ => '$content',
  };
}
