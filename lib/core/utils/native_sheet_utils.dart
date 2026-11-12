import 'package:flutter/foundation.dart'
    show TargetPlatform, Uint8List, defaultTargetPlatform, immutable;
import 'package:intl/intl.dart';
import 'package:conduit_core/features/release_notes/models/release_note.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/utils/locale_display_formatters.dart';

import 'package:conduit_core/features/chat/server_speech/direct_voice_provider_settings.dart';
import 'package:conduit_core/features/direct_connections/controllers/direct_connection_editor_draft.dart'
    show DirectConnectionEditorSource;
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_profile.dart';
import 'package:conduit_core/features/librechat/models/librechat_account.dart';
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
import 'package:conduit_core/features/push/models/push_status.dart';
import 'package:conduit_core/features/push/models/push_target.dart';
import 'package:conduit_core/ports/push_platform_port.dart' show PushTransport;
import '../../features/push/widgets/push_target_actions.dart'
    show
        kUnifiedPushDistributorsUrl,
        pushStatusText,
        pushTargetBusy,
        pushTargetNeedsAttention;
import '../../features/settings/pages/direct_connection_page_ids.dart';
import '../../features/settings/pages/hermes_page_ids.dart';
import 'account_display.dart';
import 'message_action_settings.dart';
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
  // What's New and the licenses are pages of Settings's own.
  NativeSheetItemConfig(
    id: NativeSheetRoutes.releaseNotesManual,
    title: l10n.releaseNotesTitle,
    sfSymbol: 'sparkles',
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
  ),
];

/// The SF Symbol for a release-note bullet's icon name, as the What's New
/// sheet draws it; Hermes draws its mark instead.
String _releaseNoteSymbol(String? name) => switch (name) {
  'local' => 'externaldrive',
  'direct' => 'bolt',
  'polish' => 'paintbrush',
  _ => 'sparkles',
};

/// What's New: each release in the app, newest first, its introduction and
/// what it brought, then a way to rate the app and to support it.
NativeSheetDetailConfig buildNativeReleaseNotesDetail(
  AppLocalizations l10n, {
  required List<ReleaseNote> notes,
  required String reviewUrl,
  required String supportUrl,
}) => NativeSheetDetailConfig(
  id: NativeSheetRoutes.releaseNotesManual,
  title: l10n.releaseNotesTitle,
  sections: [
    for (final note in notes)
      NativeSheetSectionConfig(
        title: note.version,
        items: [
          NativeSheetItemConfig(
            id: 'release-note-intro:${note.version}',
            title: note.title,
            kind: NativeSheetItemKind.readOnlyText,
            value: note.intro,
          ),
          for (var index = 0; index < note.bullets.length; index++)
            NativeSheetItemConfig(
              id: 'release-note:${note.version}:$index',
              title: note.bullets[index],
              sfSymbol: _releaseNoteSymbol(note.iconNameForBullet(index)),
              iconAsset: note.iconNameForBullet(index) == 'hermes'
                  ? 'assets/icons/hermes_agent.png'
                  : null,
              kind: NativeSheetItemKind.info,
            ),
        ],
      ),
    NativeSheetSectionConfig(
      footer: l10n.releaseNotesSupportPromptMessage,
      items: [
        NativeSheetItemConfig(
          id: 'release-notes-review',
          title: l10n.releaseNotesReviewButton,
          sfSymbol: 'heart',
          url: reviewUrl,
        ),
        NativeSheetItemConfig(
          id: 'release-notes-support',
          title: l10n.buyMeACoffeeTitle,
          sfSymbol: 'gift',
          url: supportUrl,
        ),
      ],
    ),
  ],
);

/// Prefix of a page showing one package's licenses.
const nativeLicensePagePrefix = 'license:';

/// The packages the app ships, each opening its licenses.
NativeSheetDetailConfig buildNativeLicensesDetail(
  AppLocalizations l10n,
  Map<String, int> licenseCounts,
) {
  final packages = licenseCounts.keys.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return NativeSheetDetailConfig(
    id: NativeSheetRoutes.openSourceLicenses,
    title: l10n.openSourceLicenses,
    sections: [
      NativeSheetSectionConfig(
        items: [
          for (final package in packages)
            NativeSheetItemConfig(
              id: '$nativeLicensePagePrefix${Uri.encodeComponent(package)}',
              title: package,
              subtitle: '${licenseCounts[package]}',
              sfSymbol: 'doc.text',
            ),
        ],
      ),
    ],
  );
}

