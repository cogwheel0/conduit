import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

const _grants = <Map<String, dynamic>>[
  {'principal_type': 'user', 'principal_id': 'u1', 'permission': 'read'},
  {'principal_type': 'user', 'principal_id': 'u1', 'permission': 'write'},
  {'principal_type': 'group', 'principal_id': 'g1', 'permission': 'read'},
];

void main() {
  late _GrantAdapter adapter;
  late ApiService api;

  setUp(() {
    adapter = _GrantAdapter();
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

  group('chat access', () {
    test(
      'reads and updates through the chat id in the route',
      () async {
        adapter.respondWith = [
          {
            'id': 'g-row',
            'principal_type': 'group',
            'principal_id': 'g1',
            'permission': 'read',
          },
        ];

        final read = await api.getChatAccessGrants('chat-original');
        await api.updateChatAccessGrants('chat-original', _grants);

        check(adapter.requests.map((r) => '${r.method} ${r.path}')).deepEquals([
          'GET /api/v1/chats/shared/chat-original/access',
          'POST /api/v1/chats/shared/chat-original/access/update',
        ]);
        check(read.single['principal_id']).equals('g1');
        check(adapter.requests.last.data)
            .isA<Map>()
            .deepEquals({'access_grants': _grants});
      },
    );
  });

  group('folder access', () {
    test(
      'reads grants and write access from the folder, updates by body',
      () async {
        adapter.respondWith = {
          'id': 'f1',
          'name': 'Team',
          'write_access': true,
          'access_grants': _grants,
        };

        final folder = await api.getFolderAccess('f1');
        await api.updateFolderAccessGrants('f1', _grants);

        check(adapter.requests.map((r) => '${r.method} ${r.path}')).deepEquals([
          'GET /api/v1/folders/f1',
          'POST /api/v1/folders/f1/access/update',
        ]);
        check(folder['write_access']).equals(true);
        check(adapter.requests.last.data)
            .isA<Map>()
            .deepEquals({'access_grants': _grants});
      },
    );
  });

  group('note access', () {
    test('a write recipient updates the grants; the response carries no write_access', () async {
      // `NoteModel` from the update route: grants, but no detail-only field.
      adapter.respondWith = {
        'id': 'n1',
        'user_id': 'creator',
        'title': 'Shared',
        'access_grants': _grants,
      };

      await api.updateNoteAccessGrants('n1', _grants);

      final request = adapter.requests.single;
      check(request.method).equals('POST');
      check(request.path).equals('/api/v1/notes/n1/access/update');
      check(request.data).isA<Map>().deepEquals({'access_grants': _grants});
    });

    test(
      'detail exposes write_access and the server-filtered grants',
      () async {
        // The caller asked for a public grant it may not give; the server kept
        // only the group row. The client must read that back, not assume.
        adapter.respondWith = {
          'id': 'n1',
          'user_id': 'creator',
          'title': 'Shared',
          'write_access': true,
          'access_grants': [_grants.last],
        };

        final note = await api.getNoteForSession('n1');

        check(adapter.requests.single.path).equals('/api/v1/notes/n1');
        check(note['write_access']).equals(true);
        check(note['access_grants']).isA<List>().length.equals(1);
      },
    );
  });

  group('session pinning', () {
    test(
      'every grant route refuses to send once the account has changed',
      () async {
        final opened = api.captureAuthSnapshot();
        api.updateAuthToken('session-b');

        final calls = <String, Future<Object?> Function()>{
          'chat read': () => api.getChatAccessGrants('c', authSnapshot: opened),
          'chat update': () =>
              api.updateChatAccessGrants('c', _grants, authSnapshot: opened),
          'folder read': () => api.getFolderAccess('f', authSnapshot: opened),
          'folder update': () =>
              api.updateFolderAccessGrants('f', _grants, authSnapshot: opened),
          'note read': () => api.getNoteForSession('n', authSnapshot: opened),
          'note update': () =>
              api.updateNoteAccessGrants('n', _grants, authSnapshot: opened),
        };
        for (final entry in calls.entries) {
          await check(entry.value(), because: entry.key).throws<DioException>(
            (e) => e.has((x) => x.type, 'type').equals(DioExceptionType.cancel),
          );
        }
        check(adapter.requests).isEmpty();
      },
    );
  });
}

final class _GrantAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  Object respondWith = const <String, dynamic>{};

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
