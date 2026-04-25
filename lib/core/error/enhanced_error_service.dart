import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'api_error.dart';
import 'api_error_handler.dart';
import 'api_error_interceptor.dart';
import '../../shared/theme/theme_extensions.dart';
import 'package:conduit/l10n/app_localizations.dart';
import '../utils/debug_logger.dart';

/// Enhanced error service with comprehensive error handling capabilities
/// Provides unified error management across the application
class EnhancedErrorService {
  static final EnhancedErrorService _instance =
      EnhancedErrorService._internal();
  factory EnhancedErrorService() => _instance;
  EnhancedErrorService._internal();

  final ApiErrorHandler _errorHandler = ApiErrorHandler();

  /// Transform any error into ApiError format
  ApiError transformError(
    dynamic error, {
    String? endpoint,
    String? method,
    Map<String, dynamic>? requestData,
  }) {
    return _errorHandler.transformError(
      error,
      endpoint: endpoint,
      method: method,
      requestData: requestData,
    );
  }

  /// Get user-friendly error message
  String getUserMessage(dynamic error) {
    if (error is ApiError) {
      return _errorHandler.getUserMessage(error);
    } else if (error is DioException) {
      return ApiErrorInterceptor.getUserMessage(error);
    } else {
      return _getGenericErrorMessage(error);
    }
  }

  /// Get technical error details for debugging
  String getTechnicalDetails(dynamic error) {
    if (error is ApiError) {
      return error.technical ?? error.toString();
    } else if (error is DioException) {
      final apiError = ApiErrorInterceptor.extractApiError(error);
      if (apiError != null) {
        return apiError.technical ?? apiError.toString();
      }
      return '${error.type}: ${error.message}';
    } else {
      return error.toString();
    }
  }

  /// Check if error is retryable
  bool isRetryable(dynamic error) {
    if (error is ApiError) {
      return _errorHandler.isRetryable(error);
    } else if (error is DioException) {
      final apiError = ApiErrorInterceptor.extractApiError(error);
      if (apiError != null) {
        return _errorHandler.isRetryable(apiError);
      }
      return _isDioErrorRetryable(error);
    }
    return false;
  }

  /// Get suggested retry delay
  Duration? getRetryDelay(dynamic error) {
    if (error is ApiError) {
      return _errorHandler.getRetryDelay(error);
    } else if (error is DioException) {
      final apiError = ApiErrorInterceptor.extractApiError(error);
      if (apiError != null) {
        return _errorHandler.getRetryDelay(apiError);
      }
      return _getDioRetryDelay(error);
    }
    return null;
  }

  /// Show error snackbar with appropriate styling and actions
  void showErrorSnackbar(
    BuildContext context,
    dynamic error, {
    VoidCallback? onRetry,
    Duration? duration,
    bool showTechnicalDetails = false,
  }) {
    final message = showTechnicalDetails
        ? '${getUserMessage(error)}\n${getTechnicalDetails(error)}'
        : getUserMessage(error);
    final isRetryableError = isRetryable(error);
    final retryDelay = getRetryDelay(error);

    final String? actionLabel = isRetryableError && onRetry != null
        ? (retryDelay != null && retryDelay.inSeconds > 5
              ? '${AppLocalizations.of(context)!.retry}'
                    ' (${retryDelay.inSeconds}s)'
              : AppLocalizations.of(context)!.retry)
        : null;

    AdaptiveSnackBar.show(
      context,
      message: message,
      type: AdaptiveSnackBarType.error,
      duration: duration ?? _getSnackbarDuration(error),
      action: actionLabel,
      onActionPressed: onRetry,
    );
  }

