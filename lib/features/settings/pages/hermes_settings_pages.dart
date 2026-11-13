import 'dart:async';

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/features/hermes/models/hermes_capabilities.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_profile.dart';
import 'package:conduit_core/features/hermes/models/hermes_session.dart';
import 'package:conduit_core/features/hermes/models/hermes_toolset.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_connection_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_connection_coordinator.dart';
import 'package:conduit_core/models/connection_attempt.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/providers/host_ports.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/native_sheet_bridge.dart';
import '../../../core/utils/current_localizations.dart';
import '../../../core/utils/native_sheet_utils.dart';
import '../../../shared/services/navigation_service.dart';
import '../../hermes/controllers/hermes_connection_controller.dart';
import '../../hermes/services/hermes_dashboard_sign_in.dart';
import '../../hermes/widgets/hermes_connection_switcher.dart'
    show hermesConnectionSummary;
import '../../hermes/widgets/hermes_session_tile.dart'
    show openHermesSessionReading;
import '../settings_page_module.dart';
import '../settings_pages.dart';
import 'hermes_page_ids.dart';

export 'hermes_page_ids.dart';

/// Hermes Agent's page of Settings: whether Hermes is on, the saved
/// connections (the one in use checked; another is switched to on a tap and
/// edited from its menu), then the scheduled agents and hidden chats of the
/// one in use.
@visibleForTesting
NativeSheetDetailConfig buildHermesSettingsPage(
  AppLocalizations l10n,
  HermesSettingsPageState state,
) {
  NativeSheetItemConfig connectionRow(HermesConnectionProfile connection) {
    final active = connection.id == state.activeId;
    final summary = hermesConnectionSummary(connection, l10n);
    final editor = hermesConnectionPageId(connection.id);
    return NativeSheetItemConfig(
      // The connection in use opens its editor; another is switched to.
      id: active ? editor : hermesSettingsRowId('use', connection.id),
      title: connection.name,
      subtitle: active ? '${l10n.hermesActiveConnection} · $summary' : summary,
      sfSymbol: connection.mode == HermesBackendMode.desktopGateway
          ? 'desktopcomputer'
          : 'cloud',
      checked: active,
      showsDisclosure: active ? null : false,
      disabled: state.switching != null,
      pending: state.switching == connection.id ? true : null,
      rowActions: [
        if (!active)
          NativeSheetRowAction(
            id: editor,
            label: l10n.edit,
            sfSymbol: 'pencil',
          ),
        NativeSheetRowAction(
          id: hermesSettingsRowId('delete', connection.id),
          label: l10n.delete,
          sfSymbol: 'trash',
          destructive: true,
          confirmMessage: l10n.hermesDeleteConnectionMessage(connection.name),
        ),
      ],
    );
  }

  return NativeSheetDetailConfig(
    id: hermesSettingsPageId,
    title: l10n.hermesAgentSettingsTitle,
    announcement: state.notice,
    sections: [
      if (state.secretsUnavailable)
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: '$hermesSettingsPageId-secrets',
              title: l10n.hermesSecretsUnavailable,
              sfSymbol: 'lock',
              kind: NativeSheetItemKind.info,
            ),
            NativeSheetItemConfig(
              id: hermesSettingsRowId('retry-secrets'),
              title: l10n.retry,
              sfSymbol: 'arrow.clockwise',
              accent: true,
              showsDisclosure: false,
              pending: state.secretsLoading ? true : null,
              disabled: state.secretsLoading,
            ),
          ],
        ),
      if (state.notice != null)
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: '$hermesSettingsPageId-notice',
              title: state.notice!,
              sfSymbol: 'exclamationmark.triangle',
              kind: NativeSheetItemKind.info,
            ),
          ],
        ),
      NativeSheetSectionConfig(
        footer: l10n.hermesEnableSubtitle,
        items: [
          NativeSheetItemConfig(
            id: hermesSettingsRowId('enabled'),
            title: l10n.hermesEnableTitle,
            sfSymbol: 'power',
            kind: NativeSheetItemKind.toggle,
            value: state.enabled,
          ),
        ],
      ),
      NativeSheetSectionConfig(
        title: l10n.hermesConnectionsSectionTitle,
        items: [
          if (state.connections.isEmpty)
            NativeSheetItemConfig(
              id: hermesConnectionPageId(null),
              title: l10n.hermesNoConnectionsTitle,
              subtitle: l10n.hermesNoConnectionsSubtitle,
              sfSymbol: 'plus.circle',
              accent: true,
            )
          else ...[
            for (final connection in state.connections)
              connectionRow(connection),
            NativeSheetItemConfig(
              id: hermesConnectionPageId(null),
              title: l10n.hermesAddConnection,
              sfSymbol: 'plus.circle',
              accent: true,
            ),
          ],
        ],
      ),
      if (state.enabled && state.usable && state.jobs)
        NativeSheetSectionConfig(
          title: l10n.hermesScheduledAgentsTitle,
          items: [
            NativeSheetItemConfig(
              id: hermesJobsPageId,
              title: l10n.hermesReviewSchedules,
              sfSymbol: 'clock',
            ),
          ],
        ),
      if (state.enabled && state.usable)
        NativeSheetSectionConfig(
          title: l10n.hermesConversationsTitle,
          footer: l10n.hermesShowScheduledRunsDescription,
          items: [
            NativeSheetItemConfig(
              id: hermesHiddenChatsPageId,
              title: l10n.hermesHiddenChatsTitle,
              sfSymbol: 'eye.slash',
            ),
            // The chats scheduled agents start, one per run, in the Hermes
            // chat list.
            NativeSheetItemConfig(
              id: hermesSettingsRowId('show-scheduled-runs'),
              title: l10n.hermesShowScheduledRuns,
              sfSymbol: 'clock',
              kind: NativeSheetItemKind.toggle,
              value: state.showScheduledRuns,
            ),
          ],
        ),
    ],
  );
}

/// What the Hermes page shows.
@immutable
@visibleForTesting
final class HermesSettingsPageState {
  const HermesSettingsPageState({
    required this.enabled,
    required this.usable,
    required this.jobs,
    required this.connections,
    required this.activeId,
    this.secretsUnavailable = false,
    this.secretsLoading = false,
    this.switching,
    this.notice,
    this.showScheduledRuns = true,
  });

  final bool enabled;
  final bool usable;

  /// Whether the connection in use runs scheduled agents.
  final bool jobs;
  final List<HermesConnectionProfile> connections;
  final String? activeId;
  final bool secretsUnavailable;
  final bool secretsLoading;

  /// The connection being switched to, while that runs.
  final String? switching;
  final String? notice;

  /// Whether the Hermes chat list shows the chats scheduled agents start.
  final bool showScheduledRuns;
}

/// What a connection's editor shows, as a snapshot of its draft.
@immutable
@visibleForTesting
final class HermesConnectionPageState {
  const HermesConnectionPageState({
    required this.key,
    required this.variant,
    this.title,
    this.ready = true,
    this.loadFailed = false,
    this.existing = false,
    this.editsActive = false,
    this.mode = HermesBackendMode.responsesApi,
    this.name = '',
    this.nameHint = '',
    this.url = '',
    this.urlError,
    this.apiKeyConfigured = false,
    this.legacyTokenConfigured = false,
    this.desktopAuthKind = HermesDesktopAuthKind.legacyToken,
    this.desktopProfile = 'default',
    this.profiles = const [],
    this.profilesError,
    this.profilesLoading = false,
    this.gatewayStopped = false,
    this.headerCount = 0,
    this.attempt = const ConnectionAttemptState.idle(),
    this.testing = false,
    this.busy = false,
    this.switching = false,
    this.edited = false,
    this.notice,
    this.management,
  });

  final String key;
  final HermesEditorVariant variant;

  /// The saved connection's name; null for a new one.
  final String? title;

  /// Whether the connection has been read: until then the page shows that
  /// it is being read, or why it could not be.
  final bool ready;

  /// Reading it, or its stored baseline, failed: the page says so and
  /// offers to read it again.
  final bool loadFailed;
  final bool existing;
  final bool editsActive;
  final HermesBackendMode mode;
  final String name;
  final String nameHint;
  final String url;
  final String? urlError;
  final bool apiKeyConfigured;
  final bool legacyTokenConfigured;
  final HermesDesktopAuthKind desktopAuthKind;
  final String desktopProfile;
  final List<String> profiles;
  final String? profilesError;
  final bool profilesLoading;
  final bool gatewayStopped;
  final int headerCount;
  final ConnectionAttemptState attempt;
  final bool testing;
  final bool busy;
  final bool switching;
  final bool edited;
  final String? notice;

  /// The server's own sections, shown on the editor of the connection in
  /// use.
  final HermesManagementState? management;
}

/// The server sections of the connection in use: what it can do, its
/// toolsets, its gateway's actions and its status.
@immutable
@visibleForTesting
final class HermesManagementState {
  const HermesManagementState({
    required this.capabilities,
    required this.desktop,
    this.toolsets,
    this.toolsetsFailed = false,
    this.pendingToolsets = const {},
    this.skills = const [],
    this.status,
    this.statusFailed = false,
    this.gatewayActionRunning = false,
  });

  final HermesCapabilities capabilities;
  final bool desktop;

  /// Null while they are read.
  final List<HermesToolset>? toolsets;
  final bool toolsetsFailed;
  final Set<String> pendingToolsets;
  final List<String> skills;

  /// Null while it is read.
  final Map<String, dynamic>? status;
  final bool statusFailed;
  final bool gatewayActionRunning;
}

/// Which way a connection editor was opened.
enum HermesEditorVariant {
  /// A saved connection, saved with Done.
  edit,

  /// A connection added from the Hermes page, saved with Done.
  add,

  /// A connection added from Accounts' Add Account: Done tests it, saves
  /// it and puts it in use, turning Hermes on.
  connect,
}

