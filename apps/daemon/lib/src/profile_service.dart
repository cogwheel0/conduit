import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:conduit_core/models/account_metadata.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/utils/account_profile_form.dart';
import 'package:conduit_core/utils/profile_avatar.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';

import 'accounts_service.dart';
import 'settled.dart';

/// `profile.*`: the signed-in Open WebUI account's profile, as the phone's
/// Settings › Profile edits it, through core's `AccountProfile`.
///
/// The photo travels as the phone sends it: a `data:` URL in the profile's
/// `profile_image_url` (an upload scaled to fit 250 px, or a picture of the
/// initials), and the server's stock `/user.png` when it is removed.
final class ProfileService {
  ProfileService(this._container, {AccountsService? accounts})
    : _accounts = accounts;

  final ProviderContainer _container;
  final AccountsService? _accounts;

  /// The largest image file `profile.setImage` reads.
  static const int maxImageBytes = 32 * 1024 * 1024;

  ApiService _api() =>
      _container.read(apiServiceProvider) ??
      (throw const RpcError(
        code: ConduitErrorCodes.unauthenticated,
        debugMessage: 'no Open WebUI account is in use',
      ));

  Future<AccountMetadata> _metadata() async {
    _api();
    final metadata = await readSettled(
      _container,
      accountProfileProvider.future,
    );
    return metadata ??
        (throw const RpcError(
          code: ConduitErrorCodes.unauthenticated,
          debugMessage: 'no profile for this account',
        ));
  }

  Future<ProfileDto> get() async => _dto(await _metadata());

  Future<ProfileDto> _dto(AccountMetadata m) async {
    var passwordChange = true;
    try {
      final about = await readSettled(
        _container,
        serverAboutInfoProvider.future,
      ).timeout(const Duration(seconds: 5));
      passwordChange = about?.enablePasswordChangeForm ?? true;
    } on Object {
      // As the phone: the form shows unless the server says otherwise.
    }
    return ProfileDto(
      id: m.id,
      name: m.name,
      email: m.email,
      role: m.role,
      username: m.username,
      image: await _image(m.profileImageUrl),
      bio: m.bio,
      gender: m.gender,
      dateOfBirth: m.dateOfBirth,
      statusEmoji: m.statusEmoji,
      statusMessage: m.statusMessage,
      isActive: m.isActive,
      passwordChangeAllowed: passwordChange,
    );
  }

  /// The photo as a `data:` URL, or null for the initials: no photo, the
  /// server's stock one, or one that will not load.
  Future<String?> _image(String? url) async {
    if (isDefaultProfileImageUrl(url)) return null;
    final value = url!.trim();
    if (value.startsWith('data:')) return value;
    try {
      final response = await _api().dio.get<List<int>>(
        value,
        options: Options(responseType: ResponseType.bytes),
      );
      final bytes = response.data;
      if (bytes == null || bytes.isEmpty) return null;
      final type =
          response.headers.value(Headers.contentTypeHeader)?.split(';').first ??
          'image/png';
      if (!type.startsWith('image/') || type.contains('svg')) return null;
      return 'data:$type;base64,${base64Encode(bytes)}';
    } on Object {
      return null;
    }
  }

