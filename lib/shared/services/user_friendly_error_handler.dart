import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:conduit/l10n/app_localizations.dart';

import '../theme/theme_extensions.dart';
import '../widgets/themed_dialogs.dart';
import 'navigation_service.dart';

import 'package:conduit_core/error/user_friendly_error.dart';
import 'package:conduit_core/utils/debug_logger.dart';

// The categorisation and the action set live in conduit_core; the action
// type stays reachable from here.
export 'package:conduit_core/error/user_friendly_error.dart'
    show ErrorActionType;

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
    final classified = classifyUserFriendlyError(error);
    final l10n = _l10n;

    if (classified.kind == UserFriendlyErrorKind.unknown) {
      // Log technical details for debugging
      _logError(error);
    }

    return _messageText(classified.message, l10n);
  }

  /// Get recovery actions for the error
  List<ErrorRecoveryAction> getRecoveryActions(dynamic error) {
    final l10n = _l10n;
    return [
      for (final action in userFriendlyRecoveryActions(error))
        _recoveryAction(action, l10n),
    ];
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

    return ThemedDialogs.showCustom<void>(
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

  String _messageText(
    UserFriendlyErrorMessage message,
    AppLocalizations? l10n,
  ) {
    switch (message) {
      case UserFriendlyErrorMessage.networkTimeout:
        return l10n?.networkTimeoutError ??
            'Connection timed out. Please check your internet connection and try again.';
      case UserFriendlyErrorMessage.networkUnreachable:
        return l10n?.networkUnreachableError ??
            'Cannot reach the server. Please check your server URL and internet connection.';
      case UserFriendlyErrorMessage.networkServerNotResponding:
        return l10n?.networkServerNotResponding ??
            'Server is not responding. Please verify the server is running and accessible.';
      case UserFriendlyErrorMessage.networkGeneric:
        return l10n?.networkGenericError ??
            'Network connection problem. Please check your internet connection.';
      case UserFriendlyErrorMessage.validationInvalidEmail:
        return l10n?.validationInvalidEmail ??
            'Please enter a valid email address.';
      case UserFriendlyErrorMessage.validationWeakPassword:
        return l10n?.validationWeakPassword ??
            'Password doesn\'t meet requirements. Please check and try again.';
      case UserFriendlyErrorMessage.validationMissingRequired:
        return l10n?.validationMissingRequired ??
            'Please fill in all required fields.';
      case UserFriendlyErrorMessage.validationFormat:
        return l10n?.validationFormatError ??
            'Some information is in the wrong format. Please check and try again.';
      case UserFriendlyErrorMessage.validationGeneric:
        return l10n?.validationGenericError ??
            'Please check your input and try again.';
      case UserFriendlyErrorMessage.server500:
        return l10n?.serverError500 ??
            'Server is experiencing issues. This is usually temporary.';
      case UserFriendlyErrorMessage.serverUnavailable:
        return l10n?.serverErrorUnavailable ??
            'Server is temporarily unavailable. Please try again in a moment.';
      case UserFriendlyErrorMessage.serverTimeout:
        return l10n?.serverErrorTimeout ??
            'Server took too long to respond. Please try again.';
      case UserFriendlyErrorMessage.serverGeneric:
        return l10n?.serverErrorGeneric ??
            'Server is having problems. Please try again later.';
      case UserFriendlyErrorMessage.authSessionExpired:
        return l10n?.authSessionExpired ??
            'Your session has expired. Please sign in again.';
      case UserFriendlyErrorMessage.authForbidden:
        return l10n?.authForbidden ??
            'You don\'t have permission to perform this action.';
      case UserFriendlyErrorMessage.authInvalidToken:
        return l10n?.authInvalidToken ??
            'Authentication token is invalid. Please sign in again.';
      case UserFriendlyErrorMessage.authGeneric:
        return l10n?.authGenericError ??
            'Authentication problem. Please sign in again.';
      case UserFriendlyErrorMessage.fileNotFound:
        return l10n?.fileNotFound ??
            'File not found. It may have been moved or deleted.';
      case UserFriendlyErrorMessage.fileAccessDenied:
        return l10n?.fileAccessDenied ??
            'Cannot access the file. Please check permissions.';
      case UserFriendlyErrorMessage.fileTooLarge:
        return l10n?.fileTooLarge ??
            'File is too large. Please choose a smaller file.';
      case UserFriendlyErrorMessage.fileGeneric:
        return l10n?.fileGenericError ??
            'Problem with the file. Please try a different file.';
      case UserFriendlyErrorMessage.permissionCamera:
        return l10n?.permissionCameraRequired ??
            'Camera permission is required. Please enable it in settings.';
      case UserFriendlyErrorMessage.permissionStorage:
        return l10n?.permissionStorageRequired ??
            'Storage permission is required. Please enable it in settings.';
      case UserFriendlyErrorMessage.permissionMicrophone:
        return l10n?.permissionMicrophoneRequired ??
            'Microphone permission is required. Please enable it in settings.';
      case UserFriendlyErrorMessage.permissionGeneric:
        return l10n?.permissionGenericError ??
            'Permission required. Please check app permissions in settings.';
      case UserFriendlyErrorMessage.unexpected:
        return l10n?.errorMessage ??
            'Something unexpected happened. Please try again.';
    }
  }

  ErrorRecoveryAction _recoveryAction(
    UserFriendlyRecoveryAction action,
    AppLocalizations? l10n,
  ) {
    final (label, description) = switch (action) {
      UserFriendlyRecoveryAction.retryRequest => (
        l10n?.retry ?? 'Retry',
        l10n?.actionRetryRequest ?? 'Try the request again',
      ),
      UserFriendlyRecoveryAction.retryServerRequest => (
        l10n?.retry ?? 'Retry',
        l10n?.actionRetryRequest ?? 'Retry your request',
      ),
      UserFriendlyRecoveryAction.retryAfterDelay => (
        l10n?.retry ?? 'Retry',
        l10n?.actionRetryAfterDelay ?? 'Wait a moment then try again',
      ),
      UserFriendlyRecoveryAction.retryOperation => (
        l10n?.retry ?? 'Retry',
        l10n?.actionRetryOperation ?? 'Retry the operation',
      ),
      UserFriendlyRecoveryAction.retryAfterPermission => (
        l10n?.retry ?? 'Retry',
        l10n?.actionRetryAfterPermission ?? 'Retry after granting permission',
      ),
      UserFriendlyRecoveryAction.checkConnection => (
        l10n?.checkConnection ?? 'Check Connection',
        l10n?.actionVerifyConnection ?? 'Verify your internet connection',
      ),
      UserFriendlyRecoveryAction.signIn => (
        l10n?.signIn ?? 'Sign In',
        l10n?.actionSignInToAccount ?? 'Sign in to your account',
      ),
      UserFriendlyRecoveryAction.chooseDifferentFile => (
        l10n?.chooseDifferentFile ?? 'Choose Different File',
        l10n?.actionSelectAnotherFile ?? 'Select another file',
      ),
      UserFriendlyRecoveryAction.openSettings => (
        l10n?.openSettings ?? 'Open Settings',
        l10n?.actionOpenAppSettings ?? 'Open app settings to grant permissions',
      ),
      UserFriendlyRecoveryAction.goBack => (
        l10n?.back ?? 'Go Back',
        l10n?.actionReturnToPrevious ?? 'Return to previous screen',
      ),
    };
    return ErrorRecoveryAction(
      label: label,
      action: action.type,
      description: description,
    );
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