/// A connection's editor: its mode, name, address and credentials, the
/// Desktop Gateway's profile and sign-in, a row to test it, and the
/// Advanced page; on the connection in use, the server's own sections.
@visibleForTesting
NativeSheetDetailConfig buildHermesConnectionPage(
  AppLocalizations l10n,
  HermesConnectionPageState state,
) {
  final key = state.key;
  final pageId = '$hermesConnectionPagePrefix$key';
  String row(String field) => hermesConnectionRowId(field, key);
  final title =
      state.title ??
      (state.variant == HermesEditorVariant.connect
          ? l10n.backendChooserHermesTitle
          : l10n.hermesNewConnectionTitle);
  NativeSheetItemConfig note(String id, String text, [String? symbol]) =>
      NativeSheetItemConfig(
        id: '$pageId-$id',
        title: text,
        sfSymbol: symbol ?? 'exclamationmark.triangle',
        kind: NativeSheetItemKind.info,
      );
  final retry = NativeSheetItemConfig(
    id: row('retry-load'),
    title: l10n.retry,
    sfSymbol: 'arrow.clockwise',
    accent: true,
    showsDisclosure: false,
  );
  if (!state.ready) {
    return NativeSheetDetailConfig(
      id: pageId,
      title: title,
      items: [
        if (state.loadFailed) ...[
          note('load-failed', l10n.hermesSecretsUnavailable, 'lock'),
          retry,
        ] else
          buildNativeLoadingItem(l10n, id: '$pageId-loading'),
      ],
    );
  }
  final desktop = state.mode == HermesBackendMode.desktopGateway;
  final responses = !desktop;
  final working = state.busy || state.testing || state.switching;
  final attempt = state.attempt;
  final management = state.management;

  final authFooter = switch (state.desktopAuthKind) {
    HermesDesktopAuthKind.dashboardCookie => [
      l10n.hermesDashboardAuthHelp,
      if (!state.editsActive && state.variant != HermesEditorVariant.connect)
        l10n.hermesSignInActivatesConnection,
    ].join('\n\n'),
    HermesDesktopAuthKind.nativePkce =>
      !state.editsActive && state.variant != HermesEditorVariant.connect
          ? l10n.hermesSignInActivatesConnection
          : null,
    HermesDesktopAuthKind.legacyToken => null,
  };

  return NativeSheetDetailConfig(
    id: pageId,
    title: title,
    confirmActionId: row('save'),
    confirmActionLabel: state.variant == HermesEditorVariant.connect
        ? l10n.hermesConnectAction
        : l10n.save,
    discardPrompt: nativeDiscardPrompt(l10n),
    busy: state.busy,
    edited: state.edited,
    announcement: attempt.isVisible && !attempt.isBusy
        ? attempt.message
        : state.notice,
    sections: [
      if (state.loadFailed)
        NativeSheetSectionConfig(
          items: [
            note('load-failed', l10n.hermesSecretsUnavailable, 'lock'),
            retry,
          ],
        ),
      if (state.notice != null)
        NativeSheetSectionConfig(items: [note('notice', state.notice!)]),
      if (state.existing &&
          !state.editsActive &&
          state.variant == HermesEditorVariant.edit)
        NativeSheetSectionConfig(
          footer: l10n.hermesInactiveConnectionNotice,
          items: [
            NativeSheetItemConfig(
              id: row('use'),
              title: l10n.hermesUseConnection,
              sfSymbol: 'checkmark.circle',
              accent: true,
              showsDisclosure: false,
              pending: state.switching ? true : null,
              disabled: working,
            ),
          ],
        ),
      NativeSheetSectionConfig(
        footer: l10n.hermesConnectionNameHint,
        items: [
          NativeSheetItemConfig(
            id: row('mode'),
            title: l10n.hermesConnectionModeTitle,
            sfSymbol: desktop ? 'desktopcomputer' : 'cloud',
            kind: NativeSheetItemKind.segment,
            value: state.mode.name,
            disabled: working,
            options: [
              NativeSheetOptionConfig(
                id: HermesBackendMode.responsesApi.name,
                label: l10n.hermesModeResponsesApi,
              ),
              NativeSheetOptionConfig(
                id: HermesBackendMode.desktopGateway.name,
                label: l10n.hermesDesktopGateway,
              ),
            ],
          ),
          NativeSheetItemConfig(
            id: row('name'),
            title: l10n.name,
            sfSymbol: 'textformat',
            kind: NativeSheetItemKind.textField,
            value: state.name,
            placeholder: state.nameHint,
            disabled: working,
          ),
          NativeSheetItemConfig(
            id: row('url'),
            title: l10n.hermesServerUrlTitle,
            subtitle: state.urlError,
            sfSymbol: 'link',
            kind: NativeSheetItemKind.textField,
            value: state.url,
            placeholder: 'http://192.168.1.10:8642',
            keyboard: NativeSheetKeyboard.url,
            disabled: working,
          ),
          if (responses)
            NativeSheetItemConfig(
              id: row('api-key'),
              title: l10n.hermesApiKeyTitle,
              sfSymbol: 'key',
              kind: NativeSheetItemKind.secureTextField,
              placeholder: state.apiKeyConfigured
                  ? l10n.hermesConfiguredReplacePlaceholder
                  : l10n.hermesApiKeyPlaceholder,
              disabled: working,
            )
          else if (state.desktopAuthKind == HermesDesktopAuthKind.legacyToken)
            NativeSheetItemConfig(
              id: row('legacy-token'),
              title: l10n.hermesLegacySessionToken,
              sfSymbol: 'key',
              kind: NativeSheetItemKind.secureTextField,
              placeholder: state.legacyTokenConfigured
                  ? l10n.hermesConfiguredReplacePlaceholder
                  : l10n.hermesLegacySessionTokenHint,
              disabled: working,
            ),
        ],
      ),
      if (desktop) ...[
        if (state.gatewayStopped)
          NativeSheetSectionConfig(
            items: [note('gateway-stopped', l10n.hermesGatewayStopped)],
          ),
        NativeSheetSectionConfig(
          title: l10n.hermesProfile,
          footer: state.profilesError,
          items: [
            NativeSheetItemConfig(
              id: row('profile'),
              title: l10n.hermesProfileLabel,
              sfSymbol: 'person.crop.circle',
              kind: NativeSheetItemKind.segment,
              value: state.desktopProfile,
              disabled: working,
              options: [
                for (final profile in {state.desktopProfile, ...state.profiles})
                  NativeSheetOptionConfig(id: profile, label: profile),
              ],
            ),
            NativeSheetItemConfig(
              id: row('refresh-profiles'),
              title: l10n.hermesRefreshProfiles,
              sfSymbol: 'arrow.clockwise',
              accent: true,
              showsDisclosure: false,
              pending: state.profilesLoading ? true : null,
              disabled: state.profilesLoading || working,
            ),
          ],
        ),
        NativeSheetSectionConfig(
          title: l10n.hermesDesktopAuthentication,
          footer: authFooter,
          items: [
            NativeSheetItemConfig(
              id: row('auth'),
              title: l10n.hermesDesktopAuthentication,
              sfSymbol: 'person.badge.key',
              kind: NativeSheetItemKind.segment,
              value: state.desktopAuthKind.name,
              disabled: working,
              options: [
                NativeSheetOptionConfig(
                  id: HermesDesktopAuthKind.legacyToken.name,
                  label: l10n.hermesAuthLegacy,
                ),
                NativeSheetOptionConfig(
                  id: HermesDesktopAuthKind.nativePkce.name,
                  label: l10n.hermesAuthNative,
                ),
                NativeSheetOptionConfig(
                  id: HermesDesktopAuthKind.dashboardCookie.name,
                  label: l10n.hermesAuthDashboard,
                ),
              ],
            ),
            if (state.desktopAuthKind == HermesDesktopAuthKind.nativePkce)
              NativeSheetItemConfig(
                id: row('sign-in-native'),
                title: l10n.hermesNativeSignIn,
                sfSymbol: 'person.badge.key',
                accent: true,
                showsDisclosure: false,
                disabled: working,
              ),
            if (state.desktopAuthKind == HermesDesktopAuthKind.dashboardCookie)
              NativeSheetItemConfig(
                id: row('sign-in-dashboard'),
                title: l10n.hermesDashboardSignIn,
                sfSymbol: 'globe',
                accent: true,
                showsDisclosure: false,
                disabled: working,
              ),
          ],
        ),
      ],
      NativeSheetSectionConfig(
        items: [
          NativeSheetItemConfig(
            id: '$hermesConnectionAdvancedPagePrefix$key',
            title: l10n.advancedSettings,
            subtitle: state.headerCount > 0
                ? '${l10n.hermesGatewayAccessHeaders} · ${state.headerCount}'
                : null,
            sfSymbol: 'gearshape',
          ),
        ],
      ),
      if (state.variant != HermesEditorVariant.connect)
        NativeSheetSectionConfig(
          footer: attempt.isVisible && !attempt.isBusy ? attempt.message : null,
          items: [
            NativeSheetItemConfig(
              id: row('test'),
              title: l10n.testDirectConnection,
              sfSymbol: 'bolt.horizontal',
              accent: true,
              showsDisclosure: false,
              pending: state.testing ? true : null,
              disabled: working,
            ),
          ],
        )
      else if (attempt.isVisible && !attempt.isBusy)
        NativeSheetSectionConfig(
          items: [
            note(
              'attempt',
              attempt.message ?? '',
              attempt.phase == ConnectionAttemptPhase.failed
                  ? 'exclamationmark.triangle'
                  : 'checkmark.circle',
            ),
          ],
        ),
      // The server's own controls apply at once, so they live on a page of
      // their own rather than on this form, which saves with Done.
      if (management != null)
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: '$hermesConnectionServerPagePrefix$key',
              title: l10n.hermesServerStatusTitle,
              subtitle: management.desktop
                  ? '${l10n.hermesCapabilityToolsets} · ${l10n.hermesMcpServers}'
                  : l10n.hermesCapabilityToolsets,
              sfSymbol: 'server.rack',
            ),
          ],
        ),
      if (state.existing && state.variant == HermesEditorVariant.edit)
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: row('delete'),
              title: l10n.delete,
              sfSymbol: 'trash',
              destructive: true,
              showsDisclosure: false,
              disabled: working,
              confirmMessage: l10n.hermesDeleteConnectionMessage(
                state.title ?? kHermesDefaultConnectionName,
              ),
            ),
          ],
        ),
    ],
  );
}

/// The server page of the connection in use: what it can do, its toolsets
/// (switched on the Desktop Gateway), the gateway's actions, and its status.
@visibleForTesting
NativeSheetDetailConfig buildHermesServerPage(
  AppLocalizations l10n,
  String key,
  HermesManagementState management, {
  String? notice,
}) => NativeSheetDetailConfig(
  id: '$hermesConnectionServerPagePrefix$key',
  title: l10n.hermesServerStatusTitle,
  announcement: notice,
  sections: [
    if (notice != null)
      NativeSheetSectionConfig(
        items: [
          NativeSheetItemConfig(
            id: '$hermesConnectionServerPagePrefix$key-notice',
            title: notice,
            sfSymbol: 'exclamationmark.triangle',
            kind: NativeSheetItemKind.info,
          ),
        ],
      ),
    ..._managementSections(l10n, key, management),
  ],
);