  Future<ProfileDto> update(ProfileEdit edit) async {
    final m = await _metadata();
    final clear = edit.clear.toSet();
    for (final field in clear) {
      if (!const <String>{'bio', 'gender', 'dateOfBirth'}.contains(field)) {
        throw RpcError(
          code: ConduitErrorCodes.invalidParams,
          debugMessage: 'cannot clear "$field"',
        );
      }
    }
    final name = (edit.name ?? m.name).trim();
    if (name.isEmpty) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'the name cannot be empty',
      );
    }
    String? pick(String field, String? edited, String? stored) =>
        clear.contains(field) ? null : (edited ?? stored);
    final birth = pick('dateOfBirth', edit.dateOfBirth, m.dateOfBirth);
    if (birth != null && birth.trim().isNotEmpty) {
      final parsed = parseProfileBirthDate(birth);
      if (parsed == null) {
        throw RpcError(
          code: ConduitErrorCodes.invalidParams,
          debugMessage: 'not a date: $birth',
        );
      }
    }
    return _save(
      m,
      name: name,
      keep: false,
      bio: pick('bio', edit.bio, m.bio),
      gender: pick('gender', edit.gender, m.gender),
      dateOfBirth: birth == null || birth.trim().isEmpty
          ? null
          : formatProfileBirthDate(
              clampProfileBirthDate(parseProfileBirthDate(birth)!),
            ),
    );
  }

  Future<ProfileDto> setImage(ProfileImageEdit edit) async {
    final m = await _metadata();
    final String image;
    if (edit.initials) {
      image = initialsAvatarDataUrl(m.displayName);
    } else {
      final path = edit.path;
      if (path == null || path.isEmpty) {
        throw const RpcError(
          code: ConduitErrorCodes.invalidParams,
          debugMessage: 'a path or initials',
        );
      }
      final file = File(path);
      if (!file.existsSync() || file.lengthSync() > maxImageBytes) {
        throw RpcError(
          code: ConduitErrorCodes.invalidParams,
          debugMessage: 'no image file at $path, or it is too large',
        );
      }
      final Uint8List bytes = await file.readAsBytes();
      image =
          profileImageDataUrlFromBytes(bytes) ??
          (throw const RpcError(
            code: ConduitErrorCodes.unsupported,
            debugMessage: 'not an image this app can read',
          ));
    }
    return _save(m, image: image);
  }

  Future<ProfileDto> removeImage() async =>
      _save(await _metadata(), image: kDefaultProfileImagePath);

  /// Saves the profile with [name], [image] and the details given, each
  /// left as it is stored when not given ([keep] details on a photo
  /// change).
  Future<ProfileDto> _save(
    AccountMetadata m, {
    String? name,
    String? image,
    bool keep = true,
    String? bio,
    String? gender,
    String? dateOfBirth,
  }) async {
    final updated = await _container
        .read(accountProfileProvider.notifier)
        .save(
          name: name ?? m.name,
          profileImageUrl: image ?? normalizeProfileImageUrl(m.profileImageUrl),
          bio: keep ? m.bio : bio,
          gender: keep ? m.gender : gender,
          dateOfBirth: keep ? m.dateOfBirth : dateOfBirth,
        );
    return _dto(updated);
  }

  /// As the phone: on success the account is signed out, to sign in again
  /// with the new password.
  Future<PasswordChangeResult> changePassword(PasswordChange change) async {
    _api();
    if (change.currentPassword.isEmpty || change.newPassword.isEmpty) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'both passwords are needed',
      );
    }
    try {
      await _container
          .read(accountProfileProvider.notifier)
          .updatePassword(
            password: change.currentPassword,
            newPassword: change.newPassword,
          );
      return const PasswordChangeResult();
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (status == 400 || status == 401 || status == 403) {
        // Open WebUI answers a current password that does not match with
        // 400 "Incorrect password".
        final detail = '${error.response?.data}'.toLowerCase();
        return PasswordChangeResult(
          failure: detail.contains('password') && !detail.contains('new')
              ? 'wrongPassword'
              : 'refused',
        );
      }
      if (status != null && status >= 400 && status < 500) {
        return const PasswordChangeResult(failure: 'refused');
      }
      return const PasswordChangeResult(failure: 'failed');
    }
  }

  /// Signs out of every saved account, the inactive ones first, each as
  /// `accounts.remove` does. A reply being written in the active one stops
  /// it unless [SignOutAll.force].
  Future<AccountChangeResult> signOutAll(SignOutAll request) async {
    final accounts =
        _accounts ??
        (throw const RpcError(
          code: ConduitErrorCodes.daemonUnavailable,
          debugMessage: 'the core is not up yet',
        ));
    final list = await accounts.list();
    final ordered = <AccountSummary>[
      ...list.accounts.where((a) => a.id != list.activeAccountId),
      ...list.accounts.where((a) => a.id == list.activeAccountId),
    ];
    var result = AccountChangeResult(
      outcome: AccountChangeOutcome.done,
      accounts: list,
    );
    for (final account in ordered) {
      result = await accounts.remove(
        AccountRef(accountId: account.id, force: request.force),
      );
      if (result.outcome == AccountChangeOutcome.blockedByActiveReply) {
        return result;
      }
    }
    return result;
  }
}
