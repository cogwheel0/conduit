import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// One request a [FakeLibreChatServer] received.
final class FakeLibreChatRequest {
  FakeLibreChatRequest(this.method, this.uri, this.headers, this.data);

  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final Object? data;

  String get path => uri.path;

  String? header(String name) {
    final lower = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == lower) return entry.value;
    }
    return null;
  }

  /// The request's cookies, by name.
  Map<String, String> get cookies => FakeLibreChatServer.parseCookieHeader(
    header('cookie'),
  );

  String? get bearer {
    final value = header('authorization');
    return value != null && value.startsWith('Bearer ')
        ? value.substring(7)
        : null;
  }
}

/// A user a [FakeLibreChatServer] knows.
final class FakeLibreChatUser {
  FakeLibreChatUser({
    required this.id,
    required this.email,
    required this.password,
    this.name,
    this.role = 'USER',
    this.totpCode,
    List<String>? backupCodes,
  }) : backupCodes = backupCodes ?? <String>[];

  final String id;
  final String email;
  final String password;
  /// Changed by a test to have the next refresh carry another name or role.
  String? name;
  String role;

  /// The one authenticator code this user's two-step check accepts, or null
  /// when the user has no two-step verification.
  final String? totpCode;
  final List<String> backupCodes;

  Map<String, dynamic> toJson() => <String, dynamic>{
    '_id': id,
    'id': id,
    'email': email,
    'name': ?name,
    'username': email.split('@').first,
    'role': role,
    'provider': 'local',
    'twoFactorEnabled': totpCode != null,
  };
}

/// What a route handler answers with.
final class FakeLibreChatResponse {
  FakeLibreChatResponse(
    this.statusCode, {
    this.body,
    this.contentType = 'application/json',
    this.setCookies = const <String>[],
    this.headers = const <String, String>{},
    this.stream,
  });

  FakeLibreChatResponse.json(
    Object? body, {
    int statusCode = 200,
    List<String> setCookies = const <String>[],
  }) : this(statusCode, body: jsonEncode(body), setCookies: setCookies);

  FakeLibreChatResponse.text(String body, {int statusCode = 200})
    : this(statusCode, body: body, contentType: 'text/html; charset=utf-8');

  final int statusCode;
  final String? body;
  final String contentType;
  final List<String> setCookies;
  final Map<String, String> headers;

  /// A streamed body, for server-sent events; [body] is ignored.
  final Stream<Uint8List>? stream;
}

typedef FakeLibreChatHandler =
    FutureOr<FakeLibreChatResponse> Function(
      FakeLibreChatRequest request,
      RegExpMatch match,
    );

/// A LibreChat v0.8.8 server for tests, as a Dio adapter.
///
/// It models what a native client trips over: the access token is a JWT that
/// lapses ([accessTokenTtl]); `/api/auth/refresh` reads only the refresh
/// cookie, rotates it and forgets the old one; sign-in refuses a foreign
/// `Origin`; and chat, agent and file routes refuse a User-Agent that does
/// not look like a browser's with uaParser's 200 "Illegal request" frame,
/// counting a [violations] point each time. Later features register their
/// routes with [on].
final class FakeLibreChatServer implements HttpClientAdapter {
  FakeLibreChatServer({
    DateTime Function()? clock,
    this.accessTokenTtl = const Duration(minutes: 15),
    this.baseUrl = 'https://chat.example.com',
  }) : _clock = clock ?? DateTime.now {
    _registerAuthRoutes();
    _registerConversationRoutes();
  }

  final DateTime Function() _clock;
  final Duration accessTokenTtl;
  final String baseUrl;

  final List<FakeLibreChatRequest> requests = <FakeLibreChatRequest>[];
  final Map<String, FakeLibreChatUser> _users = <String, FakeLibreChatUser>{};
  final List<_Route> _routes = <_Route>[];

  /// Live refresh tokens, to the user each belongs to.
  final Map<String, String> refreshTokens = <String, String>{};

