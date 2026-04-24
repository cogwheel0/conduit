import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:conduit/l10n/app_localizations.dart';
import '../../shared/theme/theme_extensions.dart';
import 'navigation_service.dart';
import '../utils/debug_logger.dart';

/// User-friendly error messages and recovery actions
class UserFriendlyErrorHandler {
  static final UserFriendlyErrorHandler _instance =
      UserFriendlyErrorHandler._internal();
  factory UserFriendlyErrorHandler() => _instance;
  UserFriendlyErrorHandler._internal();

  AppLocalizations? get _l10n {
    final ctx = NavigationService.context;
    if (ctx == null) return null;
    return AppLocalizations.of(ctx);
  }

  /// Convert technical errors to user-friendly messages
  String getUserMessage(dynamic error) {
    final errorString = error.toString().toLowerCase();
    final l10n = _l10n;

    if (_isNetworkError(errorString)) {
      return _getNetworkErrorMessage(errorString, l10n);
    } else if (_isValidationError(errorString)) {
      return _getValidationErrorMessage(errorString, l10n);
    } else if (_isServerError(errorString)) {
      return _getServerErrorMessage(errorString, l10n);
    } else if (_isAuthenticationError(errorString)) {
      return _getAuthenticationErrorMessage(errorString, l10n);
    } else if (_isFileError(errorString)) {
      return _getFileErrorMessage(errorString, l10n);
    } else if (_isPermissionError(errorString)) {
      return _getPermissionErrorMessage(errorString, l10n);
    }

    // Log technical details for debugging
    _logError(error);

    // Return generic user-friendly message
    return l10n?.errorMessage ??
        'Something unexpected happened. Please try again.';
  }

  /// Get recovery actions for the error
  List<ErrorRecoveryAction> getRecoveryActions(dynamic error) {
    final errorString = error.toString().toLowerCase();
    final l10n = _l10n;

    if (_isNetworkError(errorString)) {
      return _getNetworkRecoveryActions(l10n);
    } else if (_isServerError(errorString)) {
      return _getServerRecoveryActions(l10n);
    } else if (_isAuthenticationError(errorString)) {
      return _getAuthRecoveryActions(l10n);
    } else if (_isFileError(errorString)) {
      return _getFileRecoveryActions(l10n);
    } else if (_isPermissionError(errorString)) {
      return _getPermissionRecoveryActions(l10n);
    }

    return _getGenericRecoveryActions(l10n);
  }

  /// Build error widget with recovery options
  Widget buildErrorWidget(
    dynamic error, {
    VoidCallback? onRetry,
    VoidCallback? onDismiss,
    bool showDetails = false,
  }) {
    final message = getUserMessage(error);
    final actions = getRecoveryActions(error);

    return ErrorCard(
      message: message,
      actions: actions,
      onRetry: onRetry,
      onDismiss: onDismiss,
      showDetails: showDetails,
      technicalDetails: showDetails ? error.toString() : null,
    );
  }

  /// Show error dialog with recovery options
  Future<void> showErrorDialog(
    BuildContext context,
    dynamic error, {
    VoidCallback? onRetry,
    bool showDetails = false,
  }) async {
    final message = getUserMessage(error);
    final actions = getRecoveryActions(error);

    return showDialog(
      context: context,
      builder: (context) => ErrorDialog(
        message: message,
        actions: actions,
        onRetry: onRetry,
        showDetails: showDetails,
        technicalDetails: showDetails ? error.toString() : null,
      ),
    );
  }

  /// Show error snackbar with quick action
  void showErrorSnackbar(
    BuildContext context,
    dynamic error, {
    VoidCallback? onRetry,
  }) {
    final message = getUserMessage(error);
    final actions = getRecoveryActions(error);
    final primaryAction = actions.isNotEmpty ? actions.first : null;

    AdaptiveSnackBar.show(
      context,
      message: message,
      type: AdaptiveSnackBarType.error,
      duration: const Duration(seconds: 4),
      action: primaryAction != null && onRetry != null
          ? primaryAction.label
          : null,
      onActionPressed: onRetry,
    );
  }

  // Network error detection and handling
  bool _isNetworkError(String error) {
    return error.contains('socketexception') ||
        error.contains('network') ||
        error.contains('connection') ||
        error.contains('timeout') ||
        error.contains('handshake') ||
        error.contains('no address associated');
  }

