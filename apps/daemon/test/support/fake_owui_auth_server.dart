import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';

/// Just enough of an Open WebUI server on a loopback port to sign in to:
/// health, config, password sign-in (with a second step for the users in
/// `twoStep`, whose `mfa/verify` takes any code), the current user and
/// sign-out, for a fixed set of synthetic users. Every other authenticated read answers an
/// empty list (or, for the model list, an empty `data`), so the core's
/// background loads find an empty account rather than an error.
///
/// With [models] set it also takes the core's Open WebUI sends, as
/// [FakeOwuiChats] describes: a polling socket, chats made and saved, and
/// each answer run as a task whose words arrive on the socket, with a hold
/// at admission and one on the stream.
final class FakeOwuiAuthServer {
  FakeOwuiAuthServer._(
    this._server,
    this._users,
    this._twoStep,
    this.proxyCookie,
  );

  final HttpServer _server;
  final Map<String, ({String id, String name, String password})> _users;
  final Set<String> _twoStep;
  _Sessions _sessions = _Sessions();
  Map<String, String> get _tokens => _sessions.tokens;
  final Map<String, String> _challenges = <String, String>{};

  /// What this listener has issued (sessions and challenges).
  var _issued = 0;

  /// A new token or challenge named with [prefix]: unique across every
  /// listener sharing these sessions, so no sign-in takes another's.
  String _issue(String prefix) {
    _issued++;
    return '$prefix-${++_sessions.issued}';
  }

  /// While set, the next current-user read (how a client checks a session
  /// it was just given) waits for it, once; [sessionChecked] completes when
  /// it arrives.
  Completer<void>? holdSessionCheck;

  /// While set, a read of the user's settings
  /// (`GET /api/v1/users/user/settings`) waits for it, once [settingsToPass]
  /// more reads have gone through; [settingsAsked] completes as one reaches
  /// it.
  Completer<void>? holdSettings;
  int settingsToPass = 0;
  Completer<void> settingsAsked = Completer<void>();
  Completer<void> sessionChecked = Completer<void>();

  /// While set, a sign-in proxy in front turns every request away with its
  /// own sign-in page (HTML), as an expired proxy session does -- but one
  /// carrying the renewed proxy cookie [proxyAccepts], when that is set.
  bool proxyRefuses = false;
  String? proxyAccepts;

  /// The session the last password sign-in was given.
  String? lastIssued;

  /// The email of every user whose session was ended through sign-out.
  final List<String> signedOut = <String>[];

  /// The method and path of every request, in order.
  final List<String> requests = <String>[];

  /// The models the server offers (`/api/models`).
  List<String> models = const <String>[];

  /// The chats and answers of [models]' sends.
  final FakeOwuiChats chats = FakeOwuiChats();

  /// Answers every signed-in request as a sign-in proxy whose session
  /// expired does: a redirect to its sign-in page.
  bool turnAway = false;

  /// A sign-in proxy in front of the server: a request without this cookie
  /// (`name=value`) is sent to the proxy's sign-in page, health checks too.
  final String? proxyCookie;

  /// Takes [other]'s sessions as its own, from now on: the same server
  /// reached another way (here, through a sign-in proxy).
  void shareSessionsOf(FakeOwuiAuthServer other) => _sessions = other._sessions;

  /// Ends every session server-side: their tokens are refused from now on.
  void revokeSessions() => _tokens.clear();

  /// How many sessions password sign-ins have been given.
  int get signIns => _issued;

  /// A session for [email], as a sign-in in a window would have made.
  String sessionFor(String email) {
    final token = _issue('fake-window-token');
    _tokens[token] = email;
    return token;
  }

  /// While set, every request waits for it before it is answered.
  Future<void>? hold;

  /// Completed, and cleared, when a request starts waiting on [hold].
  Completer<void>? onHeld;

  /// While set, the next `/health` asked over this plain listener is sent
  /// to the https address on the same host and port, once.
  bool redirectHealthToHttpsOnce = false;

  /// Every request's headers, lower-case names, in arrival order.
  final List<Map<String, String>> headersSeen = <Map<String, String>>[];

  String get url => 'http://127.0.0.1:${_server.port}';

