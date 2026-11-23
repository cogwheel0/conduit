import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:conduit_core/testing.dart';
import 'package:dio/dio.dart';

/// A LibreChat server on a loopback port that takes one model's turns: the
/// core's [FakeLibreChatServer] (sign-in, sessions, conversations) behind a
/// socket, since the daemon reaches LibreChat over HTTP as the app does,
/// with an Ollama model and LibreChat's generation routes. Each reply
/// stream stays open for the test to write into ([created], [text]).
final class FakeLibreChatChat {
  FakeLibreChatChat._(this._server, this.fake) {
    fake
      ..on(
        'GET',
        '/api/endpoints',
        (request, match) => FakeLibreChatResponse.json({
          'Ollama': {
            'order': 1,
            'type': 'custom',
            'modelDisplayLabel': 'Ollama',
          },
        }),
      )
      ..on(
        'GET',
        '/api/models',
        (request, match) => FakeLibreChatResponse.json({
          'Ollama': ['llama3.2'],
        }),
      )
      ..on(
        'GET',
        '/api/agents',
        (request, match) =>
            FakeLibreChatResponse.json({'data': <Object>[], 'has_more': false}),
      )
      ..on('POST', '/api/agents/chat/([^/]+)', (request, match) {
        final id =
            (request.data as Map?)?['conversationId'] as String? ??
            'conv-ridge';
        return FakeLibreChatResponse.json({
          'streamId': id,
          'conversationId': id,
          'generationCreatedAt': 42,
          'status': 'started',
        });
      })
      ..on('POST', '/api/agents/chat/abort', (request, match) {
        aborts.add(request.data);
        if (!_streams.last.isClosed) {
          _emit({
            'final': true,
            'aborted': true,
            'responseMessage': {
              'messageId': _responseId,
              'content': [
                {'type': 'text', 'text': ''},
              ],
            },
          });
          unawaited(_streams.last.close());
        }
        return FakeLibreChatResponse.json({'success': true});
      })
      ..on('GET', '/api/agents/chat/stream/(.+)', (request, match) {
        final stream = StreamController<Uint8List>();
        _streams.add(stream);
        if (!_streamOpened.isCompleted) _streamOpened.complete();
        return FakeLibreChatResponse(
          200,
          contentType: 'text/event-stream',
          stream: stream.stream,
        );
      });
  }

  final HttpServer _server;
  final FakeLibreChatServer fake;
  final List<StreamController<Uint8List>> _streams =
      <StreamController<Uint8List>>[];
  final Completer<void> _streamOpened = Completer<void>();

  /// The bodies of the aborts asked for (LibreChat's Stop). Each ends the
  /// reply stream with the server's aborted final frame.
  final List<Object?> aborts = <Object?>[];
  String? _responseId;

  /// The model the picker lists for the Ollama model.
  static const String model = 'librechat:model:Ollama/llama3.2';

  String get url => fake.baseUrl;

  /// Completes once the first reply stream is open.
  Future<void> get streamOpened => _streamOpened.future;

  static Future<FakeLibreChatChat> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final chat = FakeLibreChatChat._(
      server,
      FakeLibreChatServer(baseUrl: 'http://127.0.0.1:${server.port}'),
    );
    server.listen((request) => unawaited(chat._handle(request)));
    return chat;
  }

  Future<void> close() async {
    for (final stream in _streams) {
      if (!stream.isClosed) await stream.close();
    }
    await _server.close(force: true);
  }

  /// The server names the turn's question [userId].
  void created(String userId, String text) => _emit({
    'created': true,
    'message': {
      'messageId': userId,
      'parentMessageId': '00000000-0000-0000-0000-000000000000',
      'text': text,
      'isCreatedByUser': true,
    },
  });

  /// The reply [responseId] writes [chunk].
  void text(String responseId, String chunk) {
    _responseId = responseId;
    _emit({
      'event': 'on_run_step',
      'data': {
        'id': 'step-text',
        'runId': responseId,
        'index': 0,
        'stepDetails': {'type': 'message_creation'},
      },
    });
    _emit({
      'event': 'on_message_delta',
      'data': {
        'id': 'step-text',
        'delta': {
          'content': [
            {'type': 'text', 'text': chunk},
          ],
        },
      },
    });
  }

  void _emit(Map<String, dynamic> json) => _streams.last.add(
    Uint8List.fromList(
      utf8.encode('event: message\ndata: ${jsonEncode(json)}\n\n'),
    ),
  );

  /// Hands [request] to the core's fake as its Dio adapter would get it, and
  /// writes its answer back, a stream as it comes.
  Future<void> _handle(HttpRequest request) async {
    final body = await request.fold<List<int>>(
      <int>[],
      (all, chunk) => all..addAll(chunk),
    );
    final headers = <String, dynamic>{};
    request.headers.forEach((name, values) => headers[name] = values.join(','));
    Object? data;
    if (body.isNotEmpty) {
      final text = utf8.decode(body);
      data = request.headers.contentType?.mimeType == 'application/json'
          ? jsonDecode(text)
          : text;
    }
    final answer = await fake.fetch(
      RequestOptions(
        method: request.method,
        baseUrl: url,
        path: request.uri.toString(),
        headers: headers,
        data: data,
      ),
      null,
      null,
    );
    final response = request.response
      ..bufferOutput = false
      ..statusCode = answer.statusCode;
    answer.headers.forEach((name, values) {
      for (final value in values) {
        response.headers.add(name, value);
      }
    });
    try {
      await response.addStream(answer.stream);
      await response.close();
    } on Object {
      // The client went away mid-stream, or the server is closing.
    }
  }
}
