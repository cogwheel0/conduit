import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/models/user.dart';
import '../../../core/network/image_header_utils.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/native_sheet_bridge.dart';
import '../../../core/services/navigation_service.dart';
import '../../../core/services/settings_service.dart';
import '../../../core/utils/native_sheet_utils.dart';
import '../../../core/utils/user_avatar_utils.dart';
import '../../../core/utils/user_display_name.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/adaptive_glass.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/user_avatar.dart';
import '../../auth/providers/unified_auth_providers.dart';
import '../../terminal/providers/terminal_providers.dart';
import '../providers/sidebar_providers.dart';

/// Resolves the best available current user for sidebar UI.
dynamic resolveSidebarUser(WidgetRef ref) {
  final authUser = ref.watch(currentUserProvider2);
  final asyncUser = ref.watch(currentUserProvider);
  return asyncUser.maybeWhen(
    data: (value) => value ?? authUser,
    orElse: () => authUser,
  );
}

/// Localized search hint for the active sidebar tab.
String sidebarSearchHintForActiveTab(WidgetRef ref, AppLocalizations l10n) {
  final tabIndex = ref.watch(sidebarActiveTabProvider);
  final notesOn = ref.watch(notesFeatureEnabledProvider);
  final terminalOn = ref
      .watch(terminalAvailableServersProvider)
      .maybeWhen(
        data: (servers) => servers.isNotEmpty,
        error: (_, _) => true,
        orElse: () => true,
      );
  final channelsOn = ref.watch(channelsFeatureEnabledProvider);

  var i = 0;
  if (tabIndex == i) return l10n.searchConversations;
  i++;
  if (notesOn) {
    if (tabIndex == i) return l10n.searchNotes;
    i++;
  }
  if (terminalOn) {
    if (tabIndex == i) return l10n.searchFiles;
    i++;
  }
  if (channelsOn) {
    if (tabIndex == i) return l10n.searchChannels;
  }
  return l10n.searchConversations;
}

/// Profile button used as the sidebar adaptive app bar leading widget.
class SidebarProfileAppBarLeading extends ConsumerWidget {
  const SidebarProfileAppBarLeading({super.key});

  static const double _avatarSize = 36;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = resolveSidebarUser(ref);
    if (user == null) return const SizedBox.shrink();

    final api = ref.watch(apiServiceProvider);
    final l10n = AppLocalizations.of(context)!;
    final displayName = deriveUserDisplayName(
      user,
      fallback: l10n.userFallbackName,
    );
    final initial = displayName.isEmpty
        ? 'U'
        : displayName.characters.first.toUpperCase();
    final avatarUrl = resolveUserAvatarUrlForUser(api, user);
    final iconColor = context.conduitTheme.textPrimary;
    final useOpaqueFallback = conduitUsesOpaqueGlassFallback();
    final style = useOpaqueFallback
        ? AdaptiveButtonStyle.plain
        : AdaptiveButtonStyle.glass;

