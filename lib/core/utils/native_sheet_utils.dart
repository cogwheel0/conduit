import 'package:flutter/foundation.dart' show Uint8List, immutable;
import 'package:intl/intl.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/utils/locale_display_formatters.dart';

import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_profile.dart';
import 'package:conduit_core/models/account_metadata.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_memory.dart';
import 'package:conduit_core/models/socket_health.dart';

import '../services/native_sheet_bridge.dart';

import 'package:conduit_core/services/settings_service.dart';

import 'package:conduit_core/providers/app_providers.dart'
    show OpenWebUiAccountEntry;

import '../../features/hermes/widgets/hermes_connection_switcher.dart'
    show hermesConnectionSummary;
import 'account_display.dart';
import 'tts_voice_utils.dart';

String nativeQuickActionsTitle(AppLocalizations l10n) {
  return l10n.quickActionsDescription;
}

String nativeSettingsTitle(AppLocalizations l10n) => l10n.settingsTitle;

String nativeProfileTitle(AppLocalizations l10n) => l10n.profileTitle;

String nativeAppearanceTitle(AppLocalizations l10n) => l10n.settingsAppearance;

String nativeChatsTitle(AppLocalizations l10n) => l10n.sidebarChatsTab;

String nativeAiMemoryTitle(AppLocalizations l10n) => l10n.aiAndMemoryTitle;

String nativeDataConnectionTitle(AppLocalizations l10n) =>
    l10n.settingsDataAndConnection;

/// Rows of the native About page. The server rows are left out when there
/// is no Open WebUI server (Hermes-only).
List<NativeSheetItemConfig> buildNativeAboutItems(
  AppLocalizations l10n, {
  required String appVersion,
  String? serverName,
  String? serverVersion,
}) => [
  NativeSheetItemConfig(
    id: 'app-version',
    title: l10n.appVersion,
    subtitle: appVersion,
    sfSymbol: 'app.badge',
    kind: NativeSheetItemKind.info,
  ),
  if (serverName != null)
    NativeSheetItemConfig(
      id: 'server-name',
      title: l10n.serverNameLabel,
      subtitle: serverName,
      sfSymbol: 'server.rack',
      kind: NativeSheetItemKind.info,
    ),
  if (serverVersion != null)
    NativeSheetItemConfig(
      id: 'server-version',
      title: l10n.serverVersionLabel,
      subtitle: serverVersion,
      sfSymbol: 'number',
      kind: NativeSheetItemKind.info,
    ),
  // Release notes and the licenses open Flutter pages, so they close the
  // sheet like the other rows that leave it, and say so with a chevron.
  NativeSheetItemConfig(
    id: NativeSheetRoutes.releaseNotesManual,
    title: l10n.releaseNotesTitle,
    sfSymbol: 'sparkles',
    showsDisclosure: true,
    dismissOnSelect: true,
  ),
  NativeSheetItemConfig(
    id: 'github',
    title: l10n.githubRepository,
    sfSymbol: 'chevron.left.forwardslash.chevron.right',
    url: 'https://github.com/cogwheel0/conduit',
  ),
  NativeSheetItemConfig(
    id: NativeSheetRoutes.openSourceLicenses,
    title: l10n.openSourceLicenses,
    sfSymbol: 'doc.text',
    showsDisclosure: true,
    dismissOnSelect: true,
  ),
];

/// Which rows of the native Settings root the signed-in account is offered.
/// Each flag is read from the same provider the Flutter Settings page
/// watches, so both lists show the same entries.
@immutable
class NativeProfileRootVisibility {
  const NativeProfileRootVisibility({
    this.showCalendar = false,
    this.canManageWorkspace = false,
    this.showScheduledTasks = false,
    this.showPersonalConnections = false,
    this.showChatDataControls = false,
  });

  final bool showCalendar;
  final bool canManageWorkspace;
  final bool showScheduledTasks;
  final bool showPersonalConnections;
  final bool showChatDataControls;

  @override
  bool operator ==(Object other) =>
      other is NativeProfileRootVisibility &&
      other.showCalendar == showCalendar &&
      other.canManageWorkspace == canManageWorkspace &&
      other.showScheduledTasks == showScheduledTasks &&
      other.showPersonalConnections == showPersonalConnections &&
      other.showChatDataControls == showChatDataControls;

  @override
  int get hashCode => Object.hash(
    showCalendar,
    canManageWorkspace,
    showScheduledTasks,
    showPersonalConnections,
    showChatDataControls,
  );
}

/// The account a native Settings root was built for: its profile row, or
/// none when there is no Open WebUI account (Hermes-only or Direct).
@immutable
class NativeProfileRootAccount {
  const NativeProfileRootAccount({
    required this.displayName,
    required this.email,
  });

  final String displayName;
  final String email;
}

