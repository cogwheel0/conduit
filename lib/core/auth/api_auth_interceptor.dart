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
    '/api/v1/auths/signup/enabled',
    '/api/v1/auths/ldap',
    '/api/v1/auths/trusted-header-auth',
    '/ollama/api/ps',
    '/ollama/api/version',
    '/docs',
    '/openapi.json',
    '/swagger',
    '/api/docs',
  };

  // Endpoints that have optional authentication (work without but better with)
  static const Set<String> _optionalAuthEndpoints = {
    '/api/config',
    '/api/models',
    '/api/v1/configs/models',
  };

  // Endpoints for features that can be disabled server-side.
  // A 403 on these indicates the feature is disabled, not an auth failure.
  static const Set<String> _featureEndpoints = {
    '/api/v1/folders/',
    '/api/v1/folders',
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

  /// Check if endpoint requires authentication based on OpenAPI spec
  bool _requiresAuth(String path) {
    // Direct public endpoint match
    if (_publicEndpoints.contains(path)) {
      return false;
    }

    // Check for partial matches (e.g., /ollama/* endpoints)
    for (final publicPattern in _publicEndpoints) {
      if (publicPattern.endsWith('*') &&
          path.startsWith(
            publicPattern.substring(0, publicPattern.length - 1),
          )) {
        return false;
      }
    }

    // Endpoints that support optional auth should not strictly require it
    if (_hasOptionalAuth(path)) {
      return false;
    }

    // All other endpoints require authentication per OpenAPI spec
    return true;
  }

  /// Check if endpoint is better with auth but works without
  bool _hasOptionalAuth(String path) {
    return _optionalAuthEndpoints.contains(path);
  }

  /// Check if endpoint is for a feature that can be disabled server-side.
  /// A 403 on these indicates feature disabled, not an auth failure.
  bool _isFeatureEndpoint(String path) {
    // Direct match for exact paths like /api/v1/folders or /api/v1/folders/
    if (_featureEndpoints.contains(path)) {
      return true;
    }
    // Check for folder sub-paths (e.g., /api/v1/folders/{id})
    if (path.startsWith('/api/v1/folders/')) {
      return true;
    }
    return false;
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final path = options.path;
    final requiresAuth = _requiresAuth(path);
    final hasOptionalAuth = _hasOptionalAuth(path);

    if (requiresAuth) {
      // Strictly required authentication
      if (_authToken == null || _authToken!.isEmpty) {
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
      options.headers['Authorization'] = 'Bearer $_authToken';
    } else if (hasOptionalAuth &&
        _authToken != null &&
        _authToken!.isNotEmpty) {
      // Optional authentication - add if available
      options.headers['Authorization'] = 'Bearer $_authToken';
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

    // Handle authentication errors consistently
    // IMPORTANT: Never auto-logout. Instead, notify the app to show connection issue page
    if (statusCode == 401) {
      // Do not clear the token for public or optional-auth endpoints.
      // A 401 here may indicate endpoint-level permission or server config,
      // not necessarily an expired/invalid token.
      final requiresAuth = _requiresAuth(path);
      final optionalAuth = _hasOptionalAuth(path);
      if (requiresAuth && !optionalAuth) {
        _notifyAuthFailure(
          '401 Unauthorized on $path - notifying app without clearing token',
        );
      } else {
        DebugLogger.auth(
          '401 on public/optional endpoint $path - keeping auth token',
        );
      }
    } else if (statusCode == 403) {
      // 403 on protected endpoints indicates insufficient permissions or invalid token
      // BUT 403 on feature endpoints indicates the feature is disabled server-side
      final requiresAuth = _requiresAuth(path);
      final optionalAuth = _hasOptionalAuth(path);
      final isFeatureEndpoint = _isFeatureEndpoint(path);
      if (isFeatureEndpoint) {
        DebugLogger.auth(
          '403 Forbidden on feature endpoint $path - feature likely disabled server-side',
        );
      } else if (requiresAuth && !optionalAuth) {
        _notifyAuthFailure(
          '403 Forbidden on protected endpoint $path - notifying app without clearing token',
        );
      } else {
        DebugLogger.auth(
          '403 Forbidden on public/optional endpoint $path - keeping auth token',
        );
      }
    }

    handler.next(err);
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
