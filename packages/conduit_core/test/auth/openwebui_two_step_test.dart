import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/openwebui_two_step.dart';
import 'package:test/test.dart';

void main() {
  group('a sign-in answer', () {
    test('names the second step it asks for', () {
      for (final (step, kind) in [
        ('verify', OpenWebUiTwoStepKind.verify),
        ('enroll', OpenWebUiTwoStepKind.enroll),
        ('recover', OpenWebUiTwoStepKind.recover),
      ]) {
        final challenge = OpenWebUiTwoStepChallenge.fromJson({
          'next_step': step,
          'challenge_token': 'user-1.challenge-token-value',
          'expires_in': 300,
        })!;
        check(challenge.kind).equals(kind);
        check(challenge.challengeToken).equals('user-1.challenge-token-value');
        check(challenge.expiresIn).equals(const Duration(minutes: 5));
      }
    });

    test('with a session, or awaiting approval, asks for none', () {
      check(
        OpenWebUiTwoStepChallenge.fromJson({'token': 'jwt', 'id': 'user-1'}),
      ).isNull();
      check(
        OpenWebUiTwoStepChallenge.fromJson({'next_step': 'pending'}),
      ).isNull();
      check(
        OpenWebUiTwoStepChallenge.fromJson({'next_step': 'verify'}),
      ).isNull();
    });
  });

  test('refusals are told apart by status and detail', () {
    OpenWebUiTwoStepFailure classify(int? status, String? detail) =>
        classifyOpenWebUiTwoStepError(status, detail);

    check(
      classify(401, 'Invalid or already used code.'),
    ).equals(OpenWebUiTwoStepFailure.invalidCode);
    check(
      classify(401, 'Invalid code. Check your authenticator and try again.'),
    ).equals(OpenWebUiTwoStepFailure.invalidCode);
    check(
      classify(401, 'Invalid or expired operator recovery token.'),
    ).equals(OpenWebUiTwoStepFailure.invalidCode);
    check(
      classify(422, 'Invalid authentication request.'),
    ).equals(OpenWebUiTwoStepFailure.invalidCode);
    check(
      classify(401, 'This authentication step expired. Please start again.'),
    ).equals(OpenWebUiTwoStepFailure.expired);
    check(
      classify(403, 'MFA is disabled. Please sign in again.'),
    ).equals(OpenWebUiTwoStepFailure.expired);
    check(
      classify(
        409,
        'Authentication changed in another request. Please start again.',
      ),
    ).equals(OpenWebUiTwoStepFailure.expired);
    check(
      classify(409, 'Authentication is busy. Please try again.'),
    ).equals(OpenWebUiTwoStepFailure.failed);
    check(
      classify(429, 'Too many codes. Please sign in again.'),
    ).equals(OpenWebUiTwoStepFailure.tooManyAttempts);
    check(classify(503, null)).equals(OpenWebUiTwoStepFailure.failed);
    check(classify(null, null)).equals(OpenWebUiTwoStepFailure.failed);
  });

  group('authenticator setup', () {
    const setup = OpenWebUiTwoStepSetup(
      manualKey: 'JBSWY3DPEHPK3PXP',
      qrCode: '',
    );

    test('links to an authenticator app as the server QR code does', () {
      check(
        setup.authenticatorUri(account: 'ava@example.test').toString(),
      ).equals(
        'otpauth://totp/Open%20WebUI:ava%40example.test'
        '?secret=JBSWY3DPEHPK3PXP&issuer=Open%20WebUI',
      );
      check(setup.authenticatorUri(account: ' ').toString()).equals(
        'otpauth://totp/Open%20WebUI?secret=JBSWY3DPEHPK3PXP&issuer=Open%20WebUI',
      );
    });

    test('reads the QR code only from a base64 SVG data URI', () {
      const svg = '<svg xmlns="http://www.w3.org/2000/svg"/>';
      check(
        OpenWebUiTwoStepSetup(
          manualKey: 'K',
          qrCode: 'data:image/svg+xml;base64,${base64.encode(utf8.encode(svg))}',
        ).qrSvg,
      ).equals(svg);
      check(setup.qrSvg).isNull();
      check(
        const OpenWebUiTwoStepSetup(
          manualKey: 'K',
          qrCode: 'data:image/png;base64,AAAA',
        ).qrSvg,
      ).isNull();
    });

    test('never prints its secret', () {
      check(setup.toString()).not((it) => it.contains('JBSW'));
      check(
        const OpenWebUiTwoStepSession(token: 'secret-jwt').toString(),
      ).not((it) => it.contains('secret-jwt'));
    });
  });
}