  static Future<FakeOwuiAuthServer> start({
    required Map<String, ({String id, String name, String password})> users,
    Set<String> twoStep = const <String>{},
    String? proxyCookie,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeOwuiAuthServer._(server, users, twoStep, proxyCookie);
    server.listen((request) => unawaited(fake._handle(request)));
    return fake;
  }

  /// The Open WebUI version the server reports; below 0.9 the core sends
  /// the legacy request shape, saving the pending turn first.
  String version = '0.13.1';

  Future<void> close() {
    chats._close();
    final settings = holdSettings;
    if (settings != null && !settings.isCompleted) settings.complete();
    return _server.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    Future<void> json(Object? body, [int status = 200]) async {
      response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
      await response.close();
    }

    final path = request.uri.path;
    if (chats._stopped) {
      // The server process is gone: the connection drops unanswered.
      final socket = await response.detachSocket(writeHeaders: false);
      socket.destroy();
      return;
    }
    requests.add('${request.method} $path');
    final seen = <String, String>{};
    request.headers.forEach((name, values) => seen[name] = values.join(','));
    headersSeen.add(seen);
    if (redirectHealthToHttpsOnce && path == '/health') {
      redirectHealthToHttpsOnce = false;
      await request.drain<void>();
      response
        ..statusCode = HttpStatus.movedPermanently
        ..headers.set(
          HttpHeaders.locationHeader,
          'https://127.0.0.1:${_server.port}/health',
        );
      return response.close();
    }
    final accepted = proxyAccepts;
    final renewed =
        accepted != null &&
        (request.headers.value('cookie') ?? '').contains(accepted);
    if (proxyRefuses && !renewed) {
      await request.drain<void>();
      response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write('<html><body>Sign in to continue</body></html>');
      return response.close();
    }
    final held = hold;
    if (held != null) {
      final reached = onHeld;
      onHeld = null;
      reached?.complete();
      await held;
    }
    final proxy = proxyCookie;
    if (proxy != null &&
        !(request.headers.value(HttpHeaders.cookieHeader) ?? '').contains(
          proxy,
        )) {
      await request.drain<void>();
      if (path == '/oauth2/start') {
        response
          ..headers.contentType = ContentType.html
          ..write('<html><body>Proxy sign-in</body></html>');
        await response.close();
        return;
      }
      response
        ..statusCode = HttpStatus.found
        ..headers.set(
          HttpHeaders.locationHeader,
          'http://127.0.0.1:${_server.port}/oauth2/start',
        );
      await response.close();
      return;
    }
    if (path == '/health') return json(<String, dynamic>{'status': true});
    if (path == '/api/version') {
      return json(<String, dynamic>{'version': version});
    }
    if (path == '/api/config') {
      return json(<String, dynamic>{
        'status': true,
        'name': 'Open WebUI',
        'version': version,
        'default_locale': '',
        'oauth': <String, dynamic>{'providers': <String, dynamic>{}},
        'features': <String, dynamic>{
          'auth': true,
          'auth_trusted_header': false,
          'enable_ldap': false,
          'enable_api_key': true,
          'enable_signup': false,
          'enable_login_form': true,
          'enable_websocket': models.isNotEmpty,
        },
      });
    }
    if (path == '/api/v1/auths/signin' && request.method == 'POST') {
      final body =
          jsonDecode(await utf8.decodeStream(request)) as Map<String, dynamic>;
      final email = body['email'] as String?;
      final user = _users[email];
      if (email == null || user == null || user.password != body['password']) {
        return json(<String, dynamic>{
          'detail': 'The email or password provided is incorrect.',
        }, 400);
      }
      if (_twoStep.contains(email)) {
        final challenge = _issue('fake-challenge');
        _challenges[challenge] = email;
        return json(<String, dynamic>{
          'next_step': 'verify',
          'challenge_token': challenge,
          'expires_in': 300,
        });
      }
      final token = _issue('fake-token');
      _tokens[token] = email;
      lastIssued = token;
      return json(<String, dynamic>{
        ..._user(email),
        'token': token,
        'token_type': 'Bearer',
        'expires_at': null,
      });
    }
    if (path == '/api/v1/auths/mfa/verify' && request.method == 'POST') {
      final body =
          jsonDecode(await utf8.decodeStream(request)) as Map<String, dynamic>;
      final email = _challenges.remove(body['challenge_token']);
      if (email == null) {
        return json(<String, dynamic>{'detail': 'Challenge expired'}, 401);
      }
      final token = _issue('fake-token');
      _tokens[token] = email;
      return json(<String, dynamic>{'token': token});
    }

    if (turnAway) {
      await request.drain<void>();
      // The proxy's own sign-in page is served, not sent to itself again.
      if (path == '/oauth2/start') {
        response
          ..headers.contentType = ContentType.html
          ..write('<html><body>Proxy sign-in</body></html>');
        return response.close();
      }
      response
        ..statusCode = HttpStatus.found
        ..headers.set(
          HttpHeaders.locationHeader,
          'http://127.0.0.1:${_server.port}/oauth2/start',
        );
      await response.close();
      return;
    }

    if (models.isNotEmpty && path.startsWith('/ws/socket.io')) {
      return chats._socket(request);
    }
    final bearer = request.headers.value('authorization');
    final token = bearer != null && bearer.startsWith('Bearer ')
        ? bearer.substring(7)
        : null;
    final email = token == null ? null : _tokens[token];
    if (email == null) {
      await request.drain<void>();
      return json(<String, dynamic>{'detail': 'Not authenticated'}, 401);
    }
    if (models.isNotEmpty &&
        await chats._handle(request, path, _users[email]!)) {
      return;
    }
    await request.drain<void>();
    if (path == '/api/v1/auths/' || path == '/api/v1/auths') {
      final hold = holdSessionCheck;
      if (hold != null) {
        holdSessionCheck = null;
        if (!sessionChecked.isCompleted) sessionChecked.complete();
        await hold.future;
      }
      return json(_user(email));
    }
    if (path.startsWith('/api/v1/auths/signout')) {
      signedOut.add(email);
      _tokens.remove(token);
      return json(<String, dynamic>{'status': true});
    }
    if (path == '/api/models' || path == '/api/v1/models') {
      return json(<String, dynamic>{
        'data': <Object>[
          for (final id in models)
            <String, dynamic>{
              'id': id,
              'name': id,
              'object': 'model',
              'owned_by': 'openai',
            },
        ],
      });
    }
    if (path == '/api/v1/users/user/settings' && request.method == 'GET') {
      if (holdSettings case final hold?) {
        if (settingsToPass > 0) {
          settingsToPass--;
        } else {
          if (!settingsAsked.isCompleted) settingsAsked.complete();
          await hold.future;
        }
      }
    }
    if (path.endsWith('/settings') || path.endsWith('/permissions')) {
      return json(<String, dynamic>{});
    }
    return json(request.method == 'GET' ? <Object>[] : <String, dynamic>{});
  }

  Map<String, dynamic> _user(String email) {
    final user = _users[email]!;
    return <String, dynamic>{
      'id': user.id,
      'email': email,
      'name': user.name,
      'role': 'user',
      'profile_image_url': '/user.png',
      'permissions': <String, dynamic>{},
    };
  }
}

/// A server's sessions, by token, and how many tokens it has issued: shared
/// by every listener of that one server ([FakeOwuiAuthServer.shareSessionsOf]).
final class _Sessions {
  final Map<String, String> tokens = <String, String>{};
  var issued = 0;
}

/// The chats of a [FakeOwuiAuthServer] that takes sends, as Open WebUI
/// serves the core's client: a Socket.IO session over Engine.IO (a
/// websocket, or long-polling) on `/ws/socket.io/`, `POST /api/v1/chats/new` to
/// make a chat, `GET`/`POST /api/v1/chats/{id}` to read and save it, and
/// `POST /api/chat/completions` to answer with [answer]: run as a task whose
/// words arrive as `chat:completion` events on the socket, or, sent with no
/// socket session, streamed in the response. Every completion asked for is
/// in [completions].
///
/// [holdAdmission], while set, keeps a completion request waiting after its
/// turn is stored, before its task starts: [admissionAsked] completes as one
/// reaches it. Hold a send in a chat already made: a held first send of a
/// new chat loses its answer here, which it does not against Open WebUI.
/// [holdStream], while set, is taken by the next answer to start: that one
/// keeps running after its first word until the hold is completed or its
/// task is stopped (counted in [stopped]).
/// [refusal], while set, refuses each completion let through admission with
/// it, as Open WebUI's 400.
/// [runElsewhere] starts an answer as another device would; a completion
/// sent under it while it runs is held as Open WebUI 0.13.4 holds one
/// (`{queued: true}`), and answered under new ids once it ends.
final class FakeOwuiChats {
  /// The answer every completion streams.
  String answer = 'The kettle is on.';

