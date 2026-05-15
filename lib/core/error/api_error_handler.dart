import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'api_error.dart';
import 'error_parser.dart';
import '../utils/current_localizations.dart';
import '../utils/debug_logger.dart';

/// Comprehensive API error handler with structured error parsing
/// Handles all types of API errors and converts them to standardized format
class ApiErrorHandler {
  static final ApiErrorHandler _instance = ApiErrorHandler._internal();
  factory ApiErrorHandler() => _instance;
  ApiErrorHandler._internal();

  final ErrorParser _errorParser = ErrorParser();

  /// Transform any exception into standardized ApiError
  ApiError transformError(
    dynamic error, {
    String? endpoint,
    String? method,
    Map<String, dynamic>? requestData,
  }) {
    final l10n = currentAppLocalizations();
    try {
      if (error is DioException) {
        return _handleDioException(error, endpoint: endpoint, method: method);
      } else if (error is ApiError) {
        return error;
      } else {
        return ApiError.unknown(
          message: l10n.errorMessage,
          originalError: error,
          technical: error.toString(),
        );
      }
    } catch (e) {
      // Fallback error if transformation itself fails
      DebugLogger.log(
        'ApiErrorHandler: Error transforming exception: $e',
        scope: 'api/error-handler',
      );
      return ApiError.unknown(
        message: l10n.errorMessage,
        originalError: error,
        technical: 'Error transformation failed: $e',
      );
    }
  }

  /// Handle DioException with detailed error parsing
  ApiError _handleDioException(
    DioException dioError, {
    String? endpoint,
    String? method,
  }) {
    final l10n = currentAppLocalizations();
    final statusCode = dioError.response?.statusCode;
    final responseData = dioError.response?.data;
    final requestPath = endpoint ?? dioError.requestOptions.path;
    final httpMethod = method ?? dioError.requestOptions.method;

    // Log error details for debugging
    _logErrorDetails(dioError, requestPath, httpMethod);

    switch (dioError.type) {
      case DioExceptionType.connectionTimeout:
        return ApiError.timeout(
          message: l10n.networkTimeoutError,
          endpoint: requestPath,
          method: httpMethod,
          timeoutDuration: dioError.requestOptions.connectTimeout,
        );

      case DioExceptionType.sendTimeout:
        return ApiError.timeout(
          message: l10n.networkTimeoutError,
          endpoint: requestPath,
          method: httpMethod,
          timeoutDuration: dioError.requestOptions.sendTimeout,
        );

      case DioExceptionType.receiveTimeout:
        return ApiError.timeout(
          message: l10n.serverErrorTimeout,
          endpoint: requestPath,
          method: httpMethod,
          timeoutDuration: dioError.requestOptions.receiveTimeout,
        );

      case DioExceptionType.badCertificate:
        return ApiError.security(
          message: l10n.securityCertificateError,
          endpoint: requestPath,
          method: httpMethod,
        );

      case DioExceptionType.connectionError:
        return ApiError.network(
          message: l10n.networkGenericError,
          endpoint: requestPath,
          method: httpMethod,
          originalError: dioError,
        );

      case DioExceptionType.cancel:
        return ApiError.cancelled(
          message: l10n.errorMessage,
          endpoint: requestPath,
          method: httpMethod,
        );

      case DioExceptionType.badResponse:
        return _handleBadResponse(
          dioError,
          requestPath,
          httpMethod,
          statusCode,
          responseData,
        );

      case DioExceptionType.unknown:
        return ApiError.unknown(
          message: l10n.networkGenericError,
          endpoint: requestPath,
          method: httpMethod,
          originalError: dioError,
          technical: dioError.message,
        );
    }
  }

