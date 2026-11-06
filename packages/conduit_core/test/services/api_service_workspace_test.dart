import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/features/workspace/models/workspace_common.dart';
import 'package:conduit_core/features/workspace/models/workspace_resources.dart';
import 'package:conduit_core/features/workspace/models/workspace_knowledge.dart';
import 'package:conduit_core/features/mcp_apps/openwebui_mcp_app.dart';

void main() {
  group('knowledge base file limits (Open WebUI 0.13)', () {
    test('an upload is checked with its count and largest size', () async {
      final requests = <RequestOptions>[];
      final adapter = _RecordingAdapter((request) {
        requests.add(request);
        return _json({'status': true});
      });

      await _api(
        adapter,
      ).validateWorkspaceKnowledgeUpload('kb-1', count: 3, largestFileSize: 42);

      check(requests.single.method).equals('POST');
      check(requests.single.path).equals('/api/v1/knowledge/kb-1/files/validate');
      check(requests.single.data as Map).deepEquals({
        'count': 3,
        'file_size': 42,
        'removed_file_ids': <String>[],
      });
    });

    test('a refusal carries the server reason', () async {
      for (final status in [400, 413]) {
        final adapter = _RecordingAdapter(
          (_) => _json({
            'detail': 'Knowledge base file limit exceeded (5 files maximum).',
          }, statusCode: status),
        );

        await check(
          _api(adapter).validateWorkspaceKnowledgeUpload('kb-1', count: 9),
        ).throws<KnowledgeUploadRefused>(
          (it) => it
              .has((e) => e.reason, 'reason')
              .equals('Knowledge base file limit exceeded (5 files maximum).'),
        );
      }
    });

    test('a server without the check is asked once and then left alone', () async {
      var calls = 0;
      final adapter = _RecordingAdapter((_) {
        calls++;
        return _json({'detail': 'Not Found'}, statusCode: 404);
      });
      final api = _api(adapter);

      await api.validateWorkspaceKnowledgeUpload('kb-1', count: 1);
      await api.validateWorkspaceKnowledgeUpload('kb-1', count: 1);

      check(calls).equals(1);
    });

    test('limits are sent only when set, and read back from meta', () {
      const plain = WorkspaceKnowledgeForm(name: 'Docs');
      check(plain.toJson().containsKey('meta')).isFalse();

      const limited = WorkspaceKnowledgeForm(
        name: 'Docs',
        limits: (maxFileCount: 50, maxFileSize: null),
      );
      check(limited.toJson()['meta'] as Map).deepEquals({
        'max_file_count': 50,
        'max_file_size': null,
      });

      final summary = WorkspaceKnowledgeSummary.fromJson({
        'id': 'kb-1',
        'name': 'Docs',
        'user_id': 'u',
        'meta': {'max_file_count': 50, 'max_file_size': 0},
      });
      check(summary.maxFileCount).equals(50);
      check(summary.maxFileSize).isNull();
    });
  });

  group('MCP App requests (Open WebUI 0.13)', () {
    const app = OpenWebUiMcpApp(
      serverId: 'maps',
      toolName: 'show_map',
      binding: 'b',
    );

    test('go to the app RPC with the binding', () async {
      final requests = <RequestOptions>[];
      final adapter = _RecordingAdapter((request) {
        requests.add(request);
        return _json({'html': '<p></p>'});
      });

      final result = await _api(adapter).runMcpAppRequest(
        app,
        method: 'resources/read',
        params: {'uri': 'ui://maps/tile'},
      );

      check(result).deepEquals({'html': '<p></p>'});
      check(
        requests.single.path,
      ).equals('/api/v1/tools/id/server%3Amcp%3Amaps/mcp/app/rpc');
      check(requests.single.data as Map).deepEquals({
        'tool_name': 'show_map',
        'binding': 'b',
        'method': 'resources/read',
        'params': {'uri': 'ui://maps/tile'},
      });
    });

    test("a refusal carries the server's reason", () async {
      final adapter = _RecordingAdapter(
        (_) => _json({
          'detail': 'Invalid app binding. Run the tool again.',
        }, statusCode: 403),
      );

      await check(
        _api(adapter).runMcpAppRequest(app, method: 'ui/resource'),
      ).throws<McpAppRpcException>(
        (it) => it
            .has((e) => e.message, 'message')
            .equals('Invalid app binding. Run the tool again.'),
      );
    });
  });

  test('model list uses exact route and workspace query names', () async {
    final adapter = _RecordingAdapter((request) {
      check(request.method).equals('GET');
      check(request.path).equals('/api/v1/models/list');
      check(request.queryParameters).deepEquals({
        'page': 2,
        'query': 'local',
        'view_option': 'owned',
        'tag': 'work',
        'order_by': 'name',
        'direction': 'asc',
      });
      return _json({
        'items': [
          {'id': 'model-1', 'name': 'Local', 'user_id': 'user-1'},
        ],
        'total': 1,
      });
    });

    final result = await _api(adapter).getWorkspaceModels(
      query: 'local',
      viewOption: 'owned',
      tag: 'work',
      orderBy: 'name',
      direction: 'asc',
      page: 2,
    );

    check(result.items.single.id).equals('model-1');
    check(result.total).equals(1);
  });

  test('model import wraps exported records in the pinned form', () async {
    final adapter = _RecordingAdapter((request) {
      check(request.method).equals('POST');
      check(request.path).equals('/api/v1/models/import');
      check(request.data as Map<String, dynamic>).deepEquals({
        'models': [
          {'id': 'model-1'},
        ],
      });
      return _json(true);
    });

    final imported = await _api(adapter).importWorkspaceModels(const [
      {'id': 'model-1'},
    ]);

    check(imported).isTrue();
  });

  test(
    'prompt create and history use pinned routes and full form body',
    () async {
      final requests = <RequestOptions>[];
      final adapter = _RecordingAdapter((request) {
        requests.add(request);
        if (request.path.endsWith('/create')) {
          return _json({
            'id': 'prompt-1',
            'command': '/hello',
            'name': 'Hello',
            'content': 'Hello {{name}}',
            'user_id': 'user-1',
          });
        }
        return _json([
          {
            'id': 'history-1',
            'prompt_id': 'prompt-1',
            'snapshot': {'content': 'Hello'},
            'user_id': 'user-1',
            'created_at': 1710000000,
          },
        ]);
      });
      final api = _api(adapter);

      await api.createWorkspacePrompt(
        const WorkspacePromptForm(
          command: '/hello',
          name: 'Hello',
          content: 'Hello {{name}}',
          tags: ['greeting'],
          commitMessage: 'Initial version',
        ),
      );
      final history = await api.getWorkspacePromptHistory('prompt-1');

      check(requests[0].method).equals('POST');
      check(requests[0].path).equals('/api/v1/prompts/create');
      check(requests[0].data as Map<String, dynamic>).deepEquals({
        'command': '/hello',
        'name': 'Hello',
        'content': 'Hello {{name}}',
        'data': null,
        'meta': null,
        'tags': ['greeting'],
        'access_grants': <Object?>[],
        'version_id': null,
        'commit_message': 'Initial version',
        'is_production': true,
      });
      check(requests[1].method).equals('GET');
      check(requests[1].path).equals('/api/v1/prompts/id/prompt-1/history');
      check(history.single.id).equals('history-1');
    },
  );

  test('tool create, access update, and valve specs match upstream', () async {
    final requests = <RequestOptions>[];
    final adapter = _RecordingAdapter((request) {
      requests.add(request);
      if (request.path.endsWith('/valves/spec')) {
        return _json({'title': 'Valves', 'type': 'object'});
      }
      return _json({
        'id': 'weather',
        'name': 'Weather',
        'user_id': 'user-1',
        'meta': {'description': 'Forecasts'},
      });
    });
    final api = _api(adapter);

    await api.createWorkspaceTool(
      const WorkspaceToolForm(
        id: 'weather',
        name: 'Weather',
        content: 'class Tools: pass',
        meta: {'description': 'Forecasts'},
      ),
    );
    await api.updateWorkspaceToolAccess('weather', const [
      WorkspaceAccessGrantInput(
        principalType: WorkspacePrincipalType.group,
        principalId: 'group-1',
        permission: WorkspaceGrantPermission.write,
      ),
    ]);
    final spec = await api.getToolValvesSpec('weather');

    check(requests[0].method).equals('POST');
    check(requests[0].path).equals('/api/v1/tools/create');
    check(requests[0].data as Map<String, dynamic>).deepEquals({
      'id': 'weather',
      'name': 'Weather',
      'content': 'class Tools: pass',
      'meta': {'description': 'Forecasts'},
      'access_grants': <Object?>[],
    });
    check(requests[1].method).equals('POST');
    check(requests[1].path).equals('/api/v1/tools/id/weather/access/update');
    check(requests[1].data as Map<String, dynamic>).deepEquals({
      'access_grants': [
        {
          'principal_type': 'group',
          'principal_id': 'group-1',
          'permission': 'write',
        },
      ],
    });
    check(requests[2].method).equals('GET');
    check(requests[2].path).equals('/api/v1/tools/id/weather/valves/spec');
    check(spec?.schema['title']).equals('Valves');
  });

  test(
    'knowledge files, pending, directories, and sync send exact contracts',
    () async {
      final requests = <RequestOptions>[];
      final adapter = _RecordingAdapter((request) {
        requests.add(request);
        if (request.path.endsWith('/files')) {
          return _json({
            'items': [
              {'id': 'file-1', 'filename': 'a.txt'},
            ],
            'directories': <Object?>[],
            'breadcrumbs': <Object?>[],
            'total': 1,
          });
        }
        if (request.path.endsWith('/files/pending')) return _json(<Object?>[]);
        if (request.path.endsWith('/dirs/create')) {
          return _json({
            'id': 'dir-1',
            'knowledge_id': 'kb-1',
            'name': 'Docs',
            'user_id': 'user-1',
          });
        }
        return _json({
          'added': <Object?>[],
          'modified': <Object?>[],
          'deleted': <Object?>[],
          'mkdir': <Object?>[],
          'rmdir': <Object?>[],
          'unmodified_count': 1,
          'directory_map': <String, Object?>{},
        });
      });
      final api = _api(adapter);

      final files = await api.getWorkspaceKnowledgeFiles(
        'kb-1',
        directoryId: '',
        includeContent: true,
        page: 3,
      );
      await api.getWorkspaceKnowledgePendingFiles('kb-1');
      await api.createWorkspaceKnowledgeDirectory(
        'kb-1',
        name: 'Docs',
        parentId: 'root',
      );
      final diff = await api.diffWorkspaceKnowledge('kb-1', const [
        {'filename': 'a.txt', 'path': 'Docs', 'checksum': 'abc'},
      ]);

      check(files.items.single.id).equals('file-1');
      check(requests[0].method).equals('GET');
      check(requests[0].path).equals('/api/v1/knowledge/kb-1/files');
      check(requests[0].queryParameters)
          .deepEquals({'page': 3, 'include_content': true, 'directory_id': ''});
      check(requests[1].method).equals('GET');
      check(requests[1].path).equals('/api/v1/knowledge/kb-1/files/pending');
      check(requests[1].queryParameters).deepEquals({'stream': false});
      check(requests[2].method).equals('POST');
      check(requests[2].path).equals('/api/v1/knowledge/kb-1/dirs/create');
      check(requests[2].data as Map<String, dynamic>)
          .deepEquals({'name': 'Docs', 'parent_id': 'root'});
      check(requests[3].method).equals('POST');
      check(requests[3].path).equals('/api/v1/knowledge/kb-1/sync/diff');
      check(requests[3].data as Map<String, dynamic>).deepEquals({
        'manifest': [
          {'filename': 'a.txt', 'path': 'Docs', 'checksum': 'abc'},
        ],
      });
      check(diff.raw['unmodified_count']).equals(1);
    },
  );

  test('skill access errors remain Dio errors with server status', () async {
    final adapter = _RecordingAdapter((request) {
      check(request.method).equals('POST');
      check(request.path).equals('/api/v1/skills/id/skill-1/access/update');
      check(request.data as Map<String, dynamic>)
          .deepEquals({'access_grants': <Object?>[]});
      return _json({'detail': 'Access prohibited'}, statusCode: 403);
    });

    try {
      await _api(adapter).updateWorkspaceSkillAccess('skill-1', const []);
      fail('Expected a DioException');
    } on DioException catch (error) {
      check(error.response?.statusCode).equals(403);
    }
  });
}

ApiService _api(HttpClientAdapter adapter) {
  final service = ApiService(
    serverConfig: const ServerConfig(
      id: 'test',
      name: 'Test',
      url: 'http://localhost:0',
    ),
    workerManager: WorkerManager(),
  );
  service.dio.httpClientAdapter = adapter;
  service.dio.interceptors.clear();
  return service;
}

class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.handler);

  final ResponseBody Function(RequestOptions request) handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => handler(options);

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object? value, {int statusCode = 200}) => ResponseBody(
  Stream.value(Uint8List.fromList(utf8.encode(jsonEncode(value)))),
  statusCode,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);