  String _getNetworkErrorMessage(String error, AppLocalizations? l10n) {
    if (error.contains('timeout')) {
      return l10n?.networkTimeoutError ??
          'Connection timed out. Please check your internet connection and try again.';
    } else if (error.contains('no address associated')) {
      return l10n?.networkUnreachableError ??
          'Cannot reach the server. Please check your server URL and internet connection.';
    } else if (error.contains('connection refused')) {
      return l10n?.networkServerNotResponding ??
          'Server is not responding. Please verify the server is running and accessible.';
    }
    return l10n?.networkGenericError ??
        'Network connection problem. Please check your internet connection.';
  }

  List<ErrorRecoveryAction> _getNetworkRecoveryActions(AppLocalizations? l10n) {
    return [
      ErrorRecoveryAction(
        label: l10n?.retry ?? 'Retry',
        action: ErrorActionType.retry,
        description: l10n?.actionRetryRequest ?? 'Try the request again',
      ),
      ErrorRecoveryAction(
        label: l10n?.checkConnection ?? 'Check Connection',
        action: ErrorActionType.checkConnection,
        description:
            l10n?.actionVerifyConnection ?? 'Verify your internet connection',
      ),
    ];
  }

  // Server error detection and handling
  bool _isServerError(String error) {
    return error.contains('500') ||
        error.contains('502') ||
        error.contains('503') ||
        error.contains('504') ||
        error.contains('server error') ||
        error.contains('internal server error');
  }

  String _getServerErrorMessage(String error, AppLocalizations? l10n) {
    if (error.contains('500')) {
      return l10n?.serverError500 ??
          'Server is experiencing issues. This is usually temporary.';
    } else if (error.contains('502') || error.contains('503')) {
      return l10n?.serverErrorUnavailable ??
          'Server is temporarily unavailable. Please try again in a moment.';
    } else if (error.contains('504')) {
      return l10n?.serverErrorTimeout ??
          'Server took too long to respond. Please try again.';
    }
    return l10n?.serverErrorGeneric ??
        'Server is having problems. Please try again later.';
  }

  List<ErrorRecoveryAction> _getServerRecoveryActions(AppLocalizations? l10n) {
    return [
      ErrorRecoveryAction(
        label: l10n?.retry ?? 'Retry',
        action: ErrorActionType.retry,
        description: l10n?.actionRetryRequest ?? 'Retry your request',
      ),
      ErrorRecoveryAction(
        label: l10n?.retry ?? 'Retry',
        action: ErrorActionType.retryLater,
        description:
            l10n?.actionRetryAfterDelay ?? 'Wait a moment then try again',
      ),
    ];
  }

  // Authentication error detection and handling
  bool _isAuthenticationError(String error) {
    return error.contains('401') ||
        error.contains('403') ||
        error.contains('unauthorized') ||
        error.contains('forbidden') ||
        error.contains('authentication') ||
        error.contains('token');
  }

  String _getAuthenticationErrorMessage(String error, AppLocalizations? l10n) {
    if (error.contains('401') || error.contains('unauthorized')) {
      return l10n?.authSessionExpired ??
          'Your session has expired. Please sign in again.';
    } else if (error.contains('403') || error.contains('forbidden')) {
      return l10n?.authForbidden ??
          'You don\'t have permission to perform this action.';
    } else if (error.contains('token')) {
      return l10n?.authInvalidToken ??
          'Authentication token is invalid. Please sign in again.';
    }
    return l10n?.authGenericError ??
        'Authentication problem. Please sign in again.';
  }

  List<ErrorRecoveryAction> _getAuthRecoveryActions(AppLocalizations? l10n) {
    return [
      ErrorRecoveryAction(
        label: l10n?.signIn ?? 'Sign In',
        action: ErrorActionType.signIn,
        description: l10n?.actionSignInToAccount ?? 'Sign in to your account',
      ),
      ErrorRecoveryAction(
        label: l10n?.retry ?? 'Retry',
        action: ErrorActionType.retry,
        description: l10n?.actionRetryOperation ?? 'Retry the request',
      ),
    ];
  }

  // Validation error detection and handling
  bool _isValidationError(String error) {
    return error.contains('validation') ||
        error.contains('invalid') ||
        error.contains('format') ||
        error.contains('required') ||
        error.contains('400');
  }

