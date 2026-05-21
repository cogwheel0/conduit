import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ApiService conversation parsing', () {
    test(
      'getConversation parses large byte payloads into typed models',
      () async {
        final largeContent = List.filled(12000, 'payload').join(' ');
        final adapter = _RouteJsonAdapter({
          '/api/v1/chats/chat-1': _fullConversationJson(
            id: 'chat-1',
            messageContent: largeContent,
          ),
        });
        final api = _buildApiService(adapter);

        final conversation = await api.getConversation('chat-1');

        check(conversation.id).equals('chat-1');
        check(conversation.model).equals('demo-model');
        check(conversation.messages).has((it) => it.length, 'length').equals(1);
        check(conversation.messages.single.content).equals(largeContent);
      },
    );

    test('getConversationPage parses large byte summary payloads', () async {
      final adapter = _RouteJsonAdapter({
        '/api/v1/chats/': List.generate(
          30,
          (index) => _conversationSummaryJson(
            'chat-$index',
            titleSuffix: List.filled(250, 'item$index').join('-'),
          ),
        ),
      });
      final api = _buildApiService(adapter);

      final conversations = await api.getConversationPage(page: 1);

      check(conversations).has((it) => it.length, 'length').equals(30);
      check(conversations.first.id).equals('chat-0');
      check(conversations.first.messages).isEmpty();
    });

    test('searchChats parses wrapped byte summary payloads', () async {
      final adapter = _RouteJsonAdapter({
        '/api/v1/chats/search': {
          'results': [
            _conversationSummaryJson(
              'search-hit',
              titleSuffix: 'wrapped-result',
            ),
          ],
        },
      });
      final api = _buildApiService(adapter);

      final conversations = await api.searchChats(query: 'wrapped');

      check(conversations).has((it) => it.length, 'length').equals(1);
      check(conversations.single.id).equals('search-hit');
    });
  });
}

class _RouteJsonAdapter implements HttpClientAdapter {
  _RouteJsonAdapter(this.responses);

  final Map<String, Object?> responses;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final response = responses[options.path] ?? const <Object?>[];
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
  final workerManager = WorkerManager();
  final service = ApiService(
    serverConfig: const ServerConfig(
      id: 'test',
      name: 'Test',
      url: 'http://localhost:0',
    ),
    workerManager: workerManager,
  );
  service.dio.httpClientAdapter = adapter;
  service.dio.interceptors.clear();
  addTearDown(workerManager.dispose);
  return service;
}

Map<String, dynamic> _fullConversationJson({
  required String id,
  required String messageContent,
}) {
  return {
    'id': id,
    'title': 'Conversation $id',
    'created_at': 1713786305,
    'updated_at': 1713786305,
    'chat': {
      'models': ['demo-model'],
      'messages': [
        {
          'id': 'message-1',
          'role': 'user',
          'content': messageContent,
          'timestamp': 1713786305,
        },
      ],
    },
  };
}

Map<String, dynamic> _conversationSummaryJson(
  String id, {
  required String titleSuffix,
}) {
  return {
    'id': id,
    'title': 'Conversation $titleSuffix',
    'created_at': 1713786305,
    'updated_at': 1713786305,
    'tags': const ['demo'],
  };
}
