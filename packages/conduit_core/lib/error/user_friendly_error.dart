/// Categorises an arbitrary error by what its text says, and picks the
/// recovery actions to offer.
///
/// This file owns *which* message and *which* actions; the app turns those
/// ids into its localized strings (`UserFriendlyErrorHandler`). Nothing here knows a locale, a
/// widget or a router.
library;

/// What kind of problem an error's text describes.
///
/// The order of the categories is the order they are tested in: an error
/// that mentions both a timeout and a 500 is a [network] error.
enum UserFriendlyErrorKind {
  network,
  validation,
  server,
  authentication,
  file,
  permission,

  /// Nothing matched.
  unknown,
}

/// The message to show, one id per string the front-ends localize.
enum UserFriendlyErrorMessage {
  networkTimeout,
  networkUnreachable,
  networkServerNotResponding,
  networkGeneric,
  validationInvalidEmail,
  validationWeakPassword,
  validationMissingRequired,
  validationFormat,
  validationGeneric,
  server500,
  serverUnavailable,
  serverTimeout,
  serverGeneric,
  authSessionExpired,
  authForbidden,
  authInvalidToken,
  authGeneric,
  fileNotFound,
  fileAccessDenied,
  fileTooLarge,
  fileGeneric,
  permissionCamera,
  permissionStorage,
  permissionMicrophone,
  permissionGeneric,

  /// Nothing matched: "something unexpected happened".
  unexpected,
}

/// What tapping a recovery action does.
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

/// A recovery action to offer. Each id is one label and description pair in
/// the front-ends' strings; [type] is what the action does.
enum UserFriendlyRecoveryAction {
  /// Network: "Retry" / "try the request again".
  retryRequest(ErrorActionType.retry),

  /// Server: "Retry" / "retry your request".
  retryServerRequest(ErrorActionType.retry),

  /// Server: "Retry" / "wait a moment then try again".
  retryAfterDelay(ErrorActionType.retryLater),

  /// Authentication, file and generic: "Retry" / "retry the operation".
  retryOperation(ErrorActionType.retry),

  /// Permission: "Retry" / "retry after granting permission".
  retryAfterPermission(ErrorActionType.retry),
  checkConnection(ErrorActionType.checkConnection),
  signIn(ErrorActionType.signIn),
  chooseDifferentFile(ErrorActionType.chooseFile),
  openSettings(ErrorActionType.openSettings),
  goBack(ErrorActionType.goBack);

  const UserFriendlyRecoveryAction(this.type);

  final ErrorActionType type;
}

/// The result of [classifyUserFriendlyError].
final class UserFriendlyError {
  const UserFriendlyError(this.kind, this.message);

  final UserFriendlyErrorKind kind;
  final UserFriendlyErrorMessage message;
}

/// Categorises [error] from its lower-cased `toString()`.
UserFriendlyError classifyUserFriendlyError(Object? error) {
  final text = '$error'.toLowerCase();
  if (_isNetwork(text)) {
    return UserFriendlyError(
      UserFriendlyErrorKind.network,
      _networkMessage(text),
    );
  }
  if (_isValidation(text)) {
    return UserFriendlyError(
      UserFriendlyErrorKind.validation,
      _validationMessage(text),
    );
  }
  if (_isServer(text)) {
    return UserFriendlyError(
      UserFriendlyErrorKind.server,
      _serverMessage(text),
    );
  }
  if (_isAuthentication(text)) {
    return UserFriendlyError(
      UserFriendlyErrorKind.authentication,
      _authenticationMessage(text),
    );
  }
  if (_isFile(text)) {
    return UserFriendlyError(UserFriendlyErrorKind.file, _fileMessage(text));
  }
  if (_isPermission(text)) {
    return UserFriendlyError(
      UserFriendlyErrorKind.permission,
      _permissionMessage(text),
    );
  }
  return const UserFriendlyError(
    UserFriendlyErrorKind.unknown,
    UserFriendlyErrorMessage.unexpected,
  );
}