  String _getValidationErrorMessage(String error, AppLocalizations? l10n) {
    if (error.contains('email')) {
      return l10n?.validationInvalidEmail ??
          'Please enter a valid email address.';
    } else if (error.contains('password')) {
      return l10n?.validationWeakPassword ??
          'Password doesn\'t meet requirements. Please check and try again.';
    } else if (error.contains('required')) {
      return l10n?.validationMissingRequired ??
          'Please fill in all required fields.';
    } else if (error.contains('format')) {
      return l10n?.validationFormatError ??
          'Some information is in the wrong format. Please check and try again.';
    }
    return l10n?.validationGenericError ??
        'Please check your input and try again.';
  }

  // File error detection and handling
  bool _isFileError(String error) {
    return error.contains('file') ||
        error.contains('path') ||
        error.contains('directory') ||
        error.contains('not found') ||
        error.contains('access denied');
  }

  String _getFileErrorMessage(String error, AppLocalizations? l10n) {
    if (error.contains('not found')) {
      return l10n?.fileNotFound ??
          'File not found. It may have been moved or deleted.';
    } else if (error.contains('access denied')) {
      return l10n?.fileAccessDenied ??
          'Cannot access the file. Please check permissions.';
    } else if (error.contains('too large')) {
      return l10n?.fileTooLarge ??
          'File is too large. Please choose a smaller file.';
    }
    return l10n?.fileGenericError ??
        'Problem with the file. Please try a different file.';
  }

  List<ErrorRecoveryAction> _getFileRecoveryActions(AppLocalizations? l10n) {
    return [
      ErrorRecoveryAction(
        label: l10n?.chooseDifferentFile ?? 'Choose Different File',
        action: ErrorActionType.chooseFile,
        description: l10n?.actionSelectAnotherFile ?? 'Select another file',
      ),
      ErrorRecoveryAction(
        label: l10n?.retry ?? 'Retry',
        action: ErrorActionType.retry,
        description: l10n?.actionRetryOperation ?? 'Retry the operation',
      ),
    ];
  }

  // Permission error detection and handling
  bool _isPermissionError(String error) {
    return error.contains('permission') ||
        error.contains('denied') ||
        error.contains('unauthorized') ||
        error.contains('access');
  }

  String _getPermissionErrorMessage(String error, AppLocalizations? l10n) {
    if (error.contains('camera')) {
      return l10n?.permissionCameraRequired ??
          'Camera permission is required. Please enable it in settings.';
    } else if (error.contains('storage')) {
      return l10n?.permissionStorageRequired ??
          'Storage permission is required. Please enable it in settings.';
    } else if (error.contains('microphone')) {
      return l10n?.permissionMicrophoneRequired ??
          'Microphone permission is required. Please enable it in settings.';
    }
    return l10n?.permissionGenericError ??
        'Permission required. Please check app permissions in settings.';
  }

  List<ErrorRecoveryAction> _getPermissionRecoveryActions(
    AppLocalizations? l10n,
  ) {
    return [
      ErrorRecoveryAction(
        label: l10n?.openSettings ?? 'Open Settings',
        action: ErrorActionType.openSettings,
        description:
            l10n?.actionOpenAppSettings ??
            'Open app settings to grant permissions',
      ),
      ErrorRecoveryAction(
        label: l10n?.retry ?? 'Retry',
        action: ErrorActionType.retry,
        description:
            l10n?.actionRetryAfterPermission ??
            'Retry after granting permission',
      ),
    ];
  }

  List<ErrorRecoveryAction> _getGenericRecoveryActions(AppLocalizations? l10n) {
    return [
      ErrorRecoveryAction(
        label: l10n?.retry ?? 'Retry',
        action: ErrorActionType.retry,
        description: l10n?.actionRetryOperation ?? 'Retry the operation',
      ),
      ErrorRecoveryAction(
        label: l10n?.back ?? 'Go Back',
        action: ErrorActionType.goBack,
        description:
            l10n?.actionReturnToPrevious ?? 'Return to previous screen',
      ),
    ];
  }

  /// Log technical error details for debugging
  void _logError(dynamic error) {
    if (kDebugMode) {
      DebugLogger.log('$error', scope: 'errors/user-friendly');
      if (error is Error) {
        DebugLogger.log(
          'STACK TRACE: ${error.stackTrace}',
          scope: 'errors/user-friendly',
        );
      }
    }

    // In production, you might want to send this to a crash reporting service
    // FirebaseCrashlytics.instance.recordError(error, stackTrace);
  }
}

/// Error recovery action definition
class ErrorRecoveryAction {
  final String label;
  final ErrorActionType action;
  final String description;
  final VoidCallback? customAction;

