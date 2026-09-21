import 'package:dio/dio.dart';
import 'package:conduit_core/conduit_core.dart';

import 'api_error.dart';
import 'error_parser.dart';

import 'package:conduit_core/utils/debug_logger.dart';

// Was Flutter's kDebugMode. `dart.vm.product` is the same signal and
// is available without Flutter.
const bool _kDebugMode = !bool.fromEnvironment('dart.vm.product');

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
    bool logErrorDetails = true,
  }) {
    try {
      if (error is DioException) {
        return _handleDioException(
          error,
          endpoint: endpoint,
          method: method,
          logErrorDetails: logErrorDetails,
        );
      } else if (error is ApiError) {
        return error;
      } else {
        return ApiError.unknown(
          messageCode: const ErrorMessage(CoreErrorCode.generic),
          originalError: error,
          technical: error.toString(),
        );
      }
    } catch (e) {
      // Fallback error if transformation itself fails
      if (logErrorDetails) {
        DebugLogger.error(
          'transform-failed',
          scope: 'api/error-handler',
          data: {
            'inputType': error.runtimeType.toString(),
            'failureType': e.runtimeType.toString(),
          },
        );
      }
      return ApiError.unknown(
        messageCode: const ErrorMessage(CoreErrorCode.generic),
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
    required bool logErrorDetails,
  }) {
    final statusCode = dioError.response?.statusCode;
    final responseData = dioError.response?.data;
    final requestPath = endpoint ?? dioError.requestOptions.path;
    final httpMethod = method ?? dioError.requestOptions.method;

    // Log error details for debugging
    if (logErrorDetails) _logErrorDetails(dioError, httpMethod);

    switch (dioError.type) {
      case DioExceptionType.connectionTimeout:
        return ApiError.timeout(
          messageCode: const ErrorMessage(CoreErrorCode.networkTimeout),
          endpoint: requestPath,
          method: httpMethod,
          timeoutDuration: dioError.requestOptions.connectTimeout,
        );

      case DioExceptionType.sendTimeout:
        return ApiError.timeout(
          messageCode: const ErrorMessage(CoreErrorCode.networkTimeout),
          endpoint: requestPath,
          method: httpMethod,
          timeoutDuration: dioError.requestOptions.sendTimeout,
        );

      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return ApiError.timeout(
          messageCode: const ErrorMessage(CoreErrorCode.serverTimeout),
          endpoint: requestPath,
          method: httpMethod,
          timeoutDuration: dioError.requestOptions.receiveTimeout,
        );

      case DioExceptionType.badCertificate:
        return ApiError.security(
          messageCode: const ErrorMessage(CoreErrorCode.securityCertificate),
          endpoint: requestPath,
          method: httpMethod,
        );

      case DioExceptionType.connectionError:
        return ApiError.network(
          messageCode: const ErrorMessage(CoreErrorCode.networkGeneric),
          endpoint: requestPath,
          method: httpMethod,
          originalError: dioError,
        );

      case DioExceptionType.cancel:
        return ApiError.cancelled(
          messageCode: const ErrorMessage(CoreErrorCode.generic),
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
          messageCode: const ErrorMessage(CoreErrorCode.networkGeneric),
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
    if (statusCode == null) {
      return ApiError.server(
        messageCode: const ErrorMessage(CoreErrorCode.serverGeneric),
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
          messageCode: const ErrorMessage(CoreErrorCode.authSessionExpired),
          endpoint: requestPath,
          method: httpMethod,
          statusCode: statusCode,
        );

      case 403:
        return ApiError.authorization(
          messageCode: const ErrorMessage(CoreErrorCode.authForbidden),
          endpoint: requestPath,
          method: httpMethod,
          statusCode: statusCode,
        );

      case 404:
        return ApiError.notFound(
          messageCode: const ErrorMessage(CoreErrorCode.fileNotFound),
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
          messageCode: const ErrorMessage(CoreErrorCode.rateLimitExceeded),
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
            messageCode: const ErrorMessage(CoreErrorCode.generic),
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
      // Server prose when there is any; the UI falls back to the code.
      message: parsedError.message,
      messageCode: const ErrorMessage(CoreErrorCode.validationGeneric),
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
      messageCode: const ErrorMessage(CoreErrorCode.validationGeneric),
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

    final messageCode = ErrorMessage(switch (statusCode) {
      500 => CoreErrorCode.serverInternal,
      502 || 503 => CoreErrorCode.serverUnavailable,
      504 => CoreErrorCode.serverTimeout,
      _ => CoreErrorCode.serverGeneric,
    });

    return ApiError.server(
      messageCode: messageCode,
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
  void _logErrorDetails(DioException dioError, String httpMethod) {
    if (!_kDebugMode) return;

    final payload = <String, Object?>{
      'method': httpMethod.toUpperCase(),
      'type': dioError.type.name,
      'status': dioError.response?.statusCode,
    };

    DebugLogger.error('dio-error', scope: 'api/error-handler', data: payload);

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
}