/// The sections of the native Settings root, in the order the Flutter
/// Settings page uses: the account card -- whom Settings is for, leading to
/// every account and connection, with Add account under it -- then the
/// signed-in account's own rows, the everyday settings, places, and an
/// Advanced group that only exists while it has a row.
///
/// Pure, so the open sheet can be rebuilt with the same rows when a setting
/// it depends on (Advanced) changes while it is up.
///
/// [otherAccountCount] counts the saved Open WebUI accounts besides the
/// active one, and is null when they could not be read in time. There may
/// be several then, and signing out signs out of every one, so the sign-out
/// row says so.
List<NativeSheetSectionConfig> buildNativeProfileRootSections(
  AppLocalizations l10n, {
  required NativeProfileRootAccount? account,
  required NativeProfileRootVisibility visibility,
  required ({String title, String? subtitle}) card,
  int? otherAccountCount = 0,
}) {
  final hasAccount = account != null;
  final cardItems = <NativeSheetItemConfig>[
    NativeSheetItemConfig(
      id: nativeAccountsDetailId,
      title: card.title,
      subtitle: card.subtitle,
      sfSymbol: 'person.crop.circle',
      usesProfileAvatar: true,
    ),
    _nativeAddItem(
      nativeAccountAddActionId,
      title: l10n.accountsAddAccount,
      kind: null,
    ),
  ];
  // What belongs to the Open WebUI account signed in.
  final accountItems = <NativeSheetItemConfig>[
    if (hasAccount) ...[
      NativeSheetItemConfig(
        id: NativeSheetRoutes.profile,
        title: l10n.profileTitle,
        sfSymbol: 'person.crop.circle',
      ),
      NativeSheetItemConfig(
        id: NativeSheetRoutes.notificationSettings,
        title: l10n.notificationsTitle,
        sfSymbol: 'bell',
      ),
      NativeSheetItemConfig(
        id: NativeSheetRoutes.aiMemory,
        title: nativeAiMemoryTitle(l10n),
        sfSymbol: 'wand.and.stars',
      ),
      NativeSheetItemConfig(
        id: NativeSheetRoutes.dataConnection,
        title: nativeDataConnectionTitle(l10n),
        sfSymbol: 'network',
      ),
    ],
  ];
  // Single-line settings rows, so each title and its symbol carry the
  // meaning without a descriptive subtitle.
  final appItems = <NativeSheetItemConfig>[
    NativeSheetItemConfig(
      id: NativeSheetRoutes.appearance,
      title: nativeAppearanceTitle(l10n),
      sfSymbol: 'paintpalette',
    ),
    NativeSheetItemConfig(
      id: NativeSheetRoutes.chats,
      title: nativeChatsTitle(l10n),
      sfSymbol: 'bubble.left.and.bubble.right',
    ),
    NativeSheetItemConfig(
      id: NativeSheetRoutes.voice,
      title: l10n.voice,
      sfSymbol: 'waveform',
    ),
  ];
  // Everyday server places: things to open and use, not to configure.
  final placeItems = <NativeSheetItemConfig>[
    if (visibility.showCalendar)
      _nativeRootPageItem(
        NativeSheetRoutes.calendar,
        title: l10n.calendarTitle,
        sfSymbol: 'calendar',
      ),
    if (visibility.canManageWorkspace)
      _nativeRootPageItem(
        NativeSheetRoutes.workspace,
        title: l10n.workspaceTitle,
        sfSymbol: 'square.grid.2x2',
      ),
  ];
  // Power-user pages Advanced reveals. The group goes with its last row, so
  // turning Advanced off leaves no empty heading behind.
  final advancedItems = <NativeSheetItemConfig>[
    if (visibility.showScheduledTasks)
      _nativeRootPageItem(
        NativeSheetRoutes.scheduledTasks,
        title: l10n.scheduledTasksTitle,
        sfSymbol: 'clock.arrow.circlepath',
      ),
    if (visibility.showPersonalConnections)
      _nativeRootPageItem(
        NativeSheetRoutes.personalConnections,
        title: l10n.personalConnectionsTitle,
        sfSymbol: 'server.rack',
      ),
    if (visibility.showChatDataControls)
      _nativeRootPageItem(
        NativeSheetRoutes.chatDataControls,
        title: l10n.chatDataControlsTitle,
        sfSymbol: 'externaldrive',
      ),
  ];
  return [
    NativeSheetSectionConfig(items: cardItems),
    if (accountItems.isNotEmpty)
      NativeSheetSectionConfig(
        title: l10n.accountSettingsTitle,
        items: accountItems,
      ),
    NativeSheetSectionConfig(items: appItems),
    if (placeItems.isNotEmpty) NativeSheetSectionConfig(items: placeItems),
    if (advancedItems.isNotEmpty)
      NativeSheetSectionConfig(
        title: l10n.advancedFeatures,
        footer: l10n.profileAdvancedFooter,
        items: advancedItems,
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
    if (hasAccount)
      NativeSheetSectionConfig(
        items: [
          // With several accounts, Sign out leaves this one and the next
          // takes over; signing out of all is on the Accounts page. With
          // one, it is what it always was.
          if (otherAccountCount != null && otherAccountCount > 0)
            NativeSheetItemConfig(
              id: nativeAccountSignOutActionId,
              title: l10n.signOut,
              sfSymbol: 'rectangle.portrait.and.arrow.right',
              destructive: true,
              dismissOnSelect: true,
              showsDisclosure: false,
              actionId: nativeAccountSignOutActionId,
              actionValue: true,
            )
          else
            _nativeSignOutItem(
              l10n,
              title: otherAccountCount == null
                  ? l10n.accountsSignOutAll
                  : l10n.signOut,
            ),
        ],
      ),
    NativeSheetSectionConfig(
      title: l10n.supportConduit,
      items: buildNativeSupportItems(l10n),
    ),
  ];
}

/// Id of the native Accounts page, pushed from the account card.
const nativeAccountsDetailId = 'accounts';

/// The native Accounts page: a card for each Open WebUI server -- its own
/// row opening its page, its accounts under it, the active one checked --
/// then Hermes with its connections, the one in use checked, and Direct
/// with its providers, each opening its editor. A card's empty list offers
/// to add its first; + in the bar adds any.
///
/// [accounts] and [directProfiles] are null when they could not be read in
/// time; [hermesInUseId] is null while Hermes is off.
NativeSheetDetailConfig buildNativeAccountsDetail(
  AppLocalizations l10n, {
  required List<OpenWebUiAccountEntry>? accounts,
  required List<HermesConnectionProfile> hermesConnections,
  required String? hermesInUseId,
  required List<DirectConnectionProfile>? directProfiles,
  bool appleOnDevice = false,
  bool applePcc = false,
}) {
  final byServer = <String, List<OpenWebUiAccountEntry>>{};
  for (final entry in accounts ?? const <OpenWebUiAccountEntry>[]) {
    byServer.putIfAbsent(entry.server.id, () => []).add(entry);
  }
  final saved = directProfiles ?? const <DirectConnectionProfile>[];
  return NativeSheetDetailConfig(
    id: nativeAccountsDetailId,
    title: l10n.accountsTitle,
    trailingActionId: nativeAccountAddActionId,
    trailingActionSfSymbol: 'plus',
    sections: [
      if (accounts == null)
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: 'accounts-unreadable',
              title: l10n.errorMessage,
              sfSymbol: 'exclamationmark.triangle',
              kind: NativeSheetItemKind.info,
            ),
          ],
        )
      else if (accounts.isEmpty)
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: 'accounts-openwebui',
              title: l10n.backendChooserOpenWebUITitle,
              sfSymbol: 'server.rack',
              iconAsset: 'assets/icons/open_webui.png',
              kind: NativeSheetItemKind.info,
            ),
            _nativeAddItem(
              'accounts-openwebui-add',
              title: l10n.connectOpenWebUITitle,
              kind: 'openWebUi',
            ),
          ],
        )
      else
        for (final group in byServer.values)
          NativeSheetSectionConfig(
            items: [
              NativeSheetItemConfig(
                id: '$nativeAccountServerActionId:${group.first.server.id}',
                title: serverDisplayName(group.first.server),
                avatarName: serverDisplayName(group.first.server),
                dismissOnSelect: true,
                actionId: nativeAccountServerActionId,
                actionValue: group.first.server.id,
              ),
              for (final entry in group) _nativeAccountItem(entry, l10n),
            ],
          ),
      NativeSheetSectionConfig(
        items: [
          NativeSheetItemConfig(
            id: 'accounts-hermes',
            title: l10n.hermesAgentSettingsTitle,
            sfSymbol: 'sparkles',
            iconAsset: 'assets/icons/hermes_agent.png',
            iconSize: 26,
            dismissOnSelect: true,
            actionId: NativeSheetRoutes.hermes,
            actionValue: true,
          ),
          for (final connection in hermesConnections)
            _nativeSwitchItem(
              id: '$nativeHermesUseActionId:${connection.id}',
              title: connection.name,
              subtitle: hermesConnectionSummary(connection),
              sfSymbol: connection.mode == HermesBackendMode.desktopGateway
                  ? 'desktopcomputer'
                  : 'cloud',
              inUse: connection.id == hermesInUseId,
              actionId: nativeHermesUseActionId,
              actionValue: connection.id,
            ),
          if (hermesConnections.isEmpty)
            _nativeAddItem(
              'accounts-hermes-add',
              title: l10n.hermesAddConnection,
              kind: 'hermes',
            ),
        ],
      ),
      NativeSheetSectionConfig(
        items: [
          _nativeRootPageItem(
            NativeSheetRoutes.directConnections,
            title: l10n.directConnectionsTitle,
            sfSymbol: 'link.circle',
          ),
          if (appleOnDevice)
            NativeSheetItemConfig(
              id: 'accounts-apple-on-device',
              title: l10n.backendChooserAppleOnDeviceTitle,
              sfSymbol: 'iphone',
              dismissOnSelect: true,
              actionId: NativeSheetRoutes.directConnections,
              actionValue: true,
            ),
          if (applePcc)
            NativeSheetItemConfig(
              id: 'accounts-apple-pcc',
              title: l10n.backendChooserApplePccTitle,
              sfSymbol: 'lock.shield',
              dismissOnSelect: true,
              actionId: NativeSheetRoutes.directConnections,
              actionValue: true,
            ),
          for (final profile in saved)
            NativeSheetItemConfig(
              id: '$nativeDirectEditActionId:${profile.id}',
              title: profile.name,
              subtitle: [
                directProviderName(profile, l10n),
                if (!profile.enabled) l10n.disabledLabel,
              ].join(' · '),
              sfSymbol: profile.adapterKey == kOllamaAdapterKey
                  ? 'desktopcomputer'
                  : 'cloud',
              dismissOnSelect: true,
              actionId: nativeDirectEditActionId,
              actionValue: profile.id,
            ),
          // Not offered while the saved ones are unread: the Direct page
          // says why, and adds from there.
          if (directProfiles != null &&
              saved.isEmpty &&
              !appleOnDevice &&
              !applePcc)
            _nativeAddItem(
              'accounts-direct-add',
              title: l10n.addDirectConnection,
              kind: 'direct',
            ),
        ],
      ),
      // With one account, Settings' Sign out already signs out of it.
      if ((accounts?.length ?? 0) > 1)
        NativeSheetSectionConfig(
          items: [_nativeSignOutItem(l10n, title: l10n.accountsSignOutAll)],
        ),
    ],
  );
}

