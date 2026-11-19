import 'package:freezed_annotation/freezed_annotation.dart';

part 'profile.freezed.dart';
part 'profile.g.dart';

/// The signed-in Open WebUI account's profile, as Settings › Profile shows
/// it. Reply to `profile.get` and the `profile.*` edits.
@freezed
abstract class ProfileDto with _$ProfileDto {
  const factory ProfileDto({
    required String id,
    @Default('') String name,
    @Default('') String email,

    /// `admin`, `user` or `pending`, as the server says it.
    @Default('user') String role,
    String? username,

    /// The photo as a `data:` URL, or null when the account shows its
    /// initials (no photo, or the server's stock one).
    String? image,
    String? bio,

    /// `male`, `female`, or the user's own words; null when not said.
    String? gender,

    /// `yyyy-MM-dd`.
    String? dateOfBirth,
    String? statusEmoji,
    String? statusMessage,
    @Default(true) bool isActive,

    /// The server lets accounts change their password here (Open WebUI's
    /// `enable_password_change_form`).
    @Default(true) bool passwordChangeAllowed,
  }) = _ProfileDto;

  factory ProfileDto.fromJson(Map<String, dynamic> json) =>
      _$ProfileDtoFromJson(json);
}

/// Params for `profile.update`: a null field is left alone, [clear] names
/// the ones to empty (`bio`, `gender`, `dateOfBirth`). The name may not be
/// empty.
@freezed
abstract class ProfileEdit with _$ProfileEdit {
  const factory ProfileEdit({
    String? name,
    String? bio,
    String? gender,
    String? dateOfBirth,
    @Default(<String>[]) List<String> clear,
  }) = _ProfileEdit;

  factory ProfileEdit.fromJson(Map<String, dynamic> json) =>
      _$ProfileEditFromJson(json);
}

/// Params for `profile.setImage`: an image file to use as the photo (scaled
/// to fit 250 pt, as the phone sends it), or, with [initials], a picture of
/// the name's initials.
@freezed
abstract class ProfileImageEdit with _$ProfileImageEdit {
  const factory ProfileImageEdit({
    String? path,
    @Default(false) bool initials,
  }) = _ProfileImageEdit;

  factory ProfileImageEdit.fromJson(Map<String, dynamic> json) =>
      _$ProfileImageEditFromJson(json);
}

/// Params for `profile.changePassword`.
@freezed
abstract class PasswordChange with _$PasswordChange {
  const factory PasswordChange({
    required String currentPassword,
    required String newPassword,
  }) = _PasswordChange;

  factory PasswordChange.fromJson(Map<String, dynamic> json) =>
      _$PasswordChangeFromJson(json);
}

/// Reply to `profile.changePassword`. [failure] is null when the password
/// changed (and, as on the phone, the account was signed out to sign in
/// again with it), else `wrongPassword` (the current one did not match),
/// `refused` (the server would not take the new one) or `failed`.
@freezed
abstract class PasswordChangeResult with _$PasswordChangeResult {
  const factory PasswordChangeResult({String? failure}) = _PasswordChangeResult;

  factory PasswordChangeResult.fromJson(Map<String, dynamic> json) =>
      _$PasswordChangeResultFromJson(json);
}

/// Params for `profile.signOutAll`: signs out of every saved Open WebUI
/// account (the phone's "Sign Out of All Accounts"), each as Sign Out signs
/// out of one: its chats on this computer go with it. Direct and Hermes
/// connections stay; Settings › Data › Clear Local Data removes those too.
@freezed
abstract class SignOutAll with _$SignOutAll {
  const factory SignOutAll({
    /// Stops an answer being written, which otherwise refuses the sign-out
    /// (`blockedByActiveReply`).
    @Default(false) bool force,
  }) = _SignOutAll;

  factory SignOutAll.fromJson(Map<String, dynamic> json) =>
      _$SignOutAllFromJson(json);
}
