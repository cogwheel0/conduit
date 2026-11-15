import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// An OpenAI-compatible chat endpoint on a loopback port, model
/// `thinking-model`, that answers in three stages a word at a time:
///
/// 1. reasoning (`reasoning_content` deltas);
/// 2. a call to the first tool it is offered, with `{"value": "tide"}`;
/// 3. once the tool's result is back, and after a pause, the answer text,
///    which says what the tool returned.
///
/// The pauses alone do not keep the stages in frames of their own: the
/// daemon coalesces frames at 60 Hz, and on a busy machine a stalled event
/// loop merges stages that follow each other closely. A test that needs
/// each stage seen on its own holds the next one back with [toolCallGate]
/// and [answerGate].
///
/// Asked `fail`, it refuses with HTTP 500 and "scripted refusal".
final class ThinkingOpenAi {
  ThinkingOpenAi._(this._server);

  final HttpServer _server;

  /// When set, the tool call waits for it, after the reasoning.
  Completer<void>? toolCallGate;

  /// When set, the answer text waits for it, after the tool's result.
  Completer<void>? answerGate;

  /// Pause between streamed words.
  static const Duration wordDelay = Duration(milliseconds: 40);

  static const String reasoning =
      'The reader wants the tide. I should ask the tool first.';

  String get baseUrl => 'http://127.0.0.1:${_server.port}/v1';

  static Future<ThinkingOpenAi> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final provider = ThinkingOpenAi._(server);
    server.listen((request) => unawaited(provider._handle(request)));
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
            {'id': 'thinking-model', 'object': 'model'},
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
    final question = _text(
      messages.lastWhere((m) => m['role'] == 'user')['content'],
    ).trim();
    if (question == 'fail') {
      response
        ..statusCode = 500
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode(<String, dynamic>{
            'error': {'message': 'scripted refusal'},
          }),
        );
      await response.close();
      return;
    }
    response.headers.contentType = ContentType(
      'text',
      'event-stream',
      charset: 'utf-8',
    );
    response.bufferOutput = false;
    Future<void> chunk(Map<String, dynamic> delta, {String? finish}) async {
      response.write(
        'data: ${jsonEncode(<String, dynamic>{
          'id': 'c',
          'object': 'chat.completion.chunk',
          'choices': [
            {'index': 0, 'delta': delta, 'finish_reason': finish},
          ],
        })}\n\n',
      );
      await response.flush();
    }

    try {
      if (toolResult == null && body['tools'] is List) {
        final words = reasoning.split(' ');
        for (final (index, word) in words.indexed) {
          await chunk(<String, dynamic>{
            if (index == 0) 'role': 'assistant',
            'reasoning_content': index == words.length - 1 ? word : '$word ',
          });
          await Future<void>.delayed(wordDelay);
        }
        final tool = ((body['tools'] as List).first as Map)['function'] as Map;
        await toolCallGate?.future;
        await chunk(<String, dynamic>{
          'tool_calls': [
            {
              'index': 0,
              'id': 'call_tide',
              'type': 'function',
              'function': {
                'name': tool['name'],
                'arguments': jsonEncode({'value': 'tide'}),
              },
            },
          ],
        }, finish: 'tool_calls');
      } else {
        // Reads the tool's result before it starts to answer.
        await answerGate?.future;
        await Future<void>.delayed(const Duration(milliseconds: 200));
        final said = toolResult == null
            ? 'no tool'
            : 'The tool says ${_text(toolResult['content'])}, which costs \$5.';
        final words = said.split(' ');
        for (final (index, word) in words.indexed) {
          await chunk(<String, dynamic>{
            if (index == 0) 'role': 'assistant',
            'content': index == words.length - 1 ? word : '$word ',
          });
          await Future<void>.delayed(wordDelay);
        }
        await chunk(<String, dynamic>{}, finish: 'stop');
      }
      response.write('data: [DONE]\n\n');
      await response.close();
    } on Object {
      // The client went away.
    }
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
