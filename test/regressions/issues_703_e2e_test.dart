// End-to-end regression for issue #703: full-chat saves persisted
// Conduit's display-rendered `<details type="tool_calls">` HTML into
// server-side content.
//
// Unlike the unit-level coverage in issues_703_test.dart, this file drives
// the REAL production pipeline end to end (no mocks of the units under
// test) against a fake Open WebUI server:
//
//   A. Legacy full-chat save (the issue's exact repro):
//      OWUI 0.11 ChatResponse -> parseFullConversationModel (the real read
//      path) -> ApiService.syncConversationMessages (the real legacy
//      serializer) -> the POST /api/v1/chats/{id} body must be clean plain
//      text while the LOCAL display model keeps the rendered wrappers.
//
//   B. Sync-engine save (the primary writer in 4.1.x):
//      fake server blob -> ChatBlobMapper.blobToRows + ChatsDao
//      .upsertServerChat (the real pull persistence) -> a new local
//      assistant row carrying display-form content (as written by the
//      stream-completion echo) -> PushSync.pushUpdateChat (the real push)
//      -> the server stores the plain text; the local row keeps the display
//      form.
import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/conversation_parsing.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/core/sync/chat_locks.dart';
import 'package:conduit/core/sync/clock.dart';
import 'package:conduit/core/sync/id_remapper.dart';
import 'package:conduit/core/sync/push_sync.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_open_webui_server.dart';
import '../support/fake_sync_api_client.dart';

/// Minimal Dio adapter: records the last request, replies with `body`.
class _CapturingAdapter implements HttpClientAdapter {
  _CapturingAdapter(this.body);