  /// Handle bad response errors with detailed status code analysis
  ApiError _handleBadResponse(
    DioException dioError,
    String requestPath,
    String httpMethod,
    int? statusCode,
    dynamic responseData,
  ) {
    final l10n = currentAppLocalizations();
    if (statusCode == null) {
      return ApiError.server(
        message: l10n.serverErrorGeneric,
        endpoint: requestPath,
        method: httpMethod,
        statusCode: null,
      );
    }

    switch (statusCode) {
      case 400:
        return _handleBadRequest(
          dioError,
          requestPath,
          httpMethod,
          responseData,
        );

      case 401:
        return ApiError.authentication(
          message: l10n.authSessionExpired,
          endpoint: requestPath,
          method: httpMethod,
          statusCode: statusCode,
        );

      case 403:
        return ApiError.authorization(
          message: l10n.authForbidden,
          endpoint: requestPath,
          method: httpMethod,
          statusCode: statusCode,
        );

      case 404:
        return ApiError.notFound(
          message: l10n.fileNotFound,
          endpoint: requestPath,
          method: httpMethod,
          statusCode: statusCode,
        );

      case 422:
        return _handleValidationError(
          dioError,
          requestPath,
          httpMethod,
          responseData,
        );

      case 429:
        return ApiError.rateLimit(
          message: l10n.rateLimitExceeded,
          endpoint: requestPath,
          method: httpMethod,
          statusCode: statusCode,
          retryAfter: _extractRetryAfter(dioError.response?.headers),
        );

      default:
        if (statusCode >= 500) {
          return _handleServerError(
            dioError,
            requestPath,
            httpMethod,
            statusCode,
            responseData,
          );
        } else {
          return ApiError.client(
            message: l10n.errorMessage,
            endpoint: requestPath,
            method: httpMethod,
            statusCode: statusCode,
            details: _errorParser.parseErrorResponse(responseData),
          );
        }
    }
  }

  /// Handle 400 Bad Request with detailed parsing
  ApiError _handleBadRequest(
    DioException dioError,
    String requestPath,
    String httpMethod,
    dynamic responseData,
  ) {
    final parsedError = _errorParser.parseErrorResponse(responseData);

    return ApiError.badRequest(
      message:
          parsedError.message ??
          currentAppLocalizations().validationGenericError,
      endpoint: requestPath,
      method: httpMethod,
      details: parsedError,
    );
  }

  /// Handle 422 Validation Error with field-specific parsing
  ApiError _handleValidationError(
    DioException dioError,
    String requestPath,
    String httpMethod,
    dynamic responseData,
  ) {
    final parsedError = _errorParser.parseValidationError(responseData);

    return ApiError.validation(
      message: currentAppLocalizations().validationGenericError,
      endpoint: requestPath,
      method: httpMethod,
      fieldErrors: parsedError.fieldErrors,
      details: parsedError,
    );
  }

  /// Handle server errors (5xx)
  ApiError _handleServerError(
    DioException dioError,
    String requestPath,
    String httpMethod,
    int statusCode,
    dynamic responseData,
  ) {
    final parsedError = _errorParser.parseErrorResponse(responseData);
    final l10n = currentAppLocalizations();

    String message;
    switch (statusCode) {
      case 500:
        message = l10n.serverError500;
        break;
      case 502:
        message = l10n.serverErrorUnavailable;
        break;
      case 503:
        message = l10n.serverErrorUnavailable;
        break;
      case 504:
        message = l10n.serverErrorTimeout;
        break;
      default:
        message = l10n.serverErrorGeneric;
    }

    return ApiError.server(
      message: message,
      endpoint: requestPath,
      method: httpMethod,
      statusCode: statusCode,
      details: parsedError,
    );
  }

  /// Extract retry-after header for rate limiting
  Duration? _extractRetryAfter(Headers? headers) {
    if (headers == null) return null;

    final retryAfterHeader =
        headers.value('retry-after') ??
        headers.value('Retry-After') ??
        headers.value('X-RateLimit-Reset-After');

    if (retryAfterHeader != null) {
      final seconds = int.tryParse(retryAfterHeader);
      if (seconds != null) {
        return Duration(seconds: seconds);
      }
    }

    return null;
  }