/// One package's licenses, each as selectable text.
NativeSheetDetailConfig buildNativeLicenseDetail(
  String package,
  List<String> licenses,
) => NativeSheetDetailConfig(
  id: '$nativeLicensePagePrefix${Uri.encodeComponent(package)}',
  title: package,
  items: [
    for (var index = 0; index < licenses.length; index++)
      NativeSheetItemConfig(
        id: 'license-text:$index',
        // The native sheet draws no row without a title; the caption names
        // the package, and which of its licenses this is.
        title: licenses.length == 1 ? package : '$package (${index + 1})',
        kind: NativeSheetItemKind.readOnlyText,
        value: licenses[index],
      ),
  ],
);

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
    this.showNotificationsWithoutAccount = false,
    this.showLibreChatPersonalization = false,
  });

  final bool showCalendar;
  final bool canManageWorkspace;
  final bool showScheduledTasks;
  final bool showPersonalConnections;
  final bool showChatDataControls;

  /// Whether Notifications is listed when there is no Open WebUI account
  /// (with one it always is): a Hermes connection is saved, or push is on.
  final bool showNotificationsWithoutAccount;

  /// LibreChat is in charge, with no Open WebUI account: its memories are
  /// on the Flutter Personalization page, as the Flutter Settings page has
  /// it.
  final bool showLibreChatPersonalization;

  @override
  bool operator ==(Object other) =>
      other is NativeProfileRootVisibility &&
      other.showCalendar == showCalendar &&
      other.canManageWorkspace == canManageWorkspace &&
      other.showScheduledTasks == showScheduledTasks &&
      other.showPersonalConnections == showPersonalConnections &&
      other.showChatDataControls == showChatDataControls &&
      other.showNotificationsWithoutAccount ==
          showNotificationsWithoutAccount &&
      other.showLibreChatPersonalization == showLibreChatPersonalization;

  @override
  int get hashCode => Object.hash(
    showCalendar,
    canManageWorkspace,
    showScheduledTasks,
    showPersonalConnections,
    showChatDataControls,
    showNotificationsWithoutAccount,
    showLibreChatPersonalization,
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
/// Settings page uses: the account card -- whom Settings is for -- with the
/// way to every account and connection under it, then the signed-in
/// account's own rows, the everyday settings, places, and an Advanced group
/// that only exists while it has a row.
///
/// With an Open WebUI account the card opens that account's profile, as the
/// Settings app's card opens its account, and an Accounts row under it
/// leads to every account and connection, so the two never read as two ways
/// to one page. Without one there is no profile, and the card itself leads
/// to the connections. Adding an account is the last row of that page, as
/// Mail's Accounts page ends on Add Account, not a second row here.
///
/// Pure, so the open sheet can be rebuilt with the same rows when a setting
/// it depends on (Advanced, the language) changes while it is up.
///
/// [appLanguageTag] is the language the app is set to, or `system`.
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
  required String appLanguageTag,
  int? otherAccountCount = 0,
}) {
  final hasAccount = account != null;
  final notificationsItem = NativeSheetItemConfig(
    id: NativeSheetRoutes.notificationSettings,
    title: l10n.notificationsTitle,
    sfSymbol: 'bell',
  );
  final cardItems = <NativeSheetItemConfig>[
    NativeSheetItemConfig(
      id: hasAccount ? NativeSheetRoutes.profile : nativeAccountsDetailId,
      title: card.title,
      subtitle: card.subtitle,
      sfSymbol: 'person.crop.circle',
      usesProfileAvatar: true,
    ),
    if (hasAccount)
      NativeSheetItemConfig(
        id: nativeAccountsDetailId,
        title: l10n.accountsTitle,
        sfSymbol: 'person.2',
      ),
  ];
  // What belongs to the Open WebUI account signed in; its profile is the
  // card above.
  //
  // Every root symbol is an outline at one weight, chosen to carry about the
  // same ink in the 29 pt column: a single bubble rather than the wider
  // pair, a head with its brain rather than the brain alone (as wide as the
  // column and busier than its neighbours) or sparkles (solid stars, the
  // one glyph that read as filled), and the bare voice waveform rather than
  // one in a ring, the only ringed glyph in its group. The native sheet
  // draws the antenna and the waveform a little larger, since their thin
  // strokes read light at the shared size (`NativeSheetSettingsStyle
  // .symbolPointSize(for:)`), and `calendar` as an outline, since the
  // system symbol's header is solid.
  final accountItems = <NativeSheetItemConfig>[
    if (hasAccount) ...[
      notificationsItem,
      NativeSheetItemConfig(
        id: NativeSheetRoutes.aiMemory,
        title: nativeAiMemoryTitle(l10n),
        sfSymbol: 'brain.head.profile',
      ),
      NativeSheetItemConfig(
        id: NativeSheetRoutes.dataConnection,
        title: nativeDataConnectionTitle(l10n),
        sfSymbol: 'antenna.radiowaves.left.and.right',
      ),
    ] else if (visibility.showLibreChatPersonalization)
      // LibreChat's memories, drawn with the head AI & Memory uses for Open
      // WebUI's, in the root's one outline family.
      NativeSheetItemConfig(
        id: nativeLibreChatPersonalizationActionId,
        title: l10n.personalization,
        sfSymbol: 'brain.head.profile',
      ),
  ];
  // Single-line settings rows, so each title and its symbol carry the
  // meaning without a descriptive subtitle. The language is the app's, not
  // a look, so it sits beside Appearance rather than inside it.
  final appItems = <NativeSheetItemConfig>[
    NativeSheetItemConfig(
      id: NativeSheetRoutes.appearance,
      title: nativeAppearanceTitle(l10n),
      sfSymbol: 'paintbrush',
    ),
    buildNativeAppLanguageItem(l10n, languageTag: appLanguageTag),
    NativeSheetItemConfig(
      id: NativeSheetRoutes.chats,
      title: nativeChatsTitle(l10n),
      sfSymbol: 'bubble.left',
    ),
    NativeSheetItemConfig(
      id: NativeSheetRoutes.voice,
      title: l10n.voice,
      sfSymbol: 'waveform',
    ),
    // Device-level notifications, as the Flutter Settings page lists them
    // without an account.
    if (!hasAccount && visibility.showNotificationsWithoutAccount)
      notificationsItem,
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
    // Pages of Settings's own: they open inside Settings.
    if (visibility.showScheduledTasks)
      NativeSheetItemConfig(
        id: NativeSheetRoutes.scheduledTasks,
        title: l10n.scheduledTasksTitle,
        sfSymbol: 'clock.arrow.circlepath',
      ),
    if (visibility.showPersonalConnections)
      NativeSheetItemConfig(
        id: NativeSheetRoutes.personalConnections,
        title: l10n.personalConnectionsTitle,
        sfSymbol: 'server.rack',
      ),
    if (visibility.showChatDataControls)
      // A page of Settings's own: it opens inside Settings.
      NativeSheetItemConfig(
        id: NativeSheetRoutes.chatDataControls,
        title: l10n.chatDataControlsTitle,
        sfSymbol: 'externaldrive',
      ),
  ];
  // Like the Settings app, no group has a heading: the rows name themselves,
  // and a footer explains a group where it needs explaining.
  return [
    NativeSheetSectionConfig(items: cardItems),
    if (accountItems.isNotEmpty) NativeSheetSectionConfig(items: accountItems),
    NativeSheetSectionConfig(items: appItems),
    if (placeItems.isNotEmpty) NativeSheetSectionConfig(items: placeItems),
    if (advancedItems.isNotEmpty)
      NativeSheetSectionConfig(
        footer: l10n.profileAdvancedFooter,
        items: advancedItems,
      ),
    // About and the ways to support the app share a group, so the list
    // ends on two groups rather than three thin ones.
    NativeSheetSectionConfig(
      footer: l10n.supportConduitFooter,
      items: [
        NativeSheetItemConfig(
          id: NativeSheetRoutes.helpAbout,
          title: l10n.aboutApp,
          sfSymbol: 'info.circle',
        ),
        ...buildNativeSupportItems(l10n),
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
  ];
}

/// Id of the native Accounts page, pushed from the account card.
const nativeAccountsDetailId = 'accounts';

/// The root row that opens the LibreChat account's memories while LibreChat
/// is in charge.
const nativeLibreChatPersonalizationActionId = 'librechat-personalization';

/// The native Accounts page: a card for each Open WebUI server -- its own
/// row opening its page, its accounts under it, the active one checked --
/// then Hermes with its connections, the one in use checked, and Direct
/// with its providers, each opening its editor. A card's empty list offers
/// to add its first; Add Account, the page's last row as on Mail's Accounts
/// page, adds any.
///
/// [accounts] and [directProfiles] are null when they could not be read in
/// time; [hermesInUseId] is null while Hermes is off. An account or
/// connection whose push scope is in [pushAttention] says its push setup
/// needs the user.
NativeSheetDetailConfig buildNativeAccountsDetail(
  AppLocalizations l10n, {
  required List<OpenWebUiAccountEntry>? accounts,
  required List<HermesConnectionProfile> hermesConnections,
  required String? hermesInUseId,
  required List<DirectConnectionProfile>? directProfiles,
  bool appleOnDevice = false,
  bool applePcc = false,
  bool libreChatEnabled = false,
  List<LibreChatAccount> libreChatAccounts = const [],
  String? libreChatInChargeId,
  bool libreChatInChargeSignedIn = true,
  Set<String> pushAttention = const {},
}) {
  String? withAttention(String scope, String? subtitle) =>
      nativePushAttentionSubtitle(l10n, pushAttention, scope, subtitle);
  final byServer = <String, List<OpenWebUiAccountEntry>>{};
  for (final entry in accounts ?? const <OpenWebUiAccountEntry>[]) {
    byServer.putIfAbsent(entry.server.id, () => []).add(entry);
  }
  final saved = directProfiles ?? const <DirectConnectionProfile>[];
  return NativeSheetDetailConfig(
    id: nativeAccountsDetailId,
    title: l10n.accountsTitle,
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
              // Opens the server's page: its accounts and addresses.
              NativeSheetItemConfig(
                id:
                    '$nativeServerAddressesPagePrefix'
                    '${Uri.encodeComponent(group.first.server.id)}',
                title: serverDisplayName(group.first.server),
                // A server known only by its address gets a server symbol;
                // initials of "127.0.0.1" would read "12".
                sfSymbol: 'server.rack',
                avatarName: serverIsKnownOnlyByAddress(group.first.server)
                    ? null
                    : serverDisplayName(group.first.server),
              ),
              for (final entry in group)
                buildNativeAccountItem(
                  entry,
                  l10n,
                  subtitle: withAttention(
                    PushTarget.openWebUiScope(entry.id),
                    accountSubtitle(entry, l10n),
                  ),
                ),
            ],
          ),
      if (libreChatEnabled || libreChatAccounts.isNotEmpty)
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: 'accounts-librechat',
              title: l10n.libreChatTitle,
              subtitle: l10n.libreChatBetaLabel,
              sfSymbol: 'bubble.left.and.bubble.right',
              kind: NativeSheetItemKind.info,
            ),
            for (final account in libreChatAccounts)
              _nativeSwitchItem(
                id: '$nativeLibreChatUseActionId:${account.id}',
                title: account.displayName,
                subtitle: [
                  if (account.id == libreChatInChargeId &&
                      !libreChatInChargeSignedIn)
                    l10n.accountsSignedOut,
                  account.serverTitle ?? account.host,
                ].join(' · '),
                avatarName: account.displayName,
                checked: account.id == libreChatInChargeId,
                // The account in charge, signed out, is switched to again,
                // which opens its sign-in.
                inUse:
                    account.id == libreChatInChargeId &&
                    libreChatInChargeSignedIn,
                actionId: nativeLibreChatUseActionId,
                actionValue: account.id,
              ),
            _nativeAddItem(
              'accounts-librechat-add',
              title: l10n.libreChatAddAccount,
              kind: 'libreChat',
            ),
            // Signs out of the account in charge, after asking; the next
            // LibreChat account, else Open WebUI, takes over.
            if (libreChatAccounts.any(
              (account) => account.id == libreChatInChargeId,
            ))
              NativeSheetItemConfig(
                id: nativeLibreChatSignOutActionId,
                title: l10n.signOut,
                sfSymbol: 'rectangle.portrait.and.arrow.right',
                destructive: true,
                dismissOnSelect: true,
                showsDisclosure: false,
                actionId: nativeLibreChatSignOutActionId,
                actionValue: libreChatInChargeId,
              ),
          ],
        ),
      NativeSheetSectionConfig(
        items: [
          // Hermes Agent's own page of Settings.
          NativeSheetItemConfig(
            id: hermesSettingsPageId,
            title: l10n.hermesAgentSettingsTitle,
            sfSymbol: 'sparkles',
            iconAsset: 'assets/icons/hermes_agent.png',
            iconSize: 26,
          ),
          for (final connection in hermesConnections)
            _nativeSwitchItem(
              id: '$nativeHermesUseActionId:${connection.id}',
              title: connection.name,
              subtitle: withAttention(
                PushTarget.hermesScope(connection.id),
                hermesConnectionSummary(connection, l10n),
              ),
              sfSymbol: connection.mode == HermesBackendMode.desktopGateway
                  ? 'desktopcomputer'
                  : 'cloud',
              inUse: connection.id == hermesInUseId,
              actionId: nativeHermesUseActionId,
              actionValue: connection.id,
            ),
          // A connection is a form of Settings's own, not a sign-in.
          if (hermesConnections.isEmpty)
            NativeSheetItemConfig(
              id: hermesConnectConnectionPageId,
              title: l10n.hermesAddConnection,
              sfSymbol: 'plus.circle',
              accent: true,
            ),
        ],
      ),
      // Direct's own page, then each of its accounts, opening its page in
      // Settings: an Apple model's, or a provider's editor.
      NativeSheetSectionConfig(
        items: [
          NativeSheetItemConfig(
            id: directConnectionsPageId,
            title: l10n.directConnectionsTitle,
            sfSymbol: 'link.circle',
          ),
          if (appleOnDevice)
            NativeSheetItemConfig(
              id: directApplePageId(directAppleOnDevice),
              title: l10n.backendChooserAppleOnDeviceTitle,
              sfSymbol: 'iphone',
            ),
          if (applePcc)
            NativeSheetItemConfig(
              id: directApplePageId(directApplePcc),
              title: l10n.backendChooserApplePccTitle,
              sfSymbol: 'lock.shield',
            ),
          for (final profile in saved)
            NativeSheetItemConfig(
              id: directConnectionPageId(
                DirectConnectionEditorSource.local,
                profile.id,
              ),
              title: profile.name,
              subtitle: [
                directProviderName(profile, l10n),
                if (!profile.enabled) l10n.disabledLabel,
              ].join(' · '),
              sfSymbol: profile.adapterKey == kOllamaAdapterKey
                  ? 'desktopcomputer'
                  : 'cloud',
            ),
          // Not offered while the saved ones are unread: the Direct page
          // says why, and adds from there.
          if (directProfiles != null &&
              saved.isEmpty &&
              !appleOnDevice &&
              !applePcc)
            NativeSheetItemConfig(
              id: directConnectionPageId(
                DirectConnectionEditorSource.local,
                null,
              ),
              title: l10n.addDirectConnection,
              sfSymbol: 'plus.circle',
              accent: true,
            ),
        ],
      ),
      NativeSheetSectionConfig(
        items: [
          // Opens the kinds of account to add, as Mail's Add Account does.
          NativeSheetItemConfig(
            id: nativeAccountsAddItemId,
            title: l10n.accountsAddAccount,
            sfSymbol: 'plus.circle',
            accent: true,
            showsDisclosure: true,
          ),
        ],
      ),
      // With one account, Settings' Sign out (or LibreChat's) already signs
      // out of it. With several, one of them can be left, or every one.
      if ((accounts?.length ?? 0) + libreChatAccounts.length > 1)
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: nativeAccountSignOutOfDetailId,
              title: l10n.signOut,
              sfSymbol: 'rectangle.portrait.and.arrow.right',
              showsDisclosure: true,
            ),
            _nativeSignOutItem(l10n, title: l10n.accountsSignOutAll),
          ],
        ),
    ],
  );
}

