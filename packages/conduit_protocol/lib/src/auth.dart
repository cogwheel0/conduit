import 'package:freezed_annotation/freezed_annotation.dart';

part 'auth.freezed.dart';
part 'auth.g.dart';

/// Mirrors the core's `AuthStatus` one-for-one.
///
/// Repeated rather than shared because `conduit_core` cannot cross into the
/// renderer -- it reaches `dart:io`. Adding a case to one without the other
/// is caught by the exhaustive switch in the daemon's mapper, which is the
/// point of keeping it an enum on both sides.
@JsonEnum(fieldRename: FieldRename.none)
enum AuthPhase {
  /// Nothing has been attempted yet this launch.
  initial,
  loading,
  authenticated,
  unauthenticated,

  /// A token existed and is no longer accepted -- distinct from never having
  /// had one, because the UI offers "sign in again" rather than onboarding.
  tokenExpired,
  error,

  /// The credentials themselves were rejected, so retrying the same ones is
  /// pointless and the form says so.
  credentialError,
}

/// The renderer's view of the session.
///
/// Carries no token. The renderer never holds one: every authenticated
/// request is made by the daemon, which is what lets the token live in the
/// secure store and nowhere else.
@freezed
abstract class AuthSnapshot with _$AuthSnapshot {
  const factory AuthSnapshot({
    required AuthPhase phase,
    @Default(false) bool isAuthenticated,
    @Default(false) bool isLoading,

    /// True when a token is held daemon-side. The UI uses this to tell
    /// "signed in" from "signing in".
    @Default(false) bool hasToken,
    AuthUser? user,

    /// Set when [phase] is `error` or `credentialError`. A code plus args,
    /// localized in the UI -- never server prose, which would arrive in the
    /// server's locale rather than the user's.
    String? errorCode,
    @Default(<String, String>{}) Map<String, String> errorArgs,

    /// True when the reviewer/demo path is active: the UI runs against
    /// canned models and conversations with no server at all.
    @Default(false) bool isReviewerMode,

    /// Set while a password or LDAP sign-in waits on its second step
    /// (`auth.twoStep.*`): the password was right, and the server asks for
    /// an authenticator code before it issues a session.
    TwoStepChallenge? twoStep,

    /// The active server is reached through a reverse proxy whose session
    /// cookie the account keeps, so an expired proxy session can be signed
    /// in to again in place (`auth.renewProxy`) rather than signed out of.
    @Default(false) bool canRenewProxy,
  }) = _AuthSnapshot;

  factory AuthSnapshot.fromJson(Map<String, dynamic> json) =>
      _$AuthSnapshotFromJson(json);
}

/// The signed-in user, reduced to what the desktop chrome renders.
@freezed
abstract class AuthUser with _$AuthUser {
  const factory AuthUser({
    required String id,
    required String name,
    String? email,
    String? role,

    /// Relative to the active server; the renderer loads it through the
    /// daemon's file proxy so no credential is needed to fetch it.
    String? avatarUrl,
  }) = _AuthUser;

  factory AuthUser.fromJson(Map<String, dynamic> json) =>
      _$AuthUserFromJson(json);
}

/// Params for `auth.loginWithPassword` and `auth.loginWithLdap`.
@freezed
abstract class PasswordLogin with _$PasswordLogin {
  const factory PasswordLogin({
    required String username,
    required String password,
  }) = _PasswordLogin;

  factory PasswordLogin.fromJson(Map<String, dynamic> json) =>
      _$PasswordLoginFromJson(json);
}

/// Params for `auth.loginWithApiKey`: a session token (JWT) copied from
/// Open WebUI. API keys (`sk-…`) are refused with `auth.apiKeyNotSupported`.
@freezed
abstract class ApiKeyLogin with _$ApiKeyLogin {
  const factory ApiKeyLogin({required String apiKey}) = _ApiKeyLogin;

  factory ApiKeyLogin.fromJson(Map<String, dynamic> json) =>
      _$ApiKeyLoginFromJson(json);
}

