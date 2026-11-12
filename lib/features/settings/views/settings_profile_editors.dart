import 'dart:convert';
import 'dart:ui' as ui;

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/models/account_metadata.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/utils/account_profile_form.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_core/utils/profile_avatar.dart';
import 'package:flutter/services.dart' show TextCapitalization;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/native_sheet_bridge.dart';
import '../../../core/utils/native_sheet_utils.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/adaptive_date_time_picker.dart';
import '../../../shared/widgets/adaptive_selection_sheet.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../chat/services/file_attachment_service.dart';
import '../settings_pages.dart';

/// The Profile page rows the Flutter Settings pages edit themselves, as the
/// native sheet draws its own editors for them.
const settingsProfileEditorIds = {
  'profile-photo',
  'profile-name',
  'profile-about',
  'profile-details',
};

/// Edits the field behind Profile row [rowId] and saves the whole profile,
/// as the native editors save every field at once.
///
/// The fields not edited come from the profile as it is once the edit is
/// done, not as it was when the editor opened, so a save never writes back a
/// copy older than the one the app holds; and nothing is saved once another
/// account has taken over.
///
/// The profile the page shows may be the copy kept from before a refresh
/// that is still running or failed; editing goes on from that copy, as long
/// as it belongs to the account signed in.
Future<void> editSettingsProfileField(
  BuildContext context,
  WidgetRef ref,
  String rowId,
) async {
  final l10n = AppLocalizations.of(context)!;
  final account = _ProfileAccount.read(ref);
  final profile = account?.profileIn(ref);
  if (account == null || profile == null) {
    UiUtils.showMessage(context, l10n.unableToLoadProfile);
    return;
  }
  final edit = switch (rowId) {
    'profile-name' => _editName(context, l10n, profile),
    'profile-about' => _editAbout(context, l10n, profile),
    'profile-details' => _editDetails(context, l10n, profile),
    'profile-photo' => _editPhoto(context, ref, l10n, profile),
    _ => Future<_ProfileEdit?>.value(),
  };
  final change = await edit;
  if (change == null || !context.mounted) return;
  // Refreshed while the editor was open, the profile may hold newer fields;
  // and the edit is for the account the editor opened on, or for none.
  final latest = account == _ProfileAccount.read(ref)
      ? account.profileIn(ref)
      : null;
  if (latest == null || latest.id != profile.id) {
    UiUtils.showMessage(context, l10n.unableToLoadProfile);
    return;
  }
  try {
    final saved = await ref
        .read(accountProfileProvider.notifier)
        .save(
          name: change.name ?? latest.name,
          profileImageUrl:
              change.profileImageUrl ??
              normalizeProfileImageUrl(latest.profileImageUrl),
          bio: change.bio ?? latest.bio ?? '',
          gender: change.clearsGender ? null : change.gender ?? latest.gender,
          dateOfBirth: change.clearsBirthDate
              ? null
              : change.dateOfBirth ?? latest.dateOfBirth,
          timezone: latest.timezone,
        );
    // Another account took over while it was sent: its Profile page is not
    // this one's.
    if (account != _ProfileAccount.read(ref)) return;
    await ref
        .read(settingsSurfaceProvider)
        .applyDetail(
          NativeSheetDetailConfig(
            id: NativeSheetRoutes.profile,
            title: nativeProfileTitle(l10n),
            sections: buildNativeProfileDetailSections(
              l10n,
              displayName: saved.name,
              accountProfile: saved,
            ),
          ),
        );
    if (context.mounted) UiUtils.showMessage(context, l10n.profileUpdated);
  } catch (error, stackTrace) {
    DebugLogger.error(
      'settings-profile-save-failed',
      scope: 'settings/profile',
      error: error,
      stackTrace: stackTrace,
    );
    if (context.mounted) UiUtils.showMessage(context, l10n.errorMessage);
  }
}

/// The account a Profile edit is for: the user signed in, on the server
/// they are signed in to.
@immutable
final class _ProfileAccount {
  const _ProfileAccount(this.userId, this.serverId);