  final Map<String, Map<String, dynamic>> stored =
      <String, Map<String, dynamic>>{};

  /// The body of every completion request, in order.
  final List<Map<String, dynamic>> completions = <Map<String, dynamic>>[];

  Completer<void>? holdAdmission;
  Completer<void> admissionAsked = Completer<void>();

  Completer<void>? holdStream;

  /// Completes once a completion's task is running here, as Open WebUI
  /// registers it before it answers the request.
  Completer<void> taskStarted = Completer<void>();

  /// While set, taken by the next answer to start, whose first word waits
  /// for it: a model that is slow to start, so the client is listening by
  /// then.
  Completer<void>? holdFirstWord;

  Map<String, dynamic>? refusal;

  /// While set, reads of a chat it keeps (`GET /api/v1/chats/{id}`) wait for
  /// it, once [chatReadsToPass] more reads have gone through; [chatReadAsked]
  /// completes as one reaches it.
  Completer<void>? holdChatReads;
  int chatReadsToPass = 0;
  Completer<void> chatReadAsked = Completer<void>();

  /// While set, the first page of the chat list (`GET /api/v1/chats/`)
  /// waits for it: a sync cycle, which starts there, reads no chat until it
  /// completes, while a pull of one chat reads it as before.
  Completer<void>? holdChatLists;

  /// While set, saves of a chat it keeps (`POST /api/v1/chats/{id}`) wait
  /// for it; [chatSaveAsked] completes as one reaches it.
  Completer<void>? holdChatSaves;
  Completer<void> chatSaveAsked = Completer<void>();

  /// While set, [holdChatSaves] holds only this chat's saves.
  String? holdChatSavesOf;

  /// Completed with the chat's id, and cleared, once a save of a chat it
  /// keeps is applied.
  Completer<String>? chatSaved;

  /// While set, a message delete (`DELETE /api/v1/chats/{id}/messages/{id}`)
  /// is done, and its answer waits for it; [messageDeleteAsked] completes as
  /// one reaches it.
  Completer<void>? holdMessageDeletes;
  Completer<void> messageDeleteAsked = Completer<void>();

  /// A held chat read or save, once let go, loses its connection instead of
  /// being answered, as when the network drops.
  bool dropHeldChats = false;

  /// The answers streaming in a response, held after their first word.
  final Set<Completer<void>> _streamHolds = <Completer<void>>{};

  /// The stream holds the running tasks took.
  final Map<String, Completer<void>> _holds = <String, Completer<void>>{};

  /// Task ids stopped, by `/api/tasks/stop/{id}` or with their chat's
  /// (`/api/tasks/chat/{id}/stop`).
  final List<String> stopped = <String>[];

  /// The running tasks, by id, and the chat each answers in.
  final Map<String, String> _running = <String, String>{};

  var _made = 0;
  var _tasks = 0;

  /// Answers [runElsewhere] started that are still running, by message id.
  final Set<String> _elsewhere = <String>{};

  /// Completion requests held behind an answer running elsewhere.
  final List<Map<String, dynamic>> heldCompletions = <Map<String, dynamic>>[];

  /// While set, the end of an answer [runElsewhere] answers a message held
  /// alone under it in place, under its own id, rather than as a copy under
  /// a new one. Several held under it are still answered as one copy, as
  /// Open WebUI keeps a message's id only for a batch of one.
  bool answerHeldInPlace = false;

  /// Messages deleted with `DELETE /api/v1/chats/{id}/messages/{id}`, as
  /// `chatId/messageId`.
  final List<String> deletedMessages = <String>[];

