import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Just enough of an Open WebUI server on a loopback port to sign in to:
/// health, config, password sign-in (with a second step for the users in
/// `twoStep`, whose `mfa/verify` takes any code), the current user and
/// sign-out, for a fixed set of synthetic users. Every other authenticated read answers an
/// empty list (or, for the model list, an empty `data`), so the core's
/// background loads find an empty account rather than an error.
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
  Map<String, String> _tokens = <String, String>{};
  final Map<String, String> _challenges = <String, String>{};
  var _issued = 0;

  /// While set, the next current-user read (how a client checks a session
  /// it was just given) waits for it, once; [sessionChecked] completes when
  /// it arrives.
  Completer<void>? holdSessionCheck;
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

  /// Answers every signed-in request as a sign-in proxy whose session
  /// expired does: a redirect to its sign-in page.
  bool turnAway = false;

  /// A sign-in proxy in front of the server: a request without this cookie
  /// (`name=value`) is sent to the proxy's sign-in page, health checks too.
  final String? proxyCookie;

  /// Takes [other]'s sessions as its own, from now on: the same server
  /// reached another way (here, through a sign-in proxy).
  void shareSessionsOf(FakeOwuiAuthServer other) => _tokens = other._tokens;

  /// Ends every session server-side: their tokens are refused from now on.
  void revokeSessions() => _tokens.clear();

  /// How many sessions password sign-ins have been given.
  int get signIns => _issued;

  /// A session for [email], as a sign-in in a window would have made.
  String sessionFor(String email) {
    final token = 'fake-window-token-${++_issued}';
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

  Future<void> close() => _server.close(force: true);

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
      return json(<String, dynamic>{'version': '0.13.1'});
    }
    if (path == '/api/config') {
      return json(<String, dynamic>{
        'status': true,
        'name': 'Open WebUI',
        'version': '0.13.1',
        'default_locale': '',
        'oauth': <String, dynamic>{'providers': <String, dynamic>{}},
        'features': <String, dynamic>{
          'auth': true,
          'auth_trusted_header': false,
          'enable_ldap': false,
          'enable_api_key': true,
          'enable_signup': false,
          'enable_login_form': true,
          'enable_websocket': false,
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
        final challenge = 'fake-challenge-${++_issued}';
        _challenges[challenge] = email;
        return json(<String, dynamic>{
          'next_step': 'verify',
          'challenge_token': challenge,
          'expires_in': 300,
        });
      }
      final token = 'fake-token-${++_issued}';
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
      final token = 'fake-token-${++_issued}';
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

    final bearer = request.headers.value('authorization');
    final token = bearer != null && bearer.startsWith('Bearer ')
        ? bearer.substring(7)
        : null;
    final email = token == null ? null : _tokens[token];
    if (email == null) {
      await request.drain<void>();
      return json(<String, dynamic>{'detail': 'Not authenticated'}, 401);
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
      return json(<String, dynamic>{'data': <Object>[]});
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