/// The Hermes pages Accounts and Add Account open, each filled in as it
/// appears: Hermes Agent's own page, and the form adding a connection.
List<NativeSheetDetailConfig> buildHermesAccountsDetails(
  AppLocalizations l10n,
) => [
  buildNativeLoadingDetail(
    l10n: l10n,
    id: hermesSettingsPageId,
    title: l10n.hermesAgentSettingsTitle,
  ),
  buildNativeLoadingDetail(
    l10n: l10n,
    id: hermesConnectConnectionPageId,
    title: l10n.backendChooserHermesTitle,
  ),
];

/// Id of the Add Account row that ends the native Accounts page.
const nativeAccountsAddItemId = 'accounts-add';

/// The Add Account page: each kind of account or connection there is to
/// add. An account's sign-in closes the sheet and opens as a flow of its
/// own; a provider's editor opens in Settings, the sheet staying open.
NativeSheetDetailConfig buildNativeAddAccountDetail(
  AppLocalizations l10n, {
  required bool libreChatEnabled,
}) {
  NativeSheetItemConfig kind(
    String id,
    String title,
    String subtitle, {
    String sfSymbol = 'server.rack',
    String? iconAsset,
  }) => NativeSheetItemConfig(
    id: '$nativeAccountsAddItemId-$id',
    title: title,
    subtitle: subtitle,
    sfSymbol: sfSymbol,
    iconAsset: iconAsset,
    dismissOnSelect: true,
    actionId: nativeAccountAddActionId,
    actionValue: id,
  );
  return NativeSheetDetailConfig(
    id: nativeAccountsAddItemId,
    title: l10n.accountsAddAccount,
    sections: [
      NativeSheetSectionConfig(
        items: [
          kind(
            'openWebUi',
            l10n.backendChooserOpenWebUITitle,
            l10n.backendChooserOpenWebUISubtitle,
            iconAsset: 'assets/icons/open_webui.png',
          ),
          if (libreChatEnabled)
            kind(
              'libreChat',
              l10n.libreChatTitle,
              l10n.libreChatChooserSubtitle,
              sfSymbol: 'bubble.left.and.bubble.right',
            ),
          // A Hermes connection is a form of Settings's own, not a sign-in.
          NativeSheetItemConfig(
            id: hermesConnectConnectionPageId,
            title: l10n.backendChooserHermesTitle,
            subtitle: l10n.backendChooserHermesSubtitle,
            sfSymbol: 'server.rack',
            iconAsset: 'assets/icons/hermes_agent.png',
          ),
          // A provider is a form of Settings's own, not a sign-in.
          NativeSheetItemConfig(
            id: directConnectionAddAccountPageId,
            title: l10n.backendChooserDirectTitle,
            subtitle: l10n.backendChooserDirectSubtitle,
            sfSymbol: 'link.circle',
          ),
        ],
      ),
    ],
  );
}

/// Id of the page that lists each saved account to sign out of alone.
const nativeAccountSignOutOfDetailId = 'accounts-sign-out-of';

/// The page that signs out of one saved account, Open WebUI's or
/// LibreChat's, leaving the others signed in. Each row closes the native
/// sheet first: signing out asks before it acts.
NativeSheetDetailConfig buildNativeAccountSignOutDetail(
  AppLocalizations l10n, {
  required List<OpenWebUiAccountEntry>? accounts,
  List<LibreChatAccount> libreChatAccounts = const [],
}) {
  NativeSheetItemConfig row({
    required String id,
    required String name,
    required String? subtitle,
    required String actionId,
    required String actionValue,
  }) => NativeSheetItemConfig(
    id: id,
    title: l10n.accountsSignOutOf(name),
    subtitle: subtitle,
    sfSymbol: 'rectangle.portrait.and.arrow.right',
    destructive: true,
    dismissOnSelect: true,
    showsDisclosure: false,
    actionId: actionId,
    actionValue: actionValue,
  );
  return NativeSheetDetailConfig(
    id: nativeAccountSignOutOfDetailId,
    title: l10n.signOut,
    sections: [
      NativeSheetSectionConfig(
        items: [
          for (final entry in accounts ?? const <OpenWebUiAccountEntry>[])
            row(
              id: '$nativeAccountSignOutOfActionId:${entry.id}',
              name: accountDisplayName(entry, l10n),
              subtitle: serverDisplayName(entry.server),
              actionId: nativeAccountSignOutOfActionId,
              actionValue: entry.id,
            ),
          for (final account in libreChatAccounts)
            row(
              id: '$nativeLibreChatSignOutActionId:${account.id}',
              name: account.displayName,
              subtitle: account.serverTitle ?? account.host,
              actionId: nativeLibreChatSignOutActionId,
              actionValue: account.id,
            ),
        ],
      ),
    ],
  );
}

