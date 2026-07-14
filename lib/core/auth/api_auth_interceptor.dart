import 'dart:async';

import 'package:dio/dio.dart';
import '../utils/debug_logger.dart';

/// Immutable authorization value captured for work that must remain bound to
/// the account session that created it, even if the shared [ApiService]
/// interceptor is updated before the queued request reaches [onRequest].
final class ApiAuthSnapshot {
  const ApiAuthSnapshot._(this._token, this._revision);

  final String? _token;
  final int _revision;
}

/// Consistent authentication interceptor for all API requests
/// Implements security requirements from OpenAPI specification
class ApiAuthInterceptor extends Interceptor {
  static const String authSnapshotExtraKey = 'conduit.api.auth_snapshot';

  String? _authToken;
  int _authRevision = 0;
  final Uri _serverUri;
  final Map<String, String> customHeaders;

  // Callbacks for auth events
  void Function()? onAuthTokenInvalid;
  Future<void> Function()? onTokenInvalidated;

  // Public endpoints that don't require authentication
  static const Set<String> _publicEndpoints = {
    '/health',
    '/api/v1/auths/signin',
    '/api/v1/auths/signup',
    '/api/v1/auths/ldap',
  };

  // Endpoints that have optional authentication (work without but better with)
  static const Set<String> _optionalAuthEndpoints = {
    '/api/config',
    '/api/models',
  };

  // Only a small set of session-validation endpoints should raise a
  // connection/auth issue. Most other 401/403 responses are endpoint-level
  // permissions or disabled features and should be handled locally.
  static const Set<String> _authFailureEndpoints = {
    '/api/v1/auths',
    '/api/v1/auths/',
  };

  ApiAuthInterceptor({
    required String serverUrl,
    String? authToken,
    this.onAuthTokenInvalid,
    this.onTokenInvalidated,
    this.customHeaders = const {},
  }) : _serverUri = Uri.parse(serverUrl),
       _authToken = authToken;

  void updateAuthToken(String? token) {
    if (token == _authToken) return;
    _authToken = token;
    _authRevision++;
  }

  String? get authToken => _authToken;

  ApiAuthSnapshot captureSnapshot() =>
      ApiAuthSnapshot._(_authToken, _authRevision);

  String _endpointPath(String rawPath) {
    final parsed = Uri.tryParse(rawPath);
    final path = parsed?.path ?? rawPath.split(RegExp(r'[?#]')).first;
    if (path.isEmpty) return '/';
    return path.startsWith('/') ? path : '/$path';
  }

  _EndpointAuthMode _authModeFor(String path) {
    if (_publicEndpoints.contains(path)) {
      return _EndpointAuthMode.public;
    }
    if (_optionalAuthEndpoints.contains(path)) {
      return _EndpointAuthMode.optional;
    }
    return _EndpointAuthMode.required;
  }

  bool _shouldNotifyAuthFailure(String path) {
    return _authFailureEndpoints.contains(path);
  }

  bool _targetsServerOrigin(RequestOptions options) {
    final Uri requestUri;
    try {
      requestUri = options.uri;
    } on FormatException {
      return false;
    }
    if (!requestUri.hasScheme && !requestUri.hasAuthority) return true;

    final requestScheme = requestUri.scheme.toLowerCase();
    final serverScheme = _serverUri.scheme.toLowerCase();
    return requestScheme == serverScheme &&
        requestUri.host.toLowerCase() == _serverUri.host.toLowerCase() &&
        _effectivePort(requestUri, requestScheme) ==
            _effectivePort(_serverUri, serverScheme);
  }

  int? _effectivePort(Uri uri, String scheme) {
    if (uri.hasPort) return uri.port;
    return switch (scheme) {
      'http' => 80,
      'https' => 443,
      _ => null,
    };
  }

