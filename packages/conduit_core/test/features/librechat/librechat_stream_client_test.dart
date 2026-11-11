import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/librechat/models/librechat_server.dart';
import 'package:conduit_core/features/librechat/models/librechat_stream_event.dart';
import 'package:conduit_core/features/librechat/services/librechat_api_service.dart';
import 'package:conduit_core/features/librechat/services/librechat_auth_service.dart';
import 'package:conduit_core/features/librechat/services/librechat_errors.dart';
import 'package:conduit_core/features/librechat/services/librechat_http_client.dart';
import 'package:conduit_core/features/librechat/services/librechat_session_handle.dart';
import 'package:conduit_core/features/librechat/services/librechat_session_store.dart';
import 'package:conduit_core/features/librechat/services/librechat_stream_client.dart';
import 'package:conduit_core/testing.dart';
import 'package:test/test.dart';

/// What [future] failed with, which must be a [T].
Future<T> _thrown<T extends Object>(Future<Object?> future) async {
  try {
    await future;
  } on T catch (error) {
    return error;
  }
  fail('Expected a $T.');
}

String _fixture(String name) => File(
  'test/features/librechat/fixtures/streams/$name',
).readAsStringSync();

/// [text] as a byte stream in small chunks, as the network delivers it.
Stream<Uint8List> _chunked(String text) async* {
  final bytes = utf8.encode(text);
  for (var start = 0; start < bytes.length; start += 50) {
    await Future<void>.delayed(Duration.zero);
    yield Uint8List.fromList(
      bytes.sublist(start, (start + 50).clamp(0, bytes.length)),
    );
  }
}

