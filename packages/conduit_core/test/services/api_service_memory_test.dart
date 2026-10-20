import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/server_memory.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  late _MemoryAdapter adapter;
  late ApiService api;

  setUp(() {
    adapter = _MemoryAdapter();
    api = ApiService(
      serverConfig: const ServerConfig(
        id: 'server',
        name: 'Server',
        url: 'https://server.example',
      ),
      workerManager: WorkerManager(),
      authToken: 'session-a',
    );
    api.dio.httpClientAdapter = adapter;
  });

  tearDown(() => api.dispose());

  group('createMemory', () {
    test('classifies an entered memory as user without a path', () async {
      await api.createMemory(content: 'I prefer metric units');

      final request = adapter.requests.single;
      check(request.method).equals('POST');
      check(request.path).equals('/api/v1/memories/add');
      check(request.data)
          .isA<Map<String, dynamic>>()
          .deepEquals({'content': 'I prefer metric units', 'type': 'user'});
    });

    test('sends an explicit type and a trimmed non-empty path', () async {
      await api.createMemory(
        content: 'Project uses Riverpod',
        type: ServerMemory.contextType,
        path: ' projects/conduit ',
      );

      check(adapter.requests.single.data)
          .isA<Map<String, dynamic>>()
          .deepEquals({
            'content': 'Project uses Riverpod',
            'type': 'context',
            'path': 'projects/conduit',
          });
    });

    test('omits a blank path', () async {
      await api.createMemory(content: 'No path', path: '   ');

      check(adapter.requests.single.data)
          .isA<Map<String, dynamic>>()
          .not((body) => body.containsKey('path'));
    });
  });

  group('updateMemory', () {
    test('content-only edit leaves type and path to the server', () async {
      await api.updateMemory(memoryId: 'm1', content: 'Edited');

      final request = adapter.requests.single;
      check(request.path).equals('/api/v1/memories/m1/update');
      check(request.data)
          .isA<Map<String, dynamic>>()
          .deepEquals({'content': 'Edited'});
    });

    test(
      'sends a changed type and path, and an empty path clears it',
      () async {
        await api.updateMemory(
          memoryId: 'm1',
          content: 'Edited',
          type: ServerMemory.userType,
          path: 'a/b',
        );
        await api.updateMemory(memoryId: 'm1', content: 'Edited', path: '');

        check(adapter.requests[0].data)
            .isA<Map<String, dynamic>>()
            .deepEquals({'content': 'Edited', 'type': 'user', 'path': 'a/b'});
        check(adapter.requests[1].data)
            .isA<Map<String, dynamic>>()
            .deepEquals({'content': 'Edited', 'path': ''});
      },
    );
  });

  group('reading classification', () {
    test(
      'keeps type and path, including a type this client does not know',
      () async {
        adapter.respondWith = [
          {
            'id': 'user-memory',
            'user_id': 'u',
            'content': 'a',
            'type': 'user',
            'path': 'prefs/units',
            'created_at': 1,
            'updated_at': 2,
          },
          {
            'id': 'future-memory',
            'user_id': 'u',
            'content': 'b',
            'type': 'episodic',
            'path': null,
            'created_at': 1,
            'updated_at': 2,
          },
          {
            'id': 'old-server-memory',
            'user_id': 'u',
            'content': 'c',
            'created_at': 1,
            'updated_at': 2,
          },
        ];

        final memories = await api.getMemories();

        check(memories.map((m) => m.type).toList())
            .deepEquals(['user', 'episodic', null]);
        check(memories.map((m) => m.path).toList())
            .deepEquals(['prefs/units', null, null]);
      },
    );
  });

  group('account fence', () {
    test(
      'every operation stays bound to the account that captured the snapshot',
      () async {
        final accountA = api.captureAuthSnapshot();
        api.updateAuthToken('session-b');

        final operations = <String, Future<Object?> Function()>{
          'get': () => api.getMemories(authSnapshot: accountA),
          'create': () =>
              api.createMemory(content: 'x', authSnapshot: accountA),
          'update': () => api.updateMemory(
            memoryId: 'm1',
            content: 'x',
            authSnapshot: accountA,
          ),
          'delete': () => api.deleteMemory('m1', authSnapshot: accountA),
          'clear': () => api.clearAllMemories(authSnapshot: accountA),
        };
        for (final entry in operations.entries) {
          await expectLater(
            entry.value(),
            throwsA(
              isA<DioException>().having(
                (error) => error.type,
                '${entry.key} type',
                DioExceptionType.cancel,
              ),
            ),
            reason: entry.key,
          );
        }
        check(adapter.requests).isEmpty();
      },
    );

    test(
      'a snapshot from the current account is sent with its token',
      () async {
        await api.updateMemory(
          memoryId: 'm1',
          content: 'x',
          authSnapshot: api.captureAuthSnapshot(),
        );

        check(adapter.requests.single.headers['Authorization'])
            .equals('Bearer session-a');
      },
    );
  });
}

final class _MemoryAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  Object respondWith = const <String, dynamic>{
    'id': 'm1',
    'user_id': 'u',
    'content': 'ok',
    'created_at': 1,
    'updated_at': 1,
  };

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(respondWith),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
