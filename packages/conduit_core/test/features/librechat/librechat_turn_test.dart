import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/librechat/models/librechat_model.dart';
import 'package:conduit_core/features/librechat/models/librechat_server.dart';
import 'package:conduit_core/features/librechat/services/librechat_auth_service.dart';
import 'package:conduit_core/features/librechat/services/librechat_http_client.dart';
import 'package:conduit_core/features/librechat/services/librechat_session_handle.dart';
import 'package:conduit_core/features/librechat/services/librechat_session_store.dart';
import 'package:conduit_core/features/librechat/services/librechat_stream_client.dart';
import 'package:conduit_core/features/librechat/services/librechat_turn_runner.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/testing.dart';
import 'package:test/test.dart';

String _fixture(String name) => File(
  'test/features/librechat/fixtures/streams/$name',
).readAsStringSync();

FakeLibreChatResponse _sse(String text) => FakeLibreChatResponse(
  200,
  contentType: 'text/event-stream',
  stream: Stream<Uint8List>.value(Uint8List.fromList(utf8.encode(text))),
);

void main() {
  group('catalog', () {
    final endpoints = <String, dynamic>{
      'agents': {'order': 0, 'capabilities': <String>[]},
      'openAI': {'order': 2, 'modelDisplayLabel': 'OpenAI'},
      'Ollama': {'order': 1, 'type': 'custom', 'modelDisplayLabel': 'Ollama'},
      'assistants': {'order': 3},
      'google': null,
    };
    final models = {
      'openAI': ['gpt-5'],
      'Ollama': ['llama3.2', 'qwen3'],
      'assistants': ['gpt-4o'],
    };
    final agents = [
      {'id': 'agent_1', 'name': 'Researcher', 'model': 'gpt-5'},
    ];
    final specs = {
      'list': [
        {
          'name': 'fast',
          'label': 'Fast chat',
          'preset': {'endpoint': 'Ollama', 'model': 'qwen3', 'temperature': 0.2},
        },
      ],
    };

    test('specs, then agents, then endpoints in server order', () {
      final catalog = libreChatCatalog(
        startupConfig: {'modelSpecs': specs},
        endpoints: endpoints,
        models: models,
        agents: agents,
      );
      check(catalog.map((model) => model.name)).deepEquals([
        'Fast chat',
        'Researcher',
        'llama3.2',
        'qwen3',
        'gpt-5',
      ]);
      check(catalog.every(isLibreChatModel)).isTrue();

      final spec = libreChatTargetOf(catalog.first)!;
      check(spec.kind).equals(LibreChatTargetKind.spec);
      check(spec.endpoint).equals('Ollama');
      check(spec.endpointType).equals('custom');
      check(spec.preset['temperature']).equals(0.2);

      final agent = libreChatTargetOf(catalog[1])!;
      check(agent.endpoint).equals('agents');
      check(agent.agentId).equals('agent_1');

      final ollama = libreChatTargetOf(catalog[2])!;
      check(ollama.section).equals('Ollama');
      check(ollama.endpointType).equals('custom');
      check(libreChatTargetOf(catalog.last)!.endpointType).isNull();
    });

    test('an odd field leaves its entry without it', () {
      final catalog = libreChatCatalog(
        startupConfig: {
          'modelSpecs': {
            'list': [
              {
                'name': 'fast',
                'label': 'Fast chat',
                'iconURL': 7,
                'preset': {
                  'endpoint': 'Ollama',
                  'model': 'qwen3',
                  'agent_id': 3,
                },
              },
            ],
          },
        },
        endpoints: endpoints,
        models: models,
        agents: [
          {
            'id': 'agent_1',
            'name': 'Researcher',
            'model': 5,
            'avatar': {'filepath': 9},
          },
        ],
      );
      final names = catalog.map((model) => model.name);
      check(names).contains('Fast chat');
      check(names).contains('Researcher');
      check(libreChatTargetOf(catalog.first)!.agentId).isNull();
    });

    test('specs that could not send are left out', () {
      final catalog = libreChatCatalog(
        startupConfig: {
          'modelSpecs': {
            'list': [
              {
                'name': 'helper',
                'preset': {'endpoint': 'assistants', 'model': 'gpt-4o'},
              },
              {
                'name': 'azure-helper',
                'preset': {'endpoint': 'azureAssistants', 'model': 'gpt-4o'},
              },
              {
                'name': 'no-agent',
                'preset': {'endpoint': 'agents'},
              },
              {
                'name': 'researcher',
                'preset': {'endpoint': 'agents', 'agent_id': 'agent_1'},
              },
            ],
          },
        },
        endpoints: endpoints,
        models: const {},
      );
      check(catalog.map((model) => model.name)).deepEquals(['researcher']);
      check(libreChatTargetOf(catalog.single)!.agentId).equals('agent_1');
    });

    test('enforced specs offer only specs', () {
      final catalog = libreChatCatalog(
        startupConfig: {
          'modelSpecs': {...specs, 'enforce': true},
        },
        endpoints: endpoints,
        models: models,
        agents: agents,
      );
      check(catalog.map((model) => model.name)).deepEquals(['Fast chat']);
    });

    test('enforced specs that cannot send leave nothing to pick', () {
      final catalog = libreChatCatalog(
        startupConfig: {
          'modelSpecs': {
            'enforce': true,
            'list': [
              {
                'name': 'helper',
                'label': 'Helper',
                'preset': {'endpoint': 'assistants', 'model': 'gpt-4o'},
              },
            ],
          },
        },
        endpoints: endpoints,
        models: models,
        agents: agents,
      );
      check(catalog).isEmpty();
    });

    test('a hidden model menu keeps specs and agents', () {
      final catalog = libreChatCatalog(
        startupConfig: {
          'modelSpecs': specs,
          'interface': {'modelSelect': false},
        },
        endpoints: endpoints,
        models: models,
        agents: agents,
      );
      check(catalog).length.equals(2);
    });

    test('ids are stable; only minted models route', () {
      final first = libreChatCatalog(
        startupConfig: const {},
        endpoints: endpoints,
        models: models,
      );
      final second = libreChatCatalog(
        startupConfig: const {},
        endpoints: endpoints,
        models: models,
      );
      check(
        first.map((model) => model.id),
      ).deepEquals(second.map((model) => model.id).toList());
      // A copy, or the same thing from JSON, carries no route.
      final copy = Model.fromJson(first.first.toJson());
      check(isLibreChatModel(copy)).isFalse();
      check(hasReservedLibreChatIdentity(copy)).isTrue();
      check(sanitizeRemoteLibreChatModels([copy, ...first])).isEmpty();
    });
  });

  group('turn runner', () {
    const server = LibreChatServer(baseUrl: 'https://chat.example.com');
    const request = LibreChatTurnRequest(
      text: 'Weather in Paris?',
      endpoint: 'agents',
      agentId: 'agent_weather',
      clientRequestId: 'turn-1',
    );
    late FakeLibreChatServer fake;
    late LibreChatTurnRunner runner;
    final sleeps = <Duration>[];

    setUp(() async {
      sleeps.clear();
      fake = FakeLibreChatServer()..addUser();
      final auth = LibreChatAuthService(server, adapter: fake);
      addTearDown(auth.close);
      final signedIn =
          await auth.signIn(email: 'dev@example.com', password: 'devpassword')
              as LibreChatSignedIn;
      final client = LibreChatHttpClient(
        server: server,
        adapter: fake,
        session: LibreChatSessionHandle(
          session: signedIn.session,
          store: InMemoryLibreChatSessionStore(),
          renew: auth.renew,
        ),
      );
      addTearDown(client.close);
      runner = LibreChatTurnRunner(
        LibreChatStreamClient(client),
        maxReconnects: 2,
        sleep: (delay) async => sleeps.add(delay),
      );
      fake.on(
        'POST',
        '/api/agents/chat/agents',
        (request, match) => FakeLibreChatResponse.json({
          'streamId': 'c1',
          'conversationId': 'c1',
          'generationCreatedAt': 7,
          'status': 'started',
        }),
      );
    });

    test('a turn streams progress and ends with the saved reply', () async {
      fake.on(
        'GET',
        '/api/agents/chat/stream/c1',
        (request, match) => _sse(_fixture('fresh_tool_reply.sse')),
      );
      final updates = await runner.run(request).toList();
      check(updates.first).isA<LibreChatTurnStarted>();
      check(updates[1]).isA<LibreChatTurnCreated>();
      check(updates.whereType<LibreChatTurnTitled>().single.title).equals(
        'Paris weather',
      );
      final finished = updates.last as LibreChatTurnFinished;
      check(finished.frame).isNotNull();
      check(finished.aborted).isFalse();
      final last = updates.whereType<LibreChatTurnProgress>().last;
      check(last.responseMessageId).equals('r1');
      check(last.parts).length.equals(3);
    });

    test('a dropped stream resumes from the snapshot', () async {
      var subscriptions = 0;
      final fresh = _fixture('fresh_tool_reply.sse');
      final dropped = fresh.substring(0, fresh.indexOf('"on_run_step_delta"'));
      fake.on('GET', '/api/agents/chat/stream/c1', (request, match) {
        subscriptions++;
        if (subscriptions == 1) {
          // Cut mid-frame, as a dropped connection leaves it.
          return _sse(dropped);
        }
        check(request.uri.queryParameters['resume']).equals('true');
        return _sse(_fixture('resume_mid_text.sse'));
      });
      final updates = await runner.run(request).toList();
      check(subscriptions).equals(2);
      check(sleeps).length.equals(1);
      final last = updates.whereType<LibreChatTurnProgress>().last;
      check(last.parts.single['text']).equals('One, two, three, four.');
      check(updates.last).isA<LibreChatTurnFinished>();
    });

    test('a stream that keeps dropping ends in a fetch', () async {
      fake.on(
        'GET',
        '/api/agents/chat/stream/c1',
        (request, match) => _sse(''),
      );
      final updates = await runner.run(request).toList();
      check(sleeps).length.equals(2);
      check(updates.last).isA<LibreChatTurnFinished>().has(
        (it) => it.frame,
        'frame',
      ).isNull();
    });

    test('a refusal to follow the turn fails it at once', () async {
      var subscriptions = 0;
      fake.on('GET', '/api/agents/chat/stream/c1', (request, match) {
        subscriptions++;
        return FakeLibreChatResponse.json({
          'message': 'Your account is suspended.',
        }, statusCode: 403);
      });
      final updates = await runner.run(request).toList();
      check(subscriptions).equals(1);
      check(sleeps).isEmpty();
      check(updates.last).isA<LibreChatTurnFailed>().has(
        (it) => it.message,
        'message',
      ).equals('Your account is suspended.');
    });

    test('a server error while following is retried', () async {
      var subscriptions = 0;
      fake.on('GET', '/api/agents/chat/stream/c1', (request, match) {
        if (++subscriptions < 3) {
          return FakeLibreChatResponse.json({
            'message': 'Busy',
          }, statusCode: 503);
        }
        return _sse(_fixture('fresh_tool_reply.sse'));
      });
      final updates = await runner.run(request).toList();
      check(subscriptions).equals(3);
      check(updates.last).isA<LibreChatTurnFinished>().has(
        (it) => it.frame,
        'frame',
      ).isNotNull();
    });

    test('resume snapshots alone do not keep a dropping stream alive', () async {
      // Every reconnect gets the same snapshot, and then the stream ends.
      final resume = _fixture('resume_mid_text.sse');
      final snapshotOnly = resume.substring(
        0,
        resume.indexOf('event: message', 1),
      );
      fake.on(
        'GET',
        '/api/agents/chat/stream/c1',
        (request, match) => _sse(snapshotOnly),
      );
      final updates = await runner.run(request).toList();
      check(sleeps).length.equals(2);
      check(updates.last).isA<LibreChatTurnFinished>().has(
        (it) => it.frame,
        'frame',
      ).isNull();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('a body that breaks off mid-stream resumes', () async {
      var subscriptions = 0;
      fake.on('GET', '/api/agents/chat/stream/c1', (request, match) {
        subscriptions++;
        if (subscriptions == 1) {
          return FakeLibreChatResponse(
            200,
            contentType: 'text/event-stream',
            stream: Stream<Uint8List>.multi((controller) {
              controller
                ..add(Uint8List.fromList(utf8.encode(
                  _fixture('fresh_tool_reply.sse').substring(0, 400),
                )))
                ..addError(const SocketException('Connection reset'))
                ..close();
            }),
          );
        }
        return _sse(_fixture('resume_mid_text.sse'));
      });
      final updates = await runner.run(request).toList();
      check(subscriptions).equals(2);
      check(updates.last).isA<LibreChatTurnFinished>().has(
        (it) => it.frame,
        'frame',
      ).isNotNull();
    });

    test('a settled duplicate ends at once in a fetch', () async {
      fake.on(
        'POST',
        '/api/agents/chat/agents',
        (request, match) => FakeLibreChatResponse.json({
          'streamId': 'c1',
          'conversationId': 'c1',
          'status': 'settled',
        }),
      );
      final updates = await runner.run(request).toList();
      check(updates).length.equals(2);
      check(updates.last).isA<LibreChatTurnFinished>();
      check(
        fake.requests.where((r) => r.path.contains('/chat/stream/')),
      ).isEmpty();
    });

    test('a failure and a pause are reported', () async {
      fake.on(
        'GET',
        '/api/agents/chat/stream/c1',
        (request, match) => _sse(_fixture('failed.sse')),
      );
      final failed = await runner.run(request).toList();
      check(failed.last).isA<LibreChatTurnFailed>().has(
        (it) => it.message,
        'message',
      ).equals('The model is not available.');

      fake.on(
        'GET',
        '/api/agents/chat/stream/c1',
        (request, match) => _sse(_fixture('pending_action.sse')),
      );
      final paused = <LibreChatTurnUpdate>[];
      await for (final update in runner.run(request)) {
        paused.add(update);
        if (update is LibreChatTurnPaused) break;
      }
      check(
        (paused.last as LibreChatTurnPaused).action['actionId'],
      ).equals('act_1');
    });
  });
}