List<NativeSheetSectionConfig> _managementSections(
  AppLocalizations l10n,
  String key,
  HermesManagementState management,
) {
  final pageId = '$hermesConnectionPagePrefix$key';
  String row(String field, [String? extra]) =>
      hermesConnectionRowId(field, key, extra);
  NativeSheetItemConfig capability(String id, String title, bool enabled) =>
      NativeSheetItemConfig(
        id: '$pageId-capability-$id',
        title: title,
        subtitle: enabled ? l10n.enabled : l10n.disabled,
        sfSymbol: enabled ? 'checkmark.circle' : 'minus.circle',
        kind: NativeSheetItemKind.info,
      );
  final capabilities = management.capabilities;
  final toolsets = management.toolsets;
  final status = management.status;
  final statusEntries = [
    for (final entry in (status ?? const <String, dynamic>{}).entries)
      if (entry.value is num || entry.value is String || entry.value is bool)
        entry,
  ];
  return [
    NativeSheetSectionConfig(
      title: l10n.hermesCapabilitiesTitle,
      items: [
        capability(
          'approval',
          l10n.hermesCapabilityApproval,
          capabilities.runApproval,
        ),
        capability('skills', l10n.hermesCapabilitySkills, capabilities.skills),
        capability(
          'toolsets',
          l10n.hermesCapabilityToolsets,
          capabilities.toolsets,
        ),
        capability('jobs', l10n.hermesCapabilityJobs, capabilities.jobs),
        capability(
          'sessions',
          l10n.hermesCapabilitySessions,
          capabilities.sessions,
        ),
      ],
    ),
    NativeSheetSectionConfig(
      title: l10n.hermesCapabilityToolsets,
      footer: toolsets != null && toolsets.isNotEmpty
          ? l10n.hermesToolsetsNewSessions
          : null,
      items: [
        if (management.toolsetsFailed)
          NativeSheetItemConfig(
            id: '$pageId-toolsets-failed',
            title: l10n.directConnectionUnavailableLabel,
            sfSymbol: 'exclamationmark.triangle',
            kind: NativeSheetItemKind.info,
          )
        else if (toolsets == null)
          buildNativeLoadingItem(l10n, id: '$pageId-toolsets-loading')
        else if (toolsets.isEmpty)
          NativeSheetItemConfig(
            id: '$pageId-toolsets-none',
            title: l10n.hermesNoToolsets,
            sfSymbol: 'wrench.and.screwdriver',
            kind: NativeSheetItemKind.info,
          )
        else
          for (final toolset in toolsets)
            NativeSheetItemConfig(
              id: row('toolset', toolset.name),
              title: toolset.label,
              subtitle: l10n.hermesToolCount(toolset.tools.length),
              sfSymbol: 'wrench.and.screwdriver',
              // Only the Desktop Gateway turns a toolset on or off.
              kind: management.desktop
                  ? NativeSheetItemKind.toggle
                  : NativeSheetItemKind.info,
              value: management.desktop ? toolset.enabled : null,
              disabled: management.pendingToolsets.contains(toolset.name),
            ),
      ],
    ),
    if (management.desktop)
      NativeSheetSectionConfig(
        title: l10n.hermesDesktopGateway,
        items: [
          NativeSheetItemConfig(
            id: row('reload-skills'),
            title: l10n.hermesReloadSkills,
            subtitle: management.skills.isEmpty
                ? l10n.hermesNoInstalledSkills
                : management.skills.map((skill) => '/$skill').join(', '),
            sfSymbol: 'arrow.clockwise',
            showsDisclosure: false,
            pending: management.gatewayActionRunning ? true : null,
            disabled: management.gatewayActionRunning,
          ),
          NativeSheetItemConfig(
            id: hermesMcpPageId,
            title: l10n.hermesMcpServers,
            sfSymbol: 'point.3.connected.trianglepath.dotted',
          ),
          NativeSheetItemConfig(
            id: row('sign-out'),
            title: l10n.hermesSignOut,
            sfSymbol: 'rectangle.portrait.and.arrow.right',
            showsDisclosure: false,
            disabled: management.gatewayActionRunning,
          ),
        ],
      ),
    NativeSheetSectionConfig(
      title: l10n.hermesServerStatusTitle,
      items: [
        if (management.statusFailed)
          NativeSheetItemConfig(
            id: '$pageId-status-failed',
            title: l10n.directConnectionUnavailableLabel,
            sfSymbol: 'exclamationmark.triangle',
            kind: NativeSheetItemKind.info,
          )
        else if (status == null)
          buildNativeLoadingItem(l10n, id: '$pageId-status-loading')
        else if (statusEntries.isEmpty)
          NativeSheetItemConfig(
            id: '$pageId-status-none',
            title: l10n.hermesNoServerStatus,
            sfSymbol: 'chart.bar',
            kind: NativeSheetItemKind.info,
          )
        else
          for (final entry in statusEntries)
            NativeSheetItemConfig(
              id: '$pageId-status-${entry.key}',
              title: _humanizeStatusKey(entry.key),
              subtitle: '${entry.value}',
              sfSymbol: 'chart.bar',
              kind: NativeSheetItemKind.info,
            ),
      ],
    ),
  ];
}

String _humanizeStatusKey(String key) => key
    .replaceAll('_', ' ')
    .replaceFirstMapped(RegExp('^.'), (match) => match.group(0)!.toUpperCase());

/// A connection's Advanced page: the gateway's access headers, each removed
/// from its menu, a row adding one; whether to trust a certificate the
/// device cannot verify; and, for the Responses API, the memory key.
@visibleForTesting
NativeSheetDetailConfig buildHermesConnectionAdvancedPage(
  AppLocalizations l10n, {
  required String key,
  required HermesBackendMode mode,
  required Map<String, String> headers,
  required bool allowSelfSigned,
  required bool sessionKeyConfigured,
  bool disabled = false,
}) {
  String row(String field, [String? extra]) =>
      hermesConnectionRowId(field, key, extra);
  return NativeSheetDetailConfig(
    id: '$hermesConnectionAdvancedPagePrefix$key',
    title: l10n.advancedSettings,
    sections: [
      NativeSheetSectionConfig(
        title: l10n.hermesGatewayAccessHeaders,
        footer: l10n.hermesGatewayAccessHeadersHelp,
        items: [
          for (final name in headers.keys)
            NativeSheetItemConfig(
              id: '$hermesConnectionAdvancedPagePrefix$key-header-$name',
              title: name,
              subtitle: '••••••',
              sfSymbol: 'list.bullet.rectangle',
              kind: NativeSheetItemKind.info,
              rowActions: [
                NativeSheetRowAction(
                  id: row('header-remove', name),
                  label: l10n.removeHeader,
                  sfSymbol: 'trash',
                  destructive: true,
                ),
              ],
            ),
          NativeSheetItemConfig(
            id: '$hermesConnectionHeaderPagePrefix$key',
            title: l10n.addHeader,
            sfSymbol: 'plus.circle',
            accent: true,
            disabled:
                disabled || headers.length >= HermesConfig.maxAccessHeaders,
          ),
        ],
      ),
      NativeSheetSectionConfig(
        items: [
          NativeSheetItemConfig(
            id: row('self-signed'),
            title: l10n.allowSelfSignedCertificates,
            subtitle: l10n.allowSelfSignedCertificatesDescription,
            sfSymbol: 'lock.open',
            kind: NativeSheetItemKind.toggle,
            value: allowSelfSigned,
            disabled: disabled,
          ),
        ],
      ),
      if (mode == HermesBackendMode.responsesApi)
        NativeSheetSectionConfig(
          title: l10n.hermesMemoryKeyTitle,
          footer: l10n.hermesMemoryKeyDescription,
          items: [
            NativeSheetItemConfig(
              id: row('memory-key'),
              title: l10n.hermesMemoryKeyFieldLabel,
              sfSymbol: 'brain',
              kind: NativeSheetItemKind.secureTextField,
              placeholder: sessionKeyConfigured
                  ? l10n.hermesConfiguredReplacePlaceholder
                  : l10n.hermesMemoryKeyPlaceholder,
              disabled: disabled,
            ),
          ],
        ),
    ],
  );
}

/// The page adding an access header to a connection: its name and value,
/// checked when Done adds it.
@visibleForTesting
NativeSheetDetailConfig buildHermesConnectionHeaderPage(
  AppLocalizations l10n, {
  required String key,
  String name = '',
  String? notice,
}) {
  final pageId = '$hermesConnectionHeaderPagePrefix$key';
  return NativeSheetDetailConfig(
    id: pageId,
    title: l10n.addHeader,
    confirmActionId: hermesConnectionRowId('header-add', key),
    confirmActionLabel: l10n.addHeader,
    discardPrompt: nativeDiscardPrompt(l10n),
    items: [
      if (notice != null)
        NativeSheetItemConfig(
          id: '$pageId-notice',
          title: notice,
          sfSymbol: 'exclamationmark.triangle',
          kind: NativeSheetItemKind.info,
        ),
      NativeSheetItemConfig(
        id: hermesConnectionRowId('header-name', key),
        title: l10n.headerName,
        sfSymbol: 'textformat',
        kind: NativeSheetItemKind.textField,
        value: name,
      ),
      NativeSheetItemConfig(
        id: hermesConnectionRowId('header-value', key),
        title: l10n.headerValue,
        sfSymbol: 'key',
        kind: NativeSheetItemKind.secureTextField,
      ),
    ],
  );
}

/// Hermes chats hidden from the session list: one opens on a tap; its menu
/// shows it in the list again.
@visibleForTesting
NativeSheetDetailConfig buildHermesHiddenChatsPage(
  AppLocalizations l10n, {
  required List<HermesSessionSummary>? sessions,
  bool failed = false,
  Set<String> unhiding = const {},
  String? notice,
}) {
  const pageId = hermesHiddenChatsPageId;
  NativeSheetItemConfig note(String id, String title, String symbol) =>
      NativeSheetItemConfig(
        id: '$pageId-$id',
        title: title,
        sfSymbol: symbol,
        kind: NativeSheetItemKind.info,
      );
  return NativeSheetDetailConfig(
    id: pageId,
    title: l10n.hermesHiddenChatsTitle,
    announcement: notice,
    sections: [
      if (notice != null)
        NativeSheetSectionConfig(
          items: [note('notice', notice, 'exclamationmark.triangle')],
        ),
      if (failed)
        NativeSheetSectionConfig(
          items: [
            note(
              'failed',
              l10n.hermesHiddenChatsLoadError,
              'exclamationmark.triangle',
            ),
          ],
        )
      else if (sessions == null)
        NativeSheetSectionConfig(
          items: [buildNativeLoadingItem(l10n, id: '$pageId-loading')],
        )
      else if (sessions.isEmpty)
        NativeSheetSectionConfig(
          items: [note('empty', l10n.hermesHiddenChatsEmpty, 'eye.slash')],
        )
      else
        NativeSheetSectionConfig(
          footer: l10n.hermesHiddenChatsDescription,
          items: [
            for (final session in sessions)
              NativeSheetItemConfig(
                id: hermesHiddenChatRowId('open', session.id),
                title: session.title,
                subtitle: session.preview,
                sfSymbol: 'bubble.left',
                showsDisclosure: false,
                disabled: unhiding.contains(session.id),
                pending: unhiding.contains(session.id) ? true : null,
                rowActions: [
                  NativeSheetRowAction(
                    id: hermesHiddenChatRowId('unhide', session.id),
                    label: l10n.hermesSessionUnhide,
                    sfSymbol: 'eye',
                  ),
                ],
              ),
          ],
        ),
    ],
  );
}

/// One connection being edited, kept until its page is left.
final class _Editor {
  _Editor(this.variant);

  final HermesEditorVariant variant;
  HermesConnectionController? controller;

  /// The stored settings of an inactive connection, which its draft is
  /// built against; the connection in use reads the live ones.
  HermesConfig? stored;
  int storedReloads = 0;
  bool loadFailed = false;
  bool switching = false;
  bool saving = false;
  bool edited = false;
  bool shownEdited = false;

  /// Whether the user chose how to sign in to the Desktop Gateway; the
  /// server's recommendation never replaces their choice.
  bool authChosen = false;
  String? notice;

