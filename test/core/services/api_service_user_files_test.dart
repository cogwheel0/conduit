import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ApiService.getUserFiles', () {
    test('stops after page 1 for legacy plain-list responses', () async {
      final adapter = _QueuedJsonAdapter({
        1: [_fileJson('file-1')],
      });
      final api = _buildApiService(adapter);

      final files = await api.getUserFiles();

      check(files).has((it) => it.length, 'length').equals(1);
      check(files.single.id).equals('file-1');
      check(adapter.requestedPages).deepEquals([1]);
    });

    test(
      'continues paging for paginated responses until total is reached',
      () async {
        final adapter = _QueuedJsonAdapter({
          1: {
            'items': [_fileJson('file-1')],
            'total': 2,
          },
          2: {
            'items': [_fileJson('file-2')],
            'total': 2,
          },
        });
        final api = _buildApiService(adapter);

        final files = await api.getUserFiles();

        check(
          files.map((file) => file.id).toList(),
        ).deepEquals(['file-1', 'file-2']);
        check(adapter.requestedPages).deepEquals([1, 2]);
      },
    );
  });
}

class _QueuedJsonAdapter implements HttpClientAdapter {
  _QueuedJsonAdapter(this.responses);

  final Map<int, Object?> responses;
  final requestedPages = <int>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final page = options.queryParameters['page'] as int? ?? 1;
    requestedPages.add(page);

    final response = responses[page] ?? const <Object?>[];
    return ResponseBody(
      Stream.value(Uint8List.fromList(utf8.encode(jsonEncode(response)))),
      200,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

ApiService _buildApiService(HttpClientAdapter adapter) {
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

Map<String, dynamic> _fileJson(String id) {
  return {
    'id': id,
    'user_id': 'user-1',
    'filename': '$id.txt',
    'original_filename': '$id.txt',
    'content_type': 'text/plain',
    'size': 128,
    'created_at': 1713786305,
    'updated_at': 1713786305,
  };
}
