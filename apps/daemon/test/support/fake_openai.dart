import 'dart:convert';
import 'dart:io';

/// An OpenAI-compatible chat endpoint on a loopback port, model
/// `fake-model`. Offered tools, it calls the first with `{"value": "hi"}`
/// and then answers with what the tool said; otherwise it says `no tool`.
final class FakeOpenAi {
  FakeOpenAi._(this._server);

  final HttpServer _server;

  String get baseUrl => 'http://127.0.0.1:${_server.port}/v1';

  static Future<FakeOpenAi> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final provider = FakeOpenAi._(server);
    server.listen(provider._handle);
    return provider;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    if (request.uri.path.endsWith('/models')) {
      await request.drain<void>();
      response.headers.contentType = ContentType.json;
      response.write(
        jsonEncode(<String, dynamic>{
          'data': [
            {'id': 'fake-model', 'object': 'model'},
          ],
        }),
      );
      await response.close();
      return;
    }
    final body =
        jsonDecode(await utf8.decodeStream(request)) as Map<String, dynamic>;
    final messages = (body['messages'] as List).cast<Map<String, dynamic>>();
    final toolResult = messages
        .where((message) => message['role'] == 'tool')
        .lastOrNull;
    response.headers.contentType = ContentType(
      'text',
      'event-stream',
      charset: 'utf-8',
    );
    void chunk(Map<String, dynamic> delta, {String? finish}) => response.write(
      'data: ${jsonEncode(<String, dynamic>{
        'id': 'c',
        'object': 'chat.completion.chunk',
        'choices': [
          {'index': 0, 'delta': delta, 'finish_reason': finish},
        ],
      })}\n\n',
    );
    if (toolResult == null && body['tools'] is List) {
      final tool = ((body['tools'] as List).first as Map)['function'] as Map;
      chunk(<String, dynamic>{
        'role': 'assistant',
        'tool_calls': [
          {
            'index': 0,
            'id': 'call_1',
            'type': 'function',
            'function': {
              'name': tool['name'],
              'arguments': jsonEncode({'value': 'hi'}),
            },
          },
        ],
      }, finish: 'tool_calls');
    } else {
      final said = toolResult == null
          ? 'no tool'
          : 'echoed: ${_text(toolResult['content'])}';
      chunk(<String, dynamic>{'role': 'assistant', 'content': said});
      chunk(<String, dynamic>{}, finish: 'stop');
    }
    response.write('data: [DONE]\n\n');
    await response.close();
  }

  static String _text(Object? content) => switch (content) {
    final String text => text,
    final List<Object?> parts =>
      parts
          .map((part) => part is Map ? '${part['text'] ?? ''}' : '$part')
          .join(),
    _ => '$content',
  };
}