  /// Work that can rotate an inactive connection's stored tokens; a switch
  /// to it waits for it.
  final Set<Future<void>> tokenWork = {};

  // The Desktop Gateway's profiles, read for this draft.
  List<String> profiles = const [];
  String? profilesError;
  bool profilesLoading = false;
  String? lastOrigin;
  String? lastProfileIdentity;
  final Object credentialSalt = Object();
  int recommendationEpoch = 0;
  int profileEpoch = 0;

  // The access header being added.
  String headerName = '';
  String headerValue = '';
  String? headerNotice;

  // The server's own sections, for the connection in use.
  List<HermesToolset>? toolsets;
  bool toolsetsFailed = false;
  final Set<String> pendingToolsets = {};
  List<String> skills = const [];
  Map<String, dynamic>? status;
  bool statusFailed = false;
  bool gatewayActionRunning = false;
  HermesCapabilities? capabilities;
  String? serverNotice;

  void dispose() => controller?.dispose();
}

/// The Hermes pages of Settings: Hermes Agent's own page, each connection's
/// editor with its Advanced and Add Header pages, and the hidden chats.
class HermesSettingsPages extends SettingsPageModule {
  HermesSettingsPages(this._ref);

  final Ref _ref;
  bool _listening = false;

  /// Follows the saved connections once a Hermes page is first shown, not
  /// before: Settings never reads Hermes for someone who does not open it.
  void _listen() {
    if (_listening) return;
    _listening = true;
    // Probing or listing profiles can rotate an inactive connection's tokens
    // in storage; its editor must not send or write the spent ones.
    _ref.listen<int>(hermesConnectionsRevisionProvider, (_, _) {
      for (final entry in _editors.entries.toList()) {
        if (!_editsActive(entry.value) && entry.value.stored != null) {
          unawaited(_refreshAndShow(entry.key, entry.value));
        }
      }
    });
    // Capabilities read after the page was drawn (a cold Desktop Gateway
    // answers later) can add rows to it, Scheduled Agents say; any page
    // already known, an open editor included, is left as it is.
    _ref.listen(hermesCapabilitiesProvider, (previous, next) {
      if (previous?.value == next.value) return;
      final l10n = _l10n;
      if (l10n == null ||
          !_ref.read(settingsPagesProvider).contains(hermesSettingsPageId)) {
        return;
      }
      unawaited(_applyRoot(l10n, keepKnownPages: true));
    });
    // An editor whose connection stops being the one in use reads its stored
    // settings before it can save again.
    _ref.listen<String?>(hermesActiveConnectionIdProvider, (previous, next) {
      if (previous == next) return;
      for (final entry in _editors.entries.toList()) {
        if (!_editsActive(entry.value) && entry.value.stored == null) {
          unawaited(_refreshAndShow(entry.key, entry.value));
        }
      }
    });
  }

  Future<void> _refreshAndShow(String key, _Editor editor) async {
    await _refreshStored(key, editor);
    final l10n = _l10n;
    if (l10n != null) await _applyEditor(l10n, key, editor, withPages: false);
  }

  final Map<String, _Editor> _editors = {};
  String? _switching;
  String? _rootNotice;
  List<HermesSessionSummary>? _hidden;
  bool _hiddenFailed = false;

  /// Counts the hidden-chat lists read.
  int _hiddenList = 0;
  final Set<String> _unhiding = {};
  String? _hiddenNotice;
  AppLocalizations? _l10n;

  SettingsSurface get _surface => _ref.read(settingsSurfaceProvider);

  @override
  bool ownsPage(String detailId) =>
      detailId == hermesSettingsPageId ||
      detailId == hermesHiddenChatsPageId ||
      detailId.startsWith(hermesConnectionPagePrefix) ||
      detailId.startsWith(hermesConnectionAdvancedPagePrefix) ||
      detailId.startsWith(hermesConnectionServerPagePrefix) ||
      detailId.startsWith(hermesConnectionHeaderPagePrefix);

  @override
  Future<void> hydrate(String detailId, AppLocalizations l10n) async {
    _l10n = l10n;
    _listen();
    if (detailId == hermesSettingsPageId) {
      await _applyRoot(l10n);
    } else if (detailId == hermesHiddenChatsPageId) {
      await _hydrateHidden(l10n);
    } else if (detailId.startsWith(hermesConnectionAdvancedPagePrefix)) {
      final key = detailId.substring(hermesConnectionAdvancedPagePrefix.length);
      final editor = await _editor(key);
      if (editor == null) return;
      await _applyAdvanced(l10n, key, editor);
    } else if (detailId.startsWith(hermesConnectionServerPagePrefix)) {
      final key = detailId.substring(hermesConnectionServerPagePrefix.length);
      final editor = await _editor(key);
      if (editor == null) return;
      await _applyServer(l10n, key, editor);
      await _readManagement(key, editor);
    } else if (detailId.startsWith(hermesConnectionHeaderPagePrefix)) {
      final key = detailId.substring(hermesConnectionHeaderPagePrefix.length);
      final editor = await _editor(key);
      if (editor == null) return;
      editor
        ..headerName = ''
        ..headerValue = ''
        ..headerNotice = null;
      await _surface.applyDetail(
        buildHermesConnectionHeaderPage(l10n, key: key),
      );
    } else if (detailId.startsWith(hermesConnectionPagePrefix)) {
      final key = detailId.substring(hermesConnectionPagePrefix.length);
      final editor = await _editor(key);
      if (editor == null) return;
      await _applyEditor(l10n, key, editor);
      unawaited(_startDesktopWork(key, editor));
    }
  }

  @override
  void pageLeft(String detailId) {
    // What a list page said goes with it: coming back, it is not still
    // there.
    if (detailId == hermesSettingsPageId) _rootNotice = null;
    if (detailId == hermesHiddenChatsPageId) _hiddenNotice = null;
    // An editor left -- Back, or Settings closing -- is abandoned with its
    // draft, credentials included. (Covered by its Advanced page, it is
    // not left.)
    if (detailId.startsWith(hermesConnectionPagePrefix)) {
      final key = detailId.substring(hermesConnectionPagePrefix.length);
      _editors.remove(key)?.dispose();
    } else if (detailId.startsWith(hermesConnectionHeaderPagePrefix)) {
      final editor =
          _editors[detailId.substring(hermesConnectionHeaderPagePrefix.length)];
      editor
        ?..headerName = ''
        ..headerValue = '';
    }
  }

  @override
  void settingsClosed() {
    for (final editor in _editors.values) {
      editor.dispose();
    }
    _editors.clear();
    _rootNotice = null;
    _hiddenNotice = null;
  }

  // -- Hermes page -----------------------------------------------------------

  HermesSettingsPageState _rootState() {
    final config = _ref.read(hermesConfigProvider);
    final capabilities =
        _ref.read(hermesCapabilitiesProvider).value ??
        (config.mode == HermesBackendMode.desktopGateway
            ? HermesCapabilities.desktopCoreOnly
            : HermesCapabilities.enabledByDefault);
    return HermesSettingsPageState(
      enabled: config.enabled,
      usable: config.isUsable,
      jobs: capabilities.jobs,
      connections: _ref.read(hermesConnectionsProvider),
      activeId: config.connectionId,
      secretsUnavailable: _ref.read(hermesSecretsErrorProvider) != null,
      secretsLoading: _ref.read(hermesSecretsLoadingProvider),
      switching: _switching,
      notice: _rootNotice,
      showScheduledRuns: _ref
          .read(appSettingsProvider)
          .hermesShowScheduledSessions,
    );
  }

  Future<void> _applyRoot(
    AppLocalizations l10n, {
    bool keepKnownPages = false,
  }) {
    final state = _rootState();
    final known = _ref.read(settingsPagesProvider);
    return _surface.applyDetail(
      buildHermesSettingsPage(l10n, state),
      detailSheets: [
        for (final page in _rootPages(l10n, state))
          if (!keepKnownPages || !known.contains(page.id)) page,
      ],
    );
  }

  /// The pages the Hermes page leads to, drawn loading until they appear.
  List<NativeSheetDetailConfig> _rootPages(
    AppLocalizations l10n,
    HermesSettingsPageState state,
  ) {
    return [
      for (final connection in state.connections)
        buildNativeLoadingDetail(
          l10n: l10n,
          id: hermesConnectionPageId(connection.id),
          title: connection.name,
        ),
      buildNativeLoadingDetail(
        l10n: l10n,
        id: hermesConnectionPageId(null),
        title: l10n.hermesNewConnectionTitle,
      ),
      buildNativeLoadingDetail(
        l10n: l10n,
        id: hermesJobsPageId,
        title: l10n.hermesScheduledAgentsTitle,
      ),
      buildNativeLoadingDetail(
        l10n: l10n,
        id: hermesHiddenChatsPageId,
        title: l10n.hermesHiddenChatsTitle,
      ),
    ];
  }

  Future<void> _setEnabled(AppLocalizations l10n, bool value) async {
    try {
      await _ref.read(hermesConfigProvider.notifier).setEnabled(value);
      // Turned off with nothing else to use, the backend chooser comes back
      // rather than a stale preference.
      if (!value &&
          _ref.read(preferredBackendProvider) == PreferredBackend.hermes) {
        await _ref
            .read(preferredBackendProvider.notifier)
            .set(PreferredBackend.unset);
      }
      _rootNotice = null;
    } catch (error) {
      DebugLogger.warning(
        'hermes-enable-failed',
        scope: 'settings/hermes',
        data: {'errorType': error.runtimeType.toString()},
      );
      _rootNotice = l10n.errorMessage;
    }
    await _applyRoot(l10n);
  }

  Future<void> _switchTo(AppLocalizations l10n, String connectionId) async {
    if (_switching != null) return;
    if (_ref.read(hermesActiveConnectionIdProvider) == connectionId) return;
    _switching = connectionId;
    _rootNotice = null;
    await _applyRoot(l10n);
    // As from its editor: a switch waits for work that rotates the
    // connection's stored tokens, or it would load the ones being replaced.
    final editor = _editors[Uri.encodeComponent(connectionId)];
    if (editor != null) await Future.wait(editor.tokenWork.toList());
    try {
      await _ref
          .read(hermesConfigProvider.notifier)
          .setActiveConnection(connectionId);
    } catch (error) {
      DebugLogger.warning(
        'connection-switch-failed',
        scope: 'settings/hermes',
        data: {'errorType': error.runtimeType.toString()},
      );
      _rootNotice = l10n.hermesSwitchConnectionFailed;
    } finally {
      _switching = null;
    }
    await _applyRoot(l10n);
  }

  /// Deletes [connectionId]; with none left, a Hermes-only install goes back
  /// to the backend chooser. Returns whether it was deleted.
  Future<bool> _delete(String connectionId) async {
    try {
      await _ref
          .read(hermesConfigProvider.notifier)
          .deleteConnection(connectionId);
      if (_ref.read(hermesConnectionsProvider).isEmpty &&
          _ref.read(preferredBackendProvider) == PreferredBackend.hermes) {
        await _ref
            .read(preferredBackendProvider.notifier)
            .set(PreferredBackend.unset);
      }
      return true;
    } catch (error) {
      DebugLogger.warning(
        'connection-delete-failed',
        scope: 'settings/hermes',
        data: {'errorType': error.runtimeType.toString()},
      );
      return false;
    }
  }

