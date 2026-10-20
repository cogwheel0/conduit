import 'dart:convert';

import 'package:meta/meta.dart';

/// What Open WebUI asks for before it issues a session to an account with
/// two-step verification (TOTP), from the `next_step` of a sign-in answer.
enum OpenWebUiTwoStepKind {
  /// A code from the account's authenticator app, or a recovery code.
  verify,

  /// First sign-in since two-step verification was required: add the
  /// authenticator, then confirm it with a code.
  enroll,

  /// An administrator reset the authenticator: redeem their recovery token,
  /// which leads on to [enroll].
  recover,
}

/// One step of an Open WebUI two-step sign-in. The server keeps the step for
/// five minutes and accepts five codes for it.
@immutable
class OpenWebUiTwoStepChallenge {
  const OpenWebUiTwoStepChallenge({
    required this.kind,
    required this.challengeToken,
    required this.expiresIn,
  });

  final OpenWebUiTwoStepKind kind;
  final String challengeToken;
  final Duration expiresIn;

  /// The step a sign-in, or a redeemed recovery token, answered with, or
  /// null when [json] is not one (a session, or an account awaiting approval).
  static OpenWebUiTwoStepChallenge? fromJson(Map<String, dynamic> json) {
    final kind = switch (json['next_step']) {
      'verify' => OpenWebUiTwoStepKind.verify,
      'enroll' => OpenWebUiTwoStepKind.enroll,
      'recover' => OpenWebUiTwoStepKind.recover,
      _ => null,
    };
    final token = json['challenge_token'];
    if (kind == null || token is! String || token.isEmpty) return null;
    final seconds = json['expires_in'];
    return OpenWebUiTwoStepChallenge(
      kind: kind,
      challengeToken: token,
      expiresIn: Duration(seconds: seconds is num ? seconds.toInt() : 0),
    );
  }

  @override
  String toString() => 'OpenWebUiTwoStepChallenge(${kind.name})';
}

/// Thrown by a password or LDAP sign-in when the server asks for a second
/// step before issuing a session.
class OpenWebUiTwoStepRequired implements Exception {
  const OpenWebUiTwoStepRequired(this.challenge);

  final OpenWebUiTwoStepChallenge challenge;

  @override
  String toString() => 'OpenWebUiTwoStepRequired(${challenge.kind.name})';
}

/// The secret to add to an authenticator app while enrolling.
@immutable
class OpenWebUiTwoStepSetup {
  const OpenWebUiTwoStepSetup({required this.manualKey, required this.qrCode});

  /// The base32 secret, for typing into an authenticator app.
  final String manualKey;

  /// The server's QR code for [manualKey], as a `data:image/svg+xml;base64`
  /// URI.
  final String qrCode;

  /// The QR code's SVG markup, or null when [qrCode] is not a base64 SVG.
  String? get qrSvg {
    const prefix = 'data:image/svg+xml;base64,';
    if (!qrCode.startsWith(prefix)) return null;
    try {
      return utf8.decode(base64.decode(qrCode.substring(prefix.length)));
    } catch (_) {
      return null;
    }
  }

  /// An `otpauth://` link that adds [manualKey] to an authenticator app on
  /// this device, labelled as the server labels its QR code.
  Uri authenticatorUri({required String account}) {
    // The same shape as the server's QR code (pyotp's provisioning URI).
    final issuer = Uri.encodeComponent('Open WebUI');
    final name = account.trim();
    final label = name.isEmpty
        ? issuer
        : '$issuer:${Uri.encodeComponent(name)}';
    return Uri.parse(
      'otpauth://totp/$label'
      '?secret=${Uri.encodeComponent(manualKey)}&issuer=$issuer',
    );
  }

  @override
  String toString() => 'OpenWebUiTwoStepSetup(<redacted>)';
}

/// A session issued once the second step succeeded, not yet signed in to.
@immutable
class OpenWebUiTwoStepSession {
  const OpenWebUiTwoStepSession({
    required this.token,
    this.recoveryCodes = const <String>[],
  });

  final String token;

  /// Issued when the authenticator was just added; each signs in once in
  /// place of a code, and the server never shows them again.
  final List<String> recoveryCodes;

  @override
  String toString() =>
      'OpenWebUiTwoStepSession(recoveryCodes: ${recoveryCodes.length})';
}

/// Why a second step was refused.
enum OpenWebUiTwoStepFailure {
  /// The code or recovery token was wrong or already used.
  invalidCode,

  /// The step expired or no longer applies; sign in again.
  expired,

  /// Too many codes for this step or this account; wait, then sign in again.
  tooManyAttempts,

  /// Anything else, such as the server being unreachable.
  failed,
}

class OpenWebUiTwoStepException implements Exception {
  const OpenWebUiTwoStepException(this.failure);

  final OpenWebUiTwoStepFailure failure;

  @override
  String toString() => 'OpenWebUiTwoStepException(${failure.name})';
}

/// Classifies an answer from `/api/v1/auths/mfa/*` by its status and detail.
///
/// Open WebUI 0.12 refuses a wrong code with 401, an expired or replaced step
/// with 401 "This authentication step expired", a step that no longer applies
/// (two-step verification turned off, the account awaiting approval, the
/// sign-in changed elsewhere) with 403 or 409, and too many codes with 429.
OpenWebUiTwoStepFailure classifyOpenWebUiTwoStepError(
  int? statusCode,
  Object? detail,
) {
  final text = detail is String ? detail.toLowerCase() : '';
  return switch (statusCode) {
    429 => OpenWebUiTwoStepFailure.tooManyAttempts,
    401 when text.contains('step expired') ||
        text.contains('invalid authentication request') =>
      OpenWebUiTwoStepFailure.expired,
    401 || 422 => OpenWebUiTwoStepFailure.invalidCode,
    403 => OpenWebUiTwoStepFailure.expired,
    409 when text.contains('start again') => OpenWebUiTwoStepFailure.expired,
    _ => OpenWebUiTwoStepFailure.failed,
  };
}
