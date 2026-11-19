import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// An OpenAI-compatible chat endpoint on a loopback port, model
/// `scripted-model`, whose answers a test steers through the question:
///
/// * `fail` -- refuses with HTTP 500 and the message "scripted refusal";
/// * `hold:<key> <words>` -- streams `<words>` a word at a time, then waits
///   for [release] of `<key>` before finishing;
/// * anything else -- streams `Answer to: <question>` a word at a time.
///
/// Every request's messages are kept, so a test can check what history a
/// turn was sent with.
final class ScriptedOpenAi {
  ScriptedOpenAi._(this._server);

  final HttpServer _server;
  final List<List<Map<String, dynamic>>> requests =
      <List<Map<String, dynamic>>>[];
  final Map<String, Completer<void>> _holds = <String, Completer<void>>{};
  final List<(String, Completer<void>)> _asked = <(String, Completer<void>)>[];

  /// Completes once a question starting with [prefix] is asked from now on.
  Future<void> asked(String prefix) {
    final asked = Completer<void>();
    _asked.add((prefix, asked));
    return asked.future;
  }

  String get baseUrl => 'http://127.0.0.1:${_server.port}/v1';

  static Future<ScriptedOpenAi> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final provider = ScriptedOpenAi._(server);
    server.listen((request) => unawaited(provider._handle(request)));
    return provider;
  }

  Future<void> close() async {
    for (final hold in _holds.values) {
      if (!hold.isCompleted) hold.complete();
    }
    await _server.close(force: true);
  }

  /// Lets every answer held under [key] finish.
  void release(String key) {
    final hold = _holds.putIfAbsent(key, Completer<void>.new);
    if (!hold.isCompleted) hold.complete();
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    if (request.uri.path.endsWith('/models')) {
      await request.drain<void>();
      response.headers.contentType = ContentType.json;
      response.write(
        jsonEncode(<String, dynamic>{
          'data': [
            {'id': 'scripted-model', 'object': 'model'},
          ],
        }),
      );
      await response.close();
      return;
    }
    final body =
        jsonDecode(await utf8.decodeStream(request)) as Map<String, dynamic>;
    final messages = (body['messages'] as List).cast<Map<String, dynamic>>();
    requests.add(messages);
    final question = _text(
      messages.lastWhere((m) => m['role'] == 'user')['content'],
    ).trim();
    _asked.removeWhere((waiter) {
      final (prefix, asked) = waiter;
      if (!question.startsWith(prefix)) return false;
      asked.complete();
      return true;
    });

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
    void chunk(Map<String, dynamic> delta, {String? finish}) => response.write(
      'data: ${jsonEncode(<String, dynamic>{
        'id': 'c',
        'object': 'chat.completion.chunk',
        'choices': [
          {'index': 0, 'delta': delta, 'finish_reason': finish},
        ],
      })}\n\n',
    );

    String? hold;
    var answer = 'Answer to: $question';
    if (question.startsWith('hold:')) {
      final space = question.indexOf(' ');
      hold = space < 0 ? question.substring(5) : question.substring(5, space);
      answer = space < 0 ? hold : question.substring(space + 1);
    }
    final words = answer.split(' ');
    try {
      for (final (index, word) in words.indexed) {
        chunk(<String, dynamic>{
          if (index == 0) 'role': 'assistant',
          'content': index == words.length - 1 ? word : '$word ',
        });
        await response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 15));
      }
      if (hold != null) {
        await _holds.putIfAbsent(hold, Completer<void>.new).future;
      }
      chunk(<String, dynamic>{}, finish: 'stop');
      response.write('data: [DONE]\n\n');
      await response.close();
    } on Object {
      // The client went away: a stopped turn.
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