  // -- Connection editor -------------------------------------------------------

  /// Whether [editor] is still open under [key] and edits the connection
  /// in use, so an action on the service in use is its own.
  bool _actsOn(String key, _Editor editor) =>
      identical(_editors[key], editor) && _editsActive(editor);

  bool _editsActive(_Editor editor) {
    final id = editor.controller?.connectionId;
    return id != null && id == _ref.read(hermesConfigProvider).connectionId;
  }

  bool _baselineReady(_Editor editor) =>
      _editsActive(editor) ||
      editor.controller?.connectionId == null ||
      editor.stored != null;

  /// The stored state its draft compares against.
  HermesConfig _saved(_Editor editor) {
    if (_editsActive(editor)) return _ref.read(hermesConfigProvider);
    final id = editor.controller?.connectionId;
    if (id == null) return const HermesConfig();
    return editor.stored ?? HermesConfig(connectionId: id);
  }

  /// The editor [key] names, opened from the connection as stored when it
  /// is not open yet; null when that connection is gone.
  Future<_Editor?> _editor(String key) async {
    final open = _editors[key];
    if (open != null) return open;
    final variant = switch (key) {
      hermesNewConnectionKey => HermesEditorVariant.add,
      hermesConnectConnectionKey => HermesEditorVariant.connect,
      _ => HermesEditorVariant.edit,
    };
    final editor = _editors[key] = _Editor(variant);
    if (variant != HermesEditorVariant.edit) {
      _attach(editor, const HermesConfig());
      return editor;
    }
    final connectionId = Uri.decodeComponent(key);
    if (!_ref
        .read(hermesConnectionsProvider)
        .any((profile) => profile.id == connectionId)) {
      _editors.remove(key);
      return null;
    }
    final active = _ref.read(hermesConfigProvider);
    if (active.connectionId == connectionId) {
      _attach(editor, active);
    } else {
      await _loadStored(key, editor, connectionId);
    }
    return editor;
  }

  void _attach(_Editor editor, HermesConfig initial) {
    final profile = _ref
        .read(hermesConnectionsProvider)
        .where((profile) => profile.id == initial.connectionId)
        .firstOrNull;
    editor.controller = HermesConnectionController(
      initialConfig: initial,
      initialNameSource: profile?.nameSource,
      gateway: _ref.read(hermesConnectionGatewayProvider),
    );
    editor.lastOrigin = HermesConfig.connectionEndpoint(initial.baseUrl);
  }

  Future<void> _loadStored(
    String key,
    _Editor editor,
    String connectionId,
  ) async {
    try {
      final stored = await _ref
          .read(hermesConfigProvider.notifier)
          .savedConnectionConfig(connectionId);
      if (!identical(_editors[key], editor)) return;
      editor
        ..stored = stored
        ..loadFailed = false;
      if (editor.controller == null) _attach(editor, stored);
    } catch (error) {
      DebugLogger.warning(
        'connection-load-failed',
        scope: 'settings/hermes',
        data: {'errorType': error.runtimeType.toString()},
      );
      if (identical(_editors[key], editor)) editor.loadFailed = true;
    }
  }

  /// Reads the stored baseline again after an inactive connection was saved
  /// or its stored state changed.
  Future<void> _refreshStored(String key, _Editor editor) async {
    final controller = editor.controller;
    final id = controller?.connectionId;
    final reload = ++editor.storedReloads;
    if (id == null || _editsActive(editor)) {
      editor
        ..stored = null
        ..loadFailed = false;
      return;
    }
    try {
      final stored = await _ref
          .read(hermesConfigProvider.notifier)
          .savedConnectionConfig(id);
      // Reloads can overlap and finish out of order; the latest read wins.
      if (identical(_editors[key], editor) && reload == editor.storedReloads) {
        editor
          ..stored = stored
          ..loadFailed = false;
      }
    } catch (error) {
      DebugLogger.warning(
        'connection-reload-failed',
        scope: 'settings/hermes',
        data: {'errorType': error.runtimeType.toString()},
      );
      // A stale baseline still guards a save; without one, Done and Test
      // are refused, so the page says why and offers to read it again.
      if (identical(_editors[key], editor) &&
          reload == editor.storedReloads &&
          editor.stored == null) {
        editor.loadFailed = true;
      }
    }
  }

  Future<void> _retryLoad(
    AppLocalizations l10n,
    String key,
    _Editor editor,
  ) async {
    editor.loadFailed = false;
    if (_ref.read(hermesSecretsErrorProvider) != null) {
      await _ref.read(hermesConfigProvider.notifier).retrySecrets();
    }
    if (editor.controller == null) {
      await _loadStored(key, editor, Uri.decodeComponent(key));
    } else {
      await _refreshStored(key, editor);
    }
    await _applyEditor(l10n, key, editor);
  }

  HermesConnectionPageState _editorState(String key, _Editor editor) {
    final controller = editor.controller;
    final l10n = _l10n!;
    final connectionId = controller?.connectionId;
    final savedName = connectionId == null
        ? null
        : _ref
              .read(hermesConnectionsProvider)
              .where((profile) => profile.id == connectionId)
              .firstOrNull
              ?.name;
    if (controller == null) {
      return HermesConnectionPageState(
        key: key,
        variant: editor.variant,
        title: savedName,
        ready: false,
        loadFailed: editor.loadFailed,
      );
    }
    final editsActive = _editsActive(editor);
    final config = _saved(editor);
    final activeConfig = _ref.read(hermesConfigProvider);
    final urlError = switch (controller.validationIssue) {
      HermesConnectionValidationIssue.invalidUrl =>
        l10n.directConnectionUrlInvalid,
      HermesConnectionValidationIssue.credentialsReentryRequired =>
        l10n.directConnectionCredentialsReentryRequired,
      null => null,
    };
    final capabilities = editor.capabilities;
    final showManagement =
        editor.variant == HermesEditorVariant.edit &&
        editsActive &&
        activeConfig.isUsable;
    final statusValue = _ref.read(hermesServerStatusProvider).value;
    return HermesConnectionPageState(
      key: key,
      variant: editor.variant,
      title: savedName,
      loadFailed: editor.loadFailed && !_baselineReady(editor),
      existing: connectionId != null,
      editsActive: editsActive,
      mode: controller.mode,
      name: controller.name.text,
      nameHint: HermesConnectionProfile.deriveName(controller.url.text),
      url: controller.url.text,
      urlError: urlError,
      apiKeyConfigured: config.apiKey?.isNotEmpty == true,
      legacyTokenConfigured:
          config.desktopCredentials?.legacyToken?.isNotEmpty == true,
      desktopAuthKind: controller.desktopAuthKind,
      desktopProfile: controller.desktopProfile,
      profiles: editor.profiles,
      profilesError: editor.profilesError,
      profilesLoading: editor.profilesLoading,
      gatewayStopped: editsActive && statusValue?['gateway_running'] == false,
      headerCount: controller.accessHeaders.length,
      attempt: controller.attempt,
      testing: controller.operation == HermesConnectionOperation.testing,
      busy:
          editor.saving ||
          controller.operation == HermesConnectionOperation.saving ||
          controller.operation == HermesConnectionOperation.finishing,
      switching: editor.switching,
      edited: editor.edited,
      notice: editor.notice,
      management: showManagement
          ? HermesManagementState(
              capabilities:
                  capabilities ??
                  (activeConfig.mode == HermesBackendMode.desktopGateway
                      ? HermesCapabilities.desktopCoreOnly
                      : HermesCapabilities.enabledByDefault),
              desktop: activeConfig.mode == HermesBackendMode.desktopGateway,
              toolsets: editor.toolsets,
              toolsetsFailed: editor.toolsetsFailed,
              pendingToolsets: Set.of(editor.pendingToolsets),
              skills: editor.skills,
              status: editor.status,
              statusFailed: editor.statusFailed,
              gatewayActionRunning: editor.gatewayActionRunning,
            )
          : null,
    );
  }

  Future<void> _applyEditor(
    AppLocalizations l10n,
    String key,
    _Editor editor, {
    bool withPages = true,
  }) async {
    if (!identical(_editors[key], editor)) return;
    editor.shownEdited = editor.edited;
    final controller = editor.controller;
    await _surface.applyDetail(
      buildHermesConnectionPage(l10n, _editorState(key, editor)),
      detailSheets: [
        if (withPages && controller != null) ...[
          _advancedPage(l10n, key, editor),
          buildHermesConnectionHeaderPage(l10n, key: key),
          if (_editsActive(editor)) ...[
            buildNativeLoadingDetail(
              l10n: l10n,
              id: '$hermesConnectionServerPagePrefix$key',
              title: l10n.hermesServerStatusTitle,
            ),
            buildNativeLoadingDetail(
              l10n: l10n,
              id: hermesMcpPageId,
              title: l10n.hermesMcpServers,
            ),
          ],
        ],
      ],
    );
  }

  NativeSheetDetailConfig _advancedPage(
    AppLocalizations l10n,
    String key,
    _Editor editor,
  ) {
    final controller = editor.controller!;
    return buildHermesConnectionAdvancedPage(
      l10n,
      key: key,
      mode: controller.mode,
      headers: controller.accessHeaders,
      allowSelfSigned: controller.allowSelfSignedCertificates,
      sessionKeyConfigured: _saved(editor).sessionKey?.isNotEmpty == true,
      disabled: controller.operation.isBusy,
    );
  }

  Future<void> _applyAdvanced(
    AppLocalizations l10n,
    String key,
    _Editor editor,
  ) async {
    if (editor.controller == null) return;
    await _surface.applyDetail(
      _advancedPage(l10n, key, editor),
      detailSheets: [buildHermesConnectionHeaderPage(l10n, key: key)],
    );
  }

  /// A change made on the Advanced page or one it opened is the editor's:
  /// the editor page, under them, is drawn again once it turns edited, so
  /// leaving it -- or closing Settings -- asks first.
  Future<void> _showEdited(
    AppLocalizations l10n,
    String key,
    _Editor editor,
  ) async {
    if (editor.edited == editor.shownEdited) return;
    await _applyEditor(l10n, key, editor, withPages: false);
  }

  HermesConnectionMessages _messages(AppLocalizations l10n) =>
      HermesConnectionMessages(
        connecting: l10n.connecting,
        connected: l10n.connectedToServer,
        saved: l10n.saved,
        unreachable: l10n.couldNotConnectGeneric,
        persistenceFailed: l10n.directConnectionSaveFailed,
        activationFailed: l10n.hermesOnboardingFailed,
      );

