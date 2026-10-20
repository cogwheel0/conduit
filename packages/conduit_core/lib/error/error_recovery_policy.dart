/// Retry, title and timing decisions for an error, read by the app's
/// `EnhancedErrorService`.
///
/// The localized message stays with the app (it reads the app's strings);
/// everything here is a decision about the error itself.
library;

import 'package:dio/dio.dart';

import 'api_error.dart';
import 'api_error_handler.dart';
import 'api_error_interceptor.dart';

class ErrorRecoveryPolicy {
  ErrorRecoveryPolicy({ApiErrorHandler? handler})
    : handler = handler ?? ApiErrorHandler();

  final ApiErrorHandler handler;

  /// The [ApiError] inside [error]: the error itself, or the one the
  /// interceptor attached to a `DioException`.
  ApiError? apiErrorOf(dynamic error) {
    if (error is ApiError) return error;
    if (error is DioException) {
      return ApiErrorInterceptor.extractApiError(error);
    }
    return null;
  }

  /// English text for a `DioException` that carries no [ApiError].
  String dioFallbackMessage(DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return 'Connection timeout - please check your internet connection';
      case DioExceptionType.connectionError:
        return 'Network connection error - please check your internet connection';
      case DioExceptionType.badResponse:
        final statusCode = error.response?.statusCode;
        if (statusCode == 401) {
          return 'Authentication failed - please sign in again';
        } else if (statusCode == 403) {
          return 'Access denied - you don\'t have permission for this action';
        } else if (statusCode == 404) {
          return 'The requested resource was not found';
        } else if (statusCode != null && statusCode >= 500) {
          return 'Server error occurred - please try again later';
        }
        return 'An error occurred with your request';
      case DioExceptionType.cancel:
        return 'Request was cancelled';
      case DioExceptionType.badCertificate:
        return 'Security certificate error - unable to verify server identity';
      case DioExceptionType.unknown:
        return 'An unexpected error occurred - please try again';
    }
  }

  /// English text for an error that is neither an [ApiError] nor a
  /// `DioException`. It never repeats the error's own text, which can carry
  /// internals; [technicalDetails] holds that for logs and the details
  /// disclosure.
  String genericMessage(dynamic error) => 'An unexpected error occurred';

  /// Technical details for logs and the "details" disclosure.
  String technicalDetails(dynamic error) {
    final apiError = apiErrorOf(error);
    if (apiError != null) return apiError.technical ?? apiError.toString();
    if (error is DioException) return '${error.type}: ${error.message}';
    return error.toString();
  }

  /// Whether trying the same request again can help.
  bool isRetryable(dynamic error) {
    final apiError = apiErrorOf(error);
    if (apiError != null) return handler.isRetryable(apiError);
    if (error is DioException) return _isDioErrorRetryable(error);
    return false;
  }

  /// How long to wait before a retry, or null when a retry will not help.
  Duration? retryDelay(dynamic error) {
    final apiError = apiErrorOf(error);
    if (apiError != null) return handler.getRetryDelay(apiError);
    if (error is DioException) return _dioRetryDelay(error);
    return null;
  }

  /// English dialog title for [error].
  String title(dynamic error) {
    if (error is ApiError) {
      switch (error.type) {
        case ApiErrorType.network:
          return 'Connection Problem';
        case ApiErrorType.timeout:
          return 'Request Timeout';
        case ApiErrorType.authentication:
          return 'Authentication Required';
        case ApiErrorType.authorization:
          return 'Access Denied';
        case ApiErrorType.validation:
          return 'Invalid Input';
        case ApiErrorType.badRequest:
          return 'Bad Request';
        case ApiErrorType.notFound:
          return 'Not Found';
        case ApiErrorType.server:
          return 'Server Error';
        case ApiErrorType.rateLimit:
          return 'Rate Limited';
        case ApiErrorType.cancelled:
          return 'Request Cancelled';
        case ApiErrorType.security:
          return 'Security Error';
        case ApiErrorType.unknown:
          return 'Unknown Error';
      }
    }
    return 'Error';
  }

  /// How long an error snackbar stays up: validation and rate-limit errors
  /// carry more to read.
  Duration snackbarDuration(dynamic error) {
    if (error is ApiError) {
      switch (error.type) {
        case ApiErrorType.validation:
        case ApiErrorType.badRequest:
          return const Duration(seconds: 6);
        case ApiErrorType.rateLimit:
          return const Duration(seconds: 8);
        default:
          return const Duration(seconds: 4);
      }
    }
    return const Duration(seconds: 4);
  }

  bool _isDioErrorRetryable(DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        return true;
      case DioExceptionType.badResponse:
        final statusCode = error.response?.statusCode;
        return statusCode != null && statusCode >= 500;
      default:
        return false;
    }
  }

  Duration? _dioRetryDelay(DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return const Duration(seconds: 5);
      case DioExceptionType.connectionError:
        return const Duration(seconds: 3);
      case DioExceptionType.badResponse:
        final statusCode = error.response?.statusCode;
        if (statusCode != null && statusCode >= 500) {
          return const Duration(seconds: 10);
        }
        return null;
      default:
        return null;
    }
  }
}
