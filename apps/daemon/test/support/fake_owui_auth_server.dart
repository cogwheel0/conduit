import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Just enough of an Open WebUI server on a loopback port to sign in to:
/// health, config, password sign-in, the current user and sign-out, for a
/// fixed set of synthetic users. Every other authenticated read answers an
/// empty list (or, for the model list, an empty `data`), so the core's
/// background loads find an empty account rather than an error.
final class FakeOwuiAuthServer {
  FakeOwuiAuthServer._(this._server, this._users);

  final HttpServer _server;
  final Map<String, ({String id, String name, String password})> _users;
  final Map<String, String> _tokens = <String, String>{};
  var _issued = 0;

  /// The email of every user whose session was ended through sign-out.
  final List<String> signedOut = <String>[];

  /// The method and path of every request, in order.
  final List<String> requests = <String>[];

  String get url => 'http://127.0.0.1:${_server.port}';

  static Future<FakeOwuiAuthServer> start({
    required Map<String, ({String id, String name, String password})> users,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeOwuiAuthServer._(server, users);
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
      final token = 'fake-token-${++_issued}';
      _tokens[token] = email;
      return json(<String, dynamic>{
        ..._user(email),
        'token': token,
        'token_type': 'Bearer',
        'expires_at': null,
      });
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