  /// Asks, over Settings, before the draft's credentials would go
  /// unencrypted to a server not agreed to. True when they may go.
  Future<bool> _confirmPlainHttp(AppLocalizations l10n, _Editor editor) async {
    final controller = editor.controller!;
    if (!controller.needsPlainHttpConsent(_saved(editor))) return true;
    final answer = await _surface.ask(
      title: l10n.directMcpInsecureCredentialsTitle,
      message: l10n.hermesInsecureCredentialsMessage,
      actions: [
        NativeSheetAlertAction(
          'cancel',
          l10n.cancel,
          style: NativeSheetAlertStyle.cancel,
        ),
        NativeSheetAlertAction(
          'send',
          l10n.directMcpInsecureCredentialsConfirm,
          style: NativeSheetAlertStyle.destructive,
        ),
      ],
    );
    if (answer != 'send' || editor.controller != controller) return false;
    controller.grantPlainHttpConsent();
    return true;
  }

  Future<bool> _save(AppLocalizations l10n, String key, _Editor editor) async {
    final controller = editor.controller!;
    if (!_baselineReady(editor) || !await _confirmPlainHttp(l10n, editor)) {
      return false;
    }
    final saved = await controller.save(
      _saved(editor),
      messages: _messages(l10n),
    );
    if (saved) {
      editor.edited = false;
      await _refreshStored(key, editor);
    }
    return saved;
  }

  Future<bool> _useConnection(
    AppLocalizations l10n,
    String key,
    _Editor editor,
  ) async {
    final id = editor.controller?.connectionId;
    if (id == null || editor.switching) return false;
    editor.switching = true;
    await _applyEditor(l10n, key, editor, withPages: false);
    // A switch waits for work that rotates the connection's stored tokens,
    // or it would load the ones being replaced.
    await Future.wait(editor.tokenWork.toList());
    var switched = false;
    try {
      await _ref.read(hermesConfigProvider.notifier).setActiveConnection(id);
      switched = true;
      editor
        ..stored = null
        ..notice = null;
    } catch (error) {
      DebugLogger.warning(
        'connection-switch-failed',
        scope: 'settings/hermes',
        data: {'errorType': error.runtimeType.toString()},
      );
      editor.notice = l10n.hermesSwitchConnectionFailed;
    } finally {
      editor.switching = false;
    }
    return switched;
  }

  /// Done: saves the draft and goes back. From Add Account, it tests the
  /// connection first and puts it in use, turning Hermes on.
  Future<void> _done(AppLocalizations l10n, String key, _Editor editor) async {
    final controller = editor.controller;
    if (controller == null || editor.saving || controller.operation.isBusy) {
      return;
    }
    // An address or key that will not do is said on its own row.
    editor
      ..saving = true
      ..notice = null;
    await _applyEditor(l10n, key, editor, withPages: false);
    var finished = false;
    try {
      if (editor.variant == HermesEditorVariant.connect) {
        finished = await _connect(l10n, key, editor);
      } else {
        finished = await _save(l10n, key, editor);
      }
    } finally {
      editor.saving = false;
    }
    if (!identical(_editors[key], editor)) return;
    if (finished) {
      _editors.remove(key)?.dispose();
      await _surface.closeDetail('$hermesConnectionPagePrefix$key');
      // The Hermes page lists it as it is now; Accounts, which the
      // connect editor comes from, describes itself again as it appears.
      if (editor.variant != HermesEditorVariant.connect) await _applyRoot(l10n);
      return;
    }
    await _applyEditor(l10n, key, editor, withPages: false);
  }

  Future<bool> _connect(
    AppLocalizations l10n,
    String key,
    _Editor editor,
  ) async {
    final controller = editor.controller!;
    if (!await _confirmPlainHttp(l10n, editor)) return false;
    final reachable = await controller.testConnection(
      saved: _saved(editor),
      messages: _messages(l10n),
    );
    if (!reachable || !await _save(l10n, key, editor)) return false;
    // Left while it saved (Add Account discarded, say): the connection is
    // saved, but not put in use nor Hermes turned on.
    if (!identical(_editors[key], editor)) return false;
    if (!_editsActive(editor) && !await _useConnection(l10n, key, editor)) {
      return false;
    }
    try {
      await _ref.read(hermesConfigProvider.notifier).setEnabled(true);
      // The primary backend only where there was none: next to Open WebUI or
      // Direct, it joins them.
      if (_ref.read(preferredBackendProvider) == PreferredBackend.unset) {
        await _ref
            .read(preferredBackendProvider.notifier)
            .set(PreferredBackend.hermes);
      }
      return true;
    } catch (error) {
      DebugLogger.warning(
        'connection-enable-failed',
        scope: 'settings/hermes',
        data: {'errorType': error.runtimeType.toString()},
      );
      editor.notice = l10n.hermesSwitchConnectionFailed;
      return false;
    }
  }

  Future<void> _test(AppLocalizations l10n, String key, _Editor editor) async {
    final controller = editor.controller;
    if (controller == null || !_baselineReady(editor)) return;
    if (!await _confirmPlainHttp(l10n, editor)) return;
    final testing = controller.testConnection(
      saved: _saved(editor),
      messages: _messages(l10n),
    );
    await _applyEditor(l10n, key, editor, withPages: false);
    await testing;
    if (_editsActive(editor)) _ref.invalidate(hermesServerStatusProvider);
  }

  // -- Desktop Gateway ---------------------------------------------------------

  HermesDesktopConnectionCoordinator get _desktopConnection =>
      HermesDesktopConnectionCoordinator(
        openExternalUrl: _ref.read(openExternalUrlProvider),
        dashboardBridgeFactory: _ref.read(
          hostHermesDashboardBridgeFactoryProvider,
        ),
      );

  String _authIdentity(_Editor editor, HermesConfig config) {
    final headers = config.accessHeaders.entries.toList()
      ..sort(
        (left, right) =>
            left.key.toLowerCase().compareTo(right.key.toLowerCase()),
      );
    final legacy = config.desktopAuthKind == HermesDesktopAuthKind.legacyToken
        ? Object.hash(
            editor.credentialSalt,
            config.desktopCredentials?.legacyToken,
          )
        : 0;
    return '${HermesConfig.connectionEndpoint(config.baseUrl)}\u0000'
        '${config.desktopAuthKind.name}\u0000'
        '$legacy\u0000'
        '${headers.map((entry) => '${entry.key.toLowerCase()}=${entry.value}').join('\u0000')}';
  }

  /// The first look at a Desktop Gateway draft: which sign-in its server
  /// recommends, and its profiles.
  Future<void> _startDesktopWork(String key, _Editor editor) async {
    final controller = editor.controller;
    if (controller == null ||
        controller.mode != HermesBackendMode.desktopGateway) {
      return;
    }
    editor.lastProfileIdentity ??= _authIdentity(
      editor,
      controller.buildDraft(_saved(editor)).config,
    );
    await Future.wait([
      _recommendAuth(key, editor),
      _loadProfiles(key, editor),
    ]);
  }

  /// After a change to the draft: a new server recommends its sign-in
  /// again, and new credentials list their profiles again.
  Future<void> _draftChanged(String key, _Editor editor) async {
    final controller = editor.controller;
    if (controller == null) return;
    editor.edited = true;
    if (controller.mode != HermesBackendMode.desktopGateway) return;
    final work = <Future<void>>[];
    final origin = HermesConfig.connectionEndpoint(controller.url.text);
    if (origin != editor.lastOrigin) {
      editor.lastOrigin = origin;
      editor.recommendationEpoch++;
      work.add(_recommendAuth(key, editor, force: true));
    }
    final identity = _authIdentity(
      editor,
      controller.buildDraft(_saved(editor)).config,
    );
    if (identity != editor.lastProfileIdentity) {
      editor
        ..lastProfileIdentity = identity
        ..profileEpoch += 1
        ..profiles = const []
        ..profilesError = null;
      work.add(_loadProfiles(key, editor, force: true));
    }
    await Future.wait(work);
  }

  Future<void> _recommendAuth(
    String key,
    _Editor editor, {
    bool force = false,
  }) async {
    final controller = editor.controller!;
    if (editor.authChosen) return;
    final saved = _saved(editor);
    if (!force && saved.mode == HermesBackendMode.desktopGateway) return;
    final draft = controller.buildDraft(saved).config.copyWith(enabled: true);
    if (HermesConfig.connectionOrigin(draft.baseUrl) == null) return;
    // Not unencrypted unasked: the access headers go with the probe.
    if (!draft.mayUsePlainHttp) return;
    final identity = _authIdentity(editor, draft);
    final epoch = ++editor.recommendationEpoch;
    try {
      final recommended = await _desktopConnection.recommendedAuth(draft);
      if (!identical(_editors[key], editor) ||
          epoch != editor.recommendationEpoch) {
        return;
      }
      final current = controller
          .buildDraft(_saved(editor))
          .config
          .copyWith(enabled: true);
      if (_authIdentity(editor, current) != identity || editor.authChosen) {
        return;
      }
      if (controller.desktopAuthKind != recommended) {
        controller.setDesktopAuthKind(recommended);
        // The profiles listed meanwhile were for the sign-in before, and are
        // dropped: they are listed again for this one.
        final changed = _authIdentity(
          editor,
          controller.buildDraft(_saved(editor)).config,
        );
        if (changed != editor.lastProfileIdentity) {
          editor
            ..lastProfileIdentity = changed
            ..profileEpoch += 1
            ..profiles = const []
            ..profilesError = null;
          unawaited(_loadProfiles(key, editor, force: true));
        }
        final l10n = _l10n;
        if (l10n != null) await _applyEditor(l10n, key, editor);
      }
    } catch (_) {
      // Testing the connection says what is wrong with the server.
    }
  }

  Future<void> _loadProfiles(
    String key,
    _Editor editor, {
    bool force = false,
  }) async {
    if (editor.profilesLoading && !force) return;
    final controller = editor.controller!;
    final l10n = _l10n ?? currentAppLocalizations();
    final saved = _saved(editor);
    final draft = controller.buildDraft(saved);
    Future<void> show() async {
      if (identical(_editors[key], editor)) {
        await _applyEditor(l10n, key, editor, withPages: false);
      }
    }

    if (HermesConfig.connectionOrigin(draft.config.baseUrl) == null) {
      editor
        ..profilesLoading = false
        ..profilesError = l10n.hermesProfilesNeedUrl;
      return show();
    }
    // Listing profiles sends the draft's credentials, which go unencrypted
    // only once Test, Done or a sign-in has asked.
    if (!draft.config.mayUsePlainHttp) {
      editor
        ..profiles = const []
        ..profilesLoading = false
        ..profilesError = l10n.hermesProfilesNeedTest;
      return show();
    }
    final identity = _authIdentity(editor, draft.config);
    final editsActive = _editsActive(editor);
    // A token refresh while listing lands with the connection it belongs to,
    // and only over the tokens this client holds.
    final writeCredentials = _ref
        .read(hermesConfigProvider.notifier)
        .credentialsWriterFor(saved);
    final epoch = ++editor.profileEpoch;
    editor
      ..profilesLoading = true
      ..profilesError = null;
    await show();
    try {
      // Read once the page was drawn: another connection may be in use by
      // now, and its client lists that connection's profiles, not this one's.
      final live = editsActive && _editsActive(editor)
          ? _ref.read(hermesApiServiceProvider)
          : null;
      final loading = _desktopConnection.profiles(
        draft.config.copyWith(enabled: true),
        service: switch (live) {
          final HermesDesktopApiService service
              when hermesDesktopConnectionMatches(saved, draft.config) &&
                  hermesDesktopConnectionMatches(saved, service.config) =>
            service,
          _ => null,
        },
        // Judged against the connection as read above: the refresh can land
        // after the editor closed, and the writer refuses once that
        // connection changes.
        onCredentialsChanged: (credentials) async {
          if (!hermesDesktopConnectionMatches(saved, draft.config)) {
            throw StateError(
              'Save the Hermes server before refreshing its sign-in.',
            );
          }
          await writeCredentials(credentials);
        },
      );
      if (!editsActive && saved.desktopCredentials?.nativeTokens != null) {
        _trackTokenWork(editor, loading);
      }
      final profiles = await loading;
      if (!identical(_editors[key], editor)) return;
      final current = controller.buildDraft(_saved(editor)).config;
      if (epoch != editor.profileEpoch ||
          _authIdentity(editor, current) != identity) {
        return;
      }
      if (profiles.isNotEmpty &&
          !profiles.contains(controller.desktopProfile)) {
        controller.setDesktopProfile(
          profiles.contains('default') ? 'default' : profiles.first,
        );
      }
      editor
        ..profiles = profiles
        ..profilesError = profiles.isEmpty ? l10n.hermesProfilesNone : null;
    } catch (_) {
      if (!identical(_editors[key], editor)) return;
      final current = controller.buildDraft(_saved(editor)).config;
      if (epoch == editor.profileEpoch &&
          _authIdentity(editor, current) == identity) {
        editor.profilesError = l10n.hermesProfilesNeedSignIn;
      }
    } finally {
      if (identical(_editors[key], editor) && epoch == editor.profileEpoch) {
        editor.profilesLoading = false;
      }
    }
    await show();
  }

