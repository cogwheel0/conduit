@TestOn('vm')
library;

import 'package:conduit_desktop_ui/src/app.dart';
import 'package:conduit_desktop_ui/src/pages/onboarding_page.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:test/test.dart';

const _signedIn = AuthSnapshot(
  phase: AuthPhase.authenticated,
  isAuthenticated: true,
  hasToken: true,
);
const _signedOut = AuthSnapshot(phase: AuthPhase.unauthenticated);
const _reviewer = AuthSnapshot(
  phase: AuthPhase.unauthenticated,
  isReviewerMode: true,
);

String? redirect({
  String location = '/',
  AsyncValue<bool> needsOnboarding = const AsyncValue<bool>.data(false),
  AsyncValue<AuthSnapshot> auth = const AsyncValue<AuthSnapshot>.data(
    _signedIn,
  ),
}) => sessionRedirectFor(
  location: location,
  needsOnboarding: needsOnboarding,
  auth: auth,
);

void main() {
  group('never redirects on an unknown state', () {
    test('while onboarding is still loading', () {
      expect(
        redirect(needsOnboarding: const AsyncValue<bool>.loading()),
        isNull,
      );
    });

    test('while the session is still loading', () {
      expect(redirect(auth: const AsyncValue<AuthSnapshot>.loading()), isNull);
    });

    test('when the daemon could not answer', () {
      // An error is not an answer. The connection banner explains this far
      // better than a login form does.
      expect(
        redirect(
          needsOnboarding: AsyncValue<bool>.error(
            const RpcError(code: ConduitErrorCodes.daemonUnavailable),
            StackTrace.empty,
          ),
        ),
        isNull,
      );
    });
  });

  group('onboarding', () {
    test('an unconfigured install goes to onboarding', () {
      expect(
        redirect(needsOnboarding: const AsyncValue<bool>.data(true)),
        '/onboarding',
      );
    });

    test('and is not redirected away from it, which would loop', () {
      expect(
        redirect(
          location: '/onboarding',
          needsOnboarding: const AsyncValue<bool>.data(true),
        ),
        isNull,
      );
    });

    test('a configured install is sent off the onboarding route', () {
      expect(redirect(location: '/onboarding'), '/');
    });
  });

  group('sign-in', () {
    test('a configured but signed-out install goes to sign-in', () {
      expect(
        redirect(auth: const AsyncValue<AuthSnapshot>.data(_signedOut)),
        '/sign-in',
      );
    });

    test('and is not redirected away from it, which would loop', () {
      expect(
        redirect(
          location: '/sign-in',
          auth: const AsyncValue<AuthSnapshot>.data(_signedOut),
        ),
        isNull,
      );
    });

    test('a signed-in window is sent off the sign-in route', () {
      expect(redirect(location: '/sign-in'), '/');
    });

    test('a signed-in window is left alone', () {
      expect(redirect(), isNull);
    });

    test('reviewer mode is a session, not a sign-in prompt', () {
      // No server, no credentials, and still not sent to a form it could
      // never satisfy.
      expect(
        redirect(
          needsOnboarding: const AsyncValue<bool>.data(false),
          auth: const AsyncValue<AuthSnapshot>.data(_reviewer),
        ),
        isNull,
      );
    });
  });

  group('diagnostics stays reachable', () {
    for (final state in <(String, AsyncValue<bool>, AsyncValue<AuthSnapshot>)>[
      (
        'unconfigured',
        AsyncValue<bool>.data(true),
        AsyncValue<AuthSnapshot>.data(_signedOut),
      ),
      (
        'signed out',
        AsyncValue<bool>.data(false),
        AsyncValue<AuthSnapshot>.data(_signedOut),
      ),
      (
        'loading',
        AsyncValue<bool>.loading(),
        AsyncValue<AuthSnapshot>.loading(),
      ),
    ]) {
      test('when ${state.$1}', () {
        // Diagnostics is where someone goes when the core will not start, so
        // gating it behind a session hides it exactly when it is needed.
        expect(
          redirect(
            location: '/diagnostics/core',
            needsOnboarding: state.$2,
            auth: state.$3,
          ),
          isNull,
        );
      });
    }
  });

  group('parseCustomHeaders', () {
    test('reads one Name: value per line', () {
      expect(parseCustomHeaders('X-One: a\nX-Two: b'), <String, String>{
        'X-One': 'a',
        'X-Two': 'b',
      });
    });

    test('ignores blank lines and trims', () {
      expect(parseCustomHeaders('\n  X-One:   a  \n\n'), <String, String>{
        'X-One': 'a',
      });
    });

    test('keeps colons inside the value', () {
      // A bearer token or a URL in a header value contains colons, and
      // splitting on the last one would corrupt it.
      expect(
        parseCustomHeaders('X-Origin: https://example.com:8443'),
        <String, String>{'X-Origin': 'https://example.com:8443'},
      );
    });

    test('allows an empty value', () {
      expect(parseCustomHeaders('X-Flag:'), <String, String>{'X-Flag': ''});
    });

    test('names the offending line rather than dropping it', () {
      // A header the user believed they had set, silently missing, is a
      // support ticket that looks like a server bug.
      expect(
        () => parseCustomHeaders('X-Good: a\nnot a header'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Line 2'),
          ),
        ),
      );
    });

    test('rejects a header name that cannot be sent', () {
      expect(
        () => parseCustomHeaders('X Bad Name: a'),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects a missing name', () {
      expect(
        () => parseCustomHeaders(': orphaned'),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
