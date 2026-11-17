import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A Hermes Agent API server (Responses mode) on loopback, in the shapes
/// the core's parsers read from a real one.
///
/// Sessions, jobs, skills and toolsets are held in memory. A run answers
/// `Echo: <input>` a word at a time; an input that mentions "approve"
/// first asks for approval and answers with what the approval was.
///
/// As Hermes v0.22.1+, it says the API server owns its sessions
/// (`run_unknown_resolution`) and refuses a run into a session another
/// Hermes app started (`source` other than `api_server`) with
/// `409 permission_denied`. [seedForeign] adds such a session.
final class FakeHermesServer {
  FakeHermesServer._(this._server, this.key);

  final HttpServer _server;
  final String key;

  final Map<String, Map<String, dynamic>> sessions = {};
  final Map<String, List<Map<String, dynamic>>> messages = {};
  final Map<String, Map<String, dynamic>> jobs = {};
  final List<Map<String, dynamic>> runRequests = [];
  final List<Map<String, dynamic>> approvals = [];

  /// While set, a session's messages are answered only once it completes;
  /// [messagesAsked] completes when such a request has come in.
  Completer<void>? holdMessages;
  Completer<void> messagesAsked = Completer<void>();

  /// While true, the jobs list is refused (409, an answer the daemon does
  /// not retry), as a server that made a job but fails the read after it.
  bool refuseJobList = false;

  /// While set, the skills are listed only once it completes;
  /// [skillsAsked] completes when such a request has come in.
  Completer<void>? holdSkills;
  Completer<void> skillsAsked = Completer<void>();

  /// Run (once) when `/v1/capabilities` is asked, before it is answered.
  Future<void> Function()? onCapabilities;
  /// Every request's headers (names in lower case), oldest first.
  final List<Map<String, String>> requestHeaders = [];

  /// Runs waiting on an approval, by run id.
  final Map<String, Completer<bool>> _waiting = {};
  final Map<String, Map<String, dynamic>> _runs = {};
  var _next = 0;

  String get baseUrl => 'http://127.0.0.1:${_server.port}/v1';

  /// Listens on [port], or on a free one when it is 0.
  static Future<FakeHermesServer> start({
    String key = 'hermes-key',
    int port = 0,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    final fake = FakeHermesServer._(server, key);
    server.listen((request) => unawaited(fake._handle(request)));
    return fake;
  }

  Future<void> close() => _server.close(force: true);

  /// A session another Hermes app ([source]) started, with [turns] as its
  /// questions and answers; answers with its id.
  String seedForeign({
    required String title,
    String source = 'cli',
    List<(String, String)> turns = const <(String, String)>[],
    bool rowIds = true,
  }) {
    final id = _id('sess');
    sessions[id] = <String, dynamic>{
      'id': id,
      'title': title,
      'source': source,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    messages[id] = <Map<String, dynamic>>[
      for (final (question, answer) in turns) ...<Map<String, dynamic>>[
        <String, dynamic>{
          if (rowIds) 'id': _id('msg'),
          'role': 'user',
          'content': question,
        },
        <String, dynamic>{
          if (rowIds) 'id': _id('msg'),
          'role': 'assistant',
          'content': answer,
        },
      ],
    ];
    return id;
  }

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

    final headers = <String, String>{};
    request.headers.forEach((name, values) => headers[name] = values.join(','));
    requestHeaders.add(headers);
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
        final hook = onCapabilities;
        onCapabilities = null;
        await hook?.call();
        return json(<String, dynamic>{
          'features': <String, dynamic>{
            'run_approval_response': true,
            'skills_api': true,
            'toolsets': true,
            'jobs': true,
            'jobs_admin': true,
            'session_resources': true,
            'run_unknown_resolution': true,
          },
        });
      case ('GET', '/v1/models'):
        return json(<String, dynamic>{
          'data': <Map<String, dynamic>>[
            <String, dynamic>{'id': 'hermes-agent'},
          ],
        });
      case ('GET', '/v1/skills'):
        if (holdSkills case final hold?) {
          if (!skillsAsked.isCompleted) skillsAsked.complete();
          await hold.future;
        }
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
        final created = await body();
        final id = _id('sess');
        // Untitled when none is given, as a real server leaves it.
        final title = created['title'] as String?;
        // A seed (the E2E's) may say which Hermes app started it and what
        // was said; a real server takes neither.
        sessions[id] = <String, dynamic>{
          'id': id,
          'title': title,
          'source': created['source'] as String? ?? 'api_server',
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        };
        messages[id] = <Map<String, dynamic>>[
          for (final m in (created['messages'] as List? ?? const <Object>[]))
            <String, dynamic>{
              'id': _id('msg'),
              ...(m as Map).cast<String, dynamic>(),
            },
        ];
        return json(<String, dynamic>{'id': id});
      case ('GET', '/api/sessions'):
        // The API server lists no archived sessions.
        return json(<String, dynamic>{
          'sessions': sessions.values
              .where((s) => s['archived'] != true)
              .toList(),
        });
      case ('POST', '/v1/runs'):
        final run = await body();
        final into = sessions[run['session_id']];
        final source = into?['source'] as String?;
        if (into != null && source != null && source != 'api_server') {
          return json(<String, dynamic>{
            'error': <String, dynamic>{
              'code': 'permission_denied',
              'message': 'this session belongs to another Hermes app',
            },
          }, 409);
        }
        runRequests.add(run);
        final id = _id('run');
        _runs[id] = run;
        return json(<String, dynamic>{'run_id': id, 'status': 'queued'});
      case ('GET', '/api/jobs'):
        if (refuseJobList) {
          return json(<String, dynamic>{'error': 'busy'}, 409);
        }
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
        if (holdMessages case final hold?) {
          if (!messagesAsked.isCompleted) messagesAsked.complete();
          await hold.future;
        }
        return json(<String, dynamic>{'messages': messages[id]});
      }
      if (segments.length == 4 && segments[3] == 'fork') {
        final copy = _id('sess');
        sessions[copy] = <String, dynamic>{
          ...sessions[id]!,
          'id': copy,
          'title': '${sessions[id]!['title']} (fork)',
          'source': 'api_server',
          'pinned': false,
          'archived': false,
          'hidden': false,
        };
        messages[copy] = <Map<String, dynamic>>[...?messages[id]];
        return json(<String, dynamic>{'id': copy});
      }
      if (request.method == 'PATCH') {
        // A title, or the sidebar flags (pinned, archived, hidden).
        final changes = await body();
        for (final key in <String>['title', 'pinned', 'archived', 'hidden']) {
          if (changes.containsKey(key)) sessions[id]![key] = changes[key];
        }
        return json(sessions[id]);
      }
      if (request.method == 'DELETE') {
        sessions.remove(id);
        messages.remove(id);
        return json(<String, dynamic>{'ok': true});
      }
      if (request.method == 'GET' && segments.length == 3) {
        return json(<String, dynamic>{'session': sessions[id]});
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