  void _removeServerCredentials(RequestOptions options) {
    final serverCredentialHeaders = <String>{
      'authorization',
      ...customHeaders.keys.map((header) => header.toLowerCase()),
    };
    options.headers.removeWhere(
      (header, _) => serverCredentialHeaders.contains(header.toLowerCase()),
    );
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (!_targetsServerOrigin(options)) {
      // The shared Dio instance is also used for externally hosted images.
      // Never forward credentials belonging to the selected Open WebUI server
      // to an absolute URL on another origin.
      _removeServerCredentials(options);
      options.headers['Content-Type'] ??= 'application/json';
      options.headers['Accept'] ??= 'application/json';
      handler.next(options);
      return;
    }

    final path = _endpointPath(options.path);
    final authMode = _authModeFor(path);
    final snapshot = options.extra[authSnapshotExtraKey];
    if (snapshot is ApiAuthSnapshot &&
        (snapshot._revision != _authRevision ||
            snapshot._token != _authToken)) {
      handler.reject(
        DioException(
          requestOptions: options,
          type: DioExceptionType.cancel,
          error: 'Authorization session changed before request dispatch.',
        ),
      );
      return;
    }
    final token = snapshot is ApiAuthSnapshot ? snapshot._token : _authToken;

    if (authMode == _EndpointAuthMode.required) {
      if (token == null || token.isEmpty) {
        final error = DioException(
          requestOptions: options,
          response: Response(
            requestOptions: options,
            statusCode: 401,
            data: {'detail': 'Authentication required for this endpoint'},
          ),
          type: DioExceptionType.badResponse,
        );
        handler.reject(error);
        return;
      }
    }

    if (authMode != _EndpointAuthMode.public &&
        token != null &&
        token.isNotEmpty) {
      options.headers['Authorization'] = 'Bearer $token';
    }

    // Add custom headers from server config (with safety checks)
    if (customHeaders.isNotEmpty) {
      customHeaders.forEach((key, value) {
        final lowerKey = key.toLowerCase();
        if (lowerKey == 'authorization') {
          DebugLogger.warning(
            'Skipping reserved header override attempt: $key',
          );
          return;
        }
        options.headers[key] = value;
      });
    }

    // Add other common headers for API consistency
    options.headers['Content-Type'] ??= 'application/json';
    options.headers['Accept'] ??= 'application/json';

    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (!_targetsServerOrigin(err.requestOptions)) {
      handler.next(err);
      return;
    }

    final statusCode = err.response?.statusCode;
    // Classify the endpoint-relative path rather than the fully resolved URI.
    // The latter includes a configured Open WebUI base-path prefix and would
    // otherwise hide auth failures for subpath-hosted installations.
    final path = _endpointPath(err.requestOptions.path);

    final suppressAuthFailureNotification =
        err.requestOptions.extra['suppressAuthFailureNotification'] == true;
    if (statusCode case final code?
        when !suppressAuthFailureNotification && (code == 401 || code == 403)) {
      _handleAuthorizationError(path: path, statusCode: code);
    }

    handler.next(err);
  }

  void _handleAuthorizationError({
    required String path,
    required int statusCode,
  }) {
    final statusLabel = statusCode == 401 ? 'Unauthorized' : 'Forbidden';
    final authMode = _authModeFor(path);

    if (authMode == _EndpointAuthMode.required &&
        _shouldNotifyAuthFailure(path)) {
      _notifyAuthFailure(
        '$statusCode $statusLabel on required endpoint - '
        'notifying app without clearing token',
      );
      return;
    }

    DebugLogger.auth(
      '$statusCode on non-essential endpoint - keeping auth token',
    );
  }

  /// Clear auth token and notify callbacks
  /// Note: This should only be called for explicit logout, not for connection errors
  void _clearAuthToken() {
    updateAuthToken(null);
    final future = onTokenInvalidated?.call();
    if (future != null) {
      unawaited(future);
    }
  }

  void _notifyAuthFailure(String message) {
    DebugLogger.auth(message);
    onAuthTokenInvalid?.call();
  }

  /// Explicitly clear auth token for logout scenarios
  void clearAuthTokenForLogout() {
    _clearAuthToken();
  }
}

enum _EndpointAuthMode { public, optional, required }
