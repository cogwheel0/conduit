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

/// Params for `auth.loginWithApiKey`.
@freezed
abstract class ApiKeyLogin with _$ApiKeyLogin {
  const factory ApiKeyLogin({required String apiKey}) = _ApiKeyLogin;

  factory ApiKeyLogin.fromJson(Map<String, dynamic> json) =>
      _$ApiKeyLoginFromJson(json);
}

/// Params for `auth.completeExternal`: the tail of an SSO, OAuth or
/// reverse-proxy sign-in that happened in an Electron window.
///
/// Electron owns that window because the flow needs a real browser -- a
/// redirect chain, third-party cookies, possibly a hardware key. It captures
/// what the session left behind and hands it over here; the daemon validates
/// it against the server before committing, so a window that was closed
/// early cannot leave a half-authenticated state.
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
  }) = _ExternalAuthCompletion;

  factory ExternalAuthCompletion.fromJson(Map<String, dynamic> json) =>
      _$ExternalAuthCompletionFromJson(json);
}

/// Params for `auth.signOut`.
///
/// The two options are genuinely different outcomes and the mobile app makes
/// the user choose, so the protocol does too rather than picking one.
@freezed
abstract class SignOutRequest with _$SignOutRequest {
  const factory SignOutRequest({
    /// Keep the server entry, its URL, headers and TLS settings, so signing
    /// back in does not mean retyping the setup. Credentials go either way.
    @Default(true) bool keepServerDetails,
  }) = _SignOutRequest;

  factory SignOutRequest.fromJson(Map<String, dynamic> json) =>
      _$SignOutRequestFromJson(json);
}

/// Reply to `auth.signOut`.
///
/// Sign-out can partially fail -- a keychain delete can be refused, a
/// database file can be locked -- and reporting that matters: the core keeps
/// an "incomplete logout" fence that suppresses cookie reuse until cleanup
/// finishes, and the UI has to be able to say so.
@freezed
abstract class SignOutResult with _$SignOutResult {
  const factory SignOutResult({
    required SignOutOutcome outcome,

    /// Present when [outcome] is not `cleared`, naming what survived.
    @Default(<String>[]) List<String> remaining,
  }) = _SignOutResult;

  factory SignOutResult.fromJson(Map<String, dynamic> json) =>
      _$SignOutResultFromJson(json);
}

/// Mirrors the core's `FullAppDataClearOutcome`.
@JsonEnum(fieldRename: FieldRename.none)
enum SignOutOutcome {
  /// Everything asked for is gone.
  cleared,

  /// Local data is gone but the session cleanup did not finish; the fence
  /// stays up.
  localDataClearedSessionCleanupIncomplete,

  /// Neither completed. The user is signed out in the UI, but the next
  /// launch must retry cleanup before trusting any surviving cookie.
  incomplete,
}
