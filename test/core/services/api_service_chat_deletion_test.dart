import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'deleteConversation treats an already-missing chat as success',
    () async {
      final adapter = _DeleteChatAdapter(statusCode: 404);
      final api = _buildApiService(adapter);

      await api.deleteConversation('already-gone');

      check(adapter.requestCount).equals(1);
      check(adapter.lastMethod).equals('DELETE');
      check(adapter.lastPath).equals('/api/v1/chats/already-gone');
    },
  );

  test('deleteConversation rethrows non-404 server failures', () async {
    final adapter = _DeleteChatAdapter(statusCode: 500);
    final api = _buildApiService(adapter);

    await check(api.deleteConversation('still-there')).throws<DioException>();

    check(adapter.requestCount).equals(1);
    check(adapter.lastMethod).equals('DELETE');
    check(adapter.lastPath).equals('/api/v1/chats/still-there');
  });
}

final class _DeleteChatAdapter implements HttpClientAdapter {
  _DeleteChatAdapter({required this.statusCode});

  final int statusCode;
  int requestCount = 0;
  String? lastMethod;
  String? lastPath;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestCount++;
    lastMethod = options.method;
    lastPath = options.path;
    return ResponseBody(
      Stream.value(
        Uint8List.fromList(utf8.encode(jsonEncode({'detail': 'Not found'}))),
      ),
      statusCode,
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
