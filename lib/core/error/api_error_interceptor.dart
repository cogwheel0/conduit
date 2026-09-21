import 'package:dio/dio.dart';

import 'api_error.dart';
import 'api_error_handler.dart';

import 'package:conduit_core/utils/debug_logger.dart';

// Was Flutter's kDebugMode. `dart.vm.product` is the same signal and
// is available without Flutter.
const bool _kDebugMode = !bool.fromEnvironment('dart.vm.product');

/// Dio interceptor for automatic error handling and transformation
/// Converts all HTTP errors into standardized ApiError format
class ApiErrorInterceptor extends Interceptor {
  final ApiErrorHandler _errorHandler = ApiErrorHandler();
  final bool logErrors;
  final bool throwApiErrors;

  ApiErrorInterceptor({this.logErrors = true, this.throwApiErrors = true});

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    try {
      // Transform the error into our standardized format
      final apiError = _errorHandler.transformError(
        err,
        endpoint: err.requestOptions.path,
        method: err.requestOptions.method,
        logErrorDetails: false,
      );

      if (logErrors) {
        _logApiError(apiError, err);
      }

      if (throwApiErrors) {
        // Replace the DioException with our ApiError
        final enhancedError = DioException(
          requestOptions: err.requestOptions,
          response: err.response,
          type: err.type,
          error: apiError,
          message: apiError.message,
        );
        handler.reject(enhancedError);
      } else {
        // Store the ApiError in the response extra data
        if (err.response != null) {
          err.response!.extra['apiError'] = apiError;
        }
        handler.next(err);
      }
    } catch (e) {
      // Fallback if error transformation fails
      if (logErrors) {
        DebugLogger.error(
          'transform-failed',
          scope: 'api/error-interceptor',
          data: {
            'method': err.requestOptions.method.toUpperCase(),
            'type': err.type.name,
            'status': err.response?.statusCode,
            'failureType': e.runtimeType.toString(),
          },
        );
      }
      handler.next(err);
    }
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    // Check for errors in successful responses (some APIs return errors with 200 status)
    if (response.statusCode == 200 && response.data is Map<String, dynamic>) {
      final data = response.data as Map<String, dynamic>;

      // Check for error indicators in successful responses
      if (_isErrorResponse(data)) {
        final apiError = _errorHandler.transformError(
          data,
          endpoint: response.requestOptions.path,
          method: response.requestOptions.method,
        );

        if (logErrors) {
          DebugLogger.warning(
            'successful-response-error',
            scope: 'api/error-interceptor',
            data: {
              'type': apiError.type.name,
              'method': apiError.method,
              'status': response.statusCode,
            },
          );
        }

        // Store the error for later handling
        response.extra['apiError'] = apiError;
      }
    }

    handler.next(response);
  }

  /// Check if a successful response actually contains an error
  bool _isErrorResponse(Map<String, dynamic> data) {
    // Common error indicators in successful responses
    const errorIndicators = [
      'error',
      'errors',
      'error_message',
      'errorMessage',
      'success',
    ];

    for (final indicator in errorIndicators) {
      if (data.containsKey(indicator)) {
        final value = data[indicator];

        // Check for explicit error indicators
        if (indicator == 'success' && value == false) {
          return true;
        }

        // Check for error messages or arrays
        if (indicator != 'success' && value != null) {
          if (value is String && value.isNotEmpty) {
            return true;
          } else if (value is List && value.isNotEmpty) {
            return true;
          } else if (value is Map && value.isNotEmpty) {
            return true;
          }
        }
      }
    }

    return false;
  }

  /// Log API error with structured information
  void _logApiError(ApiError apiError, DioException originalError) {
    if (!_kDebugMode) return;

    final payload = <String, Object?>{
      'type': apiError.type.name,
      'method': apiError.method,
      'status': apiError.statusCode ?? originalError.response?.statusCode,
      if (apiError.retryAfter != null)
        'retryAfterSeconds': apiError.retryAfter!.inSeconds,
      'originalType': originalError.type.name,
    };

    if (apiError.hasFieldErrors) {
      payload['fieldErrorCount'] = apiError.fieldErrors.values.fold<int>(
        0,
        (count, errors) => count + errors.length,
      );
    }

    DebugLogger.error(
      'api-error',
      scope: 'api/error-interceptor',
      data: payload,
    );
  }

  /// Extract ApiError from DioException if available
  static ApiError? extractApiError(DioException error) {
    return error.error is ApiError ? error.error as ApiError : null;
  }

  /// Extract ApiError from Response if available
  static ApiError? extractApiErrorFromResponse(Response response) {
    return response.extra['apiError'] as ApiError?;
  }

  /// Check if DioException contains an ApiError
  static bool hasApiError(DioException error) {
    return extractApiError(error) != null;
  }
}