  /// Access tokens the server has not revoked, to their user and the
  /// moment their `exp` claim passes.
  final Map<String, ({String userId, DateTime expires})> _accessTokens =
      <String, ({String userId, DateTime expires})>{};
  final Map<String, String> _tempTokens = <String, String>{};
  int _counter = 0;

  /// Requests refused for a non-browser User-Agent.
  int violations = 0;

  /// Called with each request before it is answered, to change what the
  /// server holds mid-sequence.
  void Function(FakeLibreChatRequest request)? onRequest;

  /// Calls to `/api/auth/refresh` that reached the session check.
  int refreshCalls = 0;

  /// When set, `/api/auth/refresh` waits for it before answering.
  Completer<void>? holdRefresh;

  /// The public startup config `/api/config` returns without a session.
  Map<String, dynamic> startupConfig = <String, dynamic>{
    'appTitle': 'LibreChat',
    'serverDomain': 'https://chat.example.com',
    'emailLoginEnabled': true,
    'registrationEnabled': true,
    'socialLoginEnabled': false,
    'socialLogins': <String>['openid', 'github', 'google'],
    'openidLoginEnabled': false,
    'githubLoginEnabled': false,
    'googleLoginEnabled': false,
    'passwordResetEnabled': false,
  };

  /// Conversations by id, as `GET /api/convos/:id` returns them.
  final Map<String, Map<String, dynamic>> conversations =
      <String, Map<String, dynamic>>{};

  /// Each conversation's messages, as `GET /api/messages/:id` returns them.
  final Map<String, List<Map<String, dynamic>>> messages =
      <String, List<Map<String, dynamic>>>{};

  /// Page size the conversation list uses when the request names none.
  int defaultPageSize = 25;

  /// Adds a conversation with [messageList]. [updatedAt] defaults to now.
  Map<String, dynamic> addConversation(
    String id, {
    String title = 'New Chat',
    DateTime? updatedAt,
    bool pinned = false,
    bool archived = false,
    String endpoint = 'Ollama',
    String? model = 'llama3.2',
    List<Map<String, dynamic>> messageList = const [],
  }) {
    final time = (updatedAt ?? _clock()).toUtc().toIso8601String();
    final conversation = <String, dynamic>{
      'conversationId': id,
      'title': title,
      'endpoint': endpoint,
      'model': ?model,
      'pinned': pinned,
      'isArchived': archived,
      'createdAt': time,
      'updatedAt': time,
    };
    conversations[id] = conversation;
    messages[id] = [
      for (final message in messageList) {...message, 'conversationId': id},
    ];
    return conversation;
  }

  FakeLibreChatUser addUser({
    String email = 'dev@example.com',
    String password = 'devpassword',
    String? name = 'Dev',
    String role = 'USER',
    String? totpCode,
    List<String>? backupCodes,
  }) {
    final user = FakeLibreChatUser(
      id: 'user${_users.length + 1}',
      email: email,
      password: password,
      name: name,
      role: role,
      totpCode: totpCode,
      backupCodes: backupCodes,
    );
    _users[user.id] = user;
    return user;
  }

  /// Registers [handler] for [method] requests whose path below the base
  /// matches [pattern] in full. Later registrations win.
  void on(String method, String pattern, FakeLibreChatHandler handler) =>
      _routes.insert(0, _Route(method, RegExp('^$pattern\$'), handler));

  /// Makes every access token issued so far lapse.
  void expireAccessTokens() => _accessTokens.clear();

  /// Ends every session, as when the refresh tokens lapse.
  void endSessions() {
    refreshTokens.clear();
    _accessTokens.clear();
  }

  /// The user an authenticated [request] belongs to, or null: null too
  /// once the token's `exp` has passed on [_clock], as jsonwebtoken checks.
  FakeLibreChatUser? userFor(FakeLibreChatRequest request) {
    final token = _accessTokens[request.bearer ?? ''];
    if (token == null || !_clock().isBefore(token.expires)) return null;
    return _users[token.userId];
  }

  static Map<String, String> parseCookieHeader(String? header) {
    final cookies = <String, String>{};
    if (header == null) return cookies;
    for (final part in header.split(';')) {
      final equals = part.indexOf('=');
      if (equals <= 0) continue;
      cookies[part.substring(0, equals).trim()] = part
          .substring(equals + 1)
          .trim();
    }
    return cookies;
  }