  void _trackTokenWork(_Editor editor, Future<void> work) {
    final settled = work.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    editor.tokenWork.add(settled);
    unawaited(settled.whenComplete(() => editor.tokenWork.remove(settled)));
  }

  /// Sign-in needs the live connection: the draft is saved, then its
  /// connection put in use.
  Future<bool> _prepareSignIn(
    AppLocalizations l10n,
    String key,
    _Editor editor,
  ) async {
    // Shown edited first, so the save that follows reads as one on both
    // renderers and Back after it asks nothing.
    if (editor.edited && !editor.shownEdited) {
      await _applyEditor(l10n, key, editor, withPages: false);
    }
    if (!await _save(l10n, key, editor)) return false;
    return _editsActive(editor) || await _useConnection(l10n, key, editor);
  }

  Future<void> _signInNative(
    AppLocalizations l10n,
    String key,
    _Editor editor,
  ) async {
    final controller = editor.controller!;
    if (!await _prepareSignIn(l10n, key, editor)) {
      return _applyEditor(l10n, key, editor, withPages: false);
    }
    final saved = _ref.read(hermesConfigProvider);
    if (saved.mode != HermesBackendMode.desktopGateway) return;
    final writeCredentials = _ref
        .read(hermesConfigProvider.notifier)
        .nativeCredentialsWriter();
    try {
      final live = _ref.read(hermesApiServiceProvider);
      await _desktopConnection.signInNative(
        saved.copyWith(enabled: true),
        onCredentialsChanged: writeCredentials,
        service: live is HermesDesktopApiService ? live : null,
      );
      if (!identical(_editors[key], editor)) return;
      await _loadProfiles(key, editor);
      await _test(l10n, key, editor);
    } catch (error) {
      DebugLogger.warning(
        'native-sign-in-failed',
        scope: 'settings/hermes',
        data: {'errorType': error.runtimeType.toString()},
      );
      controller.reportFailure(l10n.hermesNativeSignInFailed);
    }
    await _applyEditor(l10n, key, editor, withPages: false);
  }

  Future<void> _signInDashboard(
    AppLocalizations l10n,
    String key,
    _Editor editor,
  ) async {
    if (!await _prepareSignIn(l10n, key, editor)) {
      return _applyEditor(l10n, key, editor, withPages: false);
    }
    final config = _ref.read(hermesConfigProvider);
    final signedIn = await _ref
        .read(hermesDashboardSignInProvider)
        .signIn(config.copyWith(enabled: true));
    if (!signedIn || !identical(_editors[key], editor)) {
      return _applyEditor(l10n, key, editor, withPages: false);
    }
    _ref.invalidate(hermesDesktopModelsProvider);
    await _loadProfiles(key, editor);
    await _test(l10n, key, editor);
    await _applyEditor(l10n, key, editor, withPages: false);
  }

  // -- The server's own sections -----------------------------------------------

  Future<T?> _readFuture<T>(FutureProvider<T> provider) async {
    final listening = _ref.listen(provider, (_, _) {});
    try {
      return await _ref
          .read(provider.future)
          .timeout(const Duration(seconds: 10));
    } finally {
      listening.close();
    }
  }

  /// Reads the capabilities, toolsets, skills and status of the connection
  /// in use for its editor.
  Future<void> _readManagement(String key, _Editor editor) async {
    if (editor.variant != HermesEditorVariant.edit || !_editsActive(editor)) {
      return;
    }
    final l10n = _l10n;
    if (l10n == null) return;
    final desktop =
        _ref.read(hermesConfigProvider).mode ==
        HermesBackendMode.desktopGateway;
    await Future.wait([
      () async {
        try {
          editor.capabilities = await _readFuture(hermesCapabilitiesProvider);
        } catch (_) {}
      }(),
      () async {
        try {
          editor
            ..toolsets = await _readFuture(hermesToolsetsProvider) ?? const []
            ..toolsetsFailed = false;
        } catch (_) {
          editor.toolsetsFailed = true;
        }
      }(),
      if (desktop)
        () async {
          try {
            final skills =
                await _readFuture(hermesInstalledSkillsProvider) ?? const [];
            editor.skills = [for (final skill in skills) '${skill['name']}'];
          } catch (_) {}
        }(),
      () async {
        try {
          editor
            ..status = await _readFuture(hermesServerStatusProvider) ?? const {}
            ..statusFailed = false;
        } catch (_) {
          editor.statusFailed = true;
        }
      }(),
    ]);
    await _applyServer(l10n, key, editor);
  }

  /// The server page of the editor's connection, as read so far.
  Future<void> _applyServer(
    AppLocalizations l10n,
    String key,
    _Editor editor,
  ) async {
    final management = _editorState(key, editor).management;
    if (management == null) return;
    await _surface.applyDetail(
      buildHermesServerPage(l10n, key, management, notice: editor.serverNotice),
      detailSheets: [
        // An MCP page already drawn keeps what it shows.
        if (management.desktop &&
            !_ref.read(settingsPagesProvider).contains(hermesMcpPageId))
          buildNativeLoadingDetail(
            l10n: l10n,
            id: hermesMcpPageId,
            title: l10n.hermesMcpServers,
          ),
      ],
    );
  }

  Future<void> _configureToolset(
    AppLocalizations l10n,
    String key,
    _Editor editor,
    String name,
    bool enabled,
  ) async {
    if (!editor.pendingToolsets.add(name)) return;
    editor.serverNotice = null;
    await _applyServer(l10n, key, editor);
    // Another connection in use, or the editor left, while it was drawn:
    // nothing is sent to the connection in use now.
    if (!_actsOn(key, editor)) {
      editor
        ..pendingToolsets.remove(name)
        ..serverNotice = l10n.hermesToolsetUpdateFailed;
      await _applyServer(l10n, key, editor);
      return;
    }
    var changed = false;
    try {
      final service = _ref.read(hermesApiServiceProvider);
      if (service is HermesDesktopApiService) {
        await service.configureTools([name], enabled: enabled);
        changed = true;
      }
    } catch (error) {
      DebugLogger.warning(
        'toolset-update-failed',
        scope: 'settings/hermes',
        data: {'errorType': error.runtimeType.toString()},
      );
      editor.serverNotice = l10n.hermesToolsetUpdateFailed;
    }
    if (changed) {
      // The change is made; a list that cannot be read after it is only
      // stale, and shows the change as made.
      try {
        _ref.invalidate(hermesToolsetsProvider);
        editor
          ..toolsets = await _readFuture(hermesToolsetsProvider) ?? const []
          ..toolsetsFailed = false;
      } catch (error) {
        DebugLogger.warning(
          'toolsets-reload-failed',
          scope: 'settings/hermes',
          data: {'errorType': error.runtimeType.toString()},
        );
        editor.toolsets = [
          for (final toolset in editor.toolsets ?? const <HermesToolset>[])
            toolset.name == name
                ? HermesToolset(
                    name: toolset.name,
                    label: toolset.label,
                    description: toolset.description,
                    enabled: enabled,
                    tools: toolset.tools,
                  )
                : toolset,
        ];
      }
    }
    editor.pendingToolsets.remove(name);
    await _applyServer(l10n, key, editor);
  }

  Future<void> _gatewayAction(
    AppLocalizations l10n,
    String key,
    _Editor editor,
    Future<void> Function() action, {
    String? failureMessage,
  }) async {
    if (editor.gatewayActionRunning) return;
    editor
      ..gatewayActionRunning = true
      ..serverNotice = null;
    await _applyServer(l10n, key, editor);
    // Another connection in use, or the editor left, while it was drawn:
    // the action, which reads the service in use, is not run on it.
    if (!_actsOn(key, editor)) {
      editor
        ..gatewayActionRunning = false
        ..serverNotice = failureMessage ?? l10n.hermesActionFailed;
      await _applyServer(l10n, key, editor);
      return;
    }
    try {
      await action();
    } catch (error) {
      DebugLogger.warning(
        'desktop-action-failed',
        scope: 'settings/hermes',
        data: {'errorType': error.runtimeType.toString()},
      );
      editor.serverNotice = failureMessage ?? l10n.hermesActionFailed;
    } finally {
      editor.gatewayActionRunning = false;
    }
    await _applyServer(l10n, key, editor);
  }

  // -- Hidden chats --------------------------------------------------------------

  Future<void> _hydrateHidden(AppLocalizations l10n) async {
    // Opened afresh: the last list read may be another connection's, and
    // its rows would unhide that connection's chats on this one.
    final list = ++_hiddenList;
    _hidden = null;
    _hiddenFailed = false;
    await _surface.applyDetail(
      buildHermesHiddenChatsPage(
        l10n,
        sessions: _hidden,
        unhiding: _unhiding,
        notice: _hiddenNotice,
      ),
    );
    final listening = _ref.listen(hermesHiddenSessionsProvider, (_, _) {});
    List<HermesSessionSummary>? read;
    var failed = false;
    try {
      _ref.invalidate(hermesHiddenSessionsProvider);
      read = await _ref
          .read(hermesHiddenSessionsProvider.future)
          .timeout(const Duration(seconds: 15));
    } catch (error) {
      DebugLogger.warning(
        'hidden-sessions-load-failed',
        scope: 'settings/hermes',
        data: {'errorType': error.runtimeType.toString()},
      );
      failed = true;
    } finally {
      listening.close();
    }
    // A later opening started its own read meanwhile: this one is not it.
    if (list != _hiddenList) return;
    _hidden = read;
    _hiddenFailed = failed;
    await _applyHidden(l10n);
  }

