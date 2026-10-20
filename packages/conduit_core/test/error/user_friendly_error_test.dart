import 'package:checks/checks.dart';
import 'package:conduit_core/error/user_friendly_error.dart';
import 'package:test/test.dart';

void main() {
  UserFriendlyError classify(Object? error) => classifyUserFriendlyError(error);

  group('classifyUserFriendlyError messages', () {
    // Each row: error text, kind, message. The texts are what Dart and Dio
    // put in `toString()`, matched case-insensitively.
    const cases = <(String, UserFriendlyErrorKind, UserFriendlyErrorMessage)>[
      (
        'SocketException: Connection timeout',
        UserFriendlyErrorKind.network,
        UserFriendlyErrorMessage.networkTimeout,
      ),
      (
        'Failed host lookup: No address associated with hostname',
        UserFriendlyErrorKind.network,
        UserFriendlyErrorMessage.networkUnreachable,
      ),
      (
        'Connection refused',
        UserFriendlyErrorKind.network,
        UserFriendlyErrorMessage.networkServerNotResponding,
      ),
      (
        'HandshakeException',
        UserFriendlyErrorKind.network,
        UserFriendlyErrorMessage.networkGeneric,
      ),
      (
        'validation failed: bad email',
        UserFriendlyErrorKind.validation,
        UserFriendlyErrorMessage.validationInvalidEmail,
      ),
      (
        'invalid password',
        UserFriendlyErrorKind.validation,
        UserFriendlyErrorMessage.validationWeakPassword,
      ),
      (
        'field is required',
        UserFriendlyErrorKind.validation,
        UserFriendlyErrorMessage.validationMissingRequired,
      ),
      (
        'bad format',
        UserFriendlyErrorKind.validation,
        UserFriendlyErrorMessage.validationFormat,
      ),
      (
        'status 400',
        UserFriendlyErrorKind.validation,
        UserFriendlyErrorMessage.validationGeneric,
      ),
      (
        'HTTP 500',
        UserFriendlyErrorKind.server,
        UserFriendlyErrorMessage.server500,
      ),
      (
        'HTTP 502',
        UserFriendlyErrorKind.server,
        UserFriendlyErrorMessage.serverUnavailable,
      ),
      (
        'HTTP 503',
        UserFriendlyErrorKind.server,
        UserFriendlyErrorMessage.serverUnavailable,
      ),
      (
        'HTTP 504',
        UserFriendlyErrorKind.server,
        UserFriendlyErrorMessage.serverTimeout,
      ),
      (
        'server error',
        UserFriendlyErrorKind.server,
        UserFriendlyErrorMessage.serverGeneric,
      ),
      (
        'HTTP 401',
        UserFriendlyErrorKind.authentication,
        UserFriendlyErrorMessage.authSessionExpired,
      ),
      (
        'Unauthorized',
        UserFriendlyErrorKind.authentication,
        UserFriendlyErrorMessage.authSessionExpired,
      ),
      (
        'HTTP 403',
        UserFriendlyErrorKind.authentication,
        UserFriendlyErrorMessage.authForbidden,
      ),
      (
        'expired token',
        UserFriendlyErrorKind.authentication,
        UserFriendlyErrorMessage.authInvalidToken,
      ),
      (
        'authentication needed',
        UserFriendlyErrorKind.authentication,
        UserFriendlyErrorMessage.authGeneric,
      ),
      (
        'File not found',
        UserFriendlyErrorKind.file,
        UserFriendlyErrorMessage.fileNotFound,
      ),
      (
        'directory: access denied',
        UserFriendlyErrorKind.file,
        UserFriendlyErrorMessage.fileAccessDenied,
      ),
      (
        'file too large',
        UserFriendlyErrorKind.file,
        UserFriendlyErrorMessage.fileTooLarge,
      ),
      (
        'bad path',
        UserFriendlyErrorKind.file,
        UserFriendlyErrorMessage.fileGeneric,
      ),
      (
        'camera permission',
        UserFriendlyErrorKind.permission,
        UserFriendlyErrorMessage.permissionCamera,
      ),
      (
        'storage denied',
        UserFriendlyErrorKind.permission,
        UserFriendlyErrorMessage.permissionStorage,
      ),
      (
        'microphone access',
        UserFriendlyErrorKind.permission,
        UserFriendlyErrorMessage.permissionMicrophone,
      ),
      (
        'denied',
        UserFriendlyErrorKind.permission,
        UserFriendlyErrorMessage.permissionGeneric,
      ),
      (
        'something odd',
        UserFriendlyErrorKind.unknown,
        UserFriendlyErrorMessage.unexpected,
      ),
    ];

    for (final (text, kind, message) in cases) {
      test('"$text" is ${kind.name} / ${message.name}', () {
        final result = classify(text);
        check(result.kind).equals(kind);
        check(result.message).equals(message);
      });
    }

    test('matches the text of any object, not just strings', () {
      check(classify(Exception('connection lost')).kind)
          .equals(UserFriendlyErrorKind.network);
      check(classify(null).kind).equals(UserFriendlyErrorKind.unknown);
    });
  });

  group('category precedence', () {
    test('network wins over server and validation', () {
      check(classify('timeout after 500 ms, invalid').kind)
          .equals(UserFriendlyErrorKind.network);
    });

    test('validation wins over server', () {
      check(classify('invalid response 500').kind)
          .equals(UserFriendlyErrorKind.validation);
    });

    test('server wins over authentication', () {
      check(classify('503 token service').kind)
          .equals(UserFriendlyErrorKind.server);
    });

    test('authentication wins over permission for "unauthorized"', () {
      check(classify('unauthorized').kind)
          .equals(UserFriendlyErrorKind.authentication);
    });

    test('file wins over permission for "access denied"', () {
      check(classify('access denied').kind).equals(UserFriendlyErrorKind.file);
    });

    test('a timeout message beats the refused-connection one', () {
      check(classify('connection refused, timeout').message)
          .equals(UserFriendlyErrorMessage.networkTimeout);
    });
  });

  group('userFriendlyRecoveryActions', () {
    List<UserFriendlyRecoveryAction> actions(String text) =>
        userFriendlyRecoveryActions(text);

    test('network: retry, then check the connection', () {
      check(actions('socketexception')).deepEquals([
        UserFriendlyRecoveryAction.retryRequest,
        UserFriendlyRecoveryAction.checkConnection,
      ]);
    });

    test('server: retry, then retry after a delay', () {
      check(actions('http 503')).deepEquals([
        UserFriendlyRecoveryAction.retryServerRequest,
        UserFriendlyRecoveryAction.retryAfterDelay,
      ]);
    });

    test('authentication: sign in first', () {
      check(actions('http 401')).deepEquals([
        UserFriendlyRecoveryAction.signIn,
        UserFriendlyRecoveryAction.retryOperation,
      ]);
    });

    test('file: choose another file', () {
      check(actions('file missing')).deepEquals([
        UserFriendlyRecoveryAction.chooseDifferentFile,
        UserFriendlyRecoveryAction.retryOperation,
      ]);
    });

    test('permission: open settings', () {
      check(actions('permission needed')).deepEquals([
        UserFriendlyRecoveryAction.openSettings,
        UserFriendlyRecoveryAction.retryAfterPermission,
      ]);
    });

    test('validation gets the generic actions', () {
      check(actions('invalid input')).deepEquals([
        UserFriendlyRecoveryAction.retryOperation,
        UserFriendlyRecoveryAction.goBack,
      ]);
    });

    test('unknown gets the generic actions', () {
      check(actions('zzz')).deepEquals([
        UserFriendlyRecoveryAction.retryOperation,
        UserFriendlyRecoveryAction.goBack,
      ]);
    });

    test('each action maps to the type that performs it', () {
      check(UserFriendlyRecoveryAction.retryAfterDelay.type)
          .equals(ErrorActionType.retryLater);
      check(UserFriendlyRecoveryAction.retryServerRequest.type)
          .equals(ErrorActionType.retry);
      check(UserFriendlyRecoveryAction.signIn.type)
          .equals(ErrorActionType.signIn);
      check(UserFriendlyRecoveryAction.goBack.type)
          .equals(ErrorActionType.goBack);
      check(UserFriendlyRecoveryAction.chooseDifferentFile.type)
          .equals(ErrorActionType.chooseFile);
    });
  });
}