/// Prefix of the page of one saved Open WebUI server, its accounts and
/// addresses; the server's URI-encoded id follows.
const nativeServerAddressesPagePrefix = 'server-addresses:';

/// [subtitle] led by "Push needs attention" when [scope] is in
/// [pushAttention], as the Flutter account rows' chip said.
String? nativePushAttentionSubtitle(
  AppLocalizations l10n,
  Set<String> pushAttention,
  String scope,
  String? subtitle,
) => pushAttention.contains(scope)
    ? [l10n.pushAttentionChip, ?subtitle].join(' · ')
    : subtitle;

/// A saved Open WebUI account under its server: switched to on a tap, but
/// the one in use, signed in, stays put. [rowActions] are what else the row
/// can do.
NativeSheetItemConfig buildNativeAccountItem(
  OpenWebUiAccountEntry entry,
  AppLocalizations l10n, {
  String? subtitle,
  List<NativeSheetRowAction> rowActions = const [],
}) {
  final name = accountDisplayName(entry, l10n);
  return _nativeSwitchItem(
    rowActions: rowActions,
    id: '$nativeAccountSwitchActionId:${entry.id}',
    title: name,
    subtitle: subtitle ?? accountSubtitle(entry, l10n),
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
  List<NativeSheetRowAction> rowActions = const [],
}) => NativeSheetItemConfig(
  rowActions: rowActions,
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
/// connection -- on the account sheet's tab for [kind], when given. Its
/// label has the weight of every other row; the plus in a ring, an outline
/// with the ink of the symbols around it, says it adds.
NativeSheetItemConfig _nativeAddItem(
  String id, {
  required String title,
  required String? kind,
}) => NativeSheetItemConfig(
  id: id,
  title: title,
  sfSymbol: 'plus.circle',
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
const nativeSlidingSidebarId = 'sliding-sidebar';

/// Control id of the "Show citation page titles" toggle in the native Chats
/// page.
const nativeCitationShowTitlesId = 'citation-show-titles';

/// Control id of the citation background toggle in native Appearance settings.
const nativeCitationBackgroundId = 'citation-background';

/// Control id the accountless "Connect to Open WebUI" root row sends.
const nativeConnectOpenWebUiActionId = 'add-owui-server';

/// Control id of the root Sign out row.
const nativeSignOutActionId = 'sign-out';

/// Native Settings rows for accounts and connections. A row that acts on
/// one carries its id as its action value; an add row, the account sheet's
/// tab for its kind (`openWebUi`, `libreChat`), or true
/// for the first.
const nativeAccountSwitchActionId = 'account-switch';
const nativeAccountAddActionId = 'account-add';
const nativeAccountSignOutActionId = 'account-sign-out';

/// Signs out of the saved Open WebUI account it names, active or not.
const nativeAccountSignOutOfActionId = 'account-sign-out-of';
const nativeHermesUseActionId = 'account-hermes-use';
const nativeLibreChatUseActionId = 'account-librechat-use';
const nativeLibreChatSignOutActionId = 'account-librechat-sign-out';

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
/// About text, gender and birthday; with none loaded the rows show them as
/// not set.
///
/// The photo and every field share one group, each row saying what it holds
/// now, as a contact card does; the password is the account's, below.
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
          sfSymbol: 'camera',
          showsDisclosure: true,
        ),
        NativeSheetItemConfig(
          id: 'profile-name',
          title: l10n.name,
          subtitle: displayName,
          sfSymbol: 'person',
          showsDisclosure: true,
        ),
        NativeSheetItemConfig(
          id: 'profile-about',
          title: l10n.bioLabel,
          subtitle: hasBio ? bio : l10n.notSet,
          sfSymbol: 'text.quote',
          showsDisclosure: true,
        ),
        NativeSheetItemConfig(
          id: 'profile-details',
          title: l10n.profileDetails,
          subtitle:
              nativeProfileDetailsSummary(l10n, accountProfile) ??
              l10n.profileDetailsSummary,
          sfSymbol: 'calendar',
          showsDisclosure: true,
        ),
      ],
    ),
    // What the server says about the account: its role, and whether it is
    // active with the status its owner set.
    if (accountProfile != null)
      NativeSheetSectionConfig(
        items: [
          NativeSheetItemConfig(
            id: 'profile-role',
            title: l10n.roleLabel,
            subtitle: _capitalized(accountProfile.role),
            sfSymbol: 'person.crop.circle.badge.checkmark',
            kind: NativeSheetItemKind.info,
          ),
          NativeSheetItemConfig(
            id: 'profile-status',
            title: l10n.accountStatus,
            subtitle: nativeProfileStatusLabel(l10n, accountProfile),
            sfSymbol: 'circle.lefthalf.filled',
            kind: NativeSheetItemKind.info,
          ),
        ],
      ),
    NativeSheetSectionConfig(
      items: [
        NativeSheetItemConfig(
          id: 'password',
          title: l10n.changePasswordTitle,
          sfSymbol: 'lock',
        ),
      ],
    ),
  ];
}

/// Active or inactive, then the status the account's owner set, if any:
/// "Active • 🌴 On holiday".
String nativeProfileStatusLabel(
  AppLocalizations l10n,
  AccountMetadata profile,
) {
  final base = profile.isActive ? l10n.activeStatus : l10n.inactiveStatus;
  final parts = [
    if (profile.statusEmoji?.trim() case final emoji? when emoji.isNotEmpty)
      emoji,
    if (profile.statusMessage?.trim() case final message?
        when message.isNotEmpty)
      message,
  ];
  return parts.isEmpty ? base : '$base • ${parts.join(' ')}';
}

String _capitalized(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return trimmed;
  return '${trimmed[0].toUpperCase()}${trimmed.substring(1)}';
}