  /// The account signed in now, or null with none.
  static _ProfileAccount? read(WidgetRef ref) {
    final userId = ref.read(currentUserProvider2)?.id;
    final serverId = ref.read(apiServiceProvider)?.serverConfig.id;
    if (userId == null || serverId == null) return null;
    return _ProfileAccount(userId, serverId);
  }

  final String userId;
  final String serverId;

  /// The profile the app holds for this account. The copy kept from before a
  /// refresh counts, but never one left from another account.
  AccountMetadata? profileIn(WidgetRef ref) {
    final profile = ref.read(accountProfileProvider).value;
    return profile?.id == userId ? profile : null;
  }

  @override
  bool operator ==(Object other) =>
      other is _ProfileAccount &&
      other.userId == userId &&
      other.serverId == serverId;

  @override
  int get hashCode => Object.hash(userId, serverId);
}

/// One edit to the profile. Null fields keep what the profile holds; the
/// gender and birth date can also be cleared.
final class _ProfileEdit {
  const _ProfileEdit({
    this.name,
    this.bio,
    this.profileImageUrl,
    this.gender,
    this.dateOfBirth,
    this.clearsGender = false,
    this.clearsBirthDate = false,
  });

  final String? name;
  final String? bio;
  final String? profileImageUrl;
  final String? gender;
  final String? dateOfBirth;
  final bool clearsGender;
  final bool clearsBirthDate;
}

Future<_ProfileEdit?> _editName(
  BuildContext context,
  AppLocalizations l10n,
  AccountMetadata profile,
) async {
  final name = await ThemedDialogs.promptTextInput(
    context,
    title: l10n.name,
    hintText: l10n.name,
    initialValue: profile.name,
    textCapitalization: TextCapitalization.words,
  );
  if (name == null || !context.mounted) return null;
  if (name.trim().isEmpty) {
    UiUtils.showMessage(context, l10n.nameRequired);
    return null;
  }
  return _ProfileEdit(name: name.trim());
}

Future<_ProfileEdit?> _editAbout(
  BuildContext context,
  AppLocalizations l10n,
  AccountMetadata profile,
) async {
  final bio = await ThemedDialogs.promptTextInput(
    context,
    title: l10n.bioLabel,
    hintText: l10n.bioHint,
    initialValue: profile.bio ?? '',
  );
  if (bio == null) return null;
  return _ProfileEdit(bio: bio.trim());
}

/// Gender, then birthday: the two fields the Profile details row sums up.
Future<_ProfileEdit?> _editDetails(
  BuildContext context,
  AppLocalizations l10n,
  AccountMetadata profile,
) async {
  final current = splitProfileGender(profile.gender);
  final choice = await _pick(
    context,
    title: l10n.profileDetails,
    selected: null,
    options: [
      (id: 'gender', label: l10n.genderLabel),
      (id: 'birth', label: l10n.birthDateLabel),
    ],
  );
  if (choice == null || !context.mounted) return null;
  if (choice == 'birth') {
    // A saved date can be cleared, as the native editor's Clear does.
    final saved = profile.dateOfBirth?.trim() ?? '';
    if (saved.isNotEmpty) {
      final action = await _pick(
        context,
        title: l10n.birthDateLabel,
        selected: null,
        options: [
          (id: 'select', label: l10n.selectBirthDate),
          (id: 'clear', label: l10n.clear),
        ],
      );
      if (action == null || !context.mounted) return null;
      if (action == 'clear') return const _ProfileEdit(clearsBirthDate: true);
    }
    final initial = clampProfileBirthDate(
      parseProfileBirthDate(profile.dateOfBirth ?? '') ?? DateTime(1990),
    );
    final picked = await showAdaptiveDatePicker(
      context,
      initial: initial,
      first: kEarliestProfileBirthDate,
      last: DateTime.now(),
      title: l10n.birthDateLabel,
    );
    if (picked == null || !context.mounted) return null;
    return _ProfileEdit(dateOfBirth: formatProfileBirthDate(picked));
  }
  final gender = await _pick(
    context,
    title: l10n.genderLabel,
    selected: current.choice,
    options: [
      (id: '', label: l10n.genderPreferNotToSay),
      (id: 'male', label: l10n.genderMale),
      (id: 'female', label: l10n.genderFemale),
      (id: 'custom', label: l10n.genderCustom),
    ],
  );
  if (gender == null || !context.mounted) return null;
  if (gender.isEmpty) return const _ProfileEdit(clearsGender: true);
  if (gender != 'custom') return _ProfileEdit(gender: gender);
  final custom = await ThemedDialogs.promptTextInput(
    context,
    title: l10n.customGenderLabel,
    hintText: l10n.customGenderHint,
    initialValue: current.custom,
  );
  if (custom == null || !context.mounted) return null;
  if (custom.trim().isEmpty) {
    UiUtils.showMessage(context, l10n.customGenderRequired);
    return null;
  }
  return _ProfileEdit(gender: resolveProfileGender('custom', custom));
}

