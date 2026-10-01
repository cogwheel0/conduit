import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import 'package:conduit_core/error/api_error.dart';
import 'package:conduit_core/error/api_error_handler.dart';
import 'package:conduit_core/error/error_recovery_policy.dart';

import '../../core/utils/current_localizations.dart';
import '../utils/api_error_messages.dart';
import '../theme/theme_extensions.dart';
import '../widgets/themed_dialogs.dart';

import 'package:conduit/l10n/app_localizations.dart';

import 'package:conduit_core/utils/debug_logger.dart';

/// Enhanced error service with comprehensive error handling capabilities
/// Provides unified error management across the application
class EnhancedErrorService {
  static final EnhancedErrorService _instance =
      EnhancedErrorService._internal();
  factory EnhancedErrorService() => _instance;
  EnhancedErrorService._internal();

  final ErrorRecoveryPolicy _policy = ErrorRecoveryPolicy();
  ApiErrorHandler get _errorHandler => _policy.handler;

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
    final apiError = _policy.apiErrorOf(error);
    if (apiError != null) {
      // Localisation belongs to the UI: the core raises `{code, args}` and
      // each front-end renders it.
      return userFacingApiError(apiError, currentAppLocalizations());
    } else if (error is DioException) {
      return _policy.dioFallbackMessage(error);
    } else {
      return _policy.genericMessage(error);
    }
  }

  /// Get technical error details for debugging
  String getTechnicalDetails(dynamic error) => _policy.technicalDetails(error);

  /// Check if error is retryable
  bool isRetryable(dynamic error) => _policy.isRetryable(error);

  /// Get suggested retry delay
  Duration? getRetryDelay(dynamic error) => _policy.retryDelay(error);

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
      duration: duration ?? _policy.snackbarDuration(error),
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

    return ThemedDialogs.showCustom<void>(
      context: context,
      barrierDismissible: true,
      builder: (BuildContext context) {
        final theme = context.conduitTheme;
        return AlertDialog(
          title: Row(
            children: [
              Icon(_getErrorIcon(error), color: _getErrorColor(context, error)),
              const SizedBox(width: Spacing.sm),
              Expanded(child: Text(title ?? _policy.title(error))),
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
            _policy.title(error),
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
}

/// Global instance for easy access
final enhancedErrorService = EnhancedErrorService();