/// Params for `auth.completeExternal`: the tail of an SSO, OAuth or
/// reverse-proxy sign-in that happened in a window of the desktop app.
///
/// The app owns that window (a web view) because the flow needs a real
/// browser -- a redirect chain, third-party cookies, possibly a hardware
/// key. It captures what the session left behind and hands it over here;
/// the daemon validates it against the server before committing, so a
/// window that was closed early cannot leave a half-authenticated state.
@freezed
abstract class ExternalAuthCompletion with _$ExternalAuthCompletion {
  const factory ExternalAuthCompletion({
    /// Origin the cookies belong to, so they cannot be attached to a
    /// different server than the one that issued them.
    required String origin,
    @Default(<String, String>{}) Map<String, String> cookies,

    /// Set when the provider returned a bearer token directly rather than a
    /// cookie session.
    String? token,

    /// The account whose sign-in window this was (its id, as `accounts.list`
    /// names it): required for `auth.renewProxy`, and checked by
    /// `auth.completeExternal` when given. Refused with `auth.sessionExpired`
    /// once another account is in charge, or (renewal) when the captured
    /// session is another user's. Given to `servers.addresses.save`, the
    /// address is saved only when that account proves it (else
    /// `needsSignIn`).
    String? account,
  }) = _ExternalAuthCompletion;

  factory ExternalAuthCompletion.fromJson(Map<String, dynamic> json) =>
      _$ExternalAuthCompletionFromJson(json);
}

/// Reply to `auth.hasSavedCredentials`.
@freezed
abstract class SavedCredentialsResult with _$SavedCredentialsResult {
  const factory SavedCredentialsResult({required bool hasSavedCredentials}) =
      _SavedCredentialsResult;

  factory SavedCredentialsResult.fromJson(Map<String, dynamic> json) =>
      _$SavedCredentialsResultFromJson(json);
}

/// Params for `auth.setReviewerMode`.
@freezed
abstract class ReviewerMode with _$ReviewerMode {
  const factory ReviewerMode({required bool enabled}) = _ReviewerMode;

  factory ReviewerMode.fromJson(Map<String, dynamic> json) =>
      _$ReviewerModeFromJson(json);
}

/// What an Open WebUI two-step sign-in asks for next.
@JsonEnum(fieldRename: FieldRename.none)
enum TwoStepStage {
  /// A code from the account's authenticator app, or one of its recovery
  /// codes.
  verify,

  /// The first sign-in since two-step verification became required: add
  /// the authenticator (`auth.twoStep.setup`), then confirm it with a code.
  enroll,

  /// An administrator reset the authenticator: their recovery token, which
  /// leads on to [enroll].
  recover,

  /// The authenticator was just added: the account's new recovery codes,
  /// which the server shows only once, before the session is signed in to
  /// (`auth.twoStep.finish`).
  recoveryCodes,
}

/// A sign-in waiting on its second step. Carries no challenge token: that
/// stays in the daemon, as every token does.
@freezed
abstract class TwoStepChallenge with _$TwoStepChallenge {
  const factory TwoStepChallenge({
    required TwoStepStage stage,

    /// The username or email the sign-in began with, which labels the entry
    /// in the authenticator app.
    @Default('') String account,

    /// How long the server keeps this step, in seconds, from when it began.
    @Default(0) int expiresInSeconds,

    /// For [TwoStepStage.recoveryCodes]: the codes, each of which signs in
    /// once in place of an authenticator code.
    @Default(<String>[]) List<String> recoveryCodes,
  }) = _TwoStepChallenge;

  factory TwoStepChallenge.fromJson(Map<String, dynamic> json) =>
      _$TwoStepChallengeFromJson(json);
}

/// Reply to `auth.twoStep.setup`: what to add to an authenticator app.
@freezed
abstract class TwoStepSetup with _$TwoStepSetup {
  const factory TwoStepSetup({
    /// The base32 secret, for typing into an authenticator app.
    required String manualKey,

    /// The server's QR code for [manualKey], as SVG markup; null when the
    /// server sent none the app can draw.
    String? qrSvg,

    /// An `otpauth://` link that adds the key to an authenticator app on
    /// this computer, labelled as the server labels its QR code.
    required String authenticatorUri,
  }) = _TwoStepSetup;

  factory TwoStepSetup.fromJson(Map<String, dynamic> json) =>
      _$TwoStepSetupFromJson(json);
}

/// Params for `auth.twoStep.verify`: a code for a `verify` or `enroll`
/// step.
@freezed
abstract class TwoStepCode with _$TwoStepCode {
  const factory TwoStepCode({
    required String code,

    /// For a `verify` step: [code] is one of the account's recovery codes.
    @Default(false) bool recovery,
  }) = _TwoStepCode;

  factory TwoStepCode.fromJson(Map<String, dynamic> json) =>
      _$TwoStepCodeFromJson(json);
}

/// Params for `auth.twoStep.redeem`: an administrator's recovery token for a
/// `recover` step.
@freezed
abstract class TwoStepResetToken with _$TwoStepResetToken {
  const factory TwoStepResetToken({required String resetToken}) =
      _TwoStepResetToken;

  factory TwoStepResetToken.fromJson(Map<String, dynamic> json) =>
      _$TwoStepResetTokenFromJson(json);
}