  final Map<String, dynamic> body;
  RequestOptions? lastRequest;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelOnError,
  ) async {
    lastRequest = options;
    return ResponseBody(
      Stream.value(Uint8List.fromList(utf8.encode(jsonEncode(body)))),
      200,
      headers: {
        'content-type': ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

ApiService _buildApiService(_CapturingAdapter adapter) {
  final service = ApiService(
    serverConfig: const ServerConfig(
      id: 'test',
      name: 'Test Server',
      url: 'http://localhost:9999',
    ),
    workerManager: WorkerManager(),
  );
  service.dio.httpClientAdapter = adapter;
  service.dio.interceptors.clear();
  return service;
}

class _FakeClock implements SyncClock {
  @override
  int nowEpochSeconds() => 7000;
}

/// A realistic Open WebUI 0.11 `GET /api/v1/chats/{id}` envelope: the
/// assistant turn used a tool call (structured `tool_calls` + a `role: tool`
/// result message), followed by the plain-text answer message.
Map<String, dynamic> _owuiToolChatResponse() {
  final toolCalls = <dynamic>[
    <String, dynamic>{
      'id': 'call_703',
      'function': <String, dynamic>{
        'name': 'mcp_fetch',
        'arguments': '{"url": "https://example.fr/paris"}',
      },
      'done': true,
    },
  ];
  return <String, dynamic>{
    'id': 'chat-703',
    'user_id': 'fake-user',
    'title': 'Tool chat',
    'created_at': 100,
    'updated_at': 150,
    'chat': <String, dynamic>{
      'title': 'Tool chat',
      'models': <String>['llama3'],
      'history': <String, dynamic>{
        'currentId': 'asst-2',
        'messages': <String, dynamic>{
          'user-1': <String, dynamic>{
            'id': 'user-1',
            'parentId': null,
            'childrenIds': <String>['asst-1'],
            'role': 'user',
            'content': 'What is the capital of France?',
            'timestamp': 1000,
            'models': <String>['llama3'],
          },
          'asst-1': <String, dynamic>{
            'id': 'asst-1',
            'parentId': 'user-1',
            'childrenIds': <String>['tool-1'],
            'role': 'assistant',
            'content': '',
            'timestamp': 1001,
            'model': 'llama3',
            'done': true,
            'tool_calls': toolCalls,
          },
          'tool-1': <String, dynamic>{
            'id': 'tool-1',
            'parentId': 'asst-1',
            'childrenIds': <String>['asst-2'],
            'role': 'tool',
            'tool_call_id': 'call_703',
            'content': 'Page body: Paris is the capital of France. (…10KB…) ',
            'timestamp': 1002,
          },
          'asst-2': <String, dynamic>{
            'id': 'asst-2',
            'parentId': 'tool-1',
            'childrenIds': <String>[],
            'role': 'assistant',
            'content': 'The capital of France is Paris.',
            'timestamp': 1003,
            'model': 'llama3',
            'done': true,
          },
        },
      },
      'messages': <dynamic>[],
      'params': <String, dynamic>{},
      'files': <dynamic>[],
    },
  };
}

void main() {
  group('issue 703 e2e - legacy full-chat save', () {
    test(
      'server response -> parse -> save: POST body is clean, display kept',
      () async {
        // 1. The real production read path parses the server response into
        //    the local Conversation model.
        final conversation = parseFullConversationModel(
          _owuiToolChatResponse(),
        );
        final byId = {for (final m in conversation.messages) m.id: m};

        // 2. Local display state keeps the rendered tool-call wrapper
        //    (the feature this issue must NOT remove) and the plain answer.
        check(byId['asst-1']!.content).contains('<details type="tool_calls"');
        check(byId['asst-1']!.content).contains('mcp_fetch');
        check(byId['asst-2']!.content)
            .equals('The capital of France is Paris.');

        // 3. The real legacy serializer pushes the complete chat to
        //    POST /api/v1/chats/{id}.
        final adapter = _CapturingAdapter(<String, dynamic>{});
        final api = _buildApiService(adapter);
        await api.syncConversationMessages(
          'chat-703',
          conversation.messages,
          model: 'llama3',
        );

        final request = adapter.lastRequest!;
        check(request.path).equals('/api/v1/chats/chat-703');

        final chat =
            (request.data as Map<String, dynamic>)['chat']
                as Map<String, dynamic>;
        final linear = chat['messages'] as List;
        final historyMessages =
            (chat['history'] as Map<String, dynamic>)['messages'] as Map;

        // 4. No persisted message content carries rendered markup — in the
        //    linear list or the history map.
        for (final entry in [...linear, ...historyMessages.values]) {
          final content = (entry as Map)['content'];
          if (content is String) {
            check(
              content.contains('<details'),
              because: 'message ${entry['id']} must not carry rendered markup',
            ).isFalse();
          }
        }

        // 5. The tool-call message projects to its plain form (empty — its
        //    structured data is the canonical store) and the answer message
        //    is byte-identical to the server's original.
        check(((historyMessages['asst-1'] as Map)['content'] as String).trim())
            .isEmpty();
        check((historyMessages['asst-2'] as Map)['content'])
            .equals('The capital of France is Paris.');
        check((historyMessages['user-1'] as Map)['content'])
            .equals('What is the capital of France?');
      },
    );
  });

  group('issue 703 e2e - sync-engine pull -> push', () {
    late FakeOpenWebUiServer server;
    late FakeSyncApiClient client;
    late AppDatabase db;
    late ConversationLocks chatLocks;
    late FolderLocks folderLocks;
    late IdRemapper remapper;
    late PushSync push;

    setUp(() {
      server = FakeOpenWebUiServer(nowEpochSeconds: () => 7000);
      client = FakeSyncApiClient(server);
      db = AppDatabase(NativeDatabase.memory());
      chatLocks = ConversationLocks();
      folderLocks = FolderLocks();
      remapper = IdRemapper(db);
      push = PushSync(
        client: client,
        db: db,
        chatLocks: chatLocks,
        folderLocks: folderLocks,
        clock: _FakeClock(),
        remapper: remapper,
      );
    });

    tearDown(() async {
      await remapper.dispose();
      await db.close();
    });

    test('pulled chat + local tool-call turn: server stores plain text, local '
        'row keeps the display form', () async {
      // 1. The server holds a clean chat (OWUI never stores rendered
      //    wrappers; tool data lives in structured output items).
      const plainAnswer = 'The capital of France is Paris.';
      final cleanBlob = <String, dynamic>{
        'title': 'Tool chat',
        'models': <String>['llama3'],
        'history': <String, dynamic>{
          'currentId': 'e2e-asst2',
          'messages': <String, dynamic>{
            'e2e-user1': <String, dynamic>{
              'id': 'e2e-user1',
              'parentId': null,
              'childrenIds': <String>['e2e-asst2'],
              'role': 'user',
              'content': 'What is the capital of France?',
              'timestamp': 1000,
            },
            'e2e-asst2': <String, dynamic>{
              'id': 'e2e-asst2',
              'parentId': 'e2e-user1',
              'childrenIds': <String>[],
              'role': 'assistant',
              'content': plainAnswer,
              'timestamp': 1003,
              'model': 'llama3',
              'output': <dynamic>[
                <String, dynamic>{
                  'type': 'function_call',
                  'name': 'mcp_fetch',
                  'arguments': '{"url": "https://example.fr/paris"}',
                },
              ],
            },
          },
        },
      };
      server.seedChat(
        id: 'srv-e2e',
        blob: cleanBlob,
        createdAt: 100,
        updatedAt: 150,
      );

      // 2. Real pull persistence: blobToRows -> upsertServerChat.
      final rows = ChatBlobMapper.blobToRows(
        chatId: 'srv-e2e',
        blob: cleanBlob,
        title: 'Tool chat',
        createdAt: 100,
        updatedAt: 150,
      );
      await db.chatsDao.upsertServerChat(rows: rows);

      // 3. The app completes a new turn locally. The stream-completion
      //    echo writes the assistant row in DISPLAY form (rendered
      //    semantic <details> wrapper around the tool call + answer).
      const displayContent = '''<details type="tool_calls" done="true" id="call_e2e" name="mcp_fetch" arguments="{&quot;url&quot;: &quot;https://example.fr/paris&quot;}" result="{&quot;type&quot;: &quot;input_text&quot;, &quot;text&quot;: &quot;Paris …&quot;}">
<summary>Tool Executed</summary>
</details>

The capital of France is Paris.''';
      await db
          .into(db.messages)
          .insert(
            MessagesCompanion.insert(
              id: 'e2e-asst3',
              chatId: 'srv-e2e',
              parentId: Value('e2e-user1'),
              role: 'assistant',
              content: displayContent,
              createdAt: 2001,
              orderIndex: 2,
              payload: jsonEncode(<String, dynamic>{
                'id': 'e2e-asst3',
                'parentId': 'e2e-user1',
                'childrenIds': <String>[],
                'role': 'assistant',
                'content': displayContent,
                'timestamp': 2001,
                'model': 'llama3',
              }),
              dirty: const Value(true),
            ),
          );
      await (db.update(db.chats)..where((t) => t.id.equals('srv-e2e'))).write(
        ChatsCompanion(dirty: const Value(true)),
      );

      // 4. The real push reconstructs the full blob and POSTs it.
      await push.pushUpdateChat('srv-e2e');

      // 5. The server stored the PLAIN projection — no message content in
      //    the whole blob carries rendered markup.
      final stored = server.getChatById('srv-e2e')!;
      final storedChat = stored['chat'] as Map;
      final storedMessages =
          ((storedChat['history'] as Map)['messages']) as Map;
      check((storedMessages['e2e-asst3'] as Map)['content'])
          .equals('The capital of France is Paris.');
      check((storedMessages['e2e-asst2'] as Map)['content'])
          .equals(plainAnswer);
      for (final entry in (storedMessages.values).toList()) {
        final content = (entry as Map)['content'];
        if (content is String) {
          check(
            content.contains('<details'),
            because: 'stored ${entry['id']} must not carry rendered markup',
          ).isFalse();
        }
      }

      // 6. Local state is untouched: the row still carries the display
      //    form so the app renders the tool-call card as before.
      final local = (await db.messagesDao.getForChat('srv-e2e'))
          .firstWhere((m) => m.id == 'e2e-asst3');
      check(local.content).equals(displayContent);
      check(local.content).contains('<details type="tool_calls"');
    });
  });
}