    return Semantics(
      label: l10n.manage,
      button: true,
      child: AdaptiveButton.child(
        onPressed: () async {
          await Navigator.of(context).maybePop();
          if (!context.mounted) return;

          if (Platform.isIOS) {
            final config = _buildNativeProfileSheetConfig(
              context: context,
              ref: ref,
              user: user,
              api: api,
              displayName: displayName,
              initials: initial,
            );
            final presented = await NativeSheetBridge.instance
                .presentProfileMenu(config);
            if (presented) return;
          }

          if (context.mounted) {
            context.pushNamed(RouteNames.profile);
          }
        },
        style: style,
        color: useOpaqueFallback ? iconColor : null,
        size: AdaptiveButtonSize.large,
        padding: EdgeInsets.zero,
        minSize: const Size(TouchTarget.minimum, TouchTarget.minimum),
        useSmoothRectangleBorder: false,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppBorderRadius.avatar),
          child: UserAvatar(
            size: _avatarSize,
            imageUrl: avatarUrl,
            fallbackText: initial,
          ),
        ),
      ),
    );
  }

  NativeProfileSheetConfig _buildNativeProfileSheetConfig({
    required BuildContext context,
    required WidgetRef ref,
    required dynamic user,
    required dynamic api,
    required String displayName,
    required String initials,
  }) {
    final l10n = AppLocalizations.of(context)!;
    final avatarUrl = resolveUserAvatarUrlForUser(api, user);
    final avatarBytes = _decodeDataImage(avatarUrl);
    final email = _extractEmail(user) ?? l10n.noEmailLabel;
    final accountProfile = ref.read(accountProfileProvider).asData?.value;
    final appSettings = ref.read(appSettingsProvider);
    final nativeAudio = buildNativeAudioSheetParts(l10n, appSettings);
    final settingsTitle = nativeSettingsTitle(l10n);
    final profileTitle = nativeProfileTitle(l10n);
    final appearanceTitle = nativeAppearanceTitle(l10n);
    final chatsTitle = nativeChatsTitle(l10n);
    final aiMemoryTitle = nativeAiMemoryTitle(l10n);
    final dataConnectionTitle = nativeDataConnectionTitle(l10n);
    final profileSummary = [
      displayName,
      if (accountProfile?.bio?.trim().isNotEmpty == true)
        accountProfile!.bio!.trim(),
    ].join(' · ');

    return NativeProfileSheetConfig(
      profileMenuTitle: settingsTitle,
      profile: NativeProfileSheetUser(
        displayName: displayName,
        email: email,
        initials: initials,
        avatarUrl: avatarBytes == null ? avatarUrl : null,
        avatarBytes: avatarBytes,
        avatarHeaders: buildImageHeadersFromWidgetRef(ref) ?? const {},
        bio: accountProfile?.bio,
        gender: accountProfile?.gender,
        dateOfBirth: accountProfile?.dateOfBirth,
        profileImageUrl: accountProfile?.profileImageUrl,
      ),
      editProfileLabel: l10n.edit,
      editProfileSheet: NativeEditProfileSheetConfig(
        title: l10n.profileDetails,
        saveLabel: l10n.saveProfile,
        cancelLabel: l10n.cancel,
        okLabel: l10n.ok,
        footerText: l10n.accountSettingsSubtitle,
        nameLabel: l10n.name,
        nameRequiredMessage: l10n.nameRequired,
        customGenderRequiredMessage: l10n.customGenderRequired,
        bioLabel: l10n.bioLabel,
        bioHint: l10n.bioHint,
        genderLabel: l10n.genderLabel,
        genderPreferNotToSay: l10n.genderPreferNotToSay,
        genderMale: l10n.genderMale,
        genderFemale: l10n.genderFemale,
        genderCustom: l10n.genderCustom,
        customGenderLabel: l10n.customGenderLabel,
        customGenderHint: l10n.customGenderHint,
        birthDateLabel: l10n.birthDateLabel,
        selectBirthDateLabel: l10n.selectBirthDate,
        clearLabel: l10n.clear,
        uploadFromDeviceLabel: l10n.uploadFromDevice,
        useInitialsLabel: l10n.useInitials,
        removeAvatarLabel: l10n.removeAvatar,
        currentAvatarLabel: l10n.currentAvatar,
      ),
      menuItems: const [],
      sections: [
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: NativeSheetRoutes.profile,
              title: displayName,
              subtitle: email,
              sfSymbol: 'person.crop.circle',
            ),
          ],
        ),
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: NativeSheetRoutes.appearance,
              title: appearanceTitle,
              sfSymbol: 'paintpalette',
            ),
            NativeSheetItemConfig(
              id: NativeSheetRoutes.chats,
              title: chatsTitle,
              sfSymbol: 'bubble.left.and.bubble.right',
            ),
            NativeSheetItemConfig(
              id: NativeSheetRoutes.voice,
              title: l10n.voice,
              sfSymbol: 'waveform',
            ),
            NativeSheetItemConfig(
              id: NativeSheetRoutes.aiMemory,
              title: aiMemoryTitle,
              sfSymbol: 'wand.and.stars',
            ),
            NativeSheetItemConfig(
              id: NativeSheetRoutes.dataConnection,
              title: dataConnectionTitle,
              sfSymbol: 'network',
            ),
          ],
        ),
        NativeSheetSectionConfig(
          title: l10n.supportConduit,
          footer: l10n.supportConduitSubtitle,
          items: [
            NativeSheetItemConfig(
              id: 'buy-me-a-coffee',
              title: l10n.buyMeACoffeeTitle,
              subtitle: 'buymeacoffee.com/cogwheel0',
              sfSymbol: 'gift',
              url: 'https://www.buymeacoffee.com/cogwheel0',
            ),
            NativeSheetItemConfig(
              id: 'github-sponsors',
              title: l10n.githubSponsorsTitle,
              subtitle: 'github.com/sponsors/cogwheel0',
              sfSymbol: 'heart',
              url: 'https://github.com/sponsors/cogwheel0',
            ),
          ],
        ),
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: NativeSheetRoutes.helpAbout,
              title: l10n.aboutApp,
              sfSymbol: 'info.circle',
            ),
          ],
        ),
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: 'sign-out',
              title: l10n.signOut,
              subtitle: l10n.endYourSession,
              sfSymbol: 'rectangle.portrait.and.arrow.right',
              destructive: true,
            ),
          ],
        ),
      ],
      detailSheets: [
        NativeSheetDetailConfig(
          id: NativeSheetRoutes.profile,
          title: profileTitle,
          sections: [
            NativeSheetSectionConfig(
              footer: l10n.accountSettingsSubtitle,
              items: [
                NativeSheetItemConfig(
                  id: 'profile-photo',
                  title: l10n.editPhoto,
                  sfSymbol: 'person.crop.circle',
                ),
              ],
            ),
            NativeSheetSectionConfig(
              items: [
                NativeSheetItemConfig(
                  id: 'profile-name',
                  title: l10n.name,
                  subtitle: profileSummary,
                  sfSymbol: 'person.text.rectangle',
                ),
                NativeSheetItemConfig(
                  id: 'profile-about',
                  title: l10n.bioLabel,
                  subtitle: accountProfile?.bio?.trim().isNotEmpty == true
                      ? accountProfile!.bio!.trim()
                      : l10n.notSet,
                  sfSymbol: 'text.bubble',
                ),
                NativeSheetItemConfig(
                  id: 'profile-details',
                  title: l10n.profileDetails,
                  subtitle: l10n.genderLabel,
                  sfSymbol: 'person.crop.circle',
                ),
              ],
            ),
            NativeSheetSectionConfig(
              title: l10n.accountSettingsTitle,
              items: [
                NativeSheetItemConfig(
                  id: 'password',
                  title: l10n.changePasswordTitle,
                  subtitle: l10n.passwordChangesLabel,
                  sfSymbol: 'lock',
                ),
              ],
            ),
          ],
        ),
        buildNativePasswordDetail(
          l10n,
          passwordChangeEnabled: true,
          subtitle: l10n.passwordFieldsRequired,
        ),
        buildNativeLoadingDetail(
          l10n: l10n,
          id: NativeSheetRoutes.appearance,
          title: appearanceTitle,
          subtitle: l10n.loadingShort,
        ),
        NativeSheetDetailConfig(
          id: NativeSheetRoutes.voice,
          title: l10n.voice,
          subtitle: l10n.audioSettingsSubtitle,
          items: nativeAudio.mainItems,
        ),
        nativeAudio.voicePickerDetail,
        buildNativeLoadingDetail(
          l10n: l10n,
          id: NativeSheetRoutes.chats,
          title: chatsTitle,
          subtitle: l10n.loadingShort,
        ),
        buildNativeLoadingDetail(
          l10n: l10n,
          id: NativeSheetRoutes.aiMemory,
          title: aiMemoryTitle,
          subtitle: l10n.loadingShort,
        ),
        buildNativeLoadingDetail(
          l10n: l10n,
          id: NativeSheetRoutes.dataConnection,
          title: dataConnectionTitle,
          subtitle: l10n.loadingShort,
        ),
        buildNativeLoadingDetail(
          l10n: l10n,
          id: NativeSheetRoutes.helpAbout,
          title: l10n.aboutApp,
          subtitle: l10n.loadingShort,
        ),
      ],
    );
  }

  Uint8List? _decodeDataImage(String? dataUrl) {
    if (dataUrl == null || !dataUrl.startsWith('data:image')) {
      return null;
    }
    try {
      final commaIndex = dataUrl.indexOf(',');
      if (commaIndex == -1) return null;
      return base64Decode(dataUrl.substring(commaIndex + 1));
    } catch (_) {
      return null;
    }
  }

  String? _extractEmail(dynamic source) {
    if (source is User) {
      return source.email;
    }
    if (source is Map) {
      final value = source['email'];
      if (value is String && value.trim().isNotEmpty) {
        return value.trim();
      }
      final nested = source['user'];
      if (nested is Map) {
        final nestedValue = nested['email'];
        if (nestedValue is String && nestedValue.trim().isNotEmpty) {
          return nestedValue.trim();
        }
      }
    }
    return null;
  }
}

/// Search field used as the sidebar adaptive app bar leading widget.
class SidebarSearchAppBarLeading extends ConsumerWidget {
  const SidebarSearchAppBarLeading({
    super.key,
    required this.hintText,
    required this.maxWidth,
  });

  final String hintText;
  final double maxWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(sidebarSearchFieldControllerProvider);
    final focusNode = ref.watch(sidebarSearchFieldFocusNodeProvider);
    final resolvedMaxWidth = maxWidth.clamp(0.0, double.infinity).toDouble();

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: resolvedMaxWidth),
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, value, _) {
          return ConduitGlassSearchField(
            controller: controller,
            focusNode: focusNode,
            hintText: hintText,
            onChanged: (_) {},
            query: value.text,
            onClear: () => controller.clear(),
          );
        },
      ),
    );
  }
}
