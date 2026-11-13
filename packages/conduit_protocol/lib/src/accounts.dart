import 'package:freezed_annotation/freezed_annotation.dart';

import 'servers.dart';

part 'accounts.freezed.dart';
part 'accounts.g.dart';

/// Who an account is, as the account list shows it: the name, email and
/// avatar recorded the last time it signed in. Never a token or a password.
@freezed
abstract class AccountUser with _$AccountUser {
  const factory AccountUser({
    String? name,
    String? email,

    /// As the server reported it: usually a server-relative path, which the
    /// window loads through `/files` like any other server image.
    String? avatarUrl,
  }) = _AccountUser;

  factory AccountUser.fromJson(Map<String, dynamic> json) =>
      _$AccountUserFromJson(json);
}

/// One saved Open WebUI account.
///
/// Several accounts can be on one server -- two people, or one person's work
/// and personal sign-ins -- and each keeps its own session and its own local
/// data. Exactly one is active: every other namespace addresses it.
@freezed
abstract class AccountSummary with _$AccountSummary {
  const factory AccountSummary({
    required String id,

    /// The server it is on, shared with the other accounts there: accounts
    /// with the same [serverId] are listed together.
    required String serverId,

    /// How the account reaches its server: name, address in use, and which
    /// TLS and header settings are configured. Its [ServerSummary.id] is the
    /// account's [id], which is what `servers.update` takes to edit them.
    required ServerSummary connection,

    /// Null until the account has signed in once.
    AccountUser? user,
    @Default(false) bool isActive,

    /// Whether switching to it restores a session rather than asking for a
    /// sign-in. False for an account whose sign-in was never finished, or
    /// whose session was revoked.
    @Default(false) bool hasSession,

    /// UTC milliseconds of the last switch to it or sign-in on it.
    int? lastUsedMs,
  }) = _AccountSummary;

  factory AccountSummary.fromJson(Map<String, dynamic> json) =>
      _$AccountSummaryFromJson(json);
}

/// Reply to `accounts.list`, and part of every account change's reply.
@freezed
abstract class AccountList with _$AccountList {
  const factory AccountList({
    @Default(<AccountSummary>[]) List<AccountSummary> accounts,

    /// Null when no Open WebUI account is in use: a Direct-only or
    /// Hermes-only setup, or one that has not chosen a backend yet.
    String? activeAccountId,

    /// Whether an account is being added: `accounts.add` made a new account
    /// active, signed out, and its sign-in has not finished. The window shows
    /// sign-in with a Cancel back to the account it was added from.
    @Default(false) bool addingAccount,
  }) = _AccountList;

  factory AccountList.fromJson(Map<String, dynamic> json) =>
      _$AccountListFromJson(json);
}

/// Params for `accounts.add`.
@freezed
abstract class AddAccount with _$AddAccount {
  const factory AddAccount({
    /// The server to sign in to. Its [ServerDraft.id] is ignored: a new
    /// account is always a new entry, and one on a saved server's address
    /// joins that server.
    required ServerDraft server,

    /// Adding makes the new account active, which leaves the account in use
    /// and stops any answer still being written there. Without this the
    /// change is refused while one is, with `blockedByActiveReply`.
    @Default(false) bool force,
  }) = _AddAccount;

  factory AddAccount.fromJson(Map<String, dynamic> json) =>
      _$AddAccountFromJson(json);
}

/// Params for `accounts.switch` and `accounts.remove`.
@freezed
abstract class AccountRef with _$AccountRef {
  const factory AccountRef({
    required String accountId,

    /// Leave the active account even while an answer is being written there,
    /// stopping it. See [AccountChangeOutcome.blockedByActiveReply].
    @Default(false) bool force,
  }) = _AccountRef;

  factory AccountRef.fromJson(Map<String, dynamic> json) =>
      _$AccountRefFromJson(json);
}

/// Params for `accounts.signOut`: signs out of the active account.
@freezed
abstract class AccountSignOut with _$AccountSignOut {
  const factory AccountSignOut({@Default(false) bool force}) = _AccountSignOut;

  factory AccountSignOut.fromJson(Map<String, dynamic> json) =>
      _$AccountSignOutFromJson(json);
}

/// What an account change did.
@JsonEnum(fieldRename: FieldRename.none)
enum AccountChangeOutcome {
  /// Done, and the account now active is signed in -- or none is active and
  /// the app carries on with Direct or Hermes.
  done,

  /// Done, and the account now active needs a sign-in.
  needsSignIn,

  /// Nothing to do: that account was already active.
  alreadyActive,

  /// Refused: an answer is still being written in the account that would be
  /// left. Ask the user, then call again with `force`.
  blockedByActiveReply,

  /// Nothing changed: `accounts.cancelAdd` with no addition to leave, or one
  /// whose sign-in has finished.
  unchanged,
}

/// Reply to the account changes: what happened, and the accounts after it.
@freezed
abstract class AccountChangeResult with _$AccountChangeResult {
  const factory AccountChangeResult({
    required AccountChangeOutcome outcome,
    required AccountList accounts,
  }) = _AccountChangeResult;

  factory AccountChangeResult.fromJson(Map<String, dynamic> json) =>
      _$AccountChangeResultFromJson(json);
}

/// Payload of `accounts.changed`: the accounts, or which one is active,
/// changed. Fetch `accounts.list` for the rest.
@freezed
abstract class AccountsChanged with _$AccountsChanged {
  const factory AccountsChanged({String? activeAccountId}) = _AccountsChanged;

  factory AccountsChanged.fromJson(Map<String, dynamic> json) =>
      _$AccountsChangedFromJson(json);
}
