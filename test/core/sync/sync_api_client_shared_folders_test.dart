import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/core/sync/sync_api_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// Issue #710: folders another user shared with this account come from
/// `GET /api/v1/folders/shared`, a separate route from the owned-folders list.
/// The pull seam must merge both so shared folders reach the folders table.
void main() {
  group('ApiSyncApiClient.getFoldersRaw shared folders', () {
    test('merges shared folders after owned ones tagged shared:true', () async {
      final client = _buildClient(
        _RouteAdapter({
          '/api/v1/folders/': (200, [_owned('a')]),
          '/api/v1/folders/shared': (
            200,
            [
              _shared('b', owner: 'Alex', permission: 'read'),
              // Owner listing wins on an id collision.
              _shared('a', owner: 'Someone', permission: 'write'),
            ],
          ),
        }),
      );

      final (folders, enabled) = await client.getFoldersRaw();

      check(enabled).isTrue();
      check(folders.map((f) => f['id'])).deepEquals(['a', 'b']);
      check(folders[0]).not((it) => it.containsKey('shared'));
      check(folders[1]['shared']).equals(true);
      check(folders[1]['owner_name']).equals('Alex');
      check(folders[1]['permission']).equals('read');
    });

    test('a server without the shared route (404) yields owned only', () async {
      final client = _buildClient(
        _RouteAdapter({
          '/api/v1/folders/': (200, [_owned('a')]),
          '/api/v1/folders/shared': (404, {'detail': 'Not Found'}),
        }),
      );

      final (folders, enabled) = await client.getFoldersRaw();

      check(enabled).isTrue();
      check(folders.map((f) => f['id'])).deepEquals(['a']);
    });

    test(
      'a transient shared-route failure throws (no partial replace)',
      () async {
        // The pull replaces the folders table from this list, so an owned-only
        // result would purge cached shared folders until the next good pull.
        final client = _buildClient(
          _RouteAdapter({
            '/api/v1/folders/': (200, [_owned('a')]),
            '/api/v1/folders/shared': (500, {'detail': 'boom'}),
          }),
        );

        await check(client.getFoldersRaw()).throws<DioException>();
      },
    );

    test('feature disabled (403 on owned) short-circuits', () async {
      final adapter = _RouteAdapter({
        '/api/v1/folders/': (403, {'detail': 'disabled'}),
        '/api/v1/folders/shared': (200, [_shared('b')]),
      });
      final client = _buildClient(adapter);

      final (folders, enabled) = await client.getFoldersRaw();

      check(enabled).isFalse();
      check(folders).isEmpty();
      check(adapter.paths).deepEquals(['/api/v1/folders/']);
    });
  });
}

Map<String, dynamic> _owned(String id) => {
  'id': id,
  'name': 'F$id',
  'parent_id': null,
  'created_at': 50,
  'updated_at': 100,
};

Map<String, dynamic> _shared(
  String id, {
  String owner = 'Owner',
  String permission = 'read',
}) => {
  ..._owned(id),
  'user_id': 'other-user',
  'owner_name': owner,
  'permission': permission,
};

class _RouteAdapter implements HttpClientAdapter {
  _RouteAdapter(this.routes);

  final Map<String, (int, Object?)> routes;
  final List<String> paths = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    paths.add(options.path);
    final (status, body) = routes[options.path] ?? (404, null);
    return ResponseBody(
      Stream.value(Uint8List.fromList(utf8.encode(jsonEncode(body)))),
      status,
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