/// A saved Open WebUI account under its server: switched to on a tap, but
/// the one in use, signed in, stays put.
NativeSheetItemConfig _nativeAccountItem(
  OpenWebUiAccountEntry entry,
  AppLocalizations l10n,
) {
  final name = accountDisplayName(entry, l10n);
  return _nativeSwitchItem(
    id: '$nativeAccountSwitchActionId:${entry.id}',
    title: name,
    subtitle: accountSubtitle(entry, l10n),
    avatarName: name,
    avatarBytes: _dataUrlBytes(entry.summary.profileImage),
    checked: entry.isActive,
    inUse: entry.isActive && entry.hasSession,
    actionId: nativeAccountSwitchActionId,
    actionValue: entry.id,
  );
}

/// A row to switch to, checked when [checked] (by default, when [inUse]);
/// the one in use has nothing to switch to and does nothing.
NativeSheetItemConfig _nativeSwitchItem({
  required String id,
  required String title,
  required String? subtitle,
  required bool inUse,
  required String actionId,
  required String actionValue,
  bool? checked,
  String sfSymbol = 'person.crop.circle',
  String? avatarName,
  Uint8List? avatarBytes,
}) => NativeSheetItemConfig(
  id: id,
  title: title,
  subtitle: subtitle,
  sfSymbol: sfSymbol,
  avatarName: avatarName,
  avatarBytes: avatarBytes,
  checked: checked ?? inUse,
  kind: inUse ? NativeSheetItemKind.info : NativeSheetItemKind.navigation,
  dismissOnSelect: !inUse,
  showsDisclosure: false,
  actionId: inUse ? null : actionId,
  actionValue: inUse ? null : actionValue,
);