  ErrorRecoveryAction({
    required this.label,
    required this.action,
    required this.description,
    this.customAction,
  });
}

/// Types of error recovery actions
enum ErrorActionType {
  retry,
  retryLater,
  goBack,
  signIn,
  openSettings,
  checkConnection,
  chooseFile,
  contactSupport,
  dismiss,
}

/// Error card widget
class ErrorCard extends StatelessWidget {
  final String message;
  final List<ErrorRecoveryAction> actions;
  final VoidCallback? onRetry;
  final VoidCallback? onDismiss;
  final bool showDetails;
  final String? technicalDetails;

  const ErrorCard({
    super.key,
    required this.message,
    required this.actions,
    this.onRetry,
    this.onDismiss,
    this.showDetails = false,
    this.technicalDetails,
  });

  @override
  Widget build(BuildContext context) {
    return AdaptiveCard(
      margin: const EdgeInsets.all(Spacing.md),
      child: Padding(
        padding: const EdgeInsets.all(Spacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.error_outline,
                  color: Theme.of(context).colorScheme.error,
                  size: IconSize.lg,
                ),
                const SizedBox(width: Spacing.sm + Spacing.xs),
                Expanded(
                  child: Text(
                    message,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ),
              ],
            ),
            if (actions.isNotEmpty) ...[
              const SizedBox(height: Spacing.md),
              Wrap(
                spacing: 8,
                children: actions.take(2).map((action) {
                  return AdaptiveButton(
                    onPressed: () => _handleAction(context, action),
                    label: action.label,
                    style: AdaptiveButtonStyle.filled,
                  );
                }).toList(),
              ),
            ],
            if (showDetails && technicalDetails != null) ...[
              const SizedBox(height: Spacing.md),
              AdaptiveExpansionTile(
                title: Text(AppLocalizations.of(context)!.technicalDetails),
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(Spacing.md),
                    decoration: BoxDecoration(
                      color: context.conduitTheme.surfaceContainer,
                      borderRadius: BorderRadius.circular(AppBorderRadius.xs),
                    ),
                    child: SelectableText(
                      technicalDetails!,
                      style: AppTypography.labelMediumStyle.copyWith(
                        fontFamily: AppTypography.monospaceFontFamily,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _handleAction(BuildContext context, ErrorRecoveryAction action) {
    if (action.customAction != null) {
      action.customAction!();
      return;
    }

    switch (action.action) {
      case ErrorActionType.retry:
        onRetry?.call();
        break;
      case ErrorActionType.goBack:
        Navigator.of(context).pop();
        break;
      case ErrorActionType.dismiss:
        onDismiss?.call();
        break;
      case ErrorActionType.signIn:
        // Navigate to sign in page
        NavigationService.navigateToServerConnection();
        break;
      case ErrorActionType.openSettings:
        // Open app settings - would need platform-specific implementation
        break;
      default:
        onRetry?.call();
    }
  }
}

/// Error dialog widget
class ErrorDialog extends StatelessWidget {
  final String message;
  final List<ErrorRecoveryAction> actions;
  final VoidCallback? onRetry;
  final bool showDetails;
  final String? technicalDetails;

  const ErrorDialog({
    super.key,
    required this.message,
    required this.actions,
    this.onRetry,
    this.showDetails = false,
    this.technicalDetails,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error),
          const SizedBox(width: Spacing.sm + Spacing.xs),
          Text(AppLocalizations.of(context)!.errorMessage),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message),
          if (showDetails && technicalDetails != null) ...[
            const SizedBox(height: Spacing.md),
            AdaptiveExpansionTile(
              title: Text(AppLocalizations.of(context)!.technicalDetails),
              children: [
                SelectableText(
                  technicalDetails!,
                  style: AppTypography.labelMediumStyle.copyWith(
                    fontFamily: AppTypography.monospaceFontFamily,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
      actions: [
        AdaptiveButton(
          onPressed: () => Navigator.of(context).pop(),
          label: AppLocalizations.of(context)!.cancel,
          style: AdaptiveButtonStyle.plain,
        ),
        if (actions.isNotEmpty)
          AdaptiveButton(
            onPressed: () {
              Navigator.of(context).pop();
              if (actions.first.action == ErrorActionType.retry) {
                onRetry?.call();
              }
            },
            label: actions.first.label,
            style: AdaptiveButtonStyle.filled,
          ),
      ],
    );
  }
}