/// The recovery actions to offer for [error], most useful first.
///
/// Validation errors get the generic actions: there is nothing to retry
/// until the input changes.
List<UserFriendlyRecoveryAction> userFriendlyRecoveryActions(Object? error) {
  final text = '$error'.toLowerCase();
  if (_isNetwork(text)) {
    return const [
      UserFriendlyRecoveryAction.retryRequest,
      UserFriendlyRecoveryAction.checkConnection,
    ];
  }
  if (_isServer(text)) {
    return const [
      UserFriendlyRecoveryAction.retryServerRequest,
      UserFriendlyRecoveryAction.retryAfterDelay,
    ];
  }
  if (_isAuthentication(text)) {
    return const [
      UserFriendlyRecoveryAction.signIn,
      UserFriendlyRecoveryAction.retryOperation,
    ];
  }
  if (_isFile(text)) {
    return const [
      UserFriendlyRecoveryAction.chooseDifferentFile,
      UserFriendlyRecoveryAction.retryOperation,
    ];
  }
  if (_isPermission(text)) {
    return const [
      UserFriendlyRecoveryAction.openSettings,
      UserFriendlyRecoveryAction.retryAfterPermission,
    ];
  }
  return const [
    UserFriendlyRecoveryAction.retryOperation,
    UserFriendlyRecoveryAction.goBack,
  ];
}

bool _isNetwork(String error) =>
    error.contains('socketexception') ||
    error.contains('network') ||
    error.contains('connection') ||
    error.contains('timeout') ||
    error.contains('handshake') ||
    error.contains('no address associated');

UserFriendlyErrorMessage _networkMessage(String error) {
  if (error.contains('timeout')) return UserFriendlyErrorMessage.networkTimeout;
  if (error.contains('no address associated')) {
    return UserFriendlyErrorMessage.networkUnreachable;
  }
  if (error.contains('connection refused')) {
    return UserFriendlyErrorMessage.networkServerNotResponding;
  }
  return UserFriendlyErrorMessage.networkGeneric;
}

bool _isValidation(String error) =>
    error.contains('validation') ||
    error.contains('invalid') ||
    error.contains('format') ||
    error.contains('required') ||
    error.contains('400');

UserFriendlyErrorMessage _validationMessage(String error) {
  if (error.contains('email')) {
    return UserFriendlyErrorMessage.validationInvalidEmail;
  }
  if (error.contains('password')) {
    return UserFriendlyErrorMessage.validationWeakPassword;
  }
  if (error.contains('required')) {
    return UserFriendlyErrorMessage.validationMissingRequired;
  }
  if (error.contains('format')) {
    return UserFriendlyErrorMessage.validationFormat;
  }
  return UserFriendlyErrorMessage.validationGeneric;
}

bool _isServer(String error) =>
    error.contains('500') ||
    error.contains('502') ||
    error.contains('503') ||
    error.contains('504') ||
    error.contains('server error') ||
    error.contains('internal server error');

UserFriendlyErrorMessage _serverMessage(String error) {
  if (error.contains('500')) return UserFriendlyErrorMessage.server500;
  if (error.contains('502') || error.contains('503')) {
    return UserFriendlyErrorMessage.serverUnavailable;
  }
  if (error.contains('504')) return UserFriendlyErrorMessage.serverTimeout;
  return UserFriendlyErrorMessage.serverGeneric;
}

bool _isAuthentication(String error) =>
    error.contains('401') ||
    error.contains('403') ||
    error.contains('unauthorized') ||
    error.contains('forbidden') ||
    error.contains('authentication') ||
    error.contains('token');

UserFriendlyErrorMessage _authenticationMessage(String error) {
  if (error.contains('401') || error.contains('unauthorized')) {
    return UserFriendlyErrorMessage.authSessionExpired;
  }
  if (error.contains('403') || error.contains('forbidden')) {
    return UserFriendlyErrorMessage.authForbidden;
  }
  if (error.contains('token')) return UserFriendlyErrorMessage.authInvalidToken;
  return UserFriendlyErrorMessage.authGeneric;
}

bool _isFile(String error) =>
    error.contains('file') ||
    error.contains('path') ||
    error.contains('directory') ||
    error.contains('not found') ||
    error.contains('access denied');

UserFriendlyErrorMessage _fileMessage(String error) {
  if (error.contains('not found')) return UserFriendlyErrorMessage.fileNotFound;
  if (error.contains('access denied')) {
    return UserFriendlyErrorMessage.fileAccessDenied;
  }
  if (error.contains('too large')) return UserFriendlyErrorMessage.fileTooLarge;
  return UserFriendlyErrorMessage.fileGeneric;
}

bool _isPermission(String error) =>
    error.contains('permission') ||
    error.contains('denied') ||
    error.contains('unauthorized') ||
    error.contains('access');

UserFriendlyErrorMessage _permissionMessage(String error) {
  if (error.contains('camera')) {
    return UserFriendlyErrorMessage.permissionCamera;
  }
  if (error.contains('storage')) {
    return UserFriendlyErrorMessage.permissionStorage;
  }
  if (error.contains('microphone')) {
    return UserFriendlyErrorMessage.permissionMicrophone;
  }
  return UserFriendlyErrorMessage.permissionGeneric;
}