/// A row, in the accent color, that closes the sheet to add an account or
/// connection -- on the account sheet's tab for [kind], when given.
NativeSheetItemConfig _nativeAddItem(
  String id, {
  required String title,
  required String? kind,
}) => NativeSheetItemConfig(
  id: id,
  title: title,
  sfSymbol: 'plus',
  accent: true,
  dismissOnSelect: true,
  showsDisclosure: false,
  actionId: nativeAccountAddActionId,
  actionValue: kind ?? true,
);

NativeSheetItemConfig _nativeSignOutItem(
  AppLocalizations l10n, {
  required String title,
}) => NativeSheetItemConfig(
  id: nativeSignOutActionId,
  title: title,
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

/// The bytes of a picture saved as a data URL, as Open WebUI keeps uploaded
/// ones; null for anything else.
Uint8List? _dataUrlBytes(String? url) {
  if (url == null || !url.startsWith('data:image')) return null;
  try {
    return UriData.parse(url).contentAsBytes();
  } on FormatException {
    return null;
  }
}

/// Control id of the Advanced toggle in the native Chats page.
const nativeAdvancedFeaturesId = 'advanced-features';

/// Control id of the "Show citation page titles" toggle in the native Chats
/// page.
const nativeCitationShowTitlesId = 'citation-show-titles';

/// Control id the accountless "Connect to Open WebUI" root row sends.
const nativeConnectOpenWebUiActionId = 'add-owui-server';

/// Control id of the root Sign out row.
const nativeSignOutActionId = 'sign-out';

/// Native Settings rows for accounts and connections. A row that acts on
/// one carries its id as its action value; an add row, the account sheet's
/// tab for its kind (`openWebUi`, `hermes`, `direct`), or true for the first.
const nativeAccountSwitchActionId = 'account-switch';
const nativeAccountAddActionId = 'account-add';
const nativeAccountSignOutActionId = 'account-sign-out';
const nativeAccountServerActionId = 'account-server';
const nativeHermesUseActionId = 'account-hermes-use';
const nativeDirectEditActionId = 'account-direct-edit';

/// The donation rows at the bottom of the native Settings root.
List<NativeSheetItemConfig> buildNativeSupportItems(AppLocalizations l10n) => [
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

/// A root row that closes the sheet and opens a Flutter page; it sends its
/// own id as the control id.
NativeSheetItemConfig _nativeRootPageItem(
  String id, {
  required String title,
  required String sfSymbol,
}) => NativeSheetItemConfig(
  id: id,
  title: title,
  sfSymbol: sfSymbol,
  dismissOnSelect: true,
  actionId: id,
  actionValue: true,
);

/// The sections of the native Profile page. [accountProfile] supplies the
/// About text; with none loaded the rows show it as not set.
List<NativeSheetSectionConfig> buildNativeProfileDetailSections(
  AppLocalizations l10n, {
  required String displayName,
  required AccountMetadata? accountProfile,
}) {
  final bio = accountProfile?.bio?.trim();
  final hasBio = bio != null && bio.isNotEmpty;
  return [
    NativeSheetSectionConfig(
      items: [
        NativeSheetItemConfig(
          id: 'profile-photo',
          title: l10n.editPhoto,
          sfSymbol: 'person.crop.circle',
          showsDisclosure: true,
        ),
      ],
    ),
    NativeSheetSectionConfig(
      items: [
        NativeSheetItemConfig(
          id: 'profile-name',
          title: l10n.name,
          subtitle: [displayName, if (hasBio) bio].join(' · '),
          sfSymbol: 'person.text.rectangle',
          showsDisclosure: true,
        ),
        NativeSheetItemConfig(
          id: 'profile-about',
          title: l10n.bioLabel,
          subtitle: hasBio ? bio : l10n.notSet,
          sfSymbol: 'text.bubble',
          showsDisclosure: true,
        ),
        NativeSheetItemConfig(
          id: 'profile-details',
          title: l10n.profileDetails,
          subtitle: l10n.profileDetailsSummary,
          sfSymbol: 'person.crop.circle',
          showsDisclosure: true,
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
  ];
}

String? resolveNativeSheetModelName(List<Model> models, String? modelId) {
  if (modelId == null || modelId.isEmpty) return null;
  for (final model in models) {
    if (model.id == modelId) return model.name;
  }
  return modelId;
}

String nativeSheetPreviewText(AppLocalizations l10n, String? value) {
  if (value == null || value.trim().isEmpty) return l10n.notSet;
  final text = value.trim();
  if (text.length > 88) return '${text.substring(0, 85)}...';
  return text;
}

String truncateNativeSheetMemory(String content) {
  final normalized = content.trim().replaceAll('\n', ' ');
  if (normalized.length <= 72) return normalized;
  return '${normalized.substring(0, 69)}...';
}

String nativeSheetMemoryUpdatedSubtitle(
  AppLocalizations l10n,
  ServerMemory memory,
) {
  final formatted = DateFormat.yMMMd().add_jm().format(memory.updatedAt);
  return l10n.memoryUpdatedAt(formatted);
}

NativeSheetItemConfig buildNativeLoadingItem(
  AppLocalizations l10n, {
  String id = 'loading',
  String? title,
  String sfSymbol = 'ellipsis.circle',
}) {
  return NativeSheetItemConfig(
    id: id,
    title: title ?? l10n.loadingShort,
    sfSymbol: sfSymbol,
    kind: NativeSheetItemKind.info,
  );
}

NativeSheetDetailConfig buildNativeLoadingDetail({
  required AppLocalizations l10n,
  required String id,
  required String title,
  String? subtitle,
}) {
  return NativeSheetDetailConfig(
    id: id,
    title: title,
    subtitle: subtitle,
    items: [buildNativeLoadingItem(l10n, id: '$id-loading')],
  );
}

class NativeAudioSheetParts {
  const NativeAudioSheetParts({
    required this.mainSections,
    required this.voicePickerDetail,
  });

  final List<NativeSheetSectionConfig> mainSections;
  final NativeSheetDetailConfig voicePickerDetail;
}

NativeAudioSheetParts buildNativeAudioSheetParts(
  AppLocalizations l10n,
  AppSettings appSettings, {
  List<Map<String, dynamic>> ttsVoices = const <Map<String, dynamic>>[],
}) {
  final sttSegment = NativeSheetItemConfig(
    id: 'stt-engine',
    title: l10n.sttSettings,
    subtitle: l10n.sttEngineDeviceDescription,
    sfSymbol: 'mic',
    kind: NativeSheetItemKind.segment,
    value: appSettings.sttPreference.name,
    options: [
      NativeSheetOptionConfig(id: 'deviceOnly', label: l10n.sttEngineDevice),
      NativeSheetOptionConfig(id: 'serverOnly', label: l10n.sttEngineServer),
    ],
  );

  final silenceDivisions =
      ((SettingsService.maxVoiceSilenceDurationMs -
                  SettingsService.minVoiceSilenceDurationMs) ~/
              100)
          .clamp(1, 1000)
          .toInt();

  final silenceSlider = NativeSheetItemConfig(
    id: 'stt-silence-duration',
    title: l10n.sttSilenceDuration,
    subtitle: l10n.sttSilenceDurationDescription,
    sfSymbol: 'timer',
    kind: NativeSheetItemKind.slider,
    value: appSettings.voiceSilenceDuration.toDouble(),
    min: SettingsService.minVoiceSilenceDurationMs.toDouble(),
    max: SettingsService.maxVoiceSilenceDurationMs.toDouble(),
    divisions: silenceDivisions,
  );

  final sttLanguageField = NativeSheetItemConfig(
    id: 'stt-language-code',
    title: l10n.sttTranscriptionLanguage,
    subtitle: appSettings.sttLanguageCode ?? l10n.sttTranscriptionLanguageAuto,
    sfSymbol: 'globe',
    kind: NativeSheetItemKind.textField,
    value: appSettings.sttLanguageCode ?? '',
    placeholder: l10n.sttTranscriptionLanguagePlaceholder,
  );

  final ttsSegment = NativeSheetItemConfig(
    id: 'tts-engine',
    title: l10n.ttsSettings,
    subtitle: appSettings.ttsEngine == TtsEngine.server
        ? l10n.ttsEngineServerDescription
        : l10n.ttsEngineDeviceDescription,
    sfSymbol: 'speaker.wave.2',
    kind: NativeSheetItemKind.segment,
    value: appSettings.ttsEngine.name,
    options: [
      NativeSheetOptionConfig(id: 'device', label: l10n.ttsEngineDevice),
      NativeSheetOptionConfig(id: 'server', label: l10n.ttsEngineServer),
    ],
  );

  final voiceOptions = buildTtsVoiceOptions(
    l10n,
    appSettings.ttsEngine,
    ttsVoices,
  );
  final selectedVoiceId = selectedTtsVoiceOptionId(appSettings, ttsVoices);

  final voicePickerNav = NativeSheetItemConfig(
    id: 'tts-voice-picker',
    title: l10n.ttsVoice,
    subtitle: _nativeVoiceSubtitle(l10n, appSettings),
    sfSymbol: 'person.wave.2',
    kind: NativeSheetItemKind.searchablePicker,
    value: selectedVoiceId,
    options: [
      NativeSheetOptionConfig(
        id: ttsSystemDefaultVoiceId,
        label: l10n.ttsSystemDefault,
      ),
      for (final option in voiceOptions)
        NativeSheetOptionConfig(
          id: option.id,
          label: option.label,
          subtitle: option.subtitle,
          sfSymbol: 'person.wave.2',
        ),
    ],
  );

  final speechRateSlider = NativeSheetItemConfig(
    id: 'tts-speech-rate',
    title: l10n.ttsSpeechRate,
    sfSymbol: 'gauge.with.dots.needle.67percent',
    kind: NativeSheetItemKind.slider,
    value: appSettings.ttsSpeechRate,
    min: 0.25,
    max: 2.0,
    divisions: 35,
  );

  final previewNav = NativeSheetItemConfig(
    id: 'tts-preview',
    title: l10n.ttsPreview,
    subtitle: l10n.ttsPreviewText,
    sfSymbol: 'play.circle',
    value: l10n.ttsPreviewText,
  );

  final sttItems = <NativeSheetItemConfig>[
    sttSegment,
    if (appSettings.sttPreference == SttPreference.serverOnly) ...[
      sttLanguageField,
      silenceSlider,
    ],
    NativeSheetItemConfig(
      id: 'voice-barge-in',
      title: l10n.voiceBargeIn,
      subtitle: l10n.voiceBargeInDescription,
      sfSymbol: 'waveform',
      kind: NativeSheetItemKind.toggle,
      value: appSettings.voiceBargeInEnabled,
    ),
  ];

  final ttsItems = <NativeSheetItemConfig>[
    ttsSegment,
    voicePickerNav,
    if (appSettings.ttsEngine == TtsEngine.device) speechRateSlider,
    previewNav,
  ];

  final voicePickerDetail = NativeSheetDetailConfig(
    id: 'tts-voice-picker',
    title: l10n.ttsSelectVoice,
    subtitle: l10n.ttsVoice,
    items: const [],
  );

  return NativeAudioSheetParts(
    mainSections: [
      NativeSheetSectionConfig(items: sttItems),
      NativeSheetSectionConfig(items: ttsItems),
    ],
    voicePickerDetail: voicePickerDetail,
  );
}

String _nativeVoiceSubtitle(AppLocalizations l10n, AppSettings settings) {
  if (settings.ttsEngine == TtsEngine.server) {
    final voice =
        settings.ttsServerVoiceName ??
        settings.ttsServerVoiceId ??
        l10n.ttsSystemDefault;
    return formatTtsVoiceDisplayName(voice);
  }
  final voice =
      settings.ttsVoiceName ?? settings.ttsVoice ?? l10n.ttsSystemDefault;
  return formatTtsVoiceDisplayName(voice);
}

NativeSheetDetailConfig buildNativePasswordDetail(
  AppLocalizations l10n, {
  required bool passwordChangeEnabled,
  String? subtitle,
}) {
  final items = passwordChangeEnabled
      ? [
          NativeSheetItemConfig(
            id: 'current-password',
            title: l10n.currentPassword,
            subtitle: l10n.passwordHint,
            sfSymbol: 'lock',
            kind: NativeSheetItemKind.secureTextField,
            placeholder: l10n.currentPassword,
          ),
          NativeSheetItemConfig(
            id: 'new-password',
            title: l10n.newPassword,
            subtitle: l10n.passwordHint,
            sfSymbol: 'key',
            kind: NativeSheetItemKind.secureTextField,
            placeholder: l10n.newPassword,
          ),
          NativeSheetItemConfig(
            id: 'confirm-password',
            title: l10n.confirmNewPassword,
            subtitle: l10n.passwordHint,
            sfSymbol: 'checkmark.shield',
            kind: NativeSheetItemKind.secureTextField,
            placeholder: l10n.confirmNewPassword,
          ),
        ]
      : [
          NativeSheetItemConfig(
            id: 'password-unavailable',
            title: l10n.changePasswordTitle,
            subtitle: l10n.passwordChangeUnavailable,
            sfSymbol: 'lock.slash',
            kind: NativeSheetItemKind.info,
          ),
        ];
  return NativeSheetDetailConfig(
    id: 'password',
    title: l10n.changePasswordTitle,
    subtitle: passwordChangeEnabled ? subtitle : null,
    items: items,
  );
}

List<NativeSheetOptionConfig> buildNativeDefaultModelOptions(
  AppLocalizations l10n,
  List<Model> models,
) {
  return [
    NativeSheetOptionConfig(id: 'auto-select', label: l10n.autoSelect),
    for (final model in models)
      NativeSheetOptionConfig(id: model.id, label: model.name),
  ];
}

NativeSheetDetailConfig buildNativeDefaultModelDetail(
  AppLocalizations l10n, {
  required List<Model> models,
  required String? selectedModelId,
  String? subtitle,
}) {
  return NativeSheetDetailConfig(
    id: 'default-model',
    title: l10n.defaultModel,
    subtitle: subtitle ?? l10n.autoSelectDescription,
    items: [
      NativeSheetItemConfig(
        id: 'default-model',
        title: l10n.defaultModel,
        subtitle: l10n.autoSelectDescription,
        sfSymbol: 'wand.and.stars',
        kind: NativeSheetItemKind.dropdown,
        value: selectedModelId ?? 'auto-select',
        options: buildNativeDefaultModelOptions(l10n, models),
      ),
    ],
  );
}

NativeSheetItemConfig? buildNativeOpenRouterImageGenerationModelItem(
  AppLocalizations l10n, {
  required List<Model> models,
  required String? selectedModelId,
}) {
  final isAvailable = models.any(
    (model) =>
        model.capabilities?['openrouter'] == true &&
        model.capabilities?['image_generation'] == true,
  );
  if (!isAvailable) return null;

  return NativeSheetItemConfig(
    id: 'default-image-generation-model',
    title: l10n.defaultImageGenerationModel,
    subtitle: selectedModelId ?? l10n.openRouterDefaultImageGenerationModel,
    sfSymbol: 'photo.on.rectangle',
  );
}

NativeSheetDetailConfig buildNativeOpenRouterImageGenerationModelDetail(
  AppLocalizations l10n, {
  required String value,
}) {
  return NativeSheetDetailConfig(
    id: 'default-image-generation-model',
    title: l10n.defaultImageGenerationModel,
    subtitle: l10n.defaultImageGenerationModelDescription,
    items: [
      NativeSheetItemConfig(
        id: 'default-image-generation-model',
        title: l10n.defaultImageGenerationModel,
        subtitle: l10n.defaultImageGenerationModelDescription,
        sfSymbol: 'photo.on.rectangle',
        kind: NativeSheetItemKind.textField,
        value: value,
        placeholder: 'openai/gpt-5-image',
      ),
    ],
  );
}

NativeSheetDetailConfig buildNativeSystemPromptDetail(
  AppLocalizations l10n, {
  required String value,
  String? subtitle,
}) {
  return NativeSheetDetailConfig(
    id: 'system-prompt',
    title: l10n.yourSystemPrompt,
    subtitle: subtitle ?? l10n.yourSystemPromptDescription,
    items: [
      NativeSheetItemConfig(
        id: 'system-prompt',
        title: l10n.yourSystemPrompt,
        subtitle: l10n.enterSystemPrompt,
        sfSymbol: 'text.bubble',
        kind: NativeSheetItemKind.multilineTextField,
        value: value,
        placeholder: l10n.enterSystemPrompt,
      ),
    ],
  );
}

/// Control id the native Webhook destinations row sends to open the Flutter
/// Notifications page, where the destinations are managed.
const nativeNotificationTargetsActionId = 'notification-targets';

/// The Webhook destinations row of the native Notifications sheet. The native
/// sheet has no editor for them, so the row closes it and opens the Flutter
/// page, which holds the list and editor. [count] is how many the account
/// has; with none read yet the row shows no count.
NativeSheetItemConfig buildNativeNotificationTargetsItem(
  AppLocalizations l10n, {
  int? count,
}) {
  return NativeSheetItemConfig(
    id: 'notification-targets',
    title: l10n.notificationTargetsTitle,
    subtitle: count == null ? null : l10n.nativeWebhookDestinationsCount(count),
    sfSymbol: 'bell.and.waves.left.and.right',
    dismissOnSelect: true,
    actionId: nativeNotificationTargetsActionId,
  );
}

/// The Webhook destinations group of the native Notifications sheet, with the
/// explanation of what they are as its footer.
NativeSheetSectionConfig buildNativeNotificationTargetsSection(
  AppLocalizations l10n, {
  int? count,
}) {
  return NativeSheetSectionConfig(
    footer: l10n.notificationTargetsDescription,
    items: [buildNativeNotificationTargetsItem(l10n, count: count)],
  );
}

/// Control id the native Add memory row sends to open the Flutter editor.
const nativeMemoryEditorNewActionId = 'memory-editor-new';

/// Prefix of the control id a native memory row sends to open the Flutter
/// editor for one memory; the memory id follows, URI-encoded.
const nativeMemoryEditorActionPrefix = 'memory-editor:';

/// The Add memory row. The native sheet holds a content box and nothing else,
/// so with [advanced] the row closes it and opens the Flutter editor, which
/// also has the type and path.
NativeSheetItemConfig buildNativeMemoryAddItem(
  AppLocalizations l10n, {
  required bool advanced,
}) {
  return NativeSheetItemConfig(
    id: 'memory-add',
    title: l10n.addMemory,
    subtitle: l10n.manageMemoriesDescription,
    sfSymbol: 'plus.circle',
    dismissOnSelect: advanced,
    actionId: advanced ? nativeMemoryEditorNewActionId : null,
  );
}

NativeSheetDetailConfig buildNativeMemoryAddDetail(AppLocalizations l10n) {
  return NativeSheetDetailConfig(
    id: 'memory-add',
    title: l10n.addMemory,
    subtitle: l10n.memoryEditorDescription,
    items: [
      NativeSheetItemConfig(
        id: 'memory-add-content',
        title: l10n.addMemory,
        sfSymbol: 'plus.circle',
        kind: NativeSheetItemKind.multilineTextField,
        value: '',
        placeholder: l10n.memoryHint,
      ),
    ],
  );
}

/// What the Advanced row of a memory shows: its type and path.
String nativeSheetMemoryClassification(
  AppLocalizations l10n,
  ServerMemory memory,
) {
  final type = switch (memory.type) {
    ServerMemory.userType => l10n.memoryTypeUser,
    ServerMemory.contextType => l10n.memoryTypeContext,
    final other? => other,
    null => l10n.notSet,
  };
  final path = memory.path;
  return path == null || path.isEmpty ? type : '$type · $path';
}

/// The detail for each memory: its text and Delete, plus with [advanced] a row
/// that opens the Flutter editor for the type and path.
List<NativeSheetDetailConfig> buildNativeMemoryEditDetails(
  AppLocalizations l10n,
  List<ServerMemory> memories, {
  bool advanced = false,
}) {
  return [
    for (final memory in memories)
      NativeSheetDetailConfig(
        id: 'memory-edit:${Uri.encodeComponent(memory.id)}',
        title: l10n.editMemory,
        subtitle: l10n.memoryEditorDescription,
        items: [
          NativeSheetItemConfig(
            id: 'memory-save:${Uri.encodeComponent(memory.id)}',
            title: l10n.editMemory,
            sfSymbol: 'quote.bubble',
            kind: NativeSheetItemKind.multilineTextField,
            value: memory.content,
            placeholder: l10n.memoryHint,
          ),
          if (advanced)
            NativeSheetItemConfig(
              id: 'memory-classification:${Uri.encodeComponent(memory.id)}',
              title: l10n.memoryTypeLabel,
              subtitle: nativeSheetMemoryClassification(l10n, memory),
              sfSymbol: 'tag',
              dismissOnSelect: true,
              actionId:
                  '$nativeMemoryEditorActionPrefix${Uri.encodeComponent(memory.id)}',
            ),
          NativeSheetItemConfig(
            id: 'memory-delete:${Uri.encodeComponent(memory.id)}',
            title: l10n.deleteMemory,
            subtitle: l10n.deleteMemoryConfirm,
            sfSymbol: 'trash',
            destructive: true,
          ),
        ],
      ),
  ];
}

List<NativeSheetDetailConfig> buildNativeModelPromptLoadingDetails(
  AppLocalizations l10n,
  List<Model> models,
) {
  return [
    for (final model in models)
      NativeSheetDetailConfig(
        id: 'model-prompt:${Uri.encodeComponent(model.id)}',
        title: l10n.modelSystemPromptTitle(model.name),
        items: [
          buildNativeLoadingItem(
            l10n,
            id: 'model-prompt-loading:${Uri.encodeComponent(model.id)}',
          ),
        ],
      ),
  ];
}

String nativeLanguageLabel(AppLocalizations l10n, String code) {
  switch (code) {
    case 'system':
      return l10n.system;
    case 'en':
      return l10n.english;
    case 'cs':
      return l10n.czech;
    case 'sk':
      return l10n.slovak;
    case 'pl':
      return l10n.polish;
    case 'de':
      return l10n.deutsch;
    case 'fr':
      return l10n.francais;
    case 'it':
      return l10n.italiano;
    case 'es':
      return l10n.espanol;
    case 'nl':
      return l10n.nederlands;
    case 'ru':
      return l10n.russian;
    case 'zh':
      return l10n.chineseSimplified;
    case 'ko':
      return l10n.korean;
    case 'ja':
      return l10n.japanese;
    case 'zh-Hant':
      return l10n.chineseTraditional;
    default:
      final normalized = code.replaceAll('_', '-').toLowerCase();
      if (normalized == 'zh-hant') return l10n.chineseTraditional;
      if (normalized == 'zh') return l10n.chineseSimplified;
      if (normalized == 'ko') return l10n.korean;
      if (normalized == 'ja') return l10n.japanese;
      if (normalized == 'cs') return l10n.czech;
      if (normalized == 'sk') return l10n.slovak;
      if (normalized == 'pl') return l10n.polish;
      return l10n.system;
  }
}

List<NativeSheetOptionConfig> nativeLanguageDropdownOptions(
  AppLocalizations l10n,
) {
  return [
    NativeSheetOptionConfig(id: 'system', label: l10n.system),
    NativeSheetOptionConfig(id: 'en', label: l10n.english),
    NativeSheetOptionConfig(id: 'cs', label: l10n.czech),
    NativeSheetOptionConfig(id: 'sk', label: l10n.slovak),
    NativeSheetOptionConfig(id: 'pl', label: l10n.polish),
    NativeSheetOptionConfig(id: 'de', label: l10n.deutsch),
    NativeSheetOptionConfig(id: 'es', label: l10n.espanol),
    NativeSheetOptionConfig(id: 'fr', label: l10n.francais),
    NativeSheetOptionConfig(id: 'it', label: l10n.italiano),
    NativeSheetOptionConfig(id: 'nl', label: l10n.nederlands),
    NativeSheetOptionConfig(id: 'ru', label: l10n.russian),
    NativeSheetOptionConfig(id: 'zh', label: l10n.chineseSimplified),
    NativeSheetOptionConfig(id: 'zh-Hant', label: l10n.chineseTraditional),
    NativeSheetOptionConfig(id: 'ko', label: l10n.korean),
    NativeSheetOptionConfig(id: 'ja', label: l10n.japanese),
  ];
}

String nativeSocketHealthSummary(AppLocalizations l10n, SocketHealth? health) {
  if (health == null) return l10n.socketNotConnected;
  if (!health.isConnected) return l10n.socketDisconnected;
  final transport = _nativeSocketTransportLabel(l10n, health.transport);
  if (health.hasLatencyInfo) {
    return '$transport · ${health.latencyMs}ms';
  }
  return transport;
}

List<NativeSheetItemConfig> nativeSocketHealthItems(
  AppLocalizations l10n,
  SocketHealth? health,
) {
  if (health == null) {
    return [
      NativeSheetItemConfig(
        id: 'socket-health-null',
        title: l10n.socketNotConnected,
        sfSymbol: 'cloud',
        kind: NativeSheetItemKind.info,
      ),
    ];
  }
  final transportLabel = _nativeSocketTransportLabel(l10n, health.transport);
  final items = <NativeSheetItemConfig>[
    NativeSheetItemConfig(
      id: 'socket-connected',
      title: health.isConnected
          ? l10n.socketConnected
          : l10n.socketDisconnected,
      subtitle: transportLabel,
      sfSymbol: health.isConnected
          ? 'checkmark.circle.fill'
          : 'xmark.circle.fill',
      kind: NativeSheetItemKind.info,
    ),
  ];
  if (health.isConnected && health.hasLatencyInfo) {
    items.add(
      NativeSheetItemConfig(
        id: 'socket-latency',
        title: l10n.socketLatencyLabel,
        subtitle:
            '${health.latencyMs}ms · ${_nativeSocketQualityLabel(l10n, health.quality)}',
        sfSymbol: 'gauge.with.dots.needle.67percent',
        kind: NativeSheetItemKind.info,
      ),
    );
  }
  items.add(
    NativeSheetItemConfig(
      id: 'socket-reconnects',
      title: l10n.socketReconnectsLabel,
      subtitle: '${health.reconnectCount}',
      sfSymbol: 'arrow.clockwise',
      kind: NativeSheetItemKind.info,
    ),
  );
  if (health.lastHeartbeat != null) {
    items.add(
      NativeSheetItemConfig(
        id: 'socket-heartbeat',
        title: l10n.socketLastHeartbeat(
          _nativeFormatHeartbeatRelative(l10n, health.lastHeartbeat!),
        ),
        sfSymbol: 'heart',
        kind: NativeSheetItemKind.info,
      ),
    );
  }
  return items;
}

String _nativeSocketTransportLabel(AppLocalizations l10n, String transport) {
  switch (transport) {
    case 'websocket':
      return l10n.socketTransportWebSocket;
    case 'polling':
      return l10n.socketTransportPolling;
    default:
      return l10n.socketTransportUnknown;
  }
}

String _nativeSocketQualityLabel(AppLocalizations l10n, String quality) {
  switch (quality) {
    case 'excellent':
      return l10n.socketQualityExcellent;
    case 'good':
      return l10n.socketQualityGood;
    case 'fair':
      return l10n.socketQualityFair;
    case 'poor':
      return l10n.socketQualityPoor;
    default:
      return '—';
  }
}

String _nativeFormatHeartbeatRelative(
  AppLocalizations l10n,
  DateTime lastHeartbeat,
) => LocaleDisplayFormatters.relativeTime(
  l10n,
  lastHeartbeat,
  fallbackToDate: false,
);
