import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/api_auth_interceptor.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  const messages = [
    {'role': 'user', 'content': 'Plan a weekend in Oslo'},
  ];

  Map<String, Object?> completion(String content) => {
    'choices': [
      {
        'message': {'role': 'assistant', 'content': content},
      },
    ],
  };

  test('a title is read from the task model\'s JSON answer', () async {
    final adapter = _TaskAdapter(
      completion('Sure! {"title": "Weekend in Oslo"} Hope that helps.'),
    );
    final api = _buildApiService(adapter);
    final session = api.captureAuthSnapshot();

    final title = await api.generateChatTitle(
      model: 'model-1',
      messages: messages,
      chatId: 'chat-1',
      authSnapshot: session,
    );

    check(title).equals('Weekend in Oslo');
    // The request is bound to the session it was made for.
    check(adapter.snapshot).identicalTo(session);
    check(adapter.path).equals('/api/v1/tasks/title/completions');
    check(adapter.body).isNotNull().deepEquals({
      'model': 'model-1',
      'messages': messages,
      'chat_id': 'chat-1',
    });
  });

  test('single-quoted tags are read as the web client reads them', () async {
    final adapter = _TaskAdapter(
      completion("{'tags': ['Travel', ' ', 'Norway']}"),
    );
    final api = _buildApiService(adapter);

    final tags = await api.generateChatTags(
      model: 'model-1',
      messages: messages,
    );

    check(tags).deepEquals(['Travel', 'Norway']);
    check(adapter.path).equals('/api/v1/tasks/tags/completions');
    check(adapter.body).isNotNull().not((it) => it.containsKey('chat_id'));
  });

  test('apostrophes in valid JSON answers are kept', () async {
    final titled = _buildApiService(
      _TaskAdapter(completion('{"title": "What\'s next?"}')),
    );
    check(
      await titled.generateChatTitle(model: 'model-1', messages: messages),
    ).equals("What's next?");

    final tagged = _buildApiService(
      _TaskAdapter(completion('{"tags": ["Rock’n’roll", "Music"]}')),
    );
    check(
      await tagged.generateChatTags(model: 'model-1', messages: messages),
    ).deepEquals(['Rock’n’roll', 'Music']);
  });

  test('turned-off generation and unreadable answers give nothing', () async {
    // The server answers a disabled task with only a detail.
    final disabled = _buildApiService(
      _TaskAdapter({'detail': 'Title generation is disabled'}),
    );
    check(
      await disabled.generateChatTitle(model: 'model-1', messages: messages),
    ).isNull();

    final unreadable = _buildApiService(_TaskAdapter(completion('Oslo trip')));
    check(
      await unreadable.generateChatTags(model: 'model-1', messages: messages),
    ).isEmpty();
  });
}

class _TaskAdapter implements HttpClientAdapter {
  _TaskAdapter(this.response);

  final Object? response;
  String? path;
  Map<String, dynamic>? body;
  Object? snapshot;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    check(options.method).equals('POST');
    path = options.path;
    snapshot = options.extra[ApiAuthInterceptor.authSnapshotExtraKey];
    final data = options.data;
    body = data is Map ? Map<String, dynamic>.from(data) : null;
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
