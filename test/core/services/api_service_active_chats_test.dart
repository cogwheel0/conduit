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

    test(
      '404 uses an empty list fallback and caches the removed route',
      () async {
        final adapter = _ActiveChatsAdapter(
          statusCode: 404,
          body: const {},
          responsesByPath: const {
            '/api/v1/chats/': [],
            '/api/v1/chats/archived': [],
          },
        );
        final api = _buildApiService(adapter);

        final first = await api.checkActiveChats(['a']);
        final second = await api.checkActiveChats(['a', 'b']);

        check(first).isEmpty();
        check(second).isEmpty();
        // Only the first call probes the removed task route. Both calls use the
        // replacement chat-list contract.
        check(
          adapter.requestPaths
              .where((path) => path == '/api/v1/tasks/active/chats')
              .length,
        ).equals(1);
        check(
          adapter.requestPaths.where((path) => path == '/api/v1/chats/').length,
        ).equals(2);
      },
    );

    test('404 falls back to the 0.11 active field on chat lists', () async {
      final adapter = _ActiveChatsAdapter(
        statusCode: 404,
        body: const {},
        responsesByPath: const {
          '/api/v1/chats/': [
            {'id': 'a', 'active': true},
            {'id': 'b', 'active': false},
            {'id': 'c', 'active': true},
          ],
        },
      );
      final api = _buildApiService(adapter);

      final first = await api.checkActiveChats(['a', 'b', 'c']);
      final second = await api.checkActiveChats(['b', 'c']);

      check(first).deepEquals({'a', 'c'});
      check(second).deepEquals({'c'});
      check(
        adapter.requestPaths
            .where((path) => path == '/api/v1/tasks/active/chats')
            .length,
      ).equals(1);
      check(
        adapter.requestPaths.where((path) => path == '/api/v1/chats/').length,
      ).equals(2);
    });

    test(
      '0.11 fallback also checks archived chats not in the main list',
      () async {
        final adapter = _ActiveChatsAdapter(
          statusCode: 404,
          body: const {},
          responsesByPath: const {
            '/api/v1/chats/': [
              {'id': 'regular', 'active': false},
            ],
            '/api/v1/chats/archived': [
              {'id': 'archived', 'active': true},
            ],
          },
        );
        final api = _buildApiService(adapter);

        final active = await api.checkActiveChats(['regular', 'archived']);

        check(active).deepEquals({'archived'});
        check(adapter.requestPaths).deepEquals([
          '/api/v1/tasks/active/chats',
          '/api/v1/chats/',
          '/api/v1/chats/archived',
        ]);
      },
    );

    test('405 selects the 0.11 list fallback and caches the route', () async {
      final adapter = _ActiveChatsAdapter(
        statusCode: 405,
        body: const {'detail': 'Method Not Allowed'},
        responsesByPath: const {
          '/api/v1/chats/': [
            {'id': 'a', 'active': true},
          ],
        },
      );
      final api = _buildApiService(adapter);

      final first = await api.checkActiveChats(['a']);
      final second = await api.checkActiveChats(['a']);

      check(first).deepEquals({'a'});
      check(second).deepEquals({'a'});
      check(
        adapter.requestPaths
            .where((path) => path == '/api/v1/tasks/active/chats')
            .length,
      ).equals(1);
      check(
        adapter.requestPaths.where((path) => path == '/api/v1/chats/').length,
      ).equals(2);
    });

    test('list fallback propagates transient failures', () async {
      final adapter = _ActiveChatsAdapter(
        statusCode: 404,
        body: const {},
        responseHandler: (options) {
          if (options.path == '/api/v1/tasks/active/chats') {
            return _jsonResponse(const {}, statusCode: 404);
          }
          if (options.path == '/api/v1/chats/') {
            return _jsonResponse(const [
              {'id': 'regular', 'active': true},
            ]);
          }
          return _jsonResponse(const {
            'detail': 'temporarily unavailable',
          }, statusCode: 503);
        },
      );
      final api = _buildApiService(adapter);

      await check(
        api.checkActiveChats(['regular', 'archived']),
      ).throws<DioException>();
    });

    test('0.11 pagination continues after a full 60-row page', () async {
      final adapter = _ActiveChatsAdapter(
        statusCode: 404,
        body: const {},
        responseHandler: (options) {
          if (options.path == '/api/v1/tasks/active/chats') {
            return _jsonResponse(const {}, statusCode: 404);
          }
          final page = int.parse(options.queryParameters['page'].toString());
          if (options.path == '/api/v1/chats/' && page == 1) {
            return _jsonResponse(
              List.generate(
                60,
                (index) => {'id': 'regular-$index', 'active': false},
              ),
            );
          }
          return _jsonResponse(const [
            {'id': 'target', 'active': true},
          ]);
        },
      );
      final api = _buildApiService(adapter);

      final active = await api.checkActiveChats(['target']);

      check(active).deepEquals({'target'});
      check(
        adapter.requests
            .where((request) => request.path == '/api/v1/chats/')
            .map((request) => request.queryParameters['page']),
      ).deepEquals([1, 2]);
    });

    test('list fallback stops after 100 full pages per endpoint', () async {
      final adapter = _ActiveChatsAdapter(
        statusCode: 404,
        body: const {},
        responseHandler: (options) {
          if (options.path == '/api/v1/tasks/active/chats') {
            return _jsonResponse(const {}, statusCode: 404);
          }
          final page = int.parse(options.queryParameters['page'].toString());
          if (page > 100) {
            throw StateError('requested page $page beyond the safety ceiling');
          }
          return _jsonResponse(
            List.generate(
              60,
              (index) => {
                'id': '${options.path}-$page-$index',
                'active': false,
              },
            ),
          );
        },
      );
      final api = _buildApiService(adapter);

      final active = await api.checkActiveChats(['missing']);

      check(active).isEmpty();
      check(
        adapter.requests
            .where((request) => request.path == '/api/v1/chats/')
            .length,
      ).equals(100);
      check(
        adapter.requests
            .where((request) => request.path == '/api/v1/chats/archived')
            .length,
      ).equals(100);
    });
  });
}

class _ActiveChatsAdapter implements HttpClientAdapter {
  _ActiveChatsAdapter({
    required this.statusCode,
    required this.body,
    this.responsesByPath = const {},
    this.responseHandler,
  });

  final int statusCode;
  final Object? body;
  final Map<String, Object?> responsesByPath;
  final ResponseBody Function(RequestOptions options)? responseHandler;

  int requestCount = 0;
  String? lastPath;
  Map<String, dynamic>? lastBody;
  final List<String> requestPaths = [];
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestCount += 1;
    lastPath = options.path;
    requestPaths.add(options.path);
    requests.add(options);
    final data = options.data;
    if (data is Map) {
      lastBody = Map<String, dynamic>.from(data);
    } else if (data is String && data.isNotEmpty) {
      lastBody = Map<String, dynamic>.from(jsonDecode(data) as Map);
    }

    final handler = responseHandler;
    if (handler != null) return handler(options);

    final hasPathResponse = responsesByPath.containsKey(options.path);
    final responseBody = hasPathResponse ? responsesByPath[options.path] : body;
    return ResponseBody(
      Stream.value(Uint8List.fromList(utf8.encode(jsonEncode(responseBody)))),
      hasPathResponse ? 200 : statusCode,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _jsonResponse(Object? value, {int statusCode = 200}) =>
    ResponseBody(
      Stream.value(Uint8List.fromList(utf8.encode(jsonEncode(value)))),
      statusCode,
      headers: {
        'content-type': ['application/json'],
      },
    );

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
