import 'package:conduit_core/error/api_error.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/conduit_core.dart';

/// Renders a core [ErrorMessage] in the user's language.
///
/// The core classifies failures but cannot render them: it has no locale, and
/// once `conduitd` hosts it there may be several windows in several
/// languages. This is the Flutter half of that split; the desktop UI has its
/// own.
///
/// The switch is exhaustive on purpose. Adding a [CoreErrorCode] without a
/// case here is a compile error, which is the whole reason the codes are an
/// enum rather than strings.
String localizeCoreError(ErrorMessage message, AppLocalizations l10n) {
  return switch (message.code) {
    CoreErrorCode.generic => l10n.errorMessage,
    CoreErrorCode.networkGeneric => l10n.networkGenericError,
    CoreErrorCode.networkTimeout => l10n.networkTimeoutError,
    CoreErrorCode.requestTimedOut => l10n.requestTimedOut,
    CoreErrorCode.checkConnection => l10n.pleaseCheckConnection,
    CoreErrorCode.serverGeneric => l10n.serverErrorGeneric,
    CoreErrorCode.serverInternal => l10n.serverError500,
    CoreErrorCode.serverUnavailable => l10n.serverErrorUnavailable,
    CoreErrorCode.serverTimeout => l10n.serverErrorTimeout,
    CoreErrorCode.authSessionExpired => l10n.authSessionExpired,
    CoreErrorCode.authForbidden => l10n.authForbidden,
    CoreErrorCode.validationGeneric => l10n.validationGenericError,
    CoreErrorCode.fileNotFound => l10n.fileNotFound,
    CoreErrorCode.securityCertificate => l10n.securityCertificateError,
    CoreErrorCode.rateLimitExceeded => l10n.rateLimitExceeded,
    CoreErrorCode.rateLimitRetrySoon => l10n.rateLimitRetrySoon,
    CoreErrorCode.rateLimitRetryAfter => l10n.rateLimitRetryAfter(
      message.args['delay'] ?? '',
    ),
  };
}

/// The line to show for [error].
///
/// Prefers what the server actually said — it is more specific than any
/// classification — and falls back to the core's code otherwise.
String describeApiError(ApiError error, AppLocalizations l10n) {
  final prose = error.message;
  if (prose != null && prose.trim().isNotEmpty) return prose;
  return localizeCoreError(error.messageCode, l10n);
}

/// [describeApiError] plus a line of actionable advice.
///
/// Moved out of `ApiErrorHandler`: composing user-facing prose is
/// presentation, and it was the last thing keeping `lib/core/error` bound to
/// the localization chain.
String userFacingApiError(ApiError error, AppLocalizations l10n) {
  final baseMessage = describeApiError(error, l10n);

  return switch (error.type) {
    ApiErrorType.network => '$baseMessage\n\n${l10n.pleaseCheckConnection}',
    ApiErrorType.timeout => '$baseMessage\n\n${l10n.requestTimedOut}',
    ApiErrorType.authentication => _withDistinctAdvice(
      baseMessage,
      l10n.authSessionExpired,
    ),
    ApiErrorType.authorization => _withDistinctAdvice(
      baseMessage,
      l10n.authForbidden,
    ),
    ApiErrorType.validation => _withDistinctAdvice(
      baseMessage,
      l10n.validationGenericError,
    ),
    ApiErrorType.rateLimit => _rateLimitAdvice(error, baseMessage, l10n),
    ApiErrorType.server => _withDistinctAdvice(
      baseMessage,
      l10n.serverErrorGeneric,
    ),
    _ => baseMessage,
  };
}

String _rateLimitAdvice(
  ApiError error,
  String baseMessage,
  AppLocalizations l10n,
) {
  final delay = error.retryAfter;
  if (delay == null) return '$baseMessage\n\n${l10n.rateLimitRetrySoon}';
  return '$baseMessage\n\n${l10n.rateLimitRetryAfter(formatRetryDelay(delay))}';
}

/// `2m 30s`, `2m`, `45s`. Not localized, matching the behaviour this replaced.
String formatRetryDelay(Duration delay) {
  final minutes = delay.inMinutes;
  final seconds = delay.inSeconds % 60;
  if (minutes > 0 && seconds > 0) return '${minutes}m ${seconds}s';
  if (minutes > 0) return '${minutes}m';
  return '${delay.inSeconds}s';
}

/// Avoids printing the same sentence twice when the base message already is
/// the advice.
String _withDistinctAdvice(String baseMessage, String advice) {
  if (baseMessage.trim() == advice.trim()) return baseMessage;
  return '$baseMessage\n\n$advice';
}
