import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/librechat/models/librechat_prompts.dart';
import 'package:conduit_core/features/librechat/models/librechat_server.dart';
import 'package:conduit_core/features/librechat/models/librechat_tools.dart';
import 'package:conduit_core/features/librechat/services/librechat_api_service.dart';
import 'package:conduit_core/features/librechat/services/librechat_auth_service.dart';
import 'package:conduit_core/features/librechat/services/librechat_http_client.dart';
import 'package:conduit_core/features/librechat/services/librechat_server_speech.dart';
import 'package:conduit_core/features/librechat/services/librechat_session_handle.dart';
import 'package:conduit_core/features/librechat/services/librechat_session_store.dart';
import 'package:conduit_core/features/librechat/services/librechat_stream_client.dart';
import 'package:conduit_core/testing.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  group('prompts', () {
    test('LibreChat\'s variable grammar, not Open WebUI\'s', () {
      final variables = libreChatPromptVariables(
        'Write to {{name}} in a {{tone:formal|casual| friendly }} tone. '
        '{{name}} again, {{current_date}}, {{ CURRENT_USER }}, {{ratio:1:2}}.',
      );
      check(variables).deepEquals([
        const LibreChatPromptVariable(token: 'name', name: 'name'),
        const LibreChatPromptVariable(
          token: 'tone:formal|casual| friendly ',
          name: 'tone',
          options: ['formal', 'casual', 'friendly'],
        ),
        // A colon without choices is just a name, as LibreChat reads it.
        const LibreChatPromptVariable(token: 'ratio:1:2', name: 'ratio:1:2'),
      ]);
    });

    test('fills blanks and the special variables', () {
      final now = DateTime(2026, 10, 18, 9, 30);
      final filled = fillLibreChatPrompt(
        'Hi {{name}} ({{tone:a|b}}), today is {{ current_date }}; '
        '{{current_user}} wrote this. {{unfilled}}',
        values: {'name': 'Ada', 'tone:a|b': 'b'},
        now: now,
        userName: 'Dev',
      );
      check(filled).equals(
        'Hi Ada (b), today is 2026-10-18 (Sunday); Dev wrote this. '
        '{{unfilled}}',
      );
    });

    test('a group becomes a slash command', () {
      final prompt = libreChatPromptFromGroup({
        '_id': 'g1',
        'name': 'Email Reply',
        'command': 'reply',
        'category': 'work',
        'productionPrompt': {'prompt': 'Reply to {{sender}}'},
      })!;
      check(prompt.command).equals('/reply');
      check(prompt.content).equals('Reply to {{sender}}');
      check(isLibreChatPrompt(prompt)).isTrue();
      check(
        libreChatPromptFromGroup({
          '_id': 'g2',
          'name': 'Bug Report!',
          'productionPrompt': {'prompt': 'x'},
        })!.command,
      ).equals('/bug-report');
      check(
        libreChatPromptFromGroup({'_id': 'g3', 'name': 'Empty'}),
      ).isNull();
    });
  });

  group('tools', () {
    test('only endpoint turns carry an ephemeral agent', () {
      check(const LibreChatToolSelection().toEphemeralAgent()).isNull();
      check(
        const LibreChatToolSelection(
          webSearch: true,
          mcpServers: ['everything'],
        ).toEphemeralAgent(),
      ).isNotNull().deepEquals({
        'web_search': true,
        'execute_code': false,
        'file_search': false,
        'mcp': ['everything'],
      });
    });

    final approval = LibreChatPendingAction({
      'actionId': 'act_1',
      'conversationId': 'c3',
      'createdAt': 1792322400000,
      'payload': {
        'type': 'tool_approval',
        'action_requests': [
          {
            'name': 'echo_mcp_everything',
            'arguments': {'message': 'hi'},
            'tool_call_id': 'call_echo',
          },
        ],
        'review_configs': [
          {
            'tool_call_id': 'call_echo',
            'allowed_decisions': ['approve', 'reject', 'bogus'],
          },
        ],
      },
    });
    const turn = {
      'text': 'Echo hi',
      'endpoint': 'Ollama',
      'endpointType': 'custom',
      'model': 'llama3.2',
      'ephemeralAgent': {'mcp': ['everything']},
      'clientRequestId': 'turn-1',
      'conversationId': 'c3',
    };

    test('reads tool approvals and their allowed decisions', () {
      check(approval.isToolApproval).isTrue();
      final request = approval.toolRequests.single;
      check(request.name).equals('echo_mcp_everything');
      check(request.allowed).deepEquals([
        LibreChatToolDecision.approve,
        LibreChatToolDecision.reject,
      ]);
    });

    test('resumes with the paused turn\'s own settings', () {
      final body = approval.resumeWithDecisions(
        decisions: {
          'call_echo': const LibreChatToolDecisionInput(
            LibreChatToolDecision.edit,
            editedArguments: {'message': 'hello'},
          ),
        },
        turn: turn,
        generationCreatedAt: 1792322300000,
      );
      check(body).deepEquals({
        'endpoint': 'Ollama',
        'endpointType': 'custom',
        'model': 'llama3.2',
        'ephemeralAgent': {'mcp': ['everything']},
        'conversationId': 'c3',
        'decisions': [
          {
            'tool_call_id': 'call_echo',
            'decision': 'edit',
            'editedArguments': {'message': 'hello'},
          },
        ],
        'actionId': 'act_1',
        'generationCreatedAt': 1792322300000,
      });
      // Unknown, it is left out: the action's own time is when it paused,
      // which the server would reject as another run.
      check(
        approval.resumeWithAnswers(answers: const {}, turn: turn),
      ).not((it) => it.containsKey('generationCreatedAt'));
    });

    test('a single question is answered as answer, a batch as answers', () {
      final single = LibreChatPendingAction({
        'actionId': 'a',
        'payload': {
          'type': 'ask_user_question',
          'question': {'question': 'Which city?'},
          'tool_call_id': 'call_q',
        },
      });
      check(single.questions.single['id']).equals('call_q');
      check(
        single.resumeWithAnswers(answers: {'call_q': 'Paris'}, turn: turn),
      ).has((it) => it['answer'], 'answer').equals('Paris');

      final batch = LibreChatPendingAction({
        'actionId': 'b',
        'payload': {
          'type': 'ask_user_question',
          'question': {'question': 'First?'},
          'questions': [
            {'id': 'q1', 'question': 'First?'},
            {'id': 'q2', 'question': 'Second?'},
          ],
        },
      });
      check(
        batch.resumeWithAnswers(answers: {'q1': 'a', 'q2': 'b'}, turn: turn),
      ).has((it) => it['answers'], 'answers').isA<Map<String, String>>();
    });
  });

  test('memories report their share of the budget', () {
    final memories = LibreChatMemories.fromJson({
      'memories': [
        {'key': 'work', 'value': 'Engineer', 'tokenCount': 3},
        {'key': 'broken'},
      ],
      'totalTokens': 500,
      'tokenLimit': 2000,
    });
    check(memories.memories.single.key).equals('work');
    check(memories.usage).equals(0.25);
    check(LibreChatMemories.fromJson(const {}).usage).isNull();
  });

  group('api', () {
    const server = LibreChatServer(baseUrl: 'https://chat.example.com');
    late FakeLibreChatServer fake;
    late LibreChatApiService api;

    setUp(() async {
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
      api = LibreChatApiService(client);
    });

    test('uploads an image with its id, endpoint and size', () async {
      fake.on(
        'POST',
        '/api/files/images',
        (request, match) => FakeLibreChatResponse.json({
          'file_id': 'f1',
          'temp_file_id': 'f1',
          'filepath': '/images/user1/f1.png',
          'type': 'image/png',
          'width': 4,
          'height': 3,
        }),
      );
      final uploaded = await api.uploadFile(
        bytes: Uint8List.fromList([1, 2, 3]),
        filename: 'photo.png',
        mimeType: 'image/png',
        fileId: 'f1',
        endpoint: 'Ollama',
        endpointType: 'custom',
        width: 4,
        height: 3,
      );
      check(uploaded['filepath']).equals('/images/user1/f1.png');
      final form = fake.requests.last.data as FormData;
      final fields = {for (final field in form.fields) field.key: field.value};
      check(fields).deepEquals({
        'file_id': 'f1',
        'endpoint': 'Ollama',
        'endpointType': 'custom',
        'message_file': 'true',
        'width': '4',
        'height': '3',
      });
      check(form.files.single.key).equals('file');
      check(form.files.single.value.filename).equals('photo.png');
      // A file route: the browser User-Agent keeps the account unbanned.
      check(fake.violations).equals(0);
    });

    test('shares, forks and duplicates', () async {
      fake
        ..on(
          'POST',
          '/api/share/c1',
          (request, match) => FakeLibreChatResponse.json({'shareId': 's1'}),
        )
        ..on(
          'POST',
          '/api/convos/fork',
          (request, match) => FakeLibreChatResponse.json({
            'conversation': {'conversationId': 'c2', 'title': 'Fork'},
            'messages': [
              {'messageId': 'm1', 'text': 'hi', 'isCreatedByUser': true},
            ],
          }),
        );
      check(await api.createSharedLink('c1')).equals('s1');
      final fork = await api.fork('c1', messageId: 'm9');
      check(fork.conversation.conversationId).equals('c2');
      check(fork.messages.single.messageId).equals('m1');
      check(fake.requests.last.data as Map).deepEquals({
        'conversationId': 'c1',
        'messageId': 'm9',
        'option': 'directPath',
        'splitAtTarget': false,
        'latestMessageId': 'm9',
      });
    });

    test('server speech uses the audio field and reports its engines', () async {
      fake
        ..on(
          'GET',
          '/api/files/speech/config/get',
          (request, match) => FakeLibreChatResponse.json({
            'sttExternal': true,
            'ttsExternal': false,
          }),
        )
        ..on(
          'POST',
          '/api/files/speech/stt',
          (request, match) => FakeLibreChatResponse.json({'text': 'hello'}),
        );
      final speech = await LibreChatServerSpeech.forServer(api);
      check(speech.canTranscribe).isTrue();
      check(speech.canSynthesize).isFalse();
      final text = await speech.transcribe(
        Uint8List.fromList(utf8.encode('RIFF')),
        fileName: 'clip.wav',
        mimeType: 'audio/wav',
        language: 'en-US',
      );
      check(text).equals('hello');
      final form = fake.requests.last.data as FormData;
      check(form.files.single.key).equals('audio');
      check(form.fields.single.value).equals('en-US');
    });
  });

  test('stream client posts resume bodies with the protocol', () async {
    final fake = FakeLibreChatServer()..addUser();
    const server = LibreChatServer(baseUrl: 'https://chat.example.com');
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
    fake.on(
      'POST',
      '/api/agents/chat/resume',
      (request, match) => FakeLibreChatResponse.json({'status': 'resumed'}),
    );
    await LibreChatStreamClient(client).resumeAfterAction({
      'actionId': 'act_1',
      'answer': 'Paris',
    });
    check(fake.requests.last.data as Map).deepEquals({
      'actionId': 'act_1',
      'answer': 'Paris',
      'generationProtocolVersion': 2,
    });
    check(
      fake.requests.last.header('x-librechat-generation-protocol'),
    ).equals('2');
  });
}
