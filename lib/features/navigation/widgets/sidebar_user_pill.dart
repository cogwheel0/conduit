import 'dart:convert';
import 'dart:collection';
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/models/user.dart';
import '../../../core/network/image_header_utils.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/backend_mode_providers.dart';
import '../../../core/services/api_service.dart';
import '../../../core/services/native_sheet_bridge.dart';
import '../../../core/services/native_sheet_hydration_service.dart';
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
import '../../workspace/providers/workspace_capabilities_provider.dart';
import '../providers/sidebar_providers.dart';
import 'sidebar_tab_registry.dart';

part 'sidebar_user_pill.g.dart';

typedef SidebarNativeProfilePresenter =
    Future<bool> Function(NativeProfileSheetConfig config);

const double _sidebarProfileAvatarSize = 36;
const double _sidebarNativeProfileAvatarSize = 28;
const int _sidebarAvatarMaximumSourceDimension = 8192;
const int _sidebarAvatarMaximumSourcePixels = 32 * 1024 * 1024;
const double _sidebarAvatarMaximumAspectRatio = 64;
const int _sidebarAvatarMaximumDecodeDimension = 512;
const int _sidebarAvatarMaximumEncodedBytes = 2 * 1024 * 1024;

@visibleForTesting
Future<Uint8List?> rasterizeSidebarNativeAvatar(
  Uint8List bytes, {
  required double devicePixelRatio,
}) async {
  if (bytes.isEmpty) return null;
  final scale = devicePixelRatio.isFinite
      ? devicePixelRatio.clamp(1.0, 4.0)
      : 1.0;
  final canvasPixels = (TouchTarget.minimum * scale).round();
  final avatarPixels = (_sidebarNativeProfileAvatarSize * scale).round();
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? source;
  ui.Image? output;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final sourceWidth = descriptor.width;
    final sourceHeight = descriptor.height;
    final shortestSide = sourceWidth < sourceHeight
        ? sourceWidth
        : sourceHeight;
    final longestSide = sourceWidth > sourceHeight ? sourceWidth : sourceHeight;
    final sourcePixels = sourceWidth * sourceHeight;
    if (shortestSide <= 0 ||
        longestSide > _sidebarAvatarMaximumSourceDimension ||
        sourcePixels > _sidebarAvatarMaximumSourcePixels ||
        longestSide / shortestSide > _sidebarAvatarMaximumAspectRatio) {
      return null;
    }

    final decodeScale = longestSide > _sidebarAvatarMaximumDecodeDimension
        ? _sidebarAvatarMaximumDecodeDimension / longestSide
        : 1.0;
    final targetWidth = (sourceWidth * decodeScale).round().clamp(
      1,
      sourceWidth,
    );
    final targetHeight = (sourceHeight * decodeScale).round().clamp(
      1,
      sourceHeight,
    );
    codec = await descriptor.instantiateCodec(
      targetWidth: targetWidth,
      targetHeight: targetHeight,
    );
    source = (await codec.getNextFrame()).image;

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final sourceSide = source.width < source.height
        ? source.width.toDouble()
        : source.height.toDouble();
    final sourceRect = ui.Rect.fromLTWH(
      (source.width - sourceSide) / 2,
      (source.height - sourceSide) / 2,
      sourceSide,
      sourceSide,
    );
    final inset = (canvasPixels - avatarPixels) / 2;
    final destinationRect = ui.Rect.fromLTWH(
      inset,
      inset,
      avatarPixels.toDouble(),
      avatarPixels.toDouble(),
    );
    canvas.save();
    canvas.clipPath(ui.Path()..addOval(destinationRect));
    canvas.drawImageRect(
      source,
      sourceRect,
      destinationRect,
      ui.Paint()..filterQuality = ui.FilterQuality.high,
    );
    canvas.restore();
    final picture = recorder.endRecording();
    try {
      output = await picture.toImage(canvasPixels, canvasPixels);
    } finally {
      picture.dispose();
    }
    final data = await output.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) return null;
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } catch (error, stackTrace) {
    DebugLogger.error(
      'Failed to rasterize native sidebar avatar',
      error: error,
      stackTrace: stackTrace,
      scope: 'navigation/sidebar/native-avatar',
    );
    return null;
  } finally {
    output?.dispose();
    source?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

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

typedef SidebarNativeAvatarRequest = ({ApiService api, String avatarUrl});

@immutable
class SidebarNativeAvatarRasterRequest {
  const SidebarNativeAvatarRasterRequest({
    required this.cacheKey,
    required this.bytes,
    required this.devicePixelRatio,
  });

  final String cacheKey;
  final Uint8List bytes;
  final double devicePixelRatio;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SidebarNativeAvatarRasterRequest &&
          cacheKey == other.cacheKey &&
          devicePixelRatio == other.devicePixelRatio;

  @override
  int get hashCode => Object.hash(cacheKey, devicePixelRatio);
}

@riverpod
Future<Uint8List?> sidebarNativeAvatarBytes(
  Ref ref,
  SidebarNativeAvatarRequest request,
) => ref
    .watch(nativeSheetAvatarBytesHydratorProvider)
    .loadAvatarBytes(api: request.api, avatarUrl: request.avatarUrl);

@riverpod
Future<Uint8List?> sidebarNativeAvatarRaster(
  Ref ref,
  SidebarNativeAvatarRasterRequest request,
) => rasterizeSidebarNativeAvatar(
  request.bytes,
  devicePixelRatio: request.devicePixelRatio,
);

final _sidebarHermesAvatarBytesProvider = FutureProvider<Uint8List?>((ref) {
  return _loadHermesAvatarBytes();
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
}) => RouteNames.profile;

/// Localized search hint for the active sidebar tab.
String sidebarSearchHintForActiveTab(WidgetRef ref, AppLocalizations l10n) {
  final selectedTab = ref.watch(sidebarNavigationSnapshotProvider).selectedTab;
  return sidebarTabDescriptor(selectedTab).searchHint(l10n);
}

/// Builds one stable native glass avatar button on iOS 26 and Flutter
/// platform-family fallbacks everywhere else.
@visibleForTesting
Widget buildSidebarProfileButton({
  required bool supportsNativeGlass,
  required VoidCallback onPressed,
  required AdaptiveButtonStyle fallbackStyle,
  Color? fallbackColor,
  Uint8List? nativeAvatarBytes,
  required Widget child,
}) {
  const buttonKey = ValueKey<String>('sidebar-profile-button');

  if (supportsNativeGlass) {
    final avatarBytes = nativeAvatarBytes;
    final nativeButton = CNButton.icon(
      key: avatarBytes == null
          ? const ValueKey<String>('sidebar-profile-native-placeholder')
          : ObjectKey(avatarBytes),
      icon: avatarBytes == null
          ? CNSymbol(
              'person.crop.circle.fill',
              size: IconSize.large,
              color: fallbackColor,
            )
          : null,
      imageAsset: avatarBytes == null
          ? null
          : CNImageAsset(
              '',
              imageData: avatarBytes,
              size: _sidebarNativeProfileAvatarSize,
            ),
      onPressed: onPressed,
      config: const CNButtonConfig(
        padding: EdgeInsets.zero,
        minHeight: TouchTarget.minimum,
        width: TouchTarget.minimum,
        style: CNButtonStyle.glass,
      ),
    );
    return SizedBox.square(
      key: buttonKey,
      dimension: TouchTarget.minimum,
      child: nativeButton,
    );
  }

  return AdaptiveButton.child(
    key: buttonKey,
    onPressed: onPressed,
    style: fallbackStyle,
    color: fallbackColor,
    size: AdaptiveButtonSize.large,
    padding: EdgeInsets.zero,
    minSize: const Size(TouchTarget.minimum, TouchTarget.minimum),
    useSmoothRectangleBorder: false,
    child: child,
  );
}

/// Profile button used as the sidebar adaptive app bar leading widget.
class SidebarProfileAppBarLeading extends ConsumerWidget {
  const SidebarProfileAppBarLeading({super.key});

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
    final inlineAvatarBytes = _decodeDataImage(avatarUrl);
    final supportsNativeGlass = conduitSupportsNativeGlass();
    final rawNativeAvatarBytes = !supportsNativeGlass
        ? null
        : hermesOnly
        ? ref.watch(_sidebarHermesAvatarBytesProvider).asData?.value
        : inlineAvatarBytes ??
              (api == null || avatarUrl == null || avatarUrl.isEmpty
                  ? null
                  : ref
                        .watch(
                          sidebarNativeAvatarBytesProvider((
                            api: api,
                            avatarUrl: avatarUrl,
                          )),
                        )
                        .asData
                        ?.value);
    final nativeAvatarBytes = rawNativeAvatarBytes == null
        ? null
        : ref
              .watch(
                sidebarNativeAvatarRasterProvider(
                  SidebarNativeAvatarRasterRequest(
                    cacheKey:
                        '${avatarUrl ?? 'hermes'}:'
                        '${rawNativeAvatarBytes.length}:'
                        '${identityHashCode(rawNativeAvatarBytes)}',
                    bytes: rawNativeAvatarBytes,
                    devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
                  ),
                ),
              )
              .asData
              ?.value;

    return Semantics(
      label: l10n.manage,
      button: true,
      child: buildSidebarProfileButton(
        supportsNativeGlass: supportsNativeGlass,
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
        fallbackStyle: style,
        fallbackColor: useOpaqueFallback ? iconColor : null,
        nativeAvatarBytes: nativeAvatarBytes,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppBorderRadius.avatar),
          child: UserAvatar(
            size: _sidebarProfileAvatarSize,
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
    final profileMenuItem = user == null
        ? null
        : NativeSheetItemConfig(
            id: NativeSheetRoutes.profile,
            title: displayName,
            subtitle: email,
            sfSymbol: 'person.crop.circle',
          );
    final appItems = <NativeSheetItemConfig>[
      NativeSheetItemConfig(
        id: NativeSheetRoutes.appearance,
        title: appearanceTitle,
        subtitle: l10n.settingsAppearanceSubtitle,
        sfSymbol: 'paintpalette',
      ),
      NativeSheetItemConfig(
        id: NativeSheetRoutes.chats,
        title: chatsTitle,
        subtitle: l10n.settingsChatSubtitle,
        sfSymbol: 'bubble.left.and.bubble.right',
      ),
      NativeSheetItemConfig(
        id: NativeSheetRoutes.voice,
        title: l10n.voice,
        subtitle: l10n.audioSettingsSubtitle,
        sfSymbol: 'waveform',
      ),
      if (user != null)
        NativeSheetItemConfig(
          id: NativeSheetRoutes.notificationSettings,
          title: l10n.notificationsTitle,
          subtitle: l10n.notificationsSubtitle,
          sfSymbol: 'bell',
        ),
      if (user != null)
        NativeSheetItemConfig(
          id: NativeSheetRoutes.aiMemory,
          title: aiMemoryTitle,
          subtitle: l10n.personalizationSubtitle,
          sfSymbol: 'wand.and.stars',
        ),
    ];
    final connectionItems = <NativeSheetItemConfig>[
      NativeSheetItemConfig(
        id: NativeSheetRoutes.hermes,
        title: l10n.hermesAgentSettingsTitle,
        subtitle: l10n.hermesAgentSettingsSubtitle,
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
          subtitle: l10n.workspaceSubtitle,
          sfSymbol: 'square.grid.2x2',
          dismissOnSelect: true,
          actionId: NativeSheetRoutes.workspace,
          actionValue: true,
        ),
      if (user != null)
        NativeSheetItemConfig(
          id: NativeSheetRoutes.dataConnection,
          title: dataConnectionTitle,
          subtitle: l10n.connectionHealth,
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
    ];
    final aboutItem = NativeSheetItemConfig(
      id: NativeSheetRoutes.helpAbout,
      title: l10n.aboutApp,
      subtitle: l10n.aboutAppSubtitle,
      sfSymbol: 'info.circle',
    );
    final signOutItem = user == null
        ? null
        : NativeSheetItemConfig(
            id: 'sign-out',
            title: l10n.signOut,
            placeholder: l10n.signOutOptionsDescription,
            options: [
              NativeSheetOptionConfig(
                id: 'keep-server-details',
                label: l10n.keepServerDetails,
                subtitle: l10n.keepServerDetailsDescription,
              ),
            ],
            sfSymbol: 'rectangle.portrait.and.arrow.right',
            destructive: true,
          );
    final supportItems = <NativeSheetItemConfig>[
      NativeSheetItemConfig(
        id: 'buy-me-a-coffee',
        title: l10n.buyMeACoffeeTitle,
        sfSymbol: 'gift',
        url: 'https://www.buymeacoffee.com/cogwheel0',
      ),
      NativeSheetItemConfig(
        id: 'github-sponsors',
        title: l10n.githubSponsorsTitle,
        sfSymbol: 'heart',
        url: 'https://github.com/sponsors/cogwheel0',
      ),
    ];
    final menuItems = <NativeSheetItemConfig>[
      ?profileMenuItem,
      ...appItems,
      ...connectionItems,
      aboutItem,
      ?signOutItem,
    ];

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
              avatarIsTemplate: true,
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
      menuItems: menuItems,
      supportTitle: l10n.supportConduit,
      supportItems: supportItems,
      sections: [
        if (profileMenuItem != null)
          NativeSheetSectionConfig(items: [profileMenuItem]),
        NativeSheetSectionConfig(items: appItems),
        NativeSheetSectionConfig(items: connectionItems),
        NativeSheetSectionConfig(items: [aboutItem]),
        if (signOutItem != null) NativeSheetSectionConfig(items: [signOutItem]),
        NativeSheetSectionConfig(
          title: l10n.supportConduit,
          items: supportItems,
        ),
      ],
      detailSheets: [
        if (user != null)
          NativeSheetDetailConfig(
            id: NativeSheetRoutes.profile,
            title: profileTitle,
            sections: [
              NativeSheetSectionConfig(
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
                    subtitle: l10n.profileDetailsSummary,
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
                    subtitle: l10n.passwordChangeDescription,
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

  static final LinkedHashMap<String, Uint8List> _dataImageBytesCache =
      LinkedHashMap<String, Uint8List>();

  Uint8List? _decodeDataImage(String? dataUrl) {
    if (dataUrl == null || !dataUrl.startsWith('data:image')) {
      return null;
    }
    final cached = _dataImageBytesCache.remove(dataUrl);
    if (cached != null) {
      _dataImageBytesCache[dataUrl] = cached;
      return cached;
    }
    try {
      final commaIndex = dataUrl.indexOf(',');
      if (commaIndex == -1) return null;
      final encodedLength = dataUrl.length - commaIndex - 1;
      final maximumBase64Length =
          ((_sidebarAvatarMaximumEncodedBytes + 2) ~/ 3) * 4;
      if (encodedLength > maximumBase64Length) return null;
      final decoded = base64Decode(dataUrl.substring(commaIndex + 1));
      if (decoded.lengthInBytes > _sidebarAvatarMaximumEncodedBytes) {
        return null;
      }
      _dataImageBytesCache[dataUrl] = decoded;
      while (_dataImageBytesCache.length > 4) {
        _dataImageBytesCache.remove(_dataImageBytesCache.keys.first);
      }
      return decoded;
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