  /// Moves [chatId]'s `updated_at` on, as Open WebUI does with each change
  /// it makes to a chat itself: a pull reads a chat whose date has not moved
  /// as unchanged. Never the same second twice, so a change made within the
  /// second of the last one still reads as one.
  void _touch(String chatId) {
    final row = stored[chatId]!;
    final now = clock.now().millisecondsSinceEpoch ~/ 1000;
    final last = row['updated_at'] as int? ?? 0;
    row['updated_at'] = now > last ? now : last + 1;
  }

  // The socket: one Engine.IO session at a time, over a websocket or by
  // long-polling (its packets for the client's next poll, and that poll
  // while it waits).
  WebSocket? _webSocket;
  String? _sid;
  var _sessions = 0;
  final List<String> _outgoing = <String>[];
  Completer<void>? _outgoingReady;
  var _closed = false;

  void _push(String packet) {
    if (_webSocket case final socket?) {
      try {
        socket.add(packet);
      } on StateError {
        // The client hung up: nothing more reaches it.
      }
      return;
    }
    _outgoing.add(packet);
    final ready = _outgoingReady;
    _outgoingReady = null;
    ready?.complete();
  }

  void _event(
    String chatId,
    String messageId,
    Map<String, dynamic> data,
  ) => _push(
    '42${jsonEncode(<Object>[
      'events',
      <String, dynamic>{'chat_id': chatId, 'message_id': messageId, 'data': data},
    ])}',
  );

  var _refusing = false;

  /// From now on the server offers no socket, as one behind a proxy that
  /// blocks it: the open one is closed and a new one refused, so sends go
  /// without a socket session.
  void refuseSockets() {
    _refusing = true;
    final socket = _webSocket;
    _webSocket = null;
    unawaited(socket?.close());
    _push('1');
  }

  var _stopped = false;

  /// The server process stops, as `kill` on it does: the socket closes, each
  /// request after it loses its connection unanswered, and a running answer
  /// stops where it is, with no `done`. Its stored copy stays not done and
  /// empty, as Open WebUI saves a reply's text only once the reply ends.
  void stopServer() {
    _stopped = true;
    for (final MapEntry(key: task, value: chatId)
        in _running.entries.toList()) {
      _running.remove(task);
      final open = _holds.remove(task);
      if (open != null && !open.isCompleted) open.complete();
      final messages =
          ((stored[chatId]?['chat'] as Map?)?['history'] as Map?)?['messages']
              as Map?;
      for (final message in messages?.values ?? const <Object?>[]) {
        if (message is Map && message['done'] == false) message['content'] = '';
      }
    }
    final socket = _webSocket;
    _webSocket = null;
    unawaited(socket?.close());
    _push('1');
  }

  /// The server is started again after [stopServer], with no task running.
  void startServer() => _stopped = false;

  void _close() {
    _closed = true;
    _push('1');
    unawaited(_webSocket?.close());
    for (final hold in <Completer<void>?>[
      holdAdmission,
      holdStream,
      holdFirstWord,
      holdChatReads,
      holdChatSaves,
      holdMessageDeletes,
      ..._holds.values,
      ..._streamHolds,
    ]) {
      if (hold != null && !hold.isCompleted) hold.complete();
    }
  }

  /// Streams [answer] as server-sent events, word by word, into [message]
  /// (its stored copy) as it goes.
  Future<void> _streamTo(
    HttpResponse response,
    Map<String, dynamic>? message,
  ) async {
    response
      ..statusCode = 200
      ..bufferOutput = false
      ..headers.contentType = ContentType('text', 'event-stream');
    final words = answer.split(' ');
    final open = holdStream;
    holdStream = null;
    if (open != null) _streamHolds.add(open);
    try {
      for (var i = 0; i < words.length; i++) {
        message?['content'] = words.take(i + 1).join(' ');
        response.write(
          'data: ${jsonEncode(<String, dynamic>{
            'choices': <Object>[
              <String, dynamic>{
                'delta': <String, dynamic>{'content': i == 0 ? words[i] : ' ${words[i]}'},
              },
            ],
          })}\n\n',
        );
        await response.flush();
        if (i == 0 && open != null) await open.future;
      }
      message?['done'] = true;
      response.write('data: [DONE]\n\n');
      await response.close();
    } on Object {
      // The client stopped reading: the answer ends where it was.
    } finally {
      _streamHolds.remove(open);
    }
  }

  Future<void> _socket(HttpRequest request) async {
    Future<void> reply(int status, String body) async {
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType('text', 'plain', charset: 'UTF-8')
        ..write(body);
      try {
        await request.response.close();
      } on Object {
        // The client gave up on its poll.
      }
    }

    if (_refusing) return reply(HttpStatus.badRequest, 'Transport not allowed');
    if (WebSocketTransformer.isUpgradeRequest(request)) {
      final socket = await WebSocketTransformer.upgrade(request);
      if (_refusing) {
        await socket.close();
        return;
      }
      final session = ++_sessions;
      _sid = 'eio-$session';
      _outgoing.clear();
      _webSocket = socket;
      socket.add(
        '0${jsonEncode(<String, dynamic>{'sid': _sid, 'upgrades': <String>[], 'pingInterval': 25000, 'pingTimeout': 20000, 'maxPayload': 1000000})}',
      );
      socket.listen(
        (data) {
          // A Socket.IO CONNECT to the default namespace, with its auth.
          if (data is String && (data == '40' || data.startsWith('40{'))) {
            socket.add(
              '40${jsonEncode(<String, dynamic>{'sid': 'socket-$session'})}',
            );
          }
        },
        onDone: () {
          if (identical(_webSocket, socket)) _webSocket = null;
        },
        onError: (Object _) {},
      );
      return;
    }
    final sid = request.uri.queryParameters['sid'];
    if (sid == null) {
      if (request.method != 'GET' ||
          request.uri.queryParameters['transport'] != 'polling') {
        return reply(HttpStatus.badRequest, 'bad handshake');
      }
      _sid = 'eio-${++_sessions}';
      _outgoing.clear();
      return reply(
        HttpStatus.ok,
        '0${jsonEncode(<String, dynamic>{'sid': _sid, 'upgrades': <String>[], 'pingInterval': 25000, 'pingTimeout': 20000, 'maxPayload': 1000000})}',
      );
    }
    if (sid != _sid || _closed) {
      return reply(HttpStatus.badRequest, 'Invalid session');
    }
    if (request.method == 'POST') {
      final body = await utf8.decodeStream(request);
      for (final packet in body.split('\x1e')) {
        // A Socket.IO CONNECT to the default namespace, with its auth.
        if (packet == '40' || packet.startsWith('40{')) {
          _push(
            '40${jsonEncode(<String, dynamic>{'sid': 'socket-$_sessions'})}',
          );
        }
      }
      return reply(HttpStatus.ok, 'ok');
    }
    while (_outgoing.isEmpty && !_closed) {
      await (_outgoingReady ??= Completer<void>()).future;
    }
    final payload = _outgoing.join('\x1e');
    _outgoing.clear();
    return reply(HttpStatus.ok, payload);
  }

  /// A chat [id] of [userId]'s, already on the server and empty, as one
  /// made elsewhere; a send into it skips the new chat's first read-back.
  void seed(String id, {required String userId, String title = 'Lab notes'}) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    stored[id] = <String, dynamic>{
      'id': id,
      'user_id': userId,
      'title': title,
      'chat': <String, dynamic>{
        'id': id,
        'title': title,
        'models': <String>[],
        'history': <String, dynamic>{
          'messages': <String, dynamic>{},
          'currentId': null,
        },
        'messages': <Object>[],
        'params': <String, dynamic>{},
        'tags': <Object>[],
        'timestamp': now * 1000,
      },
      'created_at': now,
      'updated_at': now,
      'share_id': null,
      'archived': false,
      'pinned': false,
      'meta': <String, dynamic>{},
      'folder_id': null,
      'current_message_id': null,
      'tasks': null,
      'summary': null,
      'context_usage': null,
      'variables': <String, dynamic>{},
    };
  }

  /// An answer to [question] that another device of the chat's owner
  /// started, running at the end of [chatId]: its stored copy is not done,
  /// and its task is listed with the chat's. Completing the returned hold
  /// ends it, and answers the messages held under it ([heldCompletions]) as
  /// Open WebUI 0.13.4 does: each that nothing answers is replaced by a copy
  /// under a new id with its answer, and `chat:reload` announces them.
  Completer<void> runElsewhere(
    String chatId, {
    String question = 'Write the shopping list',
  }) {
    final chat = stored[chatId]!['chat'] as Map<String, dynamic>;
    final history = chat['history'] as Map<String, dynamic>;
    final messages = history['messages'] as Map<String, dynamic>;
    final n = ++_tasks;
    final questionId = 'elsewhere-question-$n';
    final answerId = 'elsewhere-answer-$n';
    final parentId = history['currentId'] as String?;
    if (parentId != null) {
      final parent = messages[parentId] as Map<String, dynamic>;
      parent['childrenIds'] = <Object?>[
        ...parent['childrenIds'] as List? ?? const [],
        questionId,
      ];
    }
    messages[questionId] = <String, dynamic>{
      'id': questionId,
      'parentId': parentId,
      'childrenIds': <String>[answerId],
      'role': 'user',
      'content': question,
      'timestamp': clock.now().millisecondsSinceEpoch ~/ 1000,
    };
    messages[answerId] = <String, dynamic>{
      'id': answerId,
      'parentId': questionId,
      'childrenIds': <String>[],
      'role': 'assistant',
      'content': 'Eggs,',
      'model': 'kettle-model',
      'timestamp': clock.now().millisecondsSinceEpoch ~/ 1000,
      'done': false,
    };
    history['currentId'] = answerId;
    _touch(chatId);
    _elsewhere.add(answerId);
    _running['task-$n'] = chatId;
    final ends = Completer<void>();
    unawaited(
      ends.future.then((_) {
        _running.remove('task-$n');
        _elsewhere.remove(answerId);
        // The chat as stored now: a save while it ran replaced its history.
        final history = (stored[chatId]?['chat'] as Map?)?['history'] as Map?;
        final answer = (history?['messages'] as Map?)?[answerId] as Map?;
        if (answer != null) {
          answer['content'] = 'Eggs, flour.';
          answer['done'] = true;
        }
        _touch(chatId);
        _answerHeld(chatId, answerId);
      }),
    );
    return ends;
  }

  /// Holds [question], sent under [replyId] while it runs elsewhere.
  void _hold(String chatId, String replyId, Map<String, dynamic> question) {
    final chat = stored[chatId]!['chat'] as Map<String, dynamic>;
    final messages =
        (chat['history'] as Map<String, dynamic>)['messages']
            as Map<String, dynamic>;
    final id = question['id'] as String;
    messages[id] = <String, dynamic>{
      ...question,
      'parentId': replyId,
      'childrenIds': <String>[],
      'meta': <String, dynamic>{'status': 'pending'},
    };
    final reply = messages[replyId] as Map<String, dynamic>;
    reply['childrenIds'] = <Object?>[
      ...reply['childrenIds'] as List? ?? const [],
      id,
    ];
    _touch(chatId);
  }

  /// Answers the messages held under [replyId] that nothing answers: Open
  /// WebUI reads a message's answers from the messages naming it as parent.
  void _answerHeld(String chatId, String replyId) {
    final chat = stored[chatId]!['chat'] as Map<String, dynamic>;
    final history = chat['history'] as Map<String, dynamic>;
    final messages = history['messages'] as Map<String, dynamic>;
    final waiting = <Map<String, dynamic>>[
      for (final message in messages.values.cast<Map<String, dynamic>>())
        if (message['parentId'] == replyId &&
            (message['meta'] as Map?)?['status'] == 'pending' &&
            !messages.values.any(
              (other) => (other as Map)['parentId'] == message['id'],
            ))
          message,
    ];
    if (waiting.isEmpty) return;
    final n = ++_tasks;
    if (answerHeldInPlace && waiting.length == 1) {
      final question = waiting.single;
      final answerId = 'held-answer-$n';
      question['meta'] = <String, dynamic>{};
      question['childrenIds'] = <String>[answerId];
      messages[answerId] = <String, dynamic>{
        'id': answerId,
        'parentId': question['id'],
        'childrenIds': <String>[],
        'role': 'assistant',
        'content': answer,
        'model': 'kettle-model',
        'timestamp': clock.now().millisecondsSinceEpoch ~/ 1000,
        'done': true,
      };
      history['currentId'] = answerId;
      _touch(chatId);
      _event(chatId, answerId, <String, dynamic>{'type': 'chat:reload'});
      return;
    }
    final questionId = 'held-question-$n';
    final answerId = 'held-answer-$n';
    for (final message in waiting) {
      messages.remove(message['id']);
    }
    final reply = messages[replyId] as Map<String, dynamic>;
    reply['childrenIds'] = <Object?>[
      for (final child in reply['childrenIds'] as List? ?? const [])
        if (!waiting.any((m) => m['id'] == child)) child,
      questionId,
    ];
    messages[questionId] = <String, dynamic>{
      'id': questionId,
      'parentId': replyId,
      'childrenIds': <String>[answerId],
      'role': 'user',
      'content': waiting.map((m) => m['content']).join('\n\n'),
      'meta': <String, dynamic>{},
      'timestamp': clock.now().millisecondsSinceEpoch ~/ 1000,
    };
    messages[answerId] = <String, dynamic>{
      'id': answerId,
      'parentId': questionId,
      'childrenIds': <String>[],
      'role': 'assistant',
      'content': answer,
      'model': 'kettle-model',
      'timestamp': clock.now().millisecondsSinceEpoch ~/ 1000,
      'done': true,
    };
    history['currentId'] = answerId;
    _touch(chatId);
    _event(chatId, answerId, <String, dynamic>{'type': 'chat:reload'});
  }

  /// Answers [request] when it is one of a chat's: true then.
  Future<bool> _handle(
    HttpRequest request,
    String path,
    ({String id, String name, String password}) user,
  ) async {
    final userId = user.id;
    final response = request.response;
    Future<Map<String, dynamic>> body() async {
      final text = await utf8.decodeStream(request);
      return text.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(text) as Map<String, dynamic>;
    }

    Future<bool> json(Object? value, [int status = 200]) async {
      response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(value));
      await response.close();
      return true;
    }

    final post = request.method == 'POST';
    if (post && path == '/api/v1/chats/new') {
      final chat = Map<String, dynamic>.of(
        (await body())['chat'] as Map<String, dynamic>? ?? const {},
      );
      final id = 'chat-${++_made}';
      chat['id'] = id;
      // Its messages are the user's, as Open WebUI marks them
      // (`set_message_authors`).
      final history = chat['history'];
      for (final message in <Object?>[
        if (history is Map) ...(history['messages'] as Map? ?? const {}).values,
        ...chat['messages'] as List? ?? const [],
      ]) {
        if (message is! Map) continue;
        message['user_id'] = userId;
        if (message['role'] == 'user') {
          message['user'] = <String, dynamic>{'id': userId, 'name': user.name};
        }
      }
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final row = stored[id] = <String, dynamic>{
        'id': id,
        'user_id': userId,
        'title': chat['title'] ?? 'New Chat',
        'chat': chat,
        'created_at': now,
        'updated_at': now,
        'share_id': null,
        'archived': false,
        'pinned': false,
        'meta': <String, dynamic>{},
        'folder_id': null,
        'current_message_id': history is Map ? history['currentId'] : null,
        'tasks': null,
        'summary': null,
        'context_usage': null,
        'variables': <String, dynamic>{},
      };
      return json(row);
    }
    if (!post &&
        (path == '/api/v1/chats/' || path == '/api/v1/chats/list') &&
        (request.uri.queryParameters['page'] ?? '1') == '1') {
      await request.drain<void>();
      await holdChatLists?.future;
      return json(<Object>[
        for (final row in stored.values.toList().reversed)
          <String, dynamic>{
            'id': row['id'],
            'title': row['title'],
            'updated_at': row['updated_at'],
            'created_at': row['created_at'],
            'last_read_at': null,
            'active': _running.containsValue(row['id']),
            'pending_approval': false,
            'archived': false,
          },
      ]);
    }
    // The pinned list leaves archived chats out; neither list is paged here.
    if (!post &&
        (path == '/api/v1/chats/pinned' || path == '/api/v1/chats/archived')) {
      await request.drain<void>();
      final archived = path.endsWith('/archived');
      return json(<Object>[
        for (final row in stored.values)
          if (archived
              ? row['archived'] == true
              : row['pinned'] == true && row['archived'] != true)
            <String, dynamic>{
              'id': row['id'],
              'title': row['title'],
              'updated_at': row['updated_at'],
              'created_at': row['created_at'],
              'last_read_at': null,
            },
      ]);
    }
    if (!post && path == '/api/v1/chats/archived/count') {
      await request.drain<void>();
      return json(stored.values.where((row) => row['archived'] == true).length);
    }
    final deleted = RegExp(r'^/api/v1/chats/([^/]+)/messages/([^/]+)$')
        .firstMatch(path);
    if (request.method == 'DELETE' &&
        deleted != null &&
        stored.containsKey(deleted[1])) {
      await request.drain<void>();
      final row = stored[deleted[1]!]!;
      final history =
          (row['chat'] as Map<String, dynamic>)['history']
              as Map<String, dynamic>;
      final messages = history['messages'] as Map<String, dynamic>;
      final gone = messages.remove(deleted[2]) as Map<String, dynamic>?;
      if (gone != null) {
        deletedMessages.add('${deleted[1]}/${deleted[2]}');
        final parent = messages[gone['parentId']] as Map<String, dynamic>?;
        if (parent != null) {
          parent['childrenIds'] = <Object?>[
            for (final child in parent['childrenIds'] as List? ?? const [])
              if (child != deleted[2]) child,
          ];
        }
        if (history['currentId'] == deleted[2]) {
          history['currentId'] = gone['parentId'];
        }
        _touch(deleted[1]!);
      }
      if (holdMessageDeletes case final held?) {
        if (!messageDeleteAsked.isCompleted) messageDeleteAsked.complete();
        await held.future;
      }
      return json(row);
    }
    final chatId = RegExp(r'^/api/v1/chats/([^/]+)$').firstMatch(path)?[1];
    // A chat it does not keep (the core reads a new chat's own id before
    // the server has made it) is not found, as Open WebUI answers it.
    if (chatId != null &&
        !stored.containsKey(chatId) &&
        RegExp(r'^([0-9a-f]{8}-[0-9a-f-]{27}|chat-\d+)$').hasMatch(chatId)) {
      await request.drain<void>();
      return json(<String, dynamic>{
        'detail': "We could not find what you're looking for :/",
      }, 401);
    }
    if (chatId != null && stored.containsKey(chatId)) {
      final row = stored[chatId]!;
      var held = !post
          ? holdChatReads
          : holdChatSavesOf == null || holdChatSavesOf == chatId
          ? holdChatSaves
          : null;
      if (held != null && !post && chatReadsToPass > 0) {
        chatReadsToPass--;
        held = null;
      }
      if (held != null) {
        final asked = post ? chatSaveAsked : chatReadAsked;
        if (!asked.isCompleted) asked.complete();
        await held.future;
        if (dropHeldChats) {
          final socket = await response.detachSocket(writeHeaders: false);
          socket.destroy();
          return true;
        }
      }
      if (post) {
        final chat = (await body())['chat'];
        if (chat is Map<String, dynamic>) {
          final before = row['chat'] as Map<String, dynamic>;
          row['chat'] = <String, dynamic>{...before, ...chat};
          _keepUnfinishedAnswers(before, row['chat'] as Map<String, dynamic>);
          if (chat['title'] case final String title) row['title'] = title;
          row['updated_at'] = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          final saved = chatSaved;
          chatSaved = null;
          saved?.complete(chatId);
        }
      } else {
        await request.drain<void>();
      }
      return json(row);
    }
    if (post && path == '/api/chat/completions') {
      final asked = await body();
      completions.add(asked);
      final chat = asked['chat_id'] as String?;
      final id = asked['id'] as String?;
      if (chat == null || id == null) {
        return json(<String, dynamic>{'detail': 'no chat'}, 400);
      }
      final parentId = asked['parent_id'] as String?;
      final question = asked['user_message'] as Map<String, dynamic>?;
      if (parentId != null &&
          question != null &&
          _elsewhere.contains(parentId) &&
          stored.containsKey(chat)) {
        heldCompletions.add(asked);
        _hold(chat, parentId, question);
        return json(<String, dynamic>{
          'status': true,
          'queued': true,
          'chat_id': chat,
        });
      }
      // The question and its answer are in the stored chat before the task
      // starts, as Open WebUI writes the turn first; the answer fills in
      // while the task runs.
      final message = _answerIn(
        chat,
        id: id,
        question: asked['user_message'] as Map<String, dynamic>?,
        model: asked['model'] as String?,
      );
      final held = holdAdmission;
      if (!admissionAsked.isCompleted) admissionAsked.complete();
      if (held != null) await held.future;
      if (refusal case final refused?) return json(refused, 400);
      if (asked['session_id'] == null) {
        // No socket to send it on: the answer streams in the response.
        await _streamTo(response, message);
        return true;
      }
      final task = 'task-${++_tasks}';
      _running[task] = chat;
      if (!taskStarted.isCompleted) taskStarted.complete();
      unawaited(_run(task, chat, id, message));
      return json(<String, dynamic>{
        'status': true,
        'task_ids': <String>[task],
        'chat_id': chat,
      });
    }
    if (post && path.startsWith('/api/tasks/stop/')) {
      await request.drain<void>();
      final task = path.substring('/api/tasks/stop/'.length);
      stopped.add(task);
      _running.remove(task);
      final open = _holds.remove(task);
      if (open != null && !open.isCompleted) open.complete();
      return json(<String, dynamic>{'status': true});
    }
    final stopChat = RegExp(r'^/api/tasks/chat/([^/]+)/stop$')
        .firstMatch(path)?[1];
    if (post && stopChat != null) {
      await request.drain<void>();
      final tasks = <String>[
        for (final MapEntry(:key, :value) in _running.entries)
          if (value == stopChat) key,
      ];
      for (final task in tasks) {
        stopped.add(task);
        _running.remove(task);
        final open = _holds.remove(task);
        if (open != null && !open.isCompleted) open.complete();
      }
      if (tasks.isEmpty) _finishUnfinished(stopChat, userId);
      return json(<String, dynamic>{'status': true});
    }
    if (path.startsWith('/api/tasks/chat/')) {
      await request.drain<void>();
      final chat = path.substring('/api/tasks/chat/'.length);
      return json(<String, dynamic>{
        'task_ids': <String>[
          for (final MapEntry(:key, :value) in _running.entries)
            if (value == chat) key,
        ],
      });
    }
    if (post && path == '/api/chat/completed') {
      return json(await body());
    }
    return false;
  }

  /// `update_chat_by_id`'s guard (Open WebUI 0.13.2 and 0.13.4,
  /// `models/chats.py`): an assistant message stored as not done, or sent
  /// as not done, keeps its stored copy, whatever a save sends; the stored
  /// copy is kept as it is, so a task still writing it goes on doing so.
  static void _keepUnfinishedAnswers(
    Map<String, dynamic> before,
    Map<String, dynamic> saved,
  ) {
    final stored = (before['history'] as Map?)?['messages'] as Map?;
    final history = saved['history'];
    if (stored == null ||
        history is! Map ||
        identical(history, before['history'])) {
      return;
    }
    final messages = <String, dynamic>{
      ...?(history['messages'] as Map?)?.cast<String, dynamic>(),
    };
    for (final MapEntry(:key, :value) in stored.entries) {
      final sent = messages[key];
      if (value is Map &&
          value['role'] == 'assistant' &&
          (value['done'] == false || (sent is Map && sent['done'] == false))) {
        messages[key as String] = value;
      }
    }
    saved['history'] = <String, dynamic>{
      ...history.cast<String, dynamic>(),
      'messages': messages,
    };
  }

  /// A chat's stop with no task of [userId]'s running there, as Open WebUI
  /// 0.13 answers it: each of the user's answers in [chatId] still not done is
  /// marked done, with the text it has stored and without moving the chat's
  /// `updated_at`, and the user's sockets hear that it ended.
  void _finishUnfinished(String chatId, String userId) {
    final row = stored[chatId];
    final messages =
        ((row?['chat'] as Map?)?['history'] as Map?)?['messages'] as Map?;
    for (final message in messages?.values ?? const <Object?>[]) {
      if (message is! Map ||
          message['role'] != 'assistant' ||
          message['done'] != false ||
          (message['user_id'] ?? row!['user_id']) != userId) {
        continue;
      }
      message['done'] = true;
      final id = message['id'] as String;
      _event(chatId, id, <String, dynamic>{
        'type': 'chat:completion',
        'data': <String, dynamic>{'done': true, 'output': null},
      });
      _event(chatId, id, <String, dynamic>{'type': 'chat:tasks:cancel'});
      _event(chatId, id, <String, dynamic>{
        'type': 'chat:active',
        'data': <String, dynamic>{'active': false},
      });
    }
  }

  /// Streams [task]'s answer [messageId] in [chatId], word by word, into
  /// [message] (its stored copy) and onto the socket; a stopped task ends
  /// where it was.
  Future<void> _run(
    String task,
    String chatId,
    String messageId,
    Map<String, dynamic>? message,
  ) async {
    final words = answer.split(' ');
    final open = holdStream;
    holdStream = null;
    if (open != null) _holds[task] = open;
    final first = holdFirstWord;
    holdFirstWord = null;
    if (first != null) {
      await first.future;
      if (!_running.containsKey(task)) return;
    }
    for (var i = 0; i < words.length; i++) {
      final content = words.take(i + 1).join(' ');
      message?['content'] = content;
      _event(chatId, messageId, <String, dynamic>{
        'type': 'chat:completion',
        'data': <String, dynamic>{'content': content},
      });
      if (i == 0 && open != null) await open.future;
      if (!_running.containsKey(task)) return;
    }
    message?['done'] = true;
    _running.remove(task);
    _holds.remove(task);
    _event(chatId, messageId, <String, dynamic>{
      'type': 'chat:completion',
      'data': <String, dynamic>{'done': true, 'content': answer},
    });
  }

  /// The answer [id] to [question], in [chatId]'s stored history, as Open
  /// WebUI adds them when it takes the completion; null for a chat it does
  /// not keep.
  Map<String, dynamic>? _answerIn(
    String chatId, {
    required String id,
    required Map<String, dynamic>? question,
    required String? model,
  }) {
    final row = stored[chatId];
    if (row == null) return null;
    final chat = row['chat'] as Map<String, dynamic>;
    final history = Map<String, dynamic>.of(
      chat['history'] as Map<String, dynamic>? ?? const {},
    );
    final messages = Map<String, dynamic>.of(
      history['messages'] as Map<String, dynamic>? ?? const {},
    );
    final questionId = question?['id'] as String?;
    if (questionId != null) {
      final asked = messages[questionId] = <String, dynamic>{
        ...question!,
        ...?messages[questionId] as Map<String, dynamic>?,
      };
      asked['childrenIds'] = <Object?>[
        ...asked['childrenIds'] as List? ?? const [],
        id,
      ];
    }
    final message = messages[id] = <String, dynamic>{
      'id': id,
      'parentId': questionId,
      'childrenIds': <String>[],
      'role': 'assistant',
      'content': '',
      'model': model,
      'modelName': model,
      'modelIdx': 0,
      'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'done': false,
    };
    history
      ..['messages'] = messages
      ..['currentId'] = id;
    chat['history'] = history;
    return message;
  }
}
