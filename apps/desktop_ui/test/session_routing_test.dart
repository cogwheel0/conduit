@TestOn('vm')
library;

import 'package:conduit_desktop_ui/src/app.dart';
import 'package:conduit_desktop_ui/src/file_picker.dart';
import 'package:conduit_desktop_ui/src/l10n/strings.g.dart';
import 'package:conduit_desktop_ui/src/pages/onboarding_page.dart';
import 'package:conduit_desktop_ui/src/pages/settings_page.dart';
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
  bool directOnly = false,
}) => sessionRedirectFor(
  location: location,
  needsOnboarding: needsOnboarding,
  auth: auth,
  directOnly: AsyncValue<bool>.data(directOnly),
);

void main() {
  group('direct connections and no server (M4)', () {
    const signedOut = AsyncValue<AuthSnapshot>.data(
      AuthSnapshot(phase: AuthPhase.unauthenticated),
    );

    test('the chat is reachable without signing in', () {
      expect(redirect(auth: signedOut, directOnly: true), isNull);
    });

    test('sign-in has nothing to offer, so it goes to the chat', () {
      expect(
        redirect(location: '/sign-in', auth: signedOut, directOnly: true),
        '/',
      );
    });

    test('without it, a signed-out window still signs in', () {
      expect(redirect(auth: signedOut), '/sign-in');
    });
  });

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

  group('settings', () {
    test('is reachable while signed out, once a server is configured', () {
      // The Connections tab is how a signed-out user adds, removes or
      // switches servers. Sending them to a sign-in form for the server they
      // are trying to leave is a loop with no exit.
      expect(
        redirect(
          location: '/settings/connections',
          auth: const AsyncValue<AuthSnapshot>.data(_signedOut),
        ),
        isNull,
      );
    });

    test('is reachable while signed in', () {
      expect(redirect(location: '/settings/appearance'), isNull);
    });

    test('is still behind onboarding', () {
      // With nothing configured there is nothing for it to show, and the
      // first thing to do is add a server.
      expect(
        redirect(
          location: '/settings/connections',
          needsOnboarding: const AsyncValue<bool>.data(true),
        ),
        '/onboarding',
      );
    });
  });

  group('language names', () {
    test('every supported locale has an endonym', () {
      // A locale in the catalog with no name here still appears, under its
      // tag -- but it should not, so this is the reminder.
      for (final locale in AppLocale.values) {
        expect(
          languageEndonym(locale.languageTag),
          isNot(locale.languageTag),
          reason: '${locale.languageTag} has no endonym',
        );
      }
    });

    test('an unknown tag falls back to the tag rather than vanishing', () {
      expect(languageEndonym('xx-YY'), 'xx-YY');
    });

    test('the two Chinese scripts are distinguishable', () {
      // They share a language code, so a name keyed on that alone would show
      // the same label twice and make one of them unpickable.
      expect(languageEndonym('zh'), isNot(languageEndonym('zh-Hant')));
    });
  });

  group('containsPemBlock', () {
    test('accepts a certificate', () {
      expect(
        containsPemBlock(
          '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----',
          'CERTIFICATE',
        ),
        isTrue,
      );
    });

    test('accepts the qualified private key headers OpenSSL writes', () {
      // Every one of these is a private key file someone will pick.
      for (final armour in <String>[
        'PRIVATE KEY',
        'RSA PRIVATE KEY',
        'EC PRIVATE KEY',
        'ENCRYPTED PRIVATE KEY',
      ]) {
        expect(
          containsPemBlock('-----BEGIN $armour-----\nx\n', 'PRIVATE KEY'),
          isTrue,
          reason: armour,
        );
      }
    });

    test('rejects the certificate picked into the key field', () {
      // The mistake this check exists for. Without it the failure arrives
      // minutes later as a TLS handshake error blaming the server.
      expect(
        containsPemBlock('-----BEGIN CERTIFICATE-----\nx\n', 'PRIVATE KEY'),
        isFalse,
      );
    });

    test('rejects a file with no PEM armour at all', () {
      // A DER or PKCS#12 file: binary, and nothing like this.
      expect(containsPemBlock('\u0000\u0001binary', 'CERTIFICATE'), isFalse);
      expect(containsPemBlock('', 'CERTIFICATE'), isFalse);
    });

    test('finds a block that is not the first thing in the file', () {
      // Chains and exported bundles routinely carry comments or a subject
      // line above the armour.
      expect(
        containsPemBlock(
          'subject=CN=example\n-----BEGIN CERTIFICATE-----\nx\n',
          'CERTIFICATE',
        ),
        isTrue,
      );
    });
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

  group('floating settings link', () {
    // The pill is the fallback for screens with no chrome. It used to render
    // on every route, which put it on top of the composer's send button and
    // on top of the settings dialog it opens.
    test('is suppressed where the screen has its own entry', () {
      expect(showsFloatingSettingsLink('/'), isFalse);
      expect(showsFloatingSettingsLink('/index.html'), isFalse);
      expect(showsFloatingSettingsLink('/settings/appearance'), isFalse);
      // Pages that lead back to the chat, with composers the pill would
      // cover.
      expect(showsFloatingSettingsLink('/notes/n1'), isFalse);
      expect(showsFloatingSettingsLink('/channels/c1'), isFalse);
    });

    test('is the only way in on the chromeless screens', () {
      expect(showsFloatingSettingsLink('/onboarding'), isTrue);
      expect(showsFloatingSettingsLink('/sign-in'), isTrue);
      expect(showsFloatingSettingsLink('/diagnostics/core'), isTrue);
    });
  });
}