  /// Show error dialog with detailed information and recovery options
  Future<void> showErrorDialog(
    BuildContext context,
    dynamic error, {
    String? title,
    VoidCallback? onRetry,
    VoidCallback? onDismiss,
    bool showTechnicalDetails = false,
  }) async {
    final message = getUserMessage(error);
    final technicalDetails = getTechnicalDetails(error);
    final isRetryableError = isRetryable(error);

    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (BuildContext context) {
        final theme = context.conduitTheme;
        return AlertDialog(
          title: Row(
            children: [
              Icon(_getErrorIcon(error), color: _getErrorColor(context, error)),
              const SizedBox(width: Spacing.sm),
              Expanded(child: Text(title ?? _getErrorTitle(error))),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                message,
                style: AppTypography.bodyMediumStyle.copyWith(
                  color: theme.textPrimary,
                ),
              ),
              if (showTechnicalDetails) ...[
                const SizedBox(height: Spacing.md),
                Text(
                  'Technical Details:',
                  style: AppTypography.labelStyle.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.textPrimary,
                  ),
                ),
                const SizedBox(height: Spacing.xs),
                Container(
                  padding: const EdgeInsets.all(Spacing.sm),
                  decoration: BoxDecoration(
                    color: theme.surfaceContainer,
                    borderRadius: BorderRadius.circular(AppBorderRadius.xs),
                  ),
                  child: Text(
                    technicalDetails,
                    style: AppTypography.labelMediumStyle.copyWith(
                      fontFamily: AppTypography.monospaceFontFamily,
                      color: theme.textSecondary,
                    ),
                  ),
                ),
              ],
            ],
          ),
          actions: [
            if (isRetryableError && onRetry != null)
              AdaptiveButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  onRetry();
                },
                label: AppLocalizations.of(context)!.retry,
                style: AdaptiveButtonStyle.plain,
              ),
            AdaptiveButton(
              onPressed: () {
                Navigator.of(context).pop();
                onDismiss?.call();
              },
              label: AppLocalizations.of(context)!.ok,
              style: AdaptiveButtonStyle.plain,
            ),
          ],
        );
      },
    );
  }

  /// Build error widget for displaying in UI
  Widget buildErrorWidget(
    BuildContext context,
    dynamic error, {
    VoidCallback? onRetry,
    bool showTechnicalDetails = false,
    EdgeInsets? padding,
  }) {
    final message = getUserMessage(error);
    final technicalDetails = getTechnicalDetails(error);
    final isRetryableError = isRetryable(error);
    final theme = context.conduitTheme;

    return Container(
      padding: padding ?? const EdgeInsets.all(Spacing.md),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            _getErrorIcon(error),
            size: IconSize.xxl,
            color: _getErrorColor(context, error),
          ),
          const SizedBox(height: Spacing.md),
          Text(
            _getErrorTitle(error),
            style: AppTypography.headlineSmallStyle.copyWith(
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: Spacing.sm),
          Text(
            message,
            textAlign: TextAlign.center,
            style: AppTypography.bodyMediumStyle.copyWith(
              color: theme.textSecondary,
            ),
          ),
          if (showTechnicalDetails) ...[
            const SizedBox(height: Spacing.md),
            Container(
              padding: const EdgeInsets.all(Spacing.xs),
              decoration: BoxDecoration(
                color: theme.surfaceContainer,
                borderRadius: BorderRadius.circular(AppBorderRadius.sm),
              ),
              child: Text(
                technicalDetails,
                style: AppTypography.labelMediumStyle.copyWith(
                  fontFamily: AppTypography.monospaceFontFamily,
                  color: theme.textSecondary,
                ),
              ),
            ),
          ],
          if (isRetryableError && onRetry != null) ...[
            const SizedBox(height: Spacing.md),
            AdaptiveButton.child(
              onPressed: onRetry,
              style: AdaptiveButtonStyle.filled,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.refresh),
                  const SizedBox(width: Spacing.sm),
                  Text(AppLocalizations.of(context)!.retry),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Log error with structured information
  void logError(
    dynamic error, {
    String? context,
    Map<String, dynamic>? additionalData,
    StackTrace? stackTrace,
  }) {
    if (kDebugMode) {
      final timestamp = DateTime.now().toIso8601String();
      DebugLogger.log(
        '🔴 ERROR [$timestamp] ${context ?? 'Unknown Context'}',
        scope: 'api/error-service',
      );
      DebugLogger.log(
        '  Message: ${getUserMessage(error)}',
        scope: 'api/error-service',
      );
      DebugLogger.log(
        '  Technical: ${getTechnicalDetails(error)}',
        scope: 'api/error-service',
      );

      if (additionalData != null && additionalData.isNotEmpty) {
        DebugLogger.log(
          '  Additional Data: $additionalData',
          scope: 'api/error-service',
        );
      }

      if (stackTrace != null) {
        DebugLogger.log(
          '  Stack Trace: $stackTrace',
          scope: 'api/error-service',
        );
      }
    }

    // In production, send to error tracking service
    // FirebaseCrashlytics.instance.recordError(error, stackTrace, context: context);
    // Sentry.captureException(error, stackTrace: stackTrace);
  }

  // Private helper methods

  String _getGenericErrorMessage(dynamic error) {
    if (error is Exception) {
      return 'An error occurred: ${error.toString()}';
    }
    return 'An unexpected error occurred';
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

  Duration? _getDioRetryDelay(DioException error) {
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
        break;
      default:
        break;
    }
    return null;
  }

  IconData _getErrorIcon(dynamic error) {
    if (error is ApiError) {
      switch (error.type) {
        case ApiErrorType.network:
          return Icons.wifi_off;
        case ApiErrorType.timeout:
          return Icons.timer_off;
        case ApiErrorType.authentication:
          return Icons.lock;
        case ApiErrorType.authorization:
          return Icons.block;
        case ApiErrorType.validation:
          return Icons.edit_off;
        case ApiErrorType.badRequest:
          return Icons.error_outline;
        case ApiErrorType.notFound:
          return Icons.search_off;
        case ApiErrorType.server:
          return Icons.dns;
        case ApiErrorType.rateLimit:
          return Icons.speed;
        case ApiErrorType.cancelled:
          return Icons.cancel;
        case ApiErrorType.security:
          return Icons.security;
        case ApiErrorType.unknown:
          return Icons.help_outline;
      }
    }
    return Icons.error_outline;
  }

  Color _getErrorColor(BuildContext context, dynamic error) {
    final tokens = context.colorTokens;
    if (error is ApiError) {
      switch (error.type) {
        case ApiErrorType.network:
        case ApiErrorType.timeout:
          return tokens.statusWarning60;
        case ApiErrorType.authentication:
        case ApiErrorType.authorization:
          return tokens.statusError60;
        case ApiErrorType.validation:
        case ApiErrorType.badRequest:
          return tokens.statusWarning60;
        case ApiErrorType.server:
          return tokens.statusError60;
        case ApiErrorType.rateLimit:
          return tokens.statusInfo60;
        default:
          return tokens.statusError60;
      }
    }
    return tokens.statusError60;
  }

  String _getErrorTitle(dynamic error) {
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

  Duration _getSnackbarDuration(dynamic error) {
    if (error is ApiError) {
      switch (error.type) {
        case ApiErrorType.validation:
        case ApiErrorType.badRequest:
          return const Duration(seconds: 6); // Longer for validation errors
        case ApiErrorType.rateLimit:
          return const Duration(seconds: 8); // Longer for rate limits
        default:
          return const Duration(seconds: 4);
      }
    }
    return const Duration(seconds: 4);
  }
}

/// Global instance for easy access
final enhancedErrorService = EnhancedErrorService();
