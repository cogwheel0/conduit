import 'dart:async';

import 'package:dio/dio.dart';
import '../utils/debug_logger.dart';

/// Consistent authentication interceptor for all API requests
/// Implements security requirements from OpenAPI specification
class ApiAuthInterceptor extends Interceptor {
  String? _authToken;
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
    String? authToken,
    this.onAuthTokenInvalid,
    this.onTokenInvalidated,
    this.customHeaders = const {},
  }) : _authToken = authToken;

  void updateAuthToken(String? token) {
    _authToken = token;
  }

  String? get authToken => _authToken;

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

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final path = options.path;
    final authMode = _authModeFor(path);
    final token = _authToken;

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
    final statusCode = err.response?.statusCode;
    final path = err.requestOptions.path;

    if (statusCode case final code? when code == 401 || code == 403) {
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
        '$statusCode $statusLabel on $path - '
        'notifying app without clearing token',
      );
      return;
    }

    DebugLogger.auth(
      '$statusCode on non-essential endpoint $path - keeping auth token',
    );
  }

  /// Clear auth token and notify callbacks
  /// Note: This should only be called for explicit logout, not for connection errors
  void _clearAuthToken() {
    _authToken = null;
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
