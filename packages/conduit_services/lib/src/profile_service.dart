import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/models/account_metadata.dart';
import 'package:conduit_core/persistence/account_scoped_preferences.dart';
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

  /// The account session a change starts in: read before its first await,
  /// and checked before anything is written ([_save]).
  Object _session() => _container.read(openWebUiAuthSessionEpochProvider);

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

  Future<ProfileDto> get() async {
    // The account the profile is read for: its client fetches the photo,
    // and another account in use by then gets nothing of it.
    final session = _session();
    final api = _api();
    return _dto(await _metadata(), session, api);
  }

  /// Still the account [session] and [api] were read in.
  void _stillIn(Object session, ApiService api) {
    if (!identical(session, _session()) ||
        !identical(api, _container.read(apiServiceProvider))) {
      throw const RpcError(
        code: ConduitErrorCodes.sessionExpired,
        debugMessage: 'the account changed while the profile was read',
      );
    }
  }

  Future<ProfileDto> _dto(
    AccountMetadata m,
    Object session,
    ApiService api,
  ) async {
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
    _stillIn(session, api);
    final image = await _image(m.profileImageUrl, api);
    _stillIn(session, api);
    return ProfileDto(
      id: m.id,
      name: m.name,
      email: m.email,
      role: m.role,
      username: m.username,
      image: image,
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
  ///
  /// The URL is the server's to set, and the account's client carries its
  /// token, headers and client certificate: only a path on the account's
  /// own server is fetched. Another origin (another host, scheme or port,
  /// a local address) shows the initials instead.
  Future<String?> _image(String? url, ApiService api) async {
    if (isDefaultProfileImageUrl(url)) return null;
    final value = url!.trim();
    if (value.startsWith('data:')) return value;
    final uri = avatarUri(api.serverConfig.url, value);
    if (uri == null) return null;
    try {
      // The absolute address checked above, never the reference itself:
      // Dio would join that to the server's address on its own terms.
      final response = await api.dio.getUri<List<int>>(
        uri,
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

  /// The absolute address of the photo [url] names, resolved against
  /// [server]'s address (its sub-path kept, as for every other request),
  /// or null unless it is on the server's own scheme, host and port.
  ///
  /// Anything that could name another host on the way is refused before
  /// resolving: user info (`@`), backslashes, a scheme-relative `//`, their
  /// percent-encoded forms, and spaces or control characters.
  static Uri? avatarUri(String server, String url) {
    final lower = url.toLowerCase();
    const refused = <String>['@', r'\', '%40', '%5c', '%2f%2f', '/%2f', '%2f/'];
    if (refused.any(lower.contains) ||
        lower.startsWith('//') ||
        url.runes.any((r) => r <= 0x20 || r == 0x7f)) {
      return null;
    }
    final base = Uri.tryParse(server.trim());
    final ref = Uri.tryParse(url);
    if (base == null ||
        ref == null ||
        !(base.isScheme('http') || base.isScheme('https')) ||
        base.host.isEmpty) {
      return null;
    }
    // A trailing slash keeps the server's sub-path for a path reference.
    final root = base.path.endsWith('/')
        ? base
        : base.replace(path: '${base.path}/');
    final relative = !ref.hasScheme && !ref.hasAuthority && url.startsWith('/')
        ? Uri.tryParse(url.substring(1))
        : ref;
    if (relative == null) return null;
    final resolved = root.resolveUri(relative);
    final same =
        resolved.scheme == base.scheme &&
        resolved.host.toLowerCase() == base.host.toLowerCase() &&
        resolved.port == base.port &&
        resolved.userInfo.isEmpty;
    return same ? resolved.removeFragment() : null;
  }

  /// The last profile change: each waits for the one before, so a photo
  /// change never puts back details another change just saved.
  Future<void> _changes = Future<void>.value();

  Future<T> _oneAtATime<T>(Future<T> Function() change) {
    final done = Completer<void>();
    final previous = _changes;
    _changes = done.future;
    return previous.then((_) => change()).whenComplete(done.complete);
  }

  // Each change captures the account session when asked, before it waits
  // its turn: one asked under another account writes nothing.
  Future<ProfileDto> update(ProfileEdit edit) {
    final session = _session();
    return _oneAtATime(() => _update(edit, session));
  }

  Future<ProfileDto> _update(ProfileEdit edit, Object session) async {
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
      // A day or month past its end ("2020-01-42") parses as another date:
      // refused rather than saved as that one.
      if (parsed == null ||
          !birth.trim().startsWith(formatProfileBirthDate(parsed))) {
        throw RpcError(
          code: ConduitErrorCodes.invalidParams,
          debugMessage: 'not a date: $birth',
        );
      }
    }
    return _save(
      m,
      session,
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

  Future<ProfileDto> setImage(ProfileImageEdit edit) {
    final session = _session();
    return _oneAtATime(() => _setImage(edit, session));
  }

  Future<ProfileDto> _setImage(ProfileImageEdit edit, Object session) async {
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
    return _save(m, session, image: image);
  }

  Future<ProfileDto> removeImage() {
    final session = _session();
    return _oneAtATime(
      () async =>
          _save(await _metadata(), session, image: kDefaultProfileImagePath),
    );
  }

  /// Saves the profile with [name], [image] and the details given, each
  /// left as it is stored when not given ([keep] details on a photo
  /// change). [m] was read in [session]: once another account (or a new
  /// sign-in) is in use, nothing is written.
  Future<ProfileDto> _save(
    AccountMetadata m,
    Object session, {
    String? name,
    String? image,
    bool keep = true,
    String? bio,
    String? gender,
    String? dateOfBirth,
  }) async {
    if (!identical(session, _session())) {
      throw const RpcError(
        code: ConduitErrorCodes.sessionExpired,
        debugMessage: 'the account changed',
      );
    }
    // Core refreshes the account's sign-in after saving (a new session
    // epoch, the same account): what is shown after it is checked against
    // the account, its server and the signed-in user, not the epoch.
    final accountId = currentPreferenceAccountId();
    final server = _api().serverConfig.id;
    final userId = _container.read(currentUserProvider2)?.id;
    final updated = await _container
        .read(accountProfileProvider.notifier)
        .save(
          name: name ?? m.name,
          profileImageUrl: image ?? normalizeProfileImageUrl(m.profileImageUrl),
          bio: keep ? m.bio : bio,
          gender: keep ? m.gender : gender,
          dateOfBirth: keep ? m.dateOfBirth : dateOfBirth,
        );
    final api = _container.read(apiServiceProvider);
    if (accountId != currentPreferenceAccountId() ||
        api == null ||
        api.serverConfig.id != server ||
        userId == null ||
        _container.read(currentUserProvider2)?.id != userId) {
      throw const RpcError(
        code: ConduitErrorCodes.sessionExpired,
        debugMessage: 'the account changed while the profile was saved',
      );
    }
    return _dto(updated, _session(), api);
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
