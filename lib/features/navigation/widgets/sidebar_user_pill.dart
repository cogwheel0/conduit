import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/models/user.dart';
import '../../../core/network/image_header_utils.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/backend_mode_providers.dart';
import '../../../core/services/native_sheet_bridge.dart';
import '../../../core/services/navigation_service.dart';
import '../../../core/services/settings_service.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../core/utils/native_sheet_utils.dart';
import '../../../core/utils/user_avatar_utils.dart';
import '../../../core/utils/user_display_name.dart';
import '../../hermes/providers/hermes_providers.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/adaptive_glass.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/user_avatar.dart';
import '../../auth/providers/unified_auth_providers.dart';
import '../../terminal/providers/terminal_providers.dart';
import '../../workspace/providers/workspace_capabilities_provider.dart';
import '../providers/sidebar_providers.dart';

typedef SidebarNativeProfilePresenter =
    Future<bool> Function(NativeProfileSheetConfig config);

@visibleForTesting
NativeSheetItemConfig buildDirectConnectionsNativeSheetItem({
  required String title,
  required String subtitle,
}) => NativeSheetItemConfig(
  id: NativeSheetRoutes.directConnections,
  title: title,
  subtitle: subtitle,
  sfSymbol: 'link.circle',
  dismissOnSelect: true,
  actionId: NativeSheetRoutes.directConnections,
  actionValue: true,
);

/// Nullable platform seam so the iOS native-sheet failure fallback is
/// deterministic in widget tests.
final sidebarNativeProfilePresenterProvider =
    Provider<SidebarNativeProfilePresenter?>((ref) {
      if (!Platform.isIOS) return null;
      return NativeSheetBridge.instance.presentProfileMenu;
    });

/// Cached bytes of the Hermes agent icon, used as the native profile-sheet
/// avatar in Hermes-only mode (loaded once, then reused).
Uint8List? _hermesAvatarBytesCache;
Future<Uint8List?> _loadHermesAvatarBytes() async {
  if (_hermesAvatarBytesCache != null) return _hermesAvatarBytesCache;
  try {
    final data = await rootBundle.load('assets/icons/hermes_agent.png');
    return _hermesAvatarBytesCache = data.buffer.asUint8List();
  } catch (error, stackTrace) {
    DebugLogger.error(
      'Failed to load Hermes profile avatar asset',
      error: error,
      stackTrace: stackTrace,
      scope: 'navigation/sidebar/hermes-avatar',
    );
    return null;
  }
}

/// Resolves the best available current user for sidebar UI.
dynamic resolveSidebarUser(WidgetRef ref) {
  final authUser = ref.watch(currentUserProvider2);
  final asyncUser = ref.watch(currentUserProvider);
  return asyncUser.maybeWhen(
    data: (value) => value ?? authUser,
    orElse: () => authUser,
  );
}

/// Route used when the native profile sheet is unavailable or not presented.
/// Accountless direct-primary installs have no Open WebUI profile surface.
String sidebarProfileFallbackRouteName({
  required bool directPrimary,
  required bool hasOpenWebUiUser,
}) => directPrimary && !hasOpenWebUiUser
    ? RouteNames.directConnections
    : RouteNames.profile;

