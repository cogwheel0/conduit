import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/chat/server_speech/direct_voice_provider_settings.dart';
import 'package:conduit_core/features/chat/server_speech/server_speech_providers.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart'
    show directConnectionProfilesProvider;
import 'package:conduit_core/models/account_metadata.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/services/settings_service.dart';

import '../../core/services/native_sheet_bridge.dart';
import '../../core/services/native_sheet_hydration_service.dart';
import '../../core/utils/native_sheet_utils.dart';

/// The pages the Settings root leads to that exist as soon as it opens, in
/// whichever Settings draws it: the account's pages, Voice and its pickers,
/// and a loading page for each one filled in when it appears.
///
/// [hasOpenWebUiUser] says whether an Open WebUI account is signed in; only
/// then are there Profile and Password pages. [profilePending] keeps the
/// Profile page loading until the account's profile has been refreshed,
/// since its editors save every field.
List<NativeSheetDetailConfig> buildSettingsRootDetails(
  AppLocalizations l10n,
  NativeSheetProviderReader read, {
  required bool hasOpenWebUiUser,
  required String displayName,
  required AccountMetadata? accountProfile,
  bool profilePending = false,
}) {
  final nativeAudio = buildNativeAudioSheetParts(
    l10n,
    read(appSettingsProvider),
    voiceProviderCandidates:
        (read(directConnectionProfilesProvider).value ?? const [])
            .where(canBeVoiceProvider)
            .toList(growable: false),
    serverOffersVoiceChoice:
        read(serverSpeechProviderProvider)?.offersVoiceChoice ?? false,
    availability: readNativeVoiceEngineAvailability(read),
  );
  return [
    readNativeAccountsDetail(read, l10n),
    readNativeAccountSignOutDetail(read, l10n),
    readNativeAddAccountDetail(read, l10n),
    ...buildHermesAccountsDetails(l10n),
    if (hasOpenWebUiUser && profilePending)
      buildNativeLoadingDetail(
        l10n: l10n,
        id: NativeSheetRoutes.profile,
        title: nativeProfileTitle(l10n),
        subtitle: l10n.loadingShort,
      )
    else if (hasOpenWebUiUser)
      NativeSheetDetailConfig(
        id: NativeSheetRoutes.profile,
        title: nativeProfileTitle(l10n),
        sections: buildNativeProfileDetailSections(
          l10n,
          displayName: displayName,
          accountProfile: accountProfile,
        ),
      ),
    if (hasOpenWebUiUser)
      buildNativePasswordDetail(
        l10n,
        passwordChangeEnabled: true,
        subtitle: l10n.passwordFieldsRequired,
      ),
    buildNativeLoadingDetail(
      l10n: l10n,
      id: NativeSheetRoutes.appearance,
      title: nativeAppearanceTitle(l10n),
      subtitle: l10n.loadingShort,
    ),
    NativeSheetDetailConfig(
      id: NativeSheetRoutes.voice,
      title: l10n.voice,
      discardPrompt: nativeDiscardPrompt(l10n),
      sections: nativeAudio.mainSections,
    ),
    nativeAudio.voicePickerDetail,
    nativeAudio.voiceProviderDetail,
    buildNativeLoadingDetail(
      l10n: l10n,
      id: NativeSheetRoutes.chats,
      title: nativeChatsTitle(l10n),
      subtitle: l10n.loadingShort,
    ),
    buildNativeLoadingDetail(
      l10n: l10n,
      id: NativeSheetRoutes.aiMemory,
      title: nativeAiMemoryTitle(l10n),
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
      title: nativeDataConnectionTitle(l10n),
      subtitle: l10n.loadingShort,
    ),
    buildNativeLoadingDetail(
      l10n: l10n,
      id: nativeLibreChatPersonalizationActionId,
      title: l10n.personalization,
    ),
    buildNativeLoadingDetail(
      l10n: l10n,
      id: NativeSheetRoutes.chatDataControls,
      title: l10n.chatDataControlsTitle,
      subtitle: l10n.loadingShort,
    ),
    buildNativeLoadingDetail(
      l10n: l10n,
      id: NativeSheetRoutes.calendar,
      title: l10n.calendarTitle,
      subtitle: l10n.loadingShort,
    ),
    buildNativeLoadingDetail(
      l10n: l10n,
      id: NativeSheetRoutes.workspace,
      title: l10n.workspaceTitle,
      subtitle: l10n.loadingShort,
    ),
    buildNativeLoadingDetail(
      l10n: l10n,
      id: NativeSheetRoutes.scheduledTasks,
      title: l10n.scheduledTasksTitle,
      subtitle: l10n.loadingShort,
    ),
    buildNativeLoadingDetail(
      l10n: l10n,
      id: NativeSheetRoutes.personalConnections,
      title: l10n.personalConnectionsTitle,
      subtitle: l10n.loadingShort,
    ),
    buildNativeLoadingDetail(
      l10n: l10n,
      id: NativeSheetRoutes.helpAbout,
      title: l10n.aboutApp,
      subtitle: l10n.loadingShort,
    ),
  ];
}

/// The signed-in Open WebUI user's email, from a [User] or the raw map some
/// sign-in paths keep, or null when there is none.
String? settingsUserEmail(Object? source) {
  if (source is User) return source.email;
  if (source is Map) {
    final value = source['email'];
    if (value is String && value.trim().isNotEmpty) return value.trim();
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
