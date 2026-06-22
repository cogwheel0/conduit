import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ApiService.checkActiveChats', () {
    test('posts chat_ids and parses active_chat_ids', () async {
      final adapter = _ActiveChatsAdapter(
        statusCode: 200,
        body: {
          'active_chat_ids': ['a', 'c'],
        },
      );
      final api = _buildApiService(adapter);

      final active = await api.checkActiveChats(['a', 'b', 'c']);

      check(active).deepEquals({'a', 'c'});
      check(adapter.lastPath).equals('/api/v1/tasks/active/chats');
      final sentChatIds = (adapter.lastBody?['chat_ids'] as List)
          .cast<String>();
      check(sentChatIds).deepEquals(['a', 'b', 'c']);
    });

    test('empty input short-circuits without a request', () async {
      final adapter = _ActiveChatsAdapter(statusCode: 200, body: const {});
      final api = _buildApiService(adapter);

      final active = await api.checkActiveChats(const []);

      check(active).isEmpty();
      check(adapter.requestCount).equals(0);
    });

    test('404 degrades to empty and is cached (no re-probe)', () async {
      final adapter = _ActiveChatsAdapter(statusCode: 404, body: const {});
      final api = _buildApiService(adapter);

      final first = await api.checkActiveChats(['a']);
      final second = await api.checkActiveChats(['a', 'b']);

      check(first).isEmpty();
      check(second).isEmpty();
      // Only the first call hits the network; the 404 is cached.
      check(adapter.requestCount).equals(1);
    });

    test('405 degrades to empty and is cached (no re-probe)', () async {
      final adapter = _ActiveChatsAdapter(statusCode: 405, body: const {});
      final api = _buildApiService(adapter);

      final first = await api.checkActiveChats(['a']);
      final second = await api.checkActiveChats(['a', 'b']);

      check(first).isEmpty();
      check(second).isEmpty();
      // Only the first call hits the network; the 405 is cached.
      check(adapter.requestCount).equals(1);
    });
  });
}

class _ActiveChatsAdapter implements HttpClientAdapter {
  _ActiveChatsAdapter({required this.statusCode, required this.body});

  final int statusCode;
  final Map<String, dynamic> body;

  int requestCount = 0;
  String? lastPath;
  Map<String, dynamic>? lastBody;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestCount += 1;
    lastPath = options.path;
    final data = options.data;
    if (data is Map) {
      lastBody = Map<String, dynamic>.from(data);
    } else if (data is String && data.isNotEmpty) {
      lastBody = Map<String, dynamic>.from(jsonDecode(data) as Map);
    }

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