Future<_ProfileEdit?> _editPhoto(
  BuildContext context,
  WidgetRef ref,
  AppLocalizations l10n,
  AccountMetadata profile,
) async {
  final choice = await _pick(
    context,
    title: l10n.editPhoto,
    selected: null,
    options: [
      (id: 'upload', label: l10n.uploadFromDevice),
      (id: 'initials', label: l10n.useInitials),
      (id: 'remove', label: l10n.removeAvatar),
    ],
  );
  if (choice == null || !context.mounted) return null;
  switch (choice) {
    case 'remove':
      return const _ProfileEdit(profileImageUrl: kDefaultProfileImagePath);
    case 'initials':
      return _ProfileEdit(
        profileImageUrl: await _initialsAvatarDataUrl(profile.name),
      );
  }
  final service = ref.read(fileAttachmentServiceProvider);
  try {
    final attachment = await service?.pickImage() as LocalAttachment?;
    if (attachment == null) return null;
    final dataUrl = service is FileAttachmentService
        ? await service.convertImageToDataUrl(
            attachment.file,
            enableCompression: true,
            maxWidth: 250,
            maxHeight: 250,
          )
        : await convertImageFileToDataUrl(attachment.file);
    if (dataUrl == null || dataUrl.isEmpty) {
      if (context.mounted) {
        UiUtils.showMessage(context, l10n.avatarUploadFailed);
      }
      return null;
    }
    return _ProfileEdit(profileImageUrl: dataUrl);
  } catch (_) {
    if (context.mounted) UiUtils.showMessage(context, l10n.avatarUploadFailed);
    return null;
  }
}

Future<String?> _pick(
  BuildContext context, {
  required String title,
  required String? selected,
  required List<({String id, String label})> options,
}) {
  return showAdaptiveSelectionSheet<String>(
    context: context,
    builder: (sheetContext) => AdaptiveSelectionSheet(
      title: title,
      itemCount: options.length,
      initialChildSize: 0.42,
      minChildSize: 0.3,
      maxChildSize: 0.68,
      itemBuilder: (context, index) {
        final option = options[index];
        return AdaptiveSelectionTile(
          title: option.label,
          selected: option.id == selected,
          onTap: () => Navigator.of(sheetContext).pop(option.id),
        );
      },
    ),
  );
}

/// A round picture of [name]'s initials, as a PNG data URL, the way the
/// account's own profile editor draws one.
Future<String> _initialsAvatarDataUrl(String name) async {
  const dimension = 250;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  const center = Offset(dimension / 2, dimension / 2);
  canvas.drawCircle(
    center,
    dimension / 2,
    Paint()..color = Color(initialsAvatarColorValue(name)),
  );
  final painter = TextPainter(
    text: TextSpan(
      text: extractAvatarInitials(name),
      style: const TextStyle(
        color: Color(0xFFFFFFFF),
        fontSize: 88,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.5,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  painter.paint(
    canvas,
    Offset((dimension - painter.width) / 2, (dimension - painter.height) / 2),
  );
  final image = await recorder.endRecording().toImage(dimension, dimension);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  final bytes = data?.buffer.asUint8List();
  if (bytes == null) return kDefaultProfileImagePath;
  return 'data:image/png;base64,${base64Encode(bytes)}';
}
