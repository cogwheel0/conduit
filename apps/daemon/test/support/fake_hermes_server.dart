import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A Hermes Agent API server (Responses mode) on loopback, in the shapes
/// the core's parsers read from a real one (M7).
///
/// Sessions, jobs, skills and toolsets are held in memory. A run answers
/// `Echo: <input>` a word at a time; an input that mentions "approve"
/// first asks for approval and answers with what the approval was.
final class FakeHermesServer {
  FakeHermesServer._(this._server, this.key);

  final HttpServer _server;
  final String key;

  final Map<String, Map<String, dynamic>> sessions = {};
  final Map<String, List<Map<String, dynamic>>> messages = {};
  final Map<String, Map<String, dynamic>> jobs = {};
  final List<Map<String, dynamic>> runRequests = [];
  final List<Map<String, dynamic>> approvals = [];

  /// Runs waiting on an approval, by run id.
  final Map<String, Completer<bool>> _waiting = {};
  final Map<String, Map<String, dynamic>> _runs = {};
  var _next = 0;

  String get baseUrl => 'http://127.0.0.1:${_server.port}/v1';

  static Future<FakeHermesServer> start({String key = 'hermes-key'}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeHermesServer._(server, key);
    server.listen((request) => unawaited(fake._handle(request)));
    return fake;
  }

  Future<void> close() => _server.close(force: true);

  String _id(String prefix) =>
      '${prefix}_${(++_next).toString().padLeft(6, '0')}';

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    final path = request.uri.path;
    Future<void> json(Object? body, [int status = 200]) async {
      response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
      await response.close();
    }

    if (path == '/health') return json(<String, dynamic>{'status': 'ok'});
    if (request.headers.value('authorization') != 'Bearer $key') {
      return json(<String, dynamic>{'error': 'unauthorized'}, 401);
    }
    Future<Map<String, dynamic>> body() async {
      final text = await utf8.decoder.bind(request).join();
      return text.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(text) as Map<String, dynamic>;
    }