/// Localized search hint for the active sidebar tab.
String sidebarSearchHintForActiveTab(WidgetRef ref, AppLocalizations l10n) {
  // Hermes-only: the Hermes tab is the only tab.
  if (ref.watch(hermesOnlyModeProvider)) return l10n.searchConversations;
  final tabIndex = ref.watch(sidebarActiveTabProvider);
  final hermesOn = ref.watch(hermesEnabledProvider);
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
  if (hermesOn) {
    if (tabIndex == i) return l10n.searchConversations;
    i++;
  }
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
    final nativeProfilePresenter = ref.watch(
      sidebarNativeProfilePresenterProvider,
    );
    final hermesOnly = ref.watch(hermesOnlyModeProvider);
    final directPrimary =
        ref.watch(preferredBackendProvider) == PreferredBackend.direct;
    if (user == null && !hermesOnly && !directPrimary) {
      return const SizedBox.shrink();
    }

    final api = ref.watch(apiServiceProvider);
    final l10n = AppLocalizations.of(context)!;
    final canManageWorkspace = canManageAnyWorkspaceSection(ref);
    final directTitle = l10n.directConnectionsTitle;
    final displayName = hermesOnly
        ? 'Hermes Agent'
        : directPrimary && user == null
        ? directTitle
        : deriveUserDisplayName(user, fallback: l10n.userFallbackName);
    final initial = hermesOnly
        ? 'HA'
        : directPrimary && user == null
        ? directTitle.characters.first.toUpperCase()
        : displayName.isEmpty
        ? 'U'
        : displayName.characters.first.toUpperCase();
    final avatarUrl = hermesOnly || user == null
        ? null
        : resolveUserAvatarUrlForUser(api, user);
    final iconColor = context.conduitTheme.textPrimary;
    final useOpaqueFallback = conduitUsesOpaqueGlassFallback();
    final style = useOpaqueFallback
        ? AdaptiveButtonStyle.plain
        : AdaptiveButtonStyle.glass;

    return Semantics(
      label: l10n.manage,
      button: true,
      child: AdaptiveButton.child(
        key: const ValueKey<String>('sidebar-profile-button'),
        onPressed: () async {
          await Navigator.of(context).maybePop();
          if (!context.mounted) return;

          if (nativeProfilePresenter != null) {
            // Pre-load the Hermes avatar bytes (the config builder is sync, and
            // avatarBytes must be supplied up front).
            final hermesAvatarBytes = hermesOnly
                ? await _loadHermesAvatarBytes()
                : null;
            if (!context.mounted) return;
            final config = _buildNativeProfileSheetConfig(
              context: context,
              ref: ref,
              user: user,
              api: api,
              displayName: displayName,
              initials: initial,
              canManageWorkspace: canManageWorkspace,
              hermesAvatarBytes: hermesAvatarBytes,
            );
            final presented = await nativeProfilePresenter(config);
            if (presented) return;
          }

          if (context.mounted) {
            context.pushNamed(
              sidebarProfileFallbackRouteName(
                directPrimary: directPrimary,
                hasOpenWebUiUser: user != null,
              ),
            );
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
    required bool canManageWorkspace,
    Uint8List? hermesAvatarBytes,
  }) {
    final l10n = AppLocalizations.of(context)!;
    // In Hermes-only mode there's no Open WebUI account, so hide the OWUI
    // account-specific sections (profile, memory, data connection, password,
    // sign-out) and instead surface a "Connect to Open WebUI" switch entry.
    final hermesOnly = ref.read(hermesOnlyModeProvider);
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
      profile: hermesOnly
          ? NativeProfileSheetUser(
              displayName: 'Hermes Agent',
              email: _hermesHostLabel(
                ref,
                fallback: l10n.hermesSelfHostedAgentLabel,
              ),
              initials: 'HA',
              avatarBytes: hermesAvatarBytes,
            )
          : user == null
          ? NativeProfileSheetUser(
              displayName: l10n.directConnectionsTitle,
              email: l10n.directConnectionsSubtitle,
              initials: l10n.directConnectionsTitle.characters.first
                  .toUpperCase(),
            )
          : NativeProfileSheetUser(
              displayName: displayName,
              email: email,
              initials: initials,
              avatarUrl: avatarBytes == null ? avatarUrl : null,
              avatarBytes: avatarBytes,
              avatarHeaders: avatarUrl == null
                  ? const {}
                  : buildImageHeadersForUrlFromWidgetRef(ref, avatarUrl) ??
                        const {},
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
      menuItems: [
        if (user != null)
          NativeSheetItemConfig(
            id: NativeSheetRoutes.profile,
            title: displayName,
            subtitle: email,
            sfSymbol: 'person.crop.circle',
          ),
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
        // Notifications are OWUI-socket-derived, so require an OWUI account.
        if (user != null)
          NativeSheetItemConfig(
            id: NativeSheetRoutes.notificationSettings,
            title: l10n.notificationsTitle,
            sfSymbol: 'bell',
          ),
        if (user != null)
          NativeSheetItemConfig(
            id: NativeSheetRoutes.aiMemory,
            title: aiMemoryTitle,
            sfSymbol: 'wand.and.stars',
          ),
        NativeSheetItemConfig(
          id: NativeSheetRoutes.hermes,
          title: l10n.hermesAgentSettingsTitle,
          sfSymbol: 'sparkles',
          iconAsset: 'assets/icons/hermes_agent.png',
          dismissOnSelect: true,
          actionId: NativeSheetRoutes.hermes,
          actionValue: true,
        ),
        buildDirectConnectionsNativeSheetItem(
          title: l10n.directConnectionsTitle,
          subtitle: l10n.directConnectionsSubtitle,
        ),
        if (canManageWorkspace)
          NativeSheetItemConfig(
            id: NativeSheetRoutes.workspace,
            title: l10n.workspaceTitle,
            sfSymbol: 'square.grid.2x2',
            dismissOnSelect: true,
            actionId: NativeSheetRoutes.workspace,
            actionValue: true,
          ),
        if (user != null)
          NativeSheetItemConfig(
            id: NativeSheetRoutes.dataConnection,
            title: dataConnectionTitle,
            sfSymbol: 'network',
          ),
        if (user == null)
          NativeSheetItemConfig(
            id: 'add-owui-server',
            title: l10n.connectOpenWebUITitle,
            subtitle: l10n.connectOpenWebUISubtitle,
            sfSymbol: 'plus.circle',
            dismissOnSelect: true,
            actionId: 'add-owui-server',
            actionValue: true,
          ),
        NativeSheetItemConfig(
          id: NativeSheetRoutes.helpAbout,
          title: l10n.aboutApp,
          sfSymbol: 'info.circle',
        ),
        if (user != null)
          NativeSheetItemConfig(
            id: 'sign-out',
            title: l10n.signOut,
            subtitle: l10n.endYourSession,
            sfSymbol: 'rectangle.portrait.and.arrow.right',
            destructive: true,
          ),
      ],
      supportTitle: l10n.supportConduit,
      supportSubtitle: l10n.supportConduitSubtitle,
      supportItems: [
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
      detailSheets: [
        if (user != null)
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
        if (user != null)
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
          id: NativeSheetRoutes.notificationSettings,
          title: l10n.notificationsTitle,
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

  /// Header subtitle for the Hermes-only profile sheet: the configured agent's
  /// host, falling back to a generic label.
  String _hermesHostLabel(WidgetRef ref, {required String fallback}) {
    final baseUrl = ref.read(hermesConfigProvider).baseUrl;
    final host = Uri.tryParse(baseUrl)?.host;
    return host != null && host.isNotEmpty ? host : fallback;
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