  /// Whether ua-parser-js would find a browser in [userAgent]. An
  /// approximation that holds for the strings Conduit sends and the ones it
  /// must never send; `tool/librechat_dev/ua_check.sh` is the real check.
  static bool looksLikeBrowser(String? userAgent) =>
      userAgent != null &&
      userAgent.startsWith('Mozilla/5.0 (') &&
      (userAgent.contains(' Safari/') || userAgent.contains(' Chrome/'));

  static final RegExp _browserGuardedPath = RegExp(
    r'^/api/(agents|files|assistants|permissions)(/|$)',
  );

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    final headers = <String, String>{
      for (final entry in options.headers.entries)
        entry.key: entry.value.toString(),
    };
    final request = FakeLibreChatRequest(
      options.method.toUpperCase(),
      uri,
      headers,
      options.data,
    );
    requests.add(request);
    onRequest?.call(request);

    final basePath = Uri.parse(baseUrl).path;
    final path = uri.path.startsWith(basePath)
        ? uri.path.substring(basePath.length)
        : uri.path;
    if (_browserGuardedPath.hasMatch(path) &&
        !path.startsWith('/api/agents/v1/') &&
        !looksLikeBrowser(request.header('user-agent'))) {
      violations++;
      return _render(
        FakeLibreChatResponse.text(
          'event: error\ndata: ${jsonEncode({'message': 'Illegal request'})}'
          '\n\n',
        ),
      );
    }