  Future<void> _applyHidden(AppLocalizations l10n) => _surface.applyDetail(
    buildHermesHiddenChatsPage(
      l10n,
      sessions: _hidden,
      failed: _hiddenFailed,
      unhiding: _unhiding,
      notice: _hiddenNotice,
    ),
  );

  Future<void> _unhide(AppLocalizations l10n, String sessionId) async {
    final session = _hidden
        ?.where((candidate) => candidate.id == sessionId)
        .firstOrNull;
    if (session == null || !_unhiding.add(sessionId)) return;
    final connection = _ref.read(hermesActiveConnectionIdProvider);
    // The list the chat was unhidden from: an answer arriving after another
    // list was read (another connection's, perhaps, with a chat by the same
    // id) changes nothing on it.
    final list = _hiddenList;
    bool sameList() =>
        list == _hiddenList &&
        _ref.read(hermesActiveConnectionIdProvider) == connection;
    _hiddenNotice = null;
    await _applyHidden(l10n);
    try {
      // Another connection in use since the list was drawn: the chat is the
      // last one's, and is not sent to this one.
      if (_ref.read(hermesActiveConnectionIdProvider) != connection) {
        throw StateError('Hermes connection changed.');
      }
      await _ref
          .read(hermesSessionsProvider.notifier)
          .setHidden(session, false);
      if (sameList()) {
        _hidden = [
          for (final candidate in _hidden ?? const <HermesSessionSummary>[])
            if (candidate.id != sessionId) candidate,
        ];
      }
    } catch (error) {
      DebugLogger.warning(
        'unhide-session-failed',
        scope: 'settings/hermes',
        data: {'errorType': error.runtimeType.toString()},
      );
      if (sameList()) _hiddenNotice = l10n.hermesSessionUpdateFailed;
    } finally {
      _unhiding.remove(sessionId);
    }
    await _applyHidden(l10n);
  }

  Future<void> _openHidden(String sessionId) async {
    final session = _hidden
        ?.where((candidate) => candidate.id == sessionId)
        .firstOrNull;
    if (session == null) return;
    // The chat opens over the app, so Settings closes first.
    final connection = _ref.read(hermesActiveConnectionIdProvider);
    final bridge = NativeSheetBridge.instance;
    if (bridge.settingsSheetOpen) await bridge.dismiss();
    // Another connection made active meanwhile (by a notification): the
    // chat is the last one's, and is not asked of this one.
    if (_ref.read(hermesActiveConnectionIdProvider) != connection) return;
    final context = NavigationService.context;
    if (context == null || !context.mounted) return;
    await openHermesSessionReading(
      context,
      _ref.read,
      session,
      invalidate: _ref.invalidate,
    );
  }

  // -- Row changes -----------------------------------------------------------------

  @override
  Future<bool> handleChange(
    String id,
    Object? value,
    AppLocalizations l10n,
  ) async {
    _l10n = l10n;
    if (id.startsWith(hermesSettingsRowPrefix)) {
      await _handleRootChange(l10n, id, value);
      return true;
    }
    if (id.startsWith(hermesHiddenChatRowPrefix)) {
      final rest = id.substring(hermesHiddenChatRowPrefix.length);
      final separator = rest.indexOf(':');
      if (separator < 0) return true;
      final field = rest.substring(0, separator);
      final sessionId = Uri.decodeComponent(rest.substring(separator + 1));
      switch (field) {
        case 'open':
          await _openHidden(sessionId);
        case 'unhide':
          await _unhide(l10n, sessionId);
      }
      return true;
    }
    if (!id.startsWith(hermesConnectionRowPrefix)) return false;
    final parsed = parseHermesConnectionRowId(id);
    if (parsed == null) return true;
    final (:field, :key, :extra) = parsed;
    final editor = _editors[key];
    if (editor == null) return true;
    if (field == 'retry-load') {
      await _retryLoad(l10n, key, editor);
      return true;
    }
    final controller = editor.controller;
    if (controller == null) return true;
    switch (field) {
      case 'mode' when value is String:
        final mode = HermesBackendMode.values.asNameMap()[value];
        if (mode == null) return true;
        controller.setMode(mode);
        await _draftChanged(key, editor);
        await _applyEditor(l10n, key, editor);
        if (mode == HermesBackendMode.desktopGateway) {
          unawaited(_startDesktopWork(key, editor));
        }
      case 'name' when value is String:
        if (value == controller.name.text) return true;
        controller
          ..name.text = value
          ..markNameChanged();
        await _draftChanged(key, editor);
      case 'url' when value is String:
        if (value == controller.url.text) return true;
        controller
          ..url.text = value
          ..markUrlChanged();
        await _draftChanged(key, editor);
      case 'api-key' when value is String:
        controller
          ..apiKey.text = value
          ..markApiKeyChanged();
        await _draftChanged(key, editor);
      case 'legacy-token' when value is String:
        controller
          ..desktopLegacyToken.text = value
          ..markDesktopLegacyTokenChanged();
        await _draftChanged(key, editor);
      case 'memory-key' when value is String:
        controller
          ..sessionKey.text = value
          ..markSessionKeyChanged();
        await _draftChanged(key, editor);
        await _showEdited(l10n, key, editor);
      case 'profile' when value is String:
        controller.setDesktopProfile(value);
        await _draftChanged(key, editor);
        await _applyEditor(l10n, key, editor, withPages: false);
      case 'auth' when value is String:
        final kind = HermesDesktopAuthKind.values.asNameMap()[value];
        if (kind == null) return true;
        editor.authChosen = true;
        controller.setDesktopAuthKind(kind);
        await _draftChanged(key, editor);
        await _applyEditor(l10n, key, editor, withPages: false);
      case 'refresh-profiles':
        await _loadProfiles(key, editor);
      case 'self-signed' when value is bool:
        controller.setAllowSelfSignedCertificates(value);
        await _draftChanged(key, editor);
        await _applyAdvanced(l10n, key, editor);
        await _showEdited(l10n, key, editor);
      case 'header-remove' when extra != null:
        controller.setAccessHeaders(
          {...controller.accessHeaders}..remove(extra),
        );
        await _draftChanged(key, editor);
        await _applyAdvanced(l10n, key, editor);
        await _showEdited(l10n, key, editor);
      case 'header-name' when value is String:
        editor.headerName = value;
      case 'header-value' when value is String:
        editor.headerValue = value;
      case 'header-add':
        await _addHeader(l10n, key, editor);
      case 'test':
        await _test(l10n, key, editor);
        await _applyEditor(l10n, key, editor, withPages: false);
      case 'save':
        await _done(l10n, key, editor);
      case 'use':
        final switched = await _useConnection(l10n, key, editor);
        await _applyEditor(l10n, key, editor);
        // The list under the editor marks the connection in use: this one
        // now. Its pages already drawn, this editor among them, stay.
        if (switched &&
            _ref.read(settingsPagesProvider).contains(hermesSettingsPageId)) {
          await _applyRoot(l10n, keepKnownPages: true);
        }
      case 'delete':
        final connectionId = controller.connectionId;
        if (connectionId == null) return true;
        if (await _delete(connectionId)) {
          _editors.remove(key)?.dispose();
          await _surface.closeDetail('$hermesConnectionPagePrefix$key');
          await _applyRoot(l10n);
        } else {
          editor.notice = l10n.hermesDeleteConnectionFailed;
          await _applyEditor(l10n, key, editor, withPages: false);
        }
      case 'sign-in-native':
        await _signInNative(l10n, key, editor);
      case 'sign-in-dashboard':
        await _signInDashboard(l10n, key, editor);
      case 'toolset' when extra != null && value is bool:
        await _configureToolset(l10n, key, editor, extra, value);
      case 'reload-skills':
        await _gatewayAction(l10n, key, editor, () async {
          final service = _ref.read(hermesApiServiceProvider);
          if (service is! HermesDesktopApiService) return;
          await service.reloadSkills();
          _ref
            ..invalidate(hermesSkillPromptsProvider)
            ..invalidate(hermesInstalledSkillsProvider);
          final skills =
              await _readFuture(hermesInstalledSkillsProvider) ?? const [];
          editor.skills = [for (final skill in skills) '${skill['name']}'];
        });
      case 'sign-out':
        await _gatewayAction(
          l10n,
          key,
          editor,
          () => _ref.read(hermesConfigProvider.notifier).signOutDesktop(),
          failureMessage: l10n.hermesSignOutFailed,
        );
    }
    return true;
  }

  Future<void> _addHeader(
    AppLocalizations l10n,
    String key,
    _Editor editor,
  ) async {
    final controller = editor.controller!;
    final name = editor.headerName.trim();
    final pageId = '$hermesConnectionHeaderPagePrefix$key';
    if (name.isEmpty) {
      await _surface.applyDetail(
        buildHermesConnectionHeaderPage(
          l10n,
          key: key,
          name: editor.headerName,
          notice: l10n.nameRequired,
        ),
      );
      return;
    }
    final error = controller.setAccessHeaders({
      ...controller.accessHeaders,
      name: editor.headerValue,
    });
    if (error != null) {
      await _surface.applyDetail(
        buildHermesConnectionHeaderPage(
          l10n,
          key: key,
          name: editor.headerName,
          notice: error,
        ),
      );
      return;
    }
    // Native sign-in cannot pass a gateway that wants headers.
    if (controller.mode == HermesBackendMode.desktopGateway &&
        controller.desktopAuthKind == HermesDesktopAuthKind.nativePkce) {
      controller.setDesktopAuthKind(HermesDesktopAuthKind.dashboardCookie);
    }
    editor
      ..headerName = ''
      ..headerValue = '';
    await _draftChanged(key, editor);
    await _surface.closeDetail(pageId);
    await _applyAdvanced(l10n, key, editor);
    await _applyEditor(l10n, key, editor, withPages: false);
  }

  Future<void> _handleRootChange(
    AppLocalizations l10n,
    String id,
    Object? value,
  ) async {
    final rest = id.substring(hermesSettingsRowPrefix.length);
    final separator = rest.indexOf(':');
    final field = separator < 0 ? rest : rest.substring(0, separator);
    final argument = separator < 0
        ? null
        : Uri.decodeComponent(rest.substring(separator + 1));
    switch (field) {
      case 'enabled' when value is bool:
        await _setEnabled(l10n, value);
      case 'use' when argument != null:
        await _switchTo(l10n, argument);
      case 'delete' when argument != null:
        if (!await _delete(argument)) {
          _rootNotice = l10n.hermesDeleteConnectionFailed;
        } else {
          _editors.remove(Uri.encodeComponent(argument))?.dispose();
          _rootNotice = null;
        }
        await _applyRoot(l10n);
      case 'retry-secrets':
        await _ref.read(hermesConfigProvider.notifier).retrySecrets();
        await _applyRoot(l10n);
      case 'show-scheduled-runs' when value is bool:
        await _ref
            .read(appSettingsProvider.notifier)
            .setHermesShowScheduledSessions(value);
        await _applyRoot(l10n, keepKnownPages: true);
    }
  }
}
