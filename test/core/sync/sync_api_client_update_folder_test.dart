import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/core/sync/sync_api_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

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
        _FixedAdapter(
          statusCode: 404,
          body: {'detail': 'Not found'},
        ),
      );

      final result = await client.updateFolder('folder-1', name: 'Renamed');

      check(result).isNull();
    });

    test('2xx map body is returned verbatim', () async {
      final folder = {'id': 'folder-1', 'name': 'Renamed', 'updated_at': 42};
      final client = _buildClient(
        _FixedAdapter(statusCode: 200, body: folder),
      );

      final result = await client.updateFolder('folder-1', name: 'Renamed');

      check(result).isNotNull().deepEquals(folder);
    });
  });
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