  /// Log error details for debugging and monitoring
  void _logErrorDetails(
    DioException dioError,
    String requestPath,
    String httpMethod,
  ) {
    if (kDebugMode) {
      DebugLogger.log('🔴 API Error Details:', scope: 'api/error-handler');
      DebugLogger.log(
        '  Method: ${httpMethod.toUpperCase()}',
        scope: 'api/error-handler',
      );
      DebugLogger.log('  Endpoint: $requestPath', scope: 'api/error-handler');
      DebugLogger.log('  Type: ${dioError.type}', scope: 'api/error-handler');
      DebugLogger.log(
        '  Status: ${dioError.response?.statusCode}',
        scope: 'api/error-handler',
      );

      if (dioError.response?.data != null) {
        DebugLogger.error('Response data available (truncated for security)');
      }

      if (dioError.requestOptions.data != null) {
        DebugLogger.log(
          '  Request Data: ${dioError.requestOptions.data}',
          scope: 'api/error-handler',
        );
      }

      DebugLogger.log(
        '  Error: ${dioError.message}',
        scope: 'api/error-handler',
      );
    }

    // In production, you would send this to your error tracking service
    // FirebaseCrashlytics.instance.recordError(dioError, stackTrace);
    // Sentry.captureException(dioError);
  }

  /// Check if error is retryable
  bool isRetryable(ApiError error) {
    switch (error.type) {
      case ApiErrorType.timeout:
      case ApiErrorType.network:
      case ApiErrorType.server:
        return true;
      case ApiErrorType.rateLimit:
        return true; // Can retry after waiting
      case ApiErrorType.authentication:
        return false; // Need new token
      case ApiErrorType.authorization:
      case ApiErrorType.notFound:
      case ApiErrorType.validation:
      case ApiErrorType.badRequest:
        return false; // Client errors aren't retryable
      case ApiErrorType.cancelled:
      case ApiErrorType.security:
      case ApiErrorType.unknown:
        return false;
    }
  }

  /// Get suggested retry delay for retryable errors
  Duration? getRetryDelay(ApiError error) {
    if (!isRetryable(error)) return null;

    switch (error.type) {
      case ApiErrorType.rateLimit:
        return error.retryAfter ?? const Duration(minutes: 1);
      case ApiErrorType.timeout:
        return const Duration(seconds: 5);
      case ApiErrorType.network:
        return const Duration(seconds: 3);
      case ApiErrorType.server:
        return const Duration(seconds: 10);
      default:
        return const Duration(seconds: 5);
    }
  }

  /// Get user-friendly error message with actionable advice
  String getUserMessage(ApiError error) {
    final baseMessage = error.message;
    final l10n = currentAppLocalizations();

    // Add actionable advice based on error type
    switch (error.type) {
      case ApiErrorType.network:
        return '$baseMessage\n\n${l10n.pleaseCheckConnection}';
      case ApiErrorType.timeout:
        return '$baseMessage\n\n${l10n.requestTimedOut}';
      case ApiErrorType.authentication:
        return _withDistinctAdvice(baseMessage, l10n.authSessionExpired);
      case ApiErrorType.authorization:
        return _withDistinctAdvice(baseMessage, l10n.authForbidden);
      case ApiErrorType.validation:
        return _withDistinctAdvice(baseMessage, l10n.validationGenericError);
      case ApiErrorType.rateLimit:
        final delay = error.retryAfter;
        if (delay != null) {
          return '$baseMessage\n\n${l10n.rateLimitRetryAfter(_formatRetryDelay(delay))}';
        }
        return '$baseMessage\n\n${l10n.rateLimitRetrySoon}';
      case ApiErrorType.server:
        return _withDistinctAdvice(baseMessage, l10n.serverErrorGeneric);
      default:
        return baseMessage;
    }
  }

  String _formatRetryDelay(Duration delay) {
    final minutes = delay.inMinutes;
    final seconds = delay.inSeconds % 60;
    if (minutes > 0 && seconds > 0) {
      return '${minutes}m ${seconds}s';
    }
    if (minutes > 0) {
      return '${minutes}m';
    }
    return '${delay.inSeconds}s';
  }

  String _withDistinctAdvice(String baseMessage, String advice) {
    if (baseMessage.trim() == advice.trim()) {
      return baseMessage;
    }
    return '$baseMessage\n\n$advice';
  }
}