void main() {
  const server = LibreChatServer(baseUrl: 'https://chat.example.com');
  late FakeLibreChatServer fake;
  late LibreChatHttpClient client;
  late LibreChatStreamClient streams;
  late LibreChatApiService api;

  setUp(() async {
    fake = FakeLibreChatServer()..addUser();
    final auth = LibreChatAuthService(server, adapter: fake);
    addTearDown(auth.close);
    final signedIn =
        await auth.signIn(email: 'dev@example.com', password: 'devpassword')
            as LibreChatSignedIn;
    client = LibreChatHttpClient(
      server: server,
      adapter: fake,
      session: LibreChatSessionHandle(
        session: signedIn.session,
        store: InMemoryLibreChatSessionStore(),
        renew: auth.renew,
      ),
    );
    addTearDown(client.close);
    streams = LibreChatStreamClient(client);
    api = LibreChatApiService(client);
  });

  group('start', () {
    const request = LibreChatTurnRequest(
      text: 'Hi',
      endpoint: 'Ollama',
      endpointType: 'custom',
      model: 'llama3.2',
      clientRequestId: 'conduit:turn-1',
    );

    test('asks for protocol v2 everywhere it is read', () async {
      fake.on(
        'POST',
        '/api/agents/chat/Ollama',
        (request, match) => FakeLibreChatResponse.json({
          'streamId': 'c1',
          'conversationId': 'c1',
          'generationCreatedAt': 1792322400000,
          'status': 'started',
          'generationProtocolVersion': 2,
        }),
      );
      final generation = await streams.start(request);
      check(generation.outcome).equals(LibreChatStartOutcome.started);
      check(generation.isLive).isTrue();
      check(generation.streamId).equals('c1');
      check(generation.createdAt).equals(1792322400000);

      final sent = fake.requests.last;
      check(sent.header('x-librechat-generation-protocol')).equals('2');
      check(sent.uri.queryParameters['generationProtocolVersion']).equals('2');
      final body = sent.data as Map;
      check(body['generationProtocolVersion']).equals(2);
      check(body['parentMessageId']).equals(
        '00000000-0000-0000-0000-000000000000',
      );
      check(body['conversationId']).isNull();
      check(body['clientRequestId']).equals('conduit:turn-1');
      check(
        FakeLibreChatServer.looksLikeBrowser(sent.header('user-agent')),
      ).isTrue();
      check(fake.violations).equals(0);
    });

    test('a duplicate of a finished turn is settled, not live', () async {
      fake.on(
        'POST',
        '/api/agents/chat/Ollama',
        (request, match) => FakeLibreChatResponse.json({
          'streamId': 'c1',
          'conversationId': 'c1',
          'status': 'settled',
        }),
      );
      final generation = await streams.start(request);
      check(generation.outcome).equals(LibreChatStartOutcome.settled);
      check(generation.isLive).isFalse();
    });

    test('a middleware\'s refusal in stream form is final', () async {
      fake.on(
        'POST',
        '/api/agents/chat/Ollama',
        (request, match) =>
            FakeLibreChatResponse.text(_fixture('denied_start.txt')),
      );
      final error = await _thrown<LibreChatTurnRefusedException>(
        streams.start(request),
      );
      check(error.message).contains('too many messages');
    });

    test('a server starting up or an unsaved parent defers', () async {
      fake.on(
        'POST',
        '/api/agents/chat/Ollama',
        (request, match) => FakeLibreChatResponse(
          503,
          body: jsonEncode({'code': 'SERVER_NOT_READY'}),
          headers: {'retry-after': '7'},
        ),
      );
      final notReady = await _thrown<LibreChatTurnDeferredException>(
        streams.start(request),
      );
      check(notReady.retryAfter).equals(const Duration(seconds: 7));

      fake.on(
        'POST',
        '/api/agents/chat/Ollama',
        (request, match) => FakeLibreChatResponse.json({
          'code': 'PARENT_NOT_READY',
          'message': 'The previous message is still being saved.',
        }, statusCode: 409),
      );
      await _thrown<LibreChatTurnDeferredException>(streams.start(request));
    });

    test('a validation error is a refusal', () async {
      fake.on(
        'POST',
        '/api/agents/chat/Ollama',
        (request, match) => FakeLibreChatResponse.json({
          'message': 'Model not allowed',
        }, statusCode: 400),
      );
      await _thrown<LibreChatTurnRefusedException>(streams.start(request));
    });

    test('rejects a request id LibreChat would refuse', () {
      check(
        () => const LibreChatTurnRequest(
          text: 'x',
          endpoint: 'Ollama',
          clientRequestId: 'has spaces',
        ).toJson(),
      ).throws<ArgumentError>();
    });
  });

  group('subscribe', () {
    test('reads the frames of a chunked stream up to the final', () async {
      fake.on(
        'GET',
        '/api/agents/chat/stream/c1',
        (request, match) => FakeLibreChatResponse(
          200,
          contentType: 'text/event-stream',
          stream: _chunked(
            '${_fixture('fresh_tool_reply.sse')}'
            'event: message\ndata: {"event":"after_final"}\n\n',
          ),
        ),
      );
      final events = await streams
          .subscribe('c1', generationCreatedAt: 5)
          .toList();
      check(events.first).isA<LibreChatStreamCreated>();
      check(events.last).isA<LibreChatStreamFinal>();
      check(events.whereType<LibreChatStreamStep>()).length.equals(10);
      final request = fake.requests.last;
      check(request.uri.queryParameters).deepEquals({
        'generationCreatedAt': '5',
        'generationProtocolVersion': '2',
      });
    });

    test('a resume asks for the snapshot', () async {
      fake.on(
        'GET',
        '/api/agents/chat/stream/c2',
        (request, match) => FakeLibreChatResponse(
          200,
          contentType: 'text/event-stream',
          stream: _chunked(_fixture('resume_mid_text.sse')),
        ),
      );
      final events = await streams.subscribe('c2', resume: true).toList();
      check(events.first).isA<LibreChatStreamSync>();
      check(fake.requests.last.uri.queryParameters['resume']).equals('true');
    });

    test('a gone or replaced generation means fetch the result', () async {
      fake.on(
        'GET',
        '/api/agents/chat/stream/gone',
        (request, match) => FakeLibreChatResponse.json({
          'error': 'Stream not found',
        }, statusCode: 404),
      );
      final events = await streams.subscribe('gone').toList();
      check(events.single).isA<LibreChatStreamFinal>().has(
        (it) => it.reconcile,
        'reconcile',
      ).isTrue();
    });

    test('a refusal whose body stalls is still told', () async {
      final body = StreamController<Uint8List>();
      addTearDown(body.close);
      fake.on('GET', '/api/agents/chat/stream/c1', (request, match) {
        // The status and a first piece arrive; the rest never does.
        body.add(Uint8List.fromList(utf8.encode('{"message":"Sus')));
        return FakeLibreChatResponse(403, stream: body.stream);
      });
      final quick = LibreChatStreamClient(
        client,
        errorBodyTimeout: const Duration(milliseconds: 50),
      );
      await check(quick.subscribe('c1').toList()).throws<LibreChatApiException>(
        (it) => it.has((e) => e.statusCode, 'statusCode').equals(403),
      );
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('a stopped stream may simply end', () async {
      fake.on(
        'GET',
        '/api/agents/chat/stream/c3',
        (request, match) => FakeLibreChatResponse(
          200,
          contentType: 'text/event-stream',
          stream: _chunked(_fixture('pending_action.sse')),
        ),
      );
      final events = await streams.subscribe('c3').toList();
      check(events.last).isA<LibreChatStreamPendingAction>();
    });
  });

  test('a stop the server could not save says so', () async {
    fake.on(
      'POST',
      '/api/agents/chat/abort',
      (request, match) => FakeLibreChatResponse.json({
        'success': true,
        'aborted': 'c1',
        'persistenceFailed': true,
      }),
    );
    final error = await _thrown<LibreChatApiException>(
      streams.abort('c1', generationCreatedAt: 9),
    );
    check(error.code).equals('ABORT_PERSISTENCE_FAILED');
  });

  test('an answer a middleware refuses leaves the run paused', () async {
    fake.on(
      'POST',
      '/api/agents/chat/resume',
      (request, match) =>
          FakeLibreChatResponse.text(_fixture('denied_start.txt')),
    );
    final error = await _thrown<LibreChatTurnRefusedException>(
      streams.resumeAfterAction({'conversationId': 'c1', 'actionId': 'a'}),
    );
    check(error.message).contains('too many messages');
  });

  test('abort names the conversation and its generation', () async {
    fake.on(
      'POST',
      '/api/agents/chat/abort',
      (request, match) => FakeLibreChatResponse.json({'success': true}),
    );
    await streams.abort('c1', generationCreatedAt: 9);
    check(fake.requests.last.data as Map).deepEquals({
      'conversationId': 'c1',
      'streamId': 'c1',
      'generationCreatedAt': 9,
      'generationProtocolVersion': 2,
    });
  });

  group('api', () {
    test('pages conversations by cursor', () async {
      fake.on('GET', '/api/convos', (request, match) {
        final cursor = request.uri.queryParameters['cursor'];
        return FakeLibreChatResponse.json({
          'conversations': [
            {'conversationId': cursor == null ? 'c1' : 'c2', 'title': 'T'},
            {'title': 'no id is dropped'},
          ],
          'nextCursor': cursor == null ? 'Y3Vyc29y' : null,
        });
      });
      final first = await api.conversations();
      check(first.conversations.single.conversationId).equals('c1');
      check(first.nextCursor).equals('Y3Vyc29y');
      check(fake.requests.last.uri.queryParameters['limit']).equals('100');
      final second = await api.conversations(cursor: first.nextCursor);
      check(second.conversations.single.conversationId).equals('c2');
      check(second.nextCursor).isNull();
    });

    test('wraps envelope writes in arg, as LibreChat reads them', () async {
      fake
        ..on(
          'POST',
          '/api/convos/pin',
          (request, match) => FakeLibreChatResponse.json({'ok': true}),
        )
        ..on(
          'DELETE',
          '/api/convos',
          (request, match) =>
              FakeLibreChatResponse.json({'error': 'gone'}, statusCode: 404),
        );
      await api.setPinned('c1', true);
      check(fake.requests.last.data as Map).deepEquals({
        'arg': {'conversationId': 'c1', 'pinned': true},
      });
      // Already gone is deleted.
      await api.deleteConversation('c1');
    });

    test('a rename or archive the server failed to save fails', () async {
      for (final (path, write) in [
        ('/api/convos/update', () => api.renameConversation('c1', 'New')),
        ('/api/convos/archive', () => api.setArchived('c1', true)),
      ]) {
        fake.on(
          'POST',
          path,
          (request, match) => FakeLibreChatResponse.json({
            'message': 'Error saving conversation',
          }, statusCode: path.endsWith('update') ? 201 : 200),
        );
        final error = await _thrown<LibreChatApiException>(write());
        check(error.message).equals('Error saving conversation');
      }
      // A saved conversation is not mistaken for one.
      fake.on(
        'POST',
        '/api/convos/update',
        (request, match) => FakeLibreChatResponse.json({
          'conversationId': 'c1',
          'title': 'New',
        }, statusCode: 201),
      );
      await api.renameConversation('c1', 'New');
    });

    test('reads endpoints\' models', () async {
      fake.on(
        'GET',
        '/api/models',
        (request, match) => FakeLibreChatResponse.json({
          'Ollama': ['llama3.2', '', 3],
          'openAI': null,
        }),
      );
      check(await api.models()).deepEquals({
        'Ollama': ['llama3.2'],
      });
    });

    test('reads endpoints LibreChat sends as text', () async {
      // `res.send(JSON.stringify(...))`: JSON, served as text/html.
      fake.on(
        'GET',
        '/api/endpoints',
        (request, match) => FakeLibreChatResponse.text(
          jsonEncode({
            'ollama': {'order': 1, 'type': 'custom'},
          }),
        ),
      );
      check(await api.endpoints()).deepEquals({
        'ollama': {'order': 1, 'type': 'custom'},
      });
    });

    test('a server error reads as what the server said', () async {
      fake.on(
        'GET',
        '/api/messages/c1',
        (request, match) => FakeLibreChatResponse.json({
          'error': 'Internal server error',
        }, statusCode: 500),
      );
      final error = await _thrown<LibreChatApiException>(api.messages('c1'));
      check(error.message).equals('Internal server error');
      check(error.statusCode).equals(500);
    });
  });
}