/// What the Profile details row holds now -- the gender and birthday set,
/// "Female · Feb 3, 2001" -- or null when neither is.
String? nativeProfileDetailsSummary(
  AppLocalizations l10n,
  AccountMetadata? profile,
) {
  final gender = profile?.gender?.trim() ?? '';
  final genderLabel = switch (gender) {
    '' => null,
    'male' => l10n.genderMale,
    'female' => l10n.genderFemale,
    _ => gender,
  };
  final birth = DateTime.tryParse(profile?.dateOfBirth?.trim() ?? '');
  final birthLabel = birth == null ? null : _formatBirthday(l10n, birth);
  final parts = [?genderLabel, ?birthLabel];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// [date] as the app's language writes a date, or the default locale's way
/// when that language's date data is not loaded.
String _formatBirthday(AppLocalizations l10n, DateTime date) {
  try {
    return DateFormat.yMMMd(l10n.localeName).format(date);
  } on Exception {
    return DateFormat.yMMMd().format(date);
  }
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

/// Which speech engines can work now: on this device, and on the server
/// or provider in use. An engine that cannot is still listed, greyed, and
/// a warning says so when it is the one chosen.
@immutable
class NativeVoiceEngineAvailability {
  const NativeVoiceEngineAvailability({
    this.deviceRecognition = true,
    this.serverRecognition = true,
    this.deviceSpeech = true,
    this.serverSpeech = true,
  });

  final bool deviceRecognition;
  final bool serverRecognition;
  final bool deviceSpeech;
  final bool serverSpeech;
}

class NativeAudioSheetParts {
  const NativeAudioSheetParts({
    required this.mainSections,
    required this.voicePickerDetail,
    required this.voiceProviderDetail,
  });

  final List<NativeSheetSectionConfig> mainSections;
  final NativeSheetDetailConfig voicePickerDetail;
  final NativeSheetDetailConfig voiceProviderDetail;
}

/// The Voice provider choice that clears it.
const nativeNoVoiceProviderId = 'none';

/// The Voice row that picks the language Android's own recognizer listens
/// for, which opens the device's language list.
const nativeDeviceSttLanguageId = 'stt-device-language';

/// The Chats row that picks what holding the assistant button opens on
/// Android, where Conduit can be the default assistant.
const nativeAndroidAssistantTriggerId = 'android-assistant-trigger';

/// The Notifications row that opens Android's notification settings for
/// Conduit, where its channels are switched on and off.
const nativeNotificationSystemSettingsId = 'notification-system-settings';

/// Whether Voice offers the device recognizer's language: only on Android,
/// and only while the device does the recognizing.
bool shouldShowDeviceSttLanguageSetting(
  TargetPlatform platform,
  SttPreference preference,
) =>
    platform == TargetPlatform.android &&
    preference == SttPreference.deviceOnly;

/// What the device recognizer listens for: automatic, the system's
/// language, or a locale.
String deviceSttLanguageSubtitle(AppLocalizations l10n, AppSettings settings) {
  final localeId = settings.voiceLocaleId;
  if (localeId == null) return l10n.sttTranscriptionLanguageAuto;
  if (localeId == SettingsService.voiceLocaleSystemDefault) {
    return l10n.ttsSystemDefault;
  }
  return localeId;
}

/// The text fields of the Voice provider page, by item id.
const nativeVoiceProviderFieldIds = {
  'voice-provider-transcription-model':
      DirectVoiceProviderField.transcriptionModel,
  'voice-provider-speech-model': DirectVoiceProviderField.speechModel,
  'voice-provider-speech-voice': DirectVoiceProviderField.speechVoice,
  'voice-provider-realtime-model': DirectVoiceProviderField.realtimeModel,
  'voice-provider-realtime-voice': DirectVoiceProviderField.realtimeVoice,
  'voice-provider-realtime-instructions':
      DirectVoiceProviderField.realtimeInstructions,
};

/// [voiceProviderCandidates] are the connections that can be the Voice
/// provider. [serverOffersVoiceChoice] hides the server voice picker for
/// backends that speak with their own voice.
NativeAudioSheetParts buildNativeAudioSheetParts(
  AppLocalizations l10n,
  AppSettings appSettings, {
  List<Map<String, dynamic>> ttsVoices = const <Map<String, dynamic>>[],
  List<DirectConnectionProfile> voiceProviderCandidates =
      const <DirectConnectionProfile>[],
  bool serverOffersVoiceChoice = true,
  NativeVoiceEngineAvailability availability =
      const NativeVoiceEngineAvailability(),
}) {
  final sttSegment = NativeSheetItemConfig(
    id: 'stt-engine',
    title: l10n.sttSettings,
    // Says what the chosen engine does, as Text to Speech's row does.
    subtitle: appSettings.sttPreference == SttPreference.serverOnly
        ? l10n.sttEngineServerDescription
        : l10n.sttEngineDeviceDescription,
    sfSymbol: 'mic',
    kind: NativeSheetItemKind.segment,
    value: appSettings.sttPreference.name,
    options: [
      NativeSheetOptionConfig(
        id: 'deviceOnly',
        label: l10n.sttEngineDevice,
        enabled: availability.deviceRecognition,
      ),
      NativeSheetOptionConfig(
        id: 'serverOnly',
        label: l10n.sttEngineServer,
        enabled: availability.serverRecognition,
      ),
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
      NativeSheetOptionConfig(
        id: 'device',
        label: l10n.ttsEngineDevice,
        enabled: availability.deviceSpeech,
      ),
      NativeSheetOptionConfig(
        id: 'server',
        label: l10n.ttsEngineServer,
        enabled: availability.serverSpeech,
      ),
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
    filterAllLabel: l10n.ttsAllLanguages,
    options: [
      NativeSheetOptionConfig(
        id: ttsSystemDefaultVoiceId,
        label: l10n.ttsSystemDefault,
        filterGroup: '',
      ),
      for (final option in voiceOptions)
        NativeSheetOptionConfig(
          id: option.id,
          label: option.label,
          subtitle: option.subtitle,
          sfSymbol: 'person.wave.2',
          filterGroup: ttsVoiceLanguageLabel(option.voice),
        ),
    ],
  );

  // One speed for cloud and device voices, the one read-aloud's menu sets.
  final speedSegment = NativeSheetItemConfig(
    id: 'tts-speed',
    title: l10n.ttsPlaybackSpeed,
    sfSymbol: 'gauge.with.dots.needle.67percent',
    kind: NativeSheetItemKind.segment,
    value: '${nearestTtsSpeed(appSettings.ttsSpeed)}',
    options: [
      for (final speed in ttsSpeedPresets)
        NativeSheetOptionConfig(id: '$speed', label: l10n.ttsSpeedValue(speed)),
    ],
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
    // Android's recognizer takes a locale of its own; iOS's follows the
    // system.
    if (shouldShowDeviceSttLanguageSetting(
      defaultTargetPlatform,
      appSettings.sttPreference,
    ))
      NativeSheetItemConfig(
        id: nativeDeviceSttLanguageId,
        title: l10n.sttDeviceLanguage,
        subtitle: deviceSttLanguageSubtitle(l10n, appSettings),
        sfSymbol: 'globe',
        showsDisclosure: true,
      ),
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
    if (appSettings.ttsEngine == TtsEngine.device || serverOffersVoiceChoice)
      voicePickerNav,
    speedSegment,
    previewNav,
  ];

  final voicePickerDetail = NativeSheetDetailConfig(
    id: 'tts-voice-picker',
    title: l10n.ttsSelectVoice,
    subtitle: l10n.ttsVoice,
    items: const [],
  );

  final voiceProvider = appSettings.directVoiceProvider;
  final chosenProvider = voiceProviderCandidates
      .where((profile) => profile.id == voiceProvider?.profileId)
      .firstOrNull;
  NativeSheetItemConfig providerField(
    String id,
    String title,
    String? value,
    String placeholder,
  ) => NativeSheetItemConfig(
    id: id,
    title: title,
    sfSymbol: 'textformat',
    kind: NativeSheetItemKind.textField,
    value: value ?? '',
    placeholder: placeholder,
  );

  final voiceProviderDetail = NativeSheetDetailConfig(
    id: NativeSheetRoutes.voiceProvider,
    title: l10n.voiceProviderTitle,
    discardPrompt: nativeDiscardPrompt(l10n),
    sections: [
      NativeSheetSectionConfig(
        footer: voiceProviderCandidates.isEmpty
            ? l10n.voiceProviderNoConnections
            : l10n.voiceProviderDescription,
        items: [
          NativeSheetItemConfig(
            id: 'voice-provider-connection',
            title: l10n.voiceProviderConnection,
            sfSymbol: 'link',
            kind: NativeSheetItemKind.dropdown,
            value: chosenProvider?.id ?? nativeNoVoiceProviderId,
            options: [
              NativeSheetOptionConfig(
                id: nativeNoVoiceProviderId,
                label: l10n.voiceProviderNone,
              ),
              for (final profile in voiceProviderCandidates)
                NativeSheetOptionConfig(
                  id: profile.id,
                  label: profile.name,
                  subtitle: profile.baseUrl,
                ),
            ],
          ),
        ],
      ),
      if (chosenProvider != null) ...[
        NativeSheetSectionConfig(
          title: l10n.sttSettings,
          items: [
            providerField(
              'voice-provider-transcription-model',
              l10n.voiceProviderTranscriptionModel,
              voiceProvider?.transcriptionModel,
              'whisper-1',
            ),
          ],
        ),
        NativeSheetSectionConfig(
          title: l10n.ttsSettings,
          footer: l10n.voiceProviderModelsHint,
          items: [
            providerField(
              'voice-provider-speech-model',
              l10n.voiceProviderSpeechModel,
              voiceProvider?.speechModel,
              'tts-1',
            ),
            providerField(
              'voice-provider-speech-voice',
              l10n.voice,
              voiceProvider?.speechVoice,
              'alloy',
            ),
          ],
        ),
        NativeSheetSectionConfig(
          title: l10n.voiceCallModeTitle,
          footer: l10n.voiceProviderRealtimeFooter,
          items: [
            providerField(
              'voice-provider-realtime-model',
              l10n.voiceProviderRealtimeModel,
              voiceProvider?.realtimeModel,
              'gpt-realtime-2.1-mini',
            ),
            providerField(
              'voice-provider-realtime-voice',
              l10n.voice,
              voiceProvider?.realtimeVoice,
              'marin',
            ),
            NativeSheetItemConfig(
              id: 'voice-provider-realtime-instructions',
              title: l10n.voiceProviderRealtimeInstructions,
              sfSymbol: 'text.alignleft',
              kind: NativeSheetItemKind.multilineTextField,
              value: voiceProvider?.realtimeInstructions ?? '',
              placeholder: l10n.voiceProviderRealtimeInstructionsHint,
            ),
          ],
        ),
      ],
    ],
  );

  return NativeAudioSheetParts(
    mainSections: [
      // The call mode's row shows its value on one line; what the mode does
      // is the group's footer, as Settings explains a choice.
      NativeSheetSectionConfig(
        footer: appSettings.voiceCallMode == VoiceCallMode.auto
            ? l10n.voiceCallModeRealtimeDescription
            : l10n.voiceCallModeStandardDescription,
        items: [
          NativeSheetItemConfig(
            id: 'voice-call-mode',
            title: l10n.voiceCallModeTitle,
            sfSymbol: 'phone.badge.waveform',
            kind: NativeSheetItemKind.segment,
            value: appSettings.voiceCallMode.name,
            options: [
              NativeSheetOptionConfig(
                id: VoiceCallMode.auto.name,
                label: l10n.voiceCallModeRealtime,
              ),
              NativeSheetOptionConfig(
                id: VoiceCallMode.standard.name,
                label: l10n.voiceCallModeStandard,
              ),
            ],
          ),
        ],
      ),
      // The chosen engine that cannot work says so under its group.
      NativeSheetSectionConfig(
        footer: switch (appSettings.sttPreference) {
          SttPreference.deviceOnly when !availability.deviceRecognition =>
            l10n.sttDeviceUnavailableWarning,
          SttPreference.serverOnly when !availability.serverRecognition =>
            l10n.sttServerUnavailableWarning,
          _ => null,
        },
        items: sttItems,
      ),
      NativeSheetSectionConfig(
        footer: switch (appSettings.ttsEngine) {
          TtsEngine.device when !availability.deviceSpeech =>
            l10n.ttsDeviceUnavailableWarning,
          TtsEngine.server when !availability.serverSpeech =>
            l10n.ttsServerUnavailableWarning,
          _ => null,
        },
        items: ttsItems,
      ),
      NativeSheetSectionConfig(
        footer: l10n.voiceProviderDescription,
        items: [
          NativeSheetItemConfig(
            id: NativeSheetRoutes.voiceProvider,
            title: l10n.voiceProviderTitle,
            subtitle: chosenProvider?.name ?? l10n.voiceProviderNone,
            sfSymbol: 'waveform',
          ),
        ],
      ),
    ],
    voicePickerDetail: voicePickerDetail,
    voiceProviderDetail: voiceProviderDetail,
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

/// Change Password's Done: the one control that sends the change.
const nativePasswordSaveActionId = 'password-save';

/// The Change Password page: three fields and Done, or, once [changed],
/// a note that the password was changed and nothing more to do there.
NativeSheetDetailConfig buildNativePasswordDetail(
  AppLocalizations l10n, {
  required bool passwordChangeEnabled,
  bool changed = false,
  String? subtitle,
}) {
  final form = passwordChangeEnabled && !changed;
  final items = changed && passwordChangeEnabled
      ? [
          NativeSheetItemConfig(
            id: 'password-changed',
            title: l10n.passwordUpdated,
            sfSymbol: 'checkmark.circle',
            kind: NativeSheetItemKind.info,
          ),
        ]
      : passwordChangeEnabled
      ? [
          NativeSheetItemConfig(
            id: 'current-password',
            title: l10n.currentPassword,
            subtitle: l10n.passwordHint,
            sfSymbol: 'lock',
            kind: NativeSheetItemKind.secureTextField,
            placeholder: l10n.currentPassword,
            passwordRole: NativeSheetPasswordRole.current,
          ),
          NativeSheetItemConfig(
            id: 'new-password',
            title: l10n.newPassword,
            subtitle: l10n.passwordHint,
            sfSymbol: 'key',
            kind: NativeSheetItemKind.secureTextField,
            placeholder: l10n.newPassword,
            passwordRole: NativeSheetPasswordRole.newPassword,
          ),
          NativeSheetItemConfig(
            id: 'confirm-password',
            title: l10n.confirmNewPassword,
            subtitle: l10n.passwordHint,
            sfSymbol: 'checkmark.shield',
            kind: NativeSheetItemKind.secureTextField,
            placeholder: l10n.confirmNewPassword,
            passwordRole: NativeSheetPasswordRole.newPassword,
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
    // Leaving with anything typed asks first; Back never sends it.
    discardPrompt: form ? nativeDiscardPrompt(l10n) : null,
    subtitle: form ? subtitle : null,
    // Typing fills a draft; only Done sends it.
    confirmActionId: form ? nativePasswordSaveActionId : null,
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
    discardPrompt: nativeDiscardPrompt(l10n),
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
    discardPrompt: nativeDiscardPrompt(l10n),
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

/// The question a Settings form asks before its unsaved changes are dropped.
NativeSheetDiscardPrompt nativeDiscardPrompt(AppLocalizations l10n) =>
    NativeSheetDiscardPrompt(
      title: l10n.workspaceEditorDiscardTitle,
      message: l10n.workspaceEditorDiscardMessage,
      discardLabel: l10n.workspaceEditorDiscardConfirm,
      keepLabel: l10n.workspaceEditorKeepEditing,
    );

/// Control id the native Webhook destinations row sends to open the Flutter
/// Notifications page, where the destinations are managed.
const nativeNotificationTargetsActionId = 'notification-targets';

/// The Webhook destinations row of the Notifications page, which opens their
/// list. [count] is how many the account has; with none read yet the row
/// shows no count.
NativeSheetItemConfig buildNativeNotificationTargetsItem(
  AppLocalizations l10n, {
  int? count,
}) {
  return NativeSheetItemConfig(
    id: nativeNotificationTargetsActionId,
    title: l10n.notificationTargetsTitle,
    subtitle: count == null ? null : l10n.nativeWebhookDestinationsCount(count),
    sfSymbol: 'bell.and.waves.left.and.right',
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

/// Control id of the native push switch.
const nativePushEnabledId = 'push-enabled';

/// Control id a native push target row sends, with the target's scope as its
/// value, to open that target's Flutter detail sheet.
const nativePushTargetActionId = 'push-target';

/// Control id the native "How push stays private" row sends.
const nativePushPrivacyActionId = 'push-privacy';

/// Control id of the push row shown while notifications are blocked: it
/// opens the system settings where they are allowed.
const nativePushPermissionId = 'push-permission-denied';

/// Control id prefix of an Android delivery row: `push-delivery:auto`,
/// `push-delivery:fcm` or `push-delivery:unifiedPush`.
const nativePushDeliveryPrefix = 'push-delivery:';

/// Control id prefix of a UnifiedPush distributor row, with its name.
const nativePushDistributorPrefix = 'push-distributor:';

/// Control id of Reset Encryption Keys, under Advanced.
const nativePushResetKeysId = 'push-reset-keys';

/// Reads the UnifiedPush distributors again after a read that failed.
const nativePushDistributorsRetryId = 'push-distributors-retry';

/// The push groups of the Notifications page, on iOS and Android alike: the
/// switch, and while push is on, a row into the per-target list and the
/// privacy explainer. Android without a relay points at UnifiedPush; with
/// notifications blocked a row opens the system settings. With Advanced on,
/// Android chooses its delivery service and distributor, and either
/// platform may reset its keys. [push] is null where push was never turned
/// on; [distributors] is null until read.
List<NativeSheetSectionConfig> buildNativePushSections(
  AppLocalizations l10n,
  PushState? push, {
  bool android = false,
  bool advanced = false,
  List<String>? distributors,
  bool distributorsFailed = false,
}) {
  final available = push?.available ?? true;
  final enabled = push?.enabled ?? false;
  // On while push can no longer work here, the switch still turns it off.
  final switchable = available || enabled;
  final attention = [
    for (final target in push?.targets.values ?? const <PushTargetState>[])
      if (pushTargetNeedsAttention(target)) target,
  ];
  NativeSheetItemConfig getDistributor(String id) => NativeSheetItemConfig(
    id: id,
    title: l10n.pushGetDistributor,
    sfSymbol: 'link',
    url: kUnifiedPushDistributorsUrl,
    showsDisclosure: false,
  );
  final sections = <NativeSheetSectionConfig>[
    NativeSheetSectionConfig(
      title: l10n.pushSectionTitle,
      items: [
        NativeSheetItemConfig(
          id: nativePushEnabledId,
          title: l10n.pushEnabledTitle,
          subtitle: available
              ? l10n.pushEnabledDescription
              : android
              ? l10n.pushUnavailableAndroid
              : l10n.pushUnavailableBuild,
          sfSymbol: 'bell.badge',
          kind: switchable
              ? NativeSheetItemKind.toggle
              : NativeSheetItemKind.info,
          value: enabled,
        ),
        if (!available && android) getDistributor('push-get-distributor'),
        if (enabled && (push?.permissionDenied ?? false))
          NativeSheetItemConfig(
            id: nativePushPermissionId,
            title: l10n.pushStatusPermissionDenied,
            subtitle: l10n.pushExplainPermissionDenied,
            sfSymbol: 'bell.slash',
            showsDisclosure: true,
          ),
        if (enabled && push != null)
          NativeSheetItemConfig(
            id: NativeSheetRoutes.pushTargets,
            // Each account and connection, with its push status.
            title: l10n.accountsTitle,
            subtitle: attention.isEmpty ? null : l10n.pushAttentionChip,
            sfSymbol: attention.isEmpty
                ? 'checkmark.circle'
                : 'exclamationmark.triangle',
          ),
        NativeSheetItemConfig(
          id: nativePushPrivacyActionId,
          title: l10n.pushPrivacyTitle,
          sfSymbol: 'lock.shield',
          dismissOnSelect: true,
          actionId: nativePushPrivacyActionId,
        ),
      ],
    ),
  ];
  if (!advanced || !enabled || push == null) return sections;
  if (android) {
    final fcm =
        push.relayConfigured &&
        push.availableTransports.contains(PushTransport.fcm);
    final choice = push.androidTransport;
    final selectedDistributor = push.distributor ?? distributors?.firstOrNull;
    NativeSheetItemConfig option(String name, String title, bool chosen) =>
        NativeSheetItemConfig(
          id: '$nativePushDeliveryPrefix$name',
          title: title,
          checked: chosen,
          kind: chosen
              ? NativeSheetItemKind.info
              : NativeSheetItemKind.navigation,
          showsDisclosure: false,
        );
    sections.add(
      NativeSheetSectionConfig(
        title: l10n.pushDeliveryTitle,
        items: [
          option('auto', l10n.pushDeliveryAutomatic, choice == null),
          if (fcm)
            option(
              PushAndroidTransport.fcm.name,
              l10n.pushDeliveryFcm,
              choice == PushAndroidTransport.fcm,
            ),
          option(
            PushAndroidTransport.unifiedPush.name,
            l10n.pushDeliveryUnifiedPush,
            choice == PushAndroidTransport.unifiedPush,
          ),
        ],
      ),
    );
    if (choice == PushAndroidTransport.unifiedPush ||
        (choice == null && !fcm)) {
      sections.add(
        NativeSheetSectionConfig(
          title: l10n.pushDistributorTitle,
          items: [
            if (distributors == null && distributorsFailed) ...[
              // Not read, with none read before: said, with another try.
              NativeSheetItemConfig(
                id: 'push-distributors-failed',
                title: l10n.errorMessage,
                sfSymbol: 'exclamationmark.triangle',
                kind: NativeSheetItemKind.info,
              ),
              NativeSheetItemConfig(
                id: nativePushDistributorsRetryId,
                title: l10n.retry,
                sfSymbol: 'arrow.clockwise',
                accent: true,
                showsDisclosure: false,
              ),
            ] else if (distributors == null)
              buildNativeLoadingItem(l10n, id: 'push-distributors-loading')
            else if (distributors.isEmpty) ...[
              NativeSheetItemConfig(
                id: 'push-no-distributor',
                title: l10n.pushNoDistributor,
                kind: NativeSheetItemKind.info,
              ),
              getDistributor('push-distributor-get'),
            ] else
              for (final distributor in distributors)
                NativeSheetItemConfig(
                  id: '$nativePushDistributorPrefix$distributor',
                  title: distributor,
                  checked: distributor == selectedDistributor,
                  kind: distributor == selectedDistributor
                      ? NativeSheetItemKind.info
                      : NativeSheetItemKind.navigation,
                  showsDisclosure: false,
                ),
          ],
        ),
      );
    }
  }
  sections.add(
    NativeSheetSectionConfig(
      items: [
        NativeSheetItemConfig(
          id: nativePushResetKeysId,
          title: l10n.pushResetKeys,
          subtitle: l10n.pushResetKeysDescription,
          sfSymbol: 'key',
          destructive: true,
          showsDisclosure: false,
          confirmMessage: l10n.pushResetKeysConfirmMessage,
        ),
      ],
    ),
  );
  return sections;
}

/// The native list of push targets: each row says its status and opens the
/// target's Flutter detail sheet, which has the one-tap fixes.
NativeSheetDetailConfig buildNativePushTargetsDetail(
  AppLocalizations l10n,
  PushState push, {
  required String Function(PushTarget target) titleOf,
}) {
  NativeSheetItemConfig row(PushTargetState target) => NativeSheetItemConfig(
    id: '$nativePushTargetActionId:${target.scope}',
    title: titleOf(target.target),
    subtitle: pushStatusText(l10n, target),
    sfSymbol: pushTargetBusy(target)
        ? 'hourglass'
        : pushTargetNeedsAttention(target)
        ? 'exclamationmark.triangle'
        : target.status == PushStatus.on
        ? 'checkmark.circle'
        : 'bell.slash',
    dismissOnSelect: true,
    actionId: nativePushTargetActionId,
    actionValue: target.scope,
  );

  return NativeSheetDetailConfig(
    id: NativeSheetRoutes.pushTargets,
    title: l10n.accountsTitle,
    sections: [
      if (push.enabled && push.permissionDenied)
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: 'push-permission-denied',
              title: l10n.pushStatusPermissionDenied,
              subtitle: l10n.pushExplainPermissionDenied,
              sfSymbol: 'bell.slash',
              kind: NativeSheetItemKind.info,
            ),
          ],
        ),
      NativeSheetSectionConfig(
        items: [for (final target in push.targets.values) row(target)],
      ),
    ],
  );
}

/// Ids of the Add memory page with Advanced on: its fields, which wait for
/// Done, and Done itself, which adds the memory with all three.
const nativeMemoryNewContentId = 'memory-new-content';
const nativeMemoryNewTypeId = 'memory-new-type';
const nativeMemoryNewPathId = 'memory-new-path';
const nativeMemoryNewSaveId = 'memory-new-save';

/// Prefixes of the Advanced rows of one memory's page, which save its type
/// and path as they change; the memory id follows, URI-encoded.
const nativeMemoryTypePrefix = 'memory-type:';
const nativeMemoryPathPrefix = 'memory-path:';

/// The Add memory row. It opens the Add memory page.
NativeSheetItemConfig buildNativeMemoryAddItem(AppLocalizations l10n) {
  return NativeSheetItemConfig(
    id: 'memory-add',
    title: l10n.addMemory,
    subtitle: l10n.manageMemoriesDescription,
    sfSymbol: 'plus.circle',
  );
}

/// The Type choice of a memory: User or Context. A type this app does not
/// know is kept, and listed, until another is chosen.
NativeSheetItemConfig _nativeMemoryTypeItem(
  AppLocalizations l10n, {
  required String id,
  required String? type,
}) {
  final known =
      type == ServerMemory.userType || type == ServerMemory.contextType;
  return NativeSheetItemConfig(
    id: id,
    title: l10n.memoryTypeLabel,
    subtitle: switch (type) {
      ServerMemory.contextType =>
        l10n.personalizationMemoryTypeContextDescription,
      _ when !known && type != null => l10n.personalizationMemoryTypeUnknown,
      _ => l10n.personalizationMemoryTypeUserDescription,
    },
    sfSymbol: 'tag',
    kind: NativeSheetItemKind.segment,
    value: type ?? ServerMemory.userType,
    options: [
      NativeSheetOptionConfig(
        id: ServerMemory.userType,
        label: l10n.memoryTypeUser,
      ),
      NativeSheetOptionConfig(
        id: ServerMemory.contextType,
        label: l10n.memoryTypeContext,
      ),
      if (!known && type != null)
        NativeSheetOptionConfig(id: type, label: type, enabled: false),
    ],
  );
}

NativeSheetItemConfig _nativeMemoryPathItem(
  AppLocalizations l10n, {
  required String id,
  required String? path,
}) => NativeSheetItemConfig(
  id: id,
  title: l10n.memoryPathLabel,
  sfSymbol: 'text.alignleft',
  kind: NativeSheetItemKind.textField,
  value: path ?? '',
  placeholder: l10n.memoryPathHint,
);

/// Why a memory page's action did not run, shown at the top of the page.
NativeSheetItemConfig _nativeMemoryNotice(String pageId, String notice) =>
    NativeSheetItemConfig(
      id: '$pageId-notice',
      title: notice,
      sfSymbol: 'exclamationmark.triangle',
      kind: NativeSheetItemKind.info,
    );

/// The row of the Add memory page that sends its text again after adding it
/// failed.
const nativeMemoryAddRetryId = 'memory-add-retry';

/// Prefix of the row of a memory's page that saves its text again after a
/// save failed; the memory's URI-encoded id follows.
const nativeMemorySaveRetryPrefix = 'memory-save-retry:';

/// Sends again the text its page last failed to send. The row holds no
/// text of its own: the Settings controller keeps the attempt, so a Retry
/// never sends text older than what was typed since.
NativeSheetItemConfig _nativeMemoryRetry(AppLocalizations l10n, String id) =>
    NativeSheetItemConfig(
      id: id,
      title: l10n.retry,
      sfSymbol: 'arrow.clockwise',
      accent: true,
    );

/// The Add memory page. The text alone is added as soon as it is done;
/// with [advanced] the page also has the type and path, and Done adds the
/// memory with all three. [content], [type] and [path] are what the page
/// holds, and [notice] why adding it did not go through; with [canRetry],
/// the text alone has a row that sends it again.
NativeSheetDetailConfig buildNativeMemoryAddDetail(
  AppLocalizations l10n, {
  bool advanced = false,
  String content = '',
  String type = ServerMemory.userType,
  String? path,
  String? notice,
  bool canRetry = false,
}) {
  const pageId = 'memory-add';
  if (!advanced) {
    return NativeSheetDetailConfig(
      id: pageId,
      title: l10n.addMemory,
      subtitle: l10n.memoryEditorDescription,
      discardPrompt: nativeDiscardPrompt(l10n),
      items: [
        if (notice != null) _nativeMemoryNotice(pageId, notice),
        if (notice != null && canRetry && content.trim().isNotEmpty)
          _nativeMemoryRetry(l10n, nativeMemoryAddRetryId),
        NativeSheetItemConfig(
          id: 'memory-add-content',
          title: l10n.addMemory,
          sfSymbol: 'plus.circle',
          kind: NativeSheetItemKind.multilineTextField,
          value: content,
          placeholder: l10n.memoryHint,
        ),
      ],
    );
  }
  return NativeSheetDetailConfig(
    id: pageId,
    title: l10n.addMemory,
    discardPrompt: nativeDiscardPrompt(l10n),
    confirmActionId: nativeMemoryNewSaveId,
    confirmActionLabel: l10n.save,
    sections: [
      if (notice != null)
        NativeSheetSectionConfig(items: [_nativeMemoryNotice(pageId, notice)]),
      NativeSheetSectionConfig(
        footer: l10n.memoryEditorDescription,
        items: [
          NativeSheetItemConfig(
            id: nativeMemoryNewContentId,
            title: l10n.addMemory,
            sfSymbol: 'quote.bubble',
            kind: NativeSheetItemKind.multilineTextField,
            value: content,
            placeholder: l10n.memoryHint,
          ),
        ],
      ),
      NativeSheetSectionConfig(
        items: [
          _nativeMemoryTypeItem(l10n, id: nativeMemoryNewTypeId, type: type),
          _nativeMemoryPathItem(l10n, id: nativeMemoryNewPathId, path: path),
        ],
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

/// The page of each memory: its text, with [advanced] its type and path,
/// each saved as it changes, then Delete.
List<NativeSheetDetailConfig> buildNativeMemoryEditDetails(
  AppLocalizations l10n,
  List<ServerMemory> memories, {
  bool advanced = false,
}) => [
  for (final memory in memories)
    buildNativeMemoryEditDetail(l10n, memory, advanced: advanced),
];

/// The page of [memory]. [content] is the text the page holds, when it is
/// not yet the memory's, and [notice] why a change to it did not go
/// through; with [canRetry], the text has a row that saves it again.
NativeSheetDetailConfig buildNativeMemoryEditDetail(
  AppLocalizations l10n,
  ServerMemory memory, {
  bool advanced = false,
  String? content,
  String? notice,
  bool canRetry = false,
}) {
  final encoded = Uri.encodeComponent(memory.id);
  final pageId = 'memory-edit:$encoded';
  return NativeSheetDetailConfig(
    id: pageId,
    title: l10n.editMemory,
    discardPrompt: nativeDiscardPrompt(l10n),
    sections: [
      if (notice != null)
        NativeSheetSectionConfig(
          items: [
            _nativeMemoryNotice(pageId, notice),
            if (canRetry && content != null)
              _nativeMemoryRetry(l10n, '$nativeMemorySaveRetryPrefix$encoded'),
          ],
        ),
      NativeSheetSectionConfig(
        footer: l10n.memoryEditorDescription,
        items: [
          NativeSheetItemConfig(
            id: 'memory-save:$encoded',
            title: l10n.editMemory,
            sfSymbol: 'quote.bubble',
            kind: NativeSheetItemKind.multilineTextField,
            value: content ?? memory.content,
            placeholder: l10n.memoryHint,
          ),
        ],
      ),
      if (advanced)
        NativeSheetSectionConfig(
          items: [
            _nativeMemoryTypeItem(
              l10n,
              id: '$nativeMemoryTypePrefix$encoded',
              type: memory.type,
            ),
            _nativeMemoryPathItem(
              l10n,
              id: '$nativeMemoryPathPrefix$encoded',
              path: memory.path,
            ),
          ],
        ),
      NativeSheetSectionConfig(
        items: [
          NativeSheetItemConfig(
            id: 'memory-delete:$encoded',
            title: l10n.deleteMemory,
            subtitle: l10n.deleteMemoryConfirm,
            sfSymbol: 'trash',
            destructive: true,
          ),
        ],
      ),
    ],
  );
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
        discardPrompt: nativeDiscardPrompt(l10n),
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

/// Id of the App Language picker row.
const nativeAppLanguageId = 'language';

/// The App Language row: the language the app is set to ([languageTag], or
/// `system`), picked from every language the app speaks.
NativeSheetItemConfig buildNativeAppLanguageItem(
  AppLocalizations l10n, {
  required String languageTag,
}) => NativeSheetItemConfig(
  id: nativeAppLanguageId,
  title: l10n.appLanguage,
  sfSymbol: 'globe',
  kind: NativeSheetItemKind.searchablePicker,
  value: languageTag,
  options: nativeLanguageDropdownOptions(l10n),
  // It opens the list of languages, so it says so wherever it sits.
  showsDisclosure: true,
);

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

/// Id of the Connection health page, which follows the connection live.
const nativeSocketHealthDetailId = 'socket-health';

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

NativeSheetDetailConfig buildNativeMessageActionsDetail(
  AppLocalizations l10n,
  AppSettings settings,
) {
  final saved = settings.inlineMessageActions;
  final selected = saved ?? const <String>[];
  final actions = messageActionSettings(l10n);
  NativeSheetItemConfig item(
    ({String id, String label, String symbol}) action,
    bool visible,
  ) => NativeSheetItemConfig(
    id: 'message-action:${action.id}',
    title: action.label,
    sfSymbol: action.symbol,
    kind: NativeSheetItemKind.toggle,
    value: visible,
  );
  final inline = [
    for (final id in selected)
      for (final action in actions)
        if (action.id == id) item(action, true),
  ];
  final overflow = [
    if (saved != null)
      for (final action in actions)
        if (!selected.contains(action.id)) item(action, false),
  ];
  return NativeSheetDetailConfig(
    id: 'message-actions',
    title: l10n.messageActionsTitle,
    sections: [
      NativeSheetSectionConfig(
        footer: saved == null ? l10n.messageActionsDescription : null,
        items: [
          NativeSheetItemConfig(
            id: 'message-actions-automatic',
            title: l10n.messageActionsAutomatic,
            kind: NativeSheetItemKind.toggle,
            value: saved == null,
          ),
        ],
      ),
      if (inline.isNotEmpty)
        NativeSheetSectionConfig(
          title: l10n.messageActionsInline,
          footer: l10n.messageActionsDescription,
          reorderActionId: 'message-actions-reorder',
          items: inline,
        ),
      if (overflow.isNotEmpty)
        NativeSheetSectionConfig(
          title: l10n.more,
          footer: inline.isEmpty ? l10n.messageActionsDescription : null,
          items: overflow,
        ),
      NativeSheetSectionConfig(
        items: [
          NativeSheetItemConfig(
            id: 'message-actions-reset',
            title: l10n.messageActionsReset,
            sfSymbol: 'arrow.counterclockwise',
          ),
        ],
      ),
    ],
  );
}