    for (final route in _routes) {
      if (route.method != request.method) continue;
      final match = route.pattern.firstMatch(path);
      if (match == null) continue;
      return _render(await route.handler(request, match));
    }
    return _render(FakeLibreChatResponse.text('Not Found', statusCode: 404));
  }

  ResponseBody _render(FakeLibreChatResponse response) {
    final headers = <String, List<String>>{
      'content-type': [response.contentType],
      if (response.setCookies.isNotEmpty) 'set-cookie': response.setCookies,
      for (final entry in response.headers.entries) entry.key: [entry.value],
    };
    final stream = response.stream;
    if (stream != null) {
      return ResponseBody(stream, response.statusCode, headers: headers);
    }
    return ResponseBody.fromString(
      response.body ?? '',
      response.statusCode,
      headers: headers,
    );
  }

  /// A signed-looking access token for [userId], accepted until [ttl] from
  /// now (to the second, as the `exp` claim says).
  String _jwt(String userId, Duration ttl) {
    final now = _clock().toUtc();
    String part(Map<String, Object> json) =>
        base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
    final exp = now.add(ttl).millisecondsSinceEpoch ~/ 1000;
    final payload = part({'id': userId, 'n': ++_counter, 'exp': exp});
    final token = '${part({'alg': 'HS256'})}.$payload.sig$_counter';
    _accessTokens[token] = (
      userId: userId,
      expires: DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true),
    );
    return token;
  }

  List<String> _issueSession(String userId) {
    final refresh = 'rt-$userId-${++_counter}';
    refreshTokens[refresh] = userId;
    final expires = _httpDate(_clock().toUtc().add(const Duration(days: 7)));
    return [
      'refreshToken=$refresh; Path=/; Expires=$expires; HttpOnly; Secure; '
          'SameSite=Strict',
      'token_provider=librechat; Path=/; Expires=$expires; HttpOnly; Secure; '
          'SameSite=Strict',
    ];
  }

  FakeLibreChatResponse _signedIn(FakeLibreChatUser user) {
    final token = _jwt(user.id, accessTokenTtl);
    return FakeLibreChatResponse.json({
      'token': token,
      'user': user.toJson(),
    }, setCookies: _issueSession(user.id));
  }

  /// LibreChat's `requireSameOrigin`: a request with an `Origin` (or
  /// `Sec-Fetch-Site`) must come from the server's own domain.
  FakeLibreChatResponse? _crossSite(FakeLibreChatRequest request) {
    final origin = request.header('origin');
    if (origin == null && request.header('sec-fetch-site') == null) {
      return null;
    }
    if (origin != null && origin == Uri.parse(baseUrl).origin) return null;
    return FakeLibreChatResponse.json({
      'message': 'Cross-site request rejected',
    }, statusCode: 403);
  }

  void _registerAuthRoutes() {
    on('GET', '/api/config', (request, _) {
      final user = userFor(request);
      return FakeLibreChatResponse.json({
        ...startupConfig,
        if (user != null) 'sharedLinksEnabled': true,
      });
    });

    on('POST', '/api/auth/login', (request, _) {
      final refused = _crossSite(request);
      if (refused != null) return refused;
      final body = request.data;
      final email = body is Map ? body['email'] : null;
      final password = body is Map ? body['password'] : null;
      final user = _users.values
          .where((user) => user.email == email)
          .firstOrNull;
      if (user == null) {
        return FakeLibreChatResponse.json({
          'message': 'Email does not exist.',
        }, statusCode: 404);
      }
      if (user.password != password) {
        return FakeLibreChatResponse.json({
          'message': 'Incorrect password.',
        }, statusCode: 404);
      }
      if (user.totpCode != null) {
        final tempToken = 'temp-${++_counter}';
        _tempTokens[tempToken] = user.id;
        return FakeLibreChatResponse.json({
          'twoFAPending': true,
          'tempToken': tempToken,
        });
      }
      return _signedIn(user);
    });

    on('POST', '/api/auth/2fa/verify-temp', (request, _) {
      final refused = _crossSite(request);
      if (refused != null) return refused;
      final body = request.data is Map ? request.data as Map : const {};
      final userId = _tempTokens[body['tempToken']];
      final user = userId == null ? null : _users[userId];
      if (user == null) {
        return FakeLibreChatResponse.json({
          'message': 'Invalid or expired temporary token',
        }, statusCode: 401);
      }
      final code = body['token'];
      final backup = body['backupCode'];
      final verified =
          (code != null && code == user.totpCode) ||
          (backup != null && user.backupCodes.remove(backup));
      if (!verified) {
        return FakeLibreChatResponse.json({
          'message': 'Invalid 2FA code or backup code',
        }, statusCode: 401);
      }
      _tempTokens.remove(body['tempToken']);
      return _signedIn(user);
    });

    on('POST', '/api/auth/refresh', (request, _) async {
      final hold = holdRefresh;
      if (hold != null) await hold.future;
      final token = request.cookies['refreshToken'];
      if (token == null) {
        return FakeLibreChatResponse.text('Refresh token not provided');
      }
      refreshCalls++;
      final userId = refreshTokens.remove(token);
      final user = userId == null ? null : _users[userId];
      if (user == null) {
        return FakeLibreChatResponse.text(
          'Refresh token expired or not found for this user',
          statusCode: 401,
        );
      }
      return _signedIn(user);
    });

    on('POST', '/api/auth/logout', (request, _) {
      final user = userFor(request);
      if (user == null) {
        return FakeLibreChatResponse.text('Unauthorized', statusCode: 401);
      }
      refreshTokens.remove(request.cookies['refreshToken']);
      _accessTokens.remove(request.bearer);
      final cleared = _httpDate(DateTime.utc(1970));
      return FakeLibreChatResponse.json(
        {'message': 'Logout successful'},
        setCookies: [
          'refreshToken=; Path=/; Expires=$cleared',
          'token_provider=; Path=/; Expires=$cleared',
        ],
      );
    });

    on('GET', '/api/user', (request, _) {
      final user = userFor(request);
      if (user == null) {
        return FakeLibreChatResponse.text('Unauthorized', statusCode: 401);
      }
      return FakeLibreChatResponse.json(user.toJson());
    });
  }

  FakeLibreChatResponse? _unauthorized(FakeLibreChatRequest request) =>
      userFor(request) == null
      ? FakeLibreChatResponse.text('Unauthorized', statusCode: 401)
      : null;

  void _registerConversationRoutes() {
    on('GET', '/api/convos', (request, _) {
      final refused = _unauthorized(request);
      if (refused != null) return refused;
      final query = request.uri.queryParameters;
      final archived = query['isArchived'] == 'true';
      final pinnedOnly = query['pinned'] == 'true';
      final limit = int.tryParse(query['limit'] ?? '') ?? defaultPageSize;
      final sorted =
          conversations.values
              .where(
                (c) =>
                    (c['isArchived'] == true) == archived &&
                    (!pinnedOnly || c['pinned'] == true),
              )
              .toList()
            ..sort(
              (a, b) =>
                  DateTime.parse(
                    b['updatedAt'] as String,
                  ).compareTo(DateTime.parse(a['updatedAt'] as String)),
            );
      final start = int.tryParse(
        utf8.decode(base64.decode(query['cursor'] ?? 'MA==')),
      )!;
      final page = sorted.skip(start).take(limit).toList();
      final next = start + limit < sorted.length
          ? base64.encode(utf8.encode('${start + limit}'))
          : null;
      return FakeLibreChatResponse.json({
        'conversations': page,
        'nextCursor': next,
      });
    });

    on('GET', '/api/convos/([^/]+)', (request, match) {
      final refused = _unauthorized(request);
      if (refused != null) return refused;
      final conversation = conversations[match.group(1)];
      return conversation == null
          ? FakeLibreChatResponse.json({'message': 'Not found'}, statusCode: 404)
          : FakeLibreChatResponse.json(conversation);
    });

    on('GET', '/api/messages/([^/]+)', (request, match) {
      final refused = _unauthorized(request);
      if (refused != null) return refused;
      return FakeLibreChatResponse.json(messages[match.group(1)] ?? const []);
    });

    FakeLibreChatResponse envelopeWrite(
      FakeLibreChatRequest request,
      void Function(Map<String, dynamic> conversation, Map arg) apply,
    ) {
      final refused = _unauthorized(request);
      if (refused != null) return refused;
      final body = request.data;
      final arg = body is Map && body['arg'] is Map ? body['arg'] as Map : {};
      final conversation = conversations[arg['conversationId']];
      if (conversation == null) {
        return FakeLibreChatResponse.json({
          'message': 'Conversation not found',
        }, statusCode: 404);
      }
      apply(conversation, arg);
      return FakeLibreChatResponse.json(conversation);
    }

    on(
      'POST',
      '/api/convos/update',
      (request, _) => envelopeWrite(request, (conversation, arg) {
        conversation['title'] = arg['title'];
        conversation['updatedAt'] = _clock().toUtc().toIso8601String();
      }),
    );
    // Pinning and archiving leave updatedAt alone, as LibreChat's do.
    on(
      'POST',
      '/api/convos/pin',
      (request, _) => envelopeWrite(
        request,
        (conversation, arg) => conversation['pinned'] = arg['pinned'],
      ),
    );
    on(
      'POST',
      '/api/convos/archive',
      (request, _) => envelopeWrite(
        request,
        (conversation, arg) => conversation['isArchived'] = arg['isArchived'],
      ),
    );
    on('DELETE', '/api/convos', (request, _) {
      final refused = _unauthorized(request);
      if (refused != null) return refused;
      final body = request.data;
      final id = body is Map && body['arg'] is Map
          ? (body['arg'] as Map)['conversationId']
          : null;
      final removed = conversations.remove(id);
      messages.remove(id);
      return FakeLibreChatResponse.json({
        'acknowledged': true,
        'deletedCount': removed == null ? 0 : 1,
      });
    });
  }

  static String _httpDate(DateTime time) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    String two(int value) => value.toString().padLeft(2, '0');
    final utc = time.toUtc();
    return '${days[utc.weekday - 1]}, ${two(utc.day)} ${months[utc.month - 1]} '
        '${utc.year} ${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)} '
        'GMT';
  }

  @override
  void close({bool force = false}) {}
}

final class _Route {
  _Route(this.method, this.pattern, this.handler);

  final String method;
  final RegExp pattern;
  final FakeLibreChatHandler handler;
}
