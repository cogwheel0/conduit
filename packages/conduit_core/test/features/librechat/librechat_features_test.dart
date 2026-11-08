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
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
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

    test('dates fill in LibreChat\'s digits whatever the app\'s language',
        () async {
      await initializeDateFormatting('fa');
      final appLocale = Intl.defaultLocale;
      Intl.defaultLocale = 'fa';
      addTearDown(() => Intl.defaultLocale = appLocale);
      final filled = fillLibreChatPrompt(
        '{{current_date}} / {{current_datetime}}',
        now: DateTime(2026, 10, 18, 9, 30, 5),
      );
      check(filled).startsWith('2026-10-18 (Sunday) / 2026-10-18 09:30:05 ');
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
      // Nothing in the name to make a command of: the id is used.
      check(
        libreChatPromptFromGroup({
          '_id': '65f0c0ffee',
          'name': '日本語',
          'productionPrompt': {'prompt': 'x'},
        })!.command,
      ).equals('/65f0c0ffee');
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
        approval.resumeWithDecisions(decisions: const {}, turn: turn),
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

    test('a single question with no answer is not resumed blank', () {
      final single = LibreChatPendingAction({
        'actionId': 'a',
        'payload': {
          'type': 'ask_user_question',
          'question': {'question': 'Which city?'},
          'tool_call_id': 'call_q',
        },
      });
      check(
        () => single.resumeWithAnswers(answers: const {}, turn: turn),
      ).throws<ArgumentError>();
    });

    test('odd field types read as missing, not as a failure', () {
      final action = LibreChatPendingAction({
        'actionId': 7,
        'conversationId': 8,
        'payload': {
          'type': 'tool_approval',
          'action_requests': [
            {'tool_call_id': 'call_1', 'name': 'echo', 'description': 5},
          ],
          'review_configs': [
            {'tool_call_id': 'call_1', 'allowed_decisions': 'approve'},
          ],
        },
      });
      check(action.actionId).isNull();
      check(action.conversationId).isNull();
      final request = action.toolRequests.single;
      check(request.description).isNull();
      check(request.allowed).deepEquals([
        LibreChatToolDecision.approve,
        LibreChatToolDecision.reject,
      ]);
      check(
        action.resumeWithDecisions(decisions: const {}, turn: turn),
      ).not((it) => it.containsKey('actionId'));
    });
  });

  test('memories report their share of the budget', () {
    final memories = LibreChatMemories.fromJson({
      'memories': [
        {'key': 'work', 'value': 'Engineer', 'tokenCount': 3},
        {'key': 'broken'},
        // An agent's own memory: its writes need the agent named.
        {'key': 'work', 'value': 'Agent note', 'agentId': 'agent_1'},
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
        imageSize: (width: 4, height: 3),
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

    test('sends a file name encoded, as the server decodes it', () async {
      fake.on(
        'POST',
        '/api/files',
        (request, match) => FakeLibreChatResponse.json({'file_id': 'f2'}),
      );
      await api.uploadFile(
        bytes: Uint8List.fromList([1, 2, 3]),
        filename: 'budget 50%.pdf',
        mimeType: 'application/pdf',
        fileId: 'f2',
        endpoint: 'Ollama',
      );
      final form = fake.requests.last.data as FormData;
      check(form.files.single.value.filename).equals('budget%2050%25.pdf');
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

    test('a link made without its files is updated without them', () async {
      final patches = <Object?>[];
      fake
        ..on(
          'GET',
          '/api/share/link/c1',
          (request, match) => FakeLibreChatResponse.json({
            'success': true,
            'shareId': 's1',
            'snapshotFiles': false,
          }),
        )
        ..on('PATCH', '/api/share/(.+)', (request, match) {
          patches.add(request.data);
          return FakeLibreChatResponse.json({'shareId': 's2'});
        });
      final link = (await api.sharedLink('c1'))!;
      check(link.shareId).equals('s1');
      check(link.snapshotFiles).equals(false);
      check(
        await api.refreshSharedLink(
          link.shareId,
          snapshotFiles: link.snapshotFiles,
        ),
      ).equals('s2');
      // A link that does not say keeps LibreChat's own reading of that.
      await api.refreshSharedLink('s2', snapshotFiles: null);
      check(patches).deepEquals([
        {'snapshotFiles': false},
        <String, dynamic>{},
      ]);
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

      // LibreChat decodes the name, and refuses one with a bare %.
      await speech.transcribe(
        Uint8List.fromList(utf8.encode('RIFF')),
        fileName: 'memo 50%.wav',
        mimeType: 'audio/wav',
      );
      final named = fake.requests.last.data as FormData;
      check(named.files.single.value.filename).equals('memo%2050%25.wav');
    });

    test('server speech plays the audio type the server names', () async {
      var type = 'audio/ogg; codecs=opus';
      fake
        ..on(
          'GET',
          '/api/files/speech/config/get',
          (request, match) => FakeLibreChatResponse.json({'ttsExternal': true}),
        )
        ..on(
          'POST',
          '/api/files/speech/tts/manual',
          (request, match) =>
              FakeLibreChatResponse(200, body: 'OggS', contentType: type),
        );
      final speech = await LibreChatServerSpeech.forServer(api);
      check((await speech.synthesize('Hi')).mimeType).equals('audio/ogg');
      // Not an audio type: taken as LibreChat's default, MP3.
      type = 'application/octet-stream';
      check((await speech.synthesize('Hi')).mimeType).equals('audio/mpeg');
    });

    test('the memory named preferences is changed by its id', () async {
      final patched = <String>[];
      fake
        ..on(
          'GET',
          '/api/memories',
          (request, match) => FakeLibreChatResponse.json({
            'memories': [
              // An agent's memory of the same name comes first, and is not
              // the one shown.
              {
                '_id': '665f1c2a9b3e4d0012a7c009',
                'key': 'preferences',
                'value': 'Formal tone',
                'agentId': 'agent_writer',
              },
              {
                '_id': '665f1c2a9b3e4d0012a7c001',
                'key': 'preferences',
                'value': 'Tea, no sugar',
              },
              {
                '_id': '665f1c2a9b3e4d0012a7c002',
                'key': 'work',
                'value': 'Engineer',
              },
            ],
          }),
        )
        ..on('PATCH', '/api/memories/(.+)', (request, match) {
          patched.add(match.group(1)!);
          return FakeLibreChatResponse.json({'updated': true});
        });
      await api.updateMemory('preferences', 'Coffee');
      await api.updateMemory('work', 'Designer', newKey: 'job');
      check(patched).deepEquals(['id/665f1c2a9b3e4d0012a7c001', 'work']);
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