    final segments = request.uri.pathSegments;
    switch ((request.method, path)) {
      case ('GET', '/health/detailed'):
        return json(<String, dynamic>{
          'status': 'ok',
          'active_sessions': sessions.length,
        });
      case ('GET', '/v1/capabilities'):
        return json(<String, dynamic>{
          'features': <String, dynamic>{
            'run_approval_response': true,
            'skills_api': true,
            'toolsets': true,
            'jobs': true,
            'jobs_admin': true,
            'session_resources': true,
          },
        });
      case ('GET', '/v1/models'):
        return json(<String, dynamic>{
          'data': <Map<String, dynamic>>[
            <String, dynamic>{'id': 'hermes-agent'},
          ],
        });
      case ('GET', '/v1/skills'):
        return json(<String, dynamic>{
          'skills': <Map<String, dynamic>>[
            <String, dynamic>{'name': 'review', 'description': 'Reviews code'},
          ],
        });
      case ('GET', '/v1/toolsets'):
        return json(<String, dynamic>{
          'toolsets': <Map<String, dynamic>>[
            <String, dynamic>{
              'name': 'web',
              'label': 'Web',
              'description': 'Search and fetch',
              'enabled': true,
              'tools': <String>['search', 'fetch'],
            },
          ],
        });
      case ('POST', '/api/sessions'):
        final id = _id('sess');
        final title = (await body())['title'] as String? ?? 'Untitled';
        sessions[id] = <String, dynamic>{
          'id': id,
          'title': title,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        };
        messages[id] = <Map<String, dynamic>>[];
        return json(<String, dynamic>{'id': id});
      case ('GET', '/api/sessions'):
        return json(<String, dynamic>{'sessions': sessions.values.toList()});
      case ('POST', '/v1/runs'):
        final run = await body();
        runRequests.add(run);
        final id = _id('run');
        _runs[id] = run;
        return json(<String, dynamic>{'run_id': id, 'status': 'queued'});
      case ('GET', '/api/jobs'):
        return json(<String, dynamic>{'jobs': jobs.values.toList()});
      case ('POST', '/api/jobs'):
        final job = await body();
        final id = _id('job');
        jobs[id] = <String, dynamic>{...job, 'id': id, 'enabled': true};
        return json(jobs[id]);
    }
    if (segments.length >= 3 &&
        segments[0] == 'api' &&
        segments[1] == 'sessions') {
      final id = segments[2];
      if (!sessions.containsKey(id)) return json(null, 404);
      if (segments.length == 4 && segments[3] == 'messages') {
        return json(<String, dynamic>{'messages': messages[id]});
      }
      if (segments.length == 4 && segments[3] == 'fork') {
        final copy = _id('sess');
        sessions[copy] = <String, dynamic>{
          ...sessions[id]!,
          'id': copy,
          'title': '${sessions[id]!['title']} (fork)',
        };
        messages[copy] = <Map<String, dynamic>>[...?messages[id]];
        return json(<String, dynamic>{'id': copy});
      }
      if (request.method == 'PATCH') {
        sessions[id]!['title'] = (await body())['title'];
        return json(sessions[id]);
      }
      if (request.method == 'DELETE') {
        sessions.remove(id);
        messages.remove(id);
        return json(<String, dynamic>{'ok': true});
      }
    }
    if (segments.length >= 3 && segments[0] == 'v1' && segments[1] == 'runs') {
      final runId = segments[2];
      final run = _runs[runId];
      if (run == null) return json(null, 404);
      if (segments.length == 4 && segments[3] == 'approval') {
        final answer = await body();
        approvals.add(answer);
        _waiting.remove(runId)?.complete(answer['choice'] != 'deny');
        return json(<String, dynamic>{'ok': true});
      }
      if (segments.length == 4 && segments[3] == 'events') {
        return _stream(runId, run, response);
      }
      if (segments.length == 3) {
        return json(<String, dynamic>{'run_id': runId, 'status': 'completed'});
      }
    }
    if (segments.length >= 3 && segments[0] == 'api' && segments[1] == 'jobs') {
      final id = segments[2];
      final job = jobs[id];
      if (job == null) return json(null, 404);
      if (segments.length == 4) {
        switch (segments[3]) {
          case 'pause':
            job['enabled'] = false;
          case 'resume':
            job['enabled'] = true;
          case 'run':
            job['last_status'] = 'ok';
        }
        return json(job);
      }
      if (request.method == 'PATCH') {
        job.addAll(await body());
        return json(job);
      }
      if (request.method == 'DELETE') {
        jobs.remove(id);
        return json(<String, dynamic>{'ok': true});
      }
    }
    return json(<String, dynamic>{'error': 'not found'}, 404);
  }

  Future<void> _stream(
    String runId,
    Map<String, dynamic> run,
    HttpResponse response,
  ) async {
    response.headers
      ..contentType = ContentType('text', 'event-stream')
      ..set('cache-control', 'no-cache');
    response.bufferOutput = false;
    void send(Map<String, dynamic> event) {
      response.write(
        'data: ${jsonEncode(<String, dynamic>{...event, 'run_id': runId})}\n\n',
      );
    }

    final input = run['input'] as String? ?? '';
    var answer = 'Echo: $input';
    if (input.contains('approve')) {
      final decided = Completer<bool>();
      _waiting[runId] = decided;
      send(<String, dynamic>{
        'event': 'approval.request',
        'command': 'rm -rf build',
        'description': 'Clean the build folder',
      });
      await response.flush();
      answer = await decided.future ? 'Approved and done.' : 'Not approved.';
    }
    final words = answer.split(' ');
    for (final (index, word) in words.indexed) {
      final delta = index == words.length - 1 ? word : '$word ';
      send(<String, dynamic>{'event': 'message.delta', 'delta': delta});
      await response.flush();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    send(<String, dynamic>{'event': 'run.completed', 'output': answer});
    await response.close();

    final sessionId = run['session_id'] as String?;
    if (sessionId != null && messages.containsKey(sessionId)) {
      messages[sessionId]!
        ..add(<String, dynamic>{
          'id': _id('msg'),
          'role': 'user',
          'content': input,
        })
        ..add(<String, dynamic>{
          'id': _id('msg'),
          'role': 'assistant',
          'content': answer,
        });
    }
  }
}
