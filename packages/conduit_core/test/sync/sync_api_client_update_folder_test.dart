import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/sync/chat_locks.dart';
import 'package:conduit_core/sync/clock.dart';
import 'package:conduit_core/sync/id_remapper.dart';
import 'package:conduit_core/sync/push_sync.dart';
import 'package:conduit_core/sync/sync_api_client.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:test/test.dart';

/// Regression guard: the folder-update seam must NOT collapse a healthy 2xx
/// response with an unexpected (non-map / empty) body into the same `null`
/// signal it uses for a genuine 404. The push path treats a null return as
/// "folder gone on server" and PURGES the local row, so a 2xx-null would be
/// silent data loss (CDT-RFC-001 §7.4; the route returns `null` with HTTP 200
/// when the server-side update helper bails, e.g. duplicate-name collision).
void main() {
  group('ApiSyncApiClient.updateFolder', () {
    test('2xx response with a non-map body returns a map, never null', () async {
      // Server replied 200 with a JSON `null` body (the vendored
      // `update_folder_by_id_and_user_id` returns None on its bail paths while
      // the folder still exists). This MUST read as success, not a 404.
      final client = _buildClient(_FixedAdapter(statusCode: 200, body: null));

      final result = await client.updateFolder('folder-1', name: 'Renamed');

      check(result).isNotNull();
    });

    test('genuine 404 returns null (caller purges the local row)', () async {
      final client = _buildClient(
        _FixedAdapter(statusCode: 404, body: {'detail': 'Not found'}),
      );

      final result = await client.updateFolder('folder-1', name: 'Renamed');

      check(result).isNull();
    });

    test('2xx map body is returned verbatim', () async {
      final folder = {'id': 'folder-1', 'name': 'Renamed', 'updated_at': 42};
      final client = _buildClient(_FixedAdapter(statusCode: 200, body: folder));

      final result = await client.updateFolder('folder-1', name: 'Renamed');

      check(result).isNotNull().deepEquals(folder);
    });
  });

  group('a project edit made offline', () {
    late AppDatabase db;
    late IdRemapper remapper;
    late _RecordingAdapter adapter;
    late PushSync push;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      remapper = IdRemapper(db);
      adapter = _RecordingAdapter();
      push = PushSync(
        client: _buildClient(adapter),
        db: db,
        chatLocks: ConversationLocks(),
        folderLocks: FolderLocks(),
        clock: _FixedClock(),
        remapper: remapper,
      );
      await db.foldersDao.replaceServerFolders([
        {
          'id': 'p',
          'name': 'Project',
          'created_at': 1,
          'updated_at': 2,
          'meta': {'icon': 'briefcase'},
          'data': {
            'system_prompt': 'Be brief',
            'files': [
              {'type': 'collection', 'id': 'kb-1', 'name': 'Docs'},
            ],
          },
        },
      ]);
    });

    tearDown(() async {
      await remapper.dispose();
      await db.close();
    });

    test('drains as a request that carries only the edited key', () async {
      await db.foldersDao.patchFolderDataWithOutbox(
        id: 'p',
        dataPatch: {
          'model_ids': ['m-a', 'm-b'],
        },
      );

      final op = (await db.outboxDao.pendingForChat('p')).single;
      await push.pushFolderUpsert(
        jsonDecode(op.payload) as Map<String, dynamic>,
      );

      final request = adapter.requests.single;
      check(request.method).equals('POST');
      check(request.path).equals('/api/v1/folders/p/update');
      check(request.data).isA<Map<String, dynamic>>().deepEquals({
        'data': {
          'model_ids': ['m-a', 'm-b'],
        },
      });
      check((await db.foldersDao.getFolder('p'))!.dirty).isFalse();
    });
  });

  group('getFolderById', () {
    test('reads as the account that captured the snapshot', () async {
      final adapter = _RecordingAdapter();
      final api = ApiService(
        serverConfig: const ServerConfig(
          id: 'server',
          name: 'Server',
          url: 'https://server.example',
        ),
        workerManager: WorkerManager(),
        authToken: 'session-a',
      );
      addTearDown(api.dispose);
      api.dio.httpClientAdapter = adapter;

      final accountA = api.captureAuthSnapshot();
      await api.getFolderById('p', authSnapshot: accountA);
      check(adapter.requests.single.headers['Authorization'])
          .equals('Bearer session-a');

      // Another account signs in; the editor's snapshot must not follow it.
      api.updateAuthToken('session-b');
      await check(
        api.getFolderById('p', authSnapshot: accountA),
      ).throws<DioException>(
        (error) =>
            error.has((e) => e.type, 'type').equals(DioExceptionType.cancel),
      );
      check(adapter.requests).length.equals(1);
    });
  });
}

class _FixedClock implements SyncClock {
  @override
  int nowEpochSeconds() => 1000;
}

class _RecordingAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode({'id': 'p', 'name': 'Project', 'updated_at': 3}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _FixedAdapter implements HttpClientAdapter {
  _FixedAdapter({required this.statusCode, required this.body});

  final int statusCode;
  final Object? body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody(
      Stream.value(Uint8List.fromList(utf8.encode(jsonEncode(body)))),
      statusCode,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

SyncApiClient _buildClient(HttpClientAdapter adapter) {
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
  return ApiSyncApiClient(service);
}
