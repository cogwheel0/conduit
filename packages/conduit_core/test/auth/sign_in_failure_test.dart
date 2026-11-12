import 'package:checks/checks.dart';
import 'package:conduit_core/auth/sign_in_failure.dart';
import 'package:test/test.dart';

void main() {
  test('reads the manager\'s words for a server out of reach or too slow', () {
    // As the sign-in page gets them: thrown, or published and rethrown.
    check(classifySignInFailure('Exception: $signInUnreachableMessage'))
        .equals(SignInFailure.unreachable);
    check(classifySignInFailure('Exception: $signInTimedOutMessage'))
        .equals(SignInFailure.timedOut);
    // A raw exception reads the same.
    check(classifySignInFailure('SocketException: Connection refused'))
        .equals(SignInFailure.unreachable);
    check(classifySignInFailure('DioException [connection timeout]: timeout'))
        .equals(SignInFailure.timedOut);
  });

  test('a raw exception reads as the manager words it, in its order', () {
    // The manager matches case-blind and puts a timeout before a lost
    // connection; the page must agree for the same text.
    check(
      classifySignInFailure(
        'TimeoutException after 0:00:30.000000: Future not completed',
      ),
    ).equals(SignInFailure.timedOut);
    check(classifySignInFailure('SocketException: read timeout'))
        .equals(SignInFailure.timedOut);
    // "timed out" is not "timeout": the manager reads it as unreachable.
    check(classifySignInFailure('SocketException: Connection timed out'))
        .equals(SignInFailure.unreachable);
  });

  test('a refusal or a code wins over a word about the connection', () {
    check(classifySignInFailure('401 Unauthorized: sign-in rejected by server'))
        .equals(SignInFailure.invalidCredentials);
    check(classifySignInFailure('accountPendingApproval'))
        .equals(SignInFailure.accountPendingApproval);
    check(classifySignInFailure('Sign-in failed. Please try again.'))
        .equals(SignInFailure.failed);
  });
}
