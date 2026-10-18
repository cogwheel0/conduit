import 'package:dio/dio.dart';
import 'package:meta/meta.dart';

import 'package:conduit_core/features/librechat/models/librechat_cookies.dart';
import 'package:conduit_core/features/librechat/models/librechat_server.dart';
import 'package:conduit_core/features/librechat/models/librechat_session.dart';
import 'package:conduit_core/features/librechat/services/librechat_errors.dart';
import 'package:conduit_core/features/librechat/services/librechat_http_client.dart';

/// Where a password sign-in landed.
@immutable
sealed class LibreChatSignInResult {
  const LibreChatSignInResult();
}

final class LibreChatSignedIn extends LibreChatSignInResult {
  const LibreChatSignedIn(this.session);

  final LibreChatSession session;
}

/// The account uses two-step verification: [tempToken] (valid five minutes)
/// goes back with a code from the authenticator app or a backup code.
final class LibreChatTwoFactorRequired extends LibreChatSignInResult {
  const LibreChatTwoFactorRequired(this.tempToken);

  final String tempToken;
}

/// Signs in to, renews and signs out of one LibreChat server.
///
/// It talks to the auth routes directly, outside any session handle, so it
/// carries cookies itself: the ones a response sets become the session's,
/// and renewal sends the session's own.
final class LibreChatAuthService {
  LibreChatAuthService(
    this.server, {
    HttpClientAdapter? adapter,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       _client = LibreChatHttpClient(
         server: server,
         adapter: adapter,
         clock: clock,
       );

  final LibreChatServer server;
  final LibreChatHttpClient _client;
  final DateTime Function() _clock;

  Dio get _dio => _client.dio;

  void close() => _client.close();

  /// Signs in with an email (or, on an LDAP server set up that way, a
  /// username) and password. The server picks local or LDAP itself.
  Future<LibreChatSignInResult> signIn({
    required String email,
    required String password,
  }) async {
    final response = await _post(
      '/api/auth/login',
      data: {'email': email.trim(), 'password': password},
      fallback: 'Sign-in failed.',
    );
    final data = response.data;
    if (data is Map && data['twoFAPending'] == true) {
      final tempToken = data['tempToken'];
      if (tempToken is String && tempToken.isNotEmpty) {
        return LibreChatTwoFactorRequired(tempToken);
      }
    }
    return LibreChatSignedIn(_sessionFrom(response, const LibreChatCookies()));
  }

  /// Finishes a two-step sign-in with an authenticator [code] or a
  /// [backupCode].
  Future<LibreChatSession> verifyTwoFactor({
    required String tempToken,
    String? code,
    String? backupCode,
  }) async {
    final trimmedCode = code?.replaceAll(RegExp(r'\s'), '');
    final trimmedBackup = backupCode?.trim();
    if ((trimmedCode == null || trimmedCode.isEmpty) &&
        (trimmedBackup == null || trimmedBackup.isEmpty)) {
      throw ArgumentError('A code or a backup code is required.');
    }
    final response = await _post(
      '/api/auth/2fa/verify-temp',
      data: {
        'tempToken': tempToken,
        if (trimmedCode != null && trimmedCode.isNotEmpty) 'token': trimmedCode,
        if ((trimmedCode == null || trimmedCode.isEmpty) &&
            trimmedBackup != null)
          'backupCode': trimmedBackup,
      },
      fallback: 'The code was not accepted.',
    );
    return _sessionFrom(response, const LibreChatCookies());
  }

  /// A session from cookies a web sign-in left behind (single sign-on): the
  /// server renews them into an access token.
  Future<LibreChatSession> sessionFromCookies(LibreChatCookies cookies) =>
      _renewWith(cookies, previousUser: null);

  /// Renews [current] with its refresh cookie: a [LibreChatSessionRenewer].
  ///
  /// Throws [LibreChatSessionExpiredException] when the server says the
  /// session is over, and a plain [LibreChatApiException] when it could not
  /// say (offline, overloaded, rate-limited).
  Future<LibreChatSession> renew(LibreChatSession current) =>
      _renewWith(current.cookies, previousUser: current.user);

  Future<LibreChatSession> _renewWith(
    LibreChatCookies cookies, {
    required LibreChatUser? previousUser,
  }) async {
    if (!cookies.hasRefreshToken) {
      throw const LibreChatSessionExpiredException();
    }
    final Response<dynamic> response;
    try {
      response = await _dio.post<dynamic>(
        '/api/auth/refresh',
        options: Options(
          extra: {
            LibreChatRequestExtra.authenticate: false,
            LibreChatRequestExtra.cookies: cookies,
          },
        ),
      );
    } on DioException catch (error) {
      final basePath = Uri.parse(server.baseUrl).path;
      if (_sessionIsOver(error.response, basePath: basePath)) {
        throw const LibreChatSessionExpiredException();
      }
      throw libreChatErrorOf(error, fallback: 'Could not renew the session.');
    }
    final data = response.data;
    final token = data is Map ? data['token'] : null;
    if (token is! String || token.isEmpty) {
      // LibreChat says no refresh cookie arrived with a 200 in plain text.
      // Any other body (a proxy's or captive portal's page, say) never
      // reached the server, so the session is kept for another try.
      if (data is String && data.trim() == _noRefreshCookieReply) {
        throw const LibreChatSessionExpiredException();
      }
      throw LibreChatApiException(
        message: 'The LibreChat server sent an unexpected renewal response.',
        statusCode: response.statusCode,
      );
    }
    final user =
        LibreChatUser.fromJson(data is Map ? data['user'] : null) ??
        previousUser;
    if (user == null) {
      throw const LibreChatApiException(
        message: 'The LibreChat server did not say who is signed in.',
      );
    }
    if (previousUser != null && user.id != previousUser.id) {
      throw const LibreChatSessionExpiredException(
        message: 'The LibreChat session now belongs to another user.',
      );
    }
    return LibreChatSession(
      accessToken: token,
      user: user,
      cookies: cookies.apply(_setCookies(response), now: _clock()),
    );
  }

  /// Ends [session] on the server, which forgets its refresh token. Best
  /// effort: a session that cannot be reached ends here all the same.
  Future<void> signOut(LibreChatSession session) async {
    try {
      await _dio.post<dynamic>(
        '/api/auth/logout',
        options: Options(
          headers: {'Authorization': 'Bearer ${session.accessToken}'},
          extra: {
            LibreChatRequestExtra.authenticate: false,
            LibreChatRequestExtra.cookies: session.cookies,
          },
          receiveTimeout: const Duration(seconds: 10),
        ),
      );
    } on DioException {
      // The token may already have lapsed; the refresh cookie is dropped
      // locally either way.
    }
  }

  Future<Response<dynamic>> _post(
    String path, {
    required Object data,
    required String fallback,
  }) async {
    try {
      return await _dio.post<dynamic>(
        path,
        data: data,
        options: Options(
          extra: const {LibreChatRequestExtra.authenticate: false},
        ),
      );
    } on DioException catch (error) {
      throw libreChatErrorOf(error, fallback: fallback);
    }
  }

  LibreChatSession _sessionFrom(
    Response<dynamic> response,
    LibreChatCookies base,
  ) {
    final data = response.data;
    final token = data is Map ? data['token'] : null;
    final user = LibreChatUser.fromJson(data is Map ? data['user'] : null);
    if (token is! String || token.isEmpty || user == null) {
      throw const LibreChatApiException(
        message: 'The LibreChat server sent an unexpected sign-in response.',
      );
    }
    return LibreChatSession(
      accessToken: token,
      user: user,
      cookies: base.apply(_setCookies(response), now: _clock()),
    );
  }

  /// What LibreChat's refresh route sends, with a 200, when the request
  /// carried no refresh cookie.
  static const String _noRefreshCookieReply = 'Refresh token not provided';

  /// What LibreChat's refresh route sends with a 403 for a session it ended.
  static const Set<String> _endedSessionRefusals = {
    'Invalid refresh token',
    'Invalid OpenID refresh token',
    'No session found',
  };

  /// Whether a refused renewal means the session is over.
  ///
  /// LibreChat ends a session with a 401, a 403 naming the token or session,
  /// or a redirect to its own `/login` (which a proxy may have moved under
  /// [basePath]). Any other 403 or redirect (a proxy, a ban, an SSO gateway's
  /// own sign-in page or a captive portal in front of the server) says
  /// nothing about the session, which is kept for another try.
  static bool _sessionIsOver(
    Response<dynamic>? response, {
    required String basePath,
  }) {
    final status = response?.statusCode;
    if (response == null || status == null) return false;
    if (status == 401) return true;
    if (status == 403) {
      final body = response.data;
      return body is String && _endedSessionRefusals.contains(body.trim());
    }
    if (status >= 300 && status < 400) {
      final location = Uri.tryParse(response.headers.value('location') ?? '');
      if (location == null || location.toString().isEmpty) return false;
      final request = response.requestOptions.uri;
      final target = request.resolveUri(location);
      return target.host == request.host &&
          (target.path == '/login' || target.path == '$basePath/login');
    }
    return false;
  }

  static List<String> _setCookies(Response<dynamic> response) =>
      response.headers['set-cookie'] ?? const <String>[];
}
