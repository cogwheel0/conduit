import 'package:freezed_annotation/freezed_annotation.dart';

part 'access.freezed.dart';
part 'access.g.dart';

/// A resource whose access grants the everyday UI edits. Generic on
/// purpose: chats, folders and notes, and the workspace's models,
/// knowledge bases, prompts, tools and skills.
enum AccessResourceKind {
  chat,
  folder,
  note,
  model,
  knowledge,
  prompt,
  tool,
  skill,
}

/// Who a resource is open to beyond named users and groups, as Open
/// WebUI's access editor shows it: nobody else, every user on the server,
/// or anyone with the link (chats only).
enum AccessAudience { private, public, open }

/// Names a resource for `access.get`.
@freezed
abstract class AccessRef with _$AccessRef {
  const factory AccessRef({
    required AccessResourceKind kind,
    required String id,
  }) = _AccessRef;

  factory AccessRef.fromJson(Map<String, dynamic> json) =>
      _$AccessRefFromJson(json);
}

/// One user or group who may read, or read and write, a resource.
@freezed
abstract class AccessGrantDto with _$AccessGrantDto {
  const factory AccessGrantDto({
    /// `user` or `group`.
    @Default('user') String principalType,
    required String principalId,
    @Default(false) bool write,

    /// The person's or group's name, when the server describes it. Empty
    /// for one it will not describe to this account.
    @Default('') String name,
    String? email,
  }) = _AccessGrantDto;

  factory AccessGrantDto.fromJson(Map<String, dynamic> json) =>
      _$AccessGrantDtoFromJson(json);
}

/// Reply to `access.get` and `access.set`: who can reach the resource now,
/// as the server answers.
@freezed
abstract class AccessState with _$AccessState {
  const factory AccessState({
    required AccessResourceKind kind,
    required String id,

    /// The named users and groups.
    @Default(<AccessGrantDto>[]) List<AccessGrantDto> grants,
    @Default(AccessAudience.private) AccessAudience audience,

    /// The account may change these grants.
    @Default(false) bool canEdit,

    /// The server lets this account grant access to single users.
    @Default(true) bool allowUsers,

    /// The server lets this account grant access to groups.
    @Default(true) bool allowGroups,

    /// A recipient may be given write access (chats' audiences read only).
    @Default(true) bool allowWrite,

    /// The sheet offers an audience (private or every user): not for a
    /// folder, which has none.
    @Default(false) bool allowPublic,

    /// "Anyone with the link" may be chosen too: a chat only, when the
    /// account may share chats openly (`sharing.open_chats`).
    @Default(false) bool allowOpen,

    /// Who owns the resource, when known.
    String? ownerName,
  }) = _AccessState;

  factory AccessState.fromJson(Map<String, dynamic> json) =>
      _$AccessStateFromJson(json);
}

/// Params for `access.set`: the named grants as the sheet holds them.
@freezed
abstract class AccessEdit with _$AccessEdit {
  const factory AccessEdit({
    required AccessResourceKind kind,
    required String id,
    @Default(<AccessGrantDto>[]) List<AccessGrantDto> grants,

    /// Set only when the user picked an audience on purpose; null keeps
    /// the one the resource has.
    AccessAudience? audience,
  }) = _AccessEdit;

  factory AccessEdit.fromJson(Map<String, dynamic> json) =>
      _$AccessEditFromJson(json);
}

/// A user or group access can be granted to.
@freezed
abstract class AccessPrincipal with _$AccessPrincipal {
  const factory AccessPrincipal({
    /// `user` or `group`.
    required String type,
    required String id,
    @Default('') String name,
    String? email,
  }) = _AccessPrincipal;

  factory AccessPrincipal.fromJson(Map<String, dynamic> json) =>
      _$AccessPrincipalFromJson(json);
}

/// Params for `access.principals`: users and groups matching [query].
@freezed
abstract class AccessPrincipalQuery with _$AccessPrincipalQuery {
  const factory AccessPrincipalQuery({@Default('') String query}) =
      _AccessPrincipalQuery;

  factory AccessPrincipalQuery.fromJson(Map<String, dynamic> json) =>
      _$AccessPrincipalQueryFromJson(json);
}

/// Reply to `access.principals`.
@freezed
abstract class AccessPrincipals with _$AccessPrincipals {
  const factory AccessPrincipals({
    @Default(<AccessPrincipal>[]) List<AccessPrincipal> items,
  }) = _AccessPrincipals;

  factory AccessPrincipals.fromJson(Map<String, dynamic> json) =>
      _$AccessPrincipalsFromJson(json);
}
