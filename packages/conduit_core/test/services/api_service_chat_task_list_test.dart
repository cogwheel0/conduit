import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/sync/sync_api_client.dart'
    show SyncTerminalException;
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// A chat's task list (`GET /api/tasks/chat/{id}`) decides whether the chat's
/// stop may be asked: an empty one means no task runs. Only Open WebUI's own
/// answer, `{"task_ids": [...]}`, says so; anything else is no answer.
void main() {
  group('getChatTaskIdsRaw', () {
    for (final (label, body, contentType, tasks)
        in <(String, String, String, List<String>)>[
          ('none running', '{"task_ids": []}', 'application/json', []),
          (
            'one running',
            '{"task_ids": ["task-7"]}',
            'application/json',
            ['task-7'],
          ),
        ]) {
      test('reads $label', () async {
        final api = _api(_TaskListAdapter(body, contentType));
        check(await api.getChatTaskIdsRaw('chat-1')).deepEquals(tasks);
      });
    }

    for (final (label, body, contentType) in <(String, String, String)>[
      ('an empty object', '{}', 'application/json'),
      ('no list', '{"task_ids": null}', 'application/json'),
      ('a string', '{"task_ids": "task-7"}', 'application/json'),
      ('a page', '<html><body>Sign in</body></html>', 'text/html'),
    ]) {
      test('takes $label for no answer, not for no task', () async {
        final api = _api(_TaskListAdapter(body, contentType));
        await check(api.getChatTaskIdsRaw('chat-1')).throws<FormatException>();
      });
    }
  });

  // The same reading, for the task checks of the chat on screen.
  test('getTaskIdsByChat takes an answer with no list for no answer, not for '
      'no task', () async {
    final api = _api(_TaskListAdapter('{}', 'application/json'));
    await check(api.getTaskIdsByChat('chat-1')).throws<FormatException>();
  });

  // As the chat's stop and the other bound chat routes: a refusal of the
  // session still current is final, one of a session replaced meanwhile is
  // not.
  test('getChatTaskIdsRaw: a refusal of the session still current is '
      'final', () async {
    final api = _api(
      _TaskListAdapter(
        '{"detail": "Forbidden"}',
        'application/json',
        status: 403,
      ),
    );
    await check(
      api.getChatTaskIdsRaw('chat-1', authSnapshot: api.captureAuthSnapshot()),
    ).throws<SyncTerminalException>();
  });

  test('getChatTaskIdsRaw: a refusal of a session replaced since is asked '
      'again', () async {
    late final ApiService api;
    final adapter = _TaskListAdapter(
      '{"detail": "Forbidden"}',
      'application/json',
      status: 403,
      // The account signs in again while the check is out.
      onFetch: () => api.updateAuthToken('newer-session'),
    );
    api = _api(adapter);
    await check(
      api.getChatTaskIdsRaw('chat-1', authSnapshot: api.captureAuthSnapshot()),
    ).throws<DioException>();
  });
}

final class _TaskListAdapter implements HttpClientAdapter {
  _TaskListAdapter(
    this.body,
    this.contentType, {
    this.status = 200,
    this.onFetch,
  });

  final String body;
  final String contentType;
  final int status;
  final void Function()? onFetch;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    onFetch?.call();
    return ResponseBody(
      Stream.value(Uint8List.fromList(utf8.encode(body))),
      status,
      headers: {
        'content-type': [contentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

ApiService _api(HttpClientAdapter adapter) {
  final service = ApiService(
    serverConfig: const ServerConfig(
      id: 'test',
      name: 'Test',
      url: 'http://localhost:0',
    ),
    workerManager: WorkerManager(),
    authToken: 'original-session',
  );
  service.dio.httpClientAdapter = adapter;
  service.dio.interceptors.clear();
  return service;
}
