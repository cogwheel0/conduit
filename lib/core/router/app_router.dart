import 'dart:async';

import 'package:conduit_core/features/navigation/models/sidebar_navigation_model.dart';
import 'package:flutter/foundation.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:riverpod/riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/services/navigation_service.dart';

import 'package:conduit_core/services/performance_profiler.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_core/ports/browser_auth_port.dart';

import '../../features/auth/views/authentication_page.dart';
import '../../features/auth/views/backend_chooser_page.dart';
import '../../features/auth/views/connect_signin_page.dart';
import '../../features/auth/views/connection_issue_page.dart';
import '../../features/auth/views/proxy_auth_page.dart';
import '../../features/auth/views/server_connection_page.dart';
import '../../features/auth/views/sso_auth_page.dart';
import '../../features/chat/views/chat_page.dart';
import '../../features/navigation/views/folder_page.dart';
import '../../features/navigation/widgets/drawer_shell_page.dart';
import '../../features/navigation/views/splash_launcher_page.dart';
import '../../features/notes/views/notes_list_page.dart';
import '../../features/navigation/widgets/sidebar_destination_page.dart';
import '../../features/navigation/widgets/sidebar_tab_registry.dart';
import '../../shared/widgets/adaptive_route_shell.dart';
import '../../shared/widgets/platform_ui/platform_ui.dart';
import '../../features/channels/views/channel_page.dart';
import '../../features/notes/views/note_editor_page.dart';
import '../../features/settings/pages/server_address_settings_pages.dart'
    show serverAddressPageId, serverAddressesPageId;
import '../../features/hermes/views/hermes_settings_page.dart';
import '../../features/librechat/views/librechat_sign_in_page.dart';
import '../../features/settings/pages/hermes_page_ids.dart';
import '../../features/hermes/views/hermes_room_page.dart';
import '../../features/settings/pages/push_page_ids.dart'
    show pushPrivacyPageId;
import '../../features/settings/views/settings_columns.dart';
import '../../features/settings/views/settings_page_view.dart';
import '../../features/settings/views/settings_root_page.dart';
import '../services/native_sheet_bridge.dart' show NativeSheetRoutes;
import '../utils/native_sheet_utils.dart' show nativeAccountsDetailId;
import '../../features/workspace/workspace_navigation.dart';

import 'package:conduit_core/features/direct_connections/controllers/direct_connection_editor_draft.dart';

import '../../features/direct_connections/views/direct_connection_editor_page.dart';
import '../../features/direct_connections/views/direct_connections_page.dart';
import '../../features/settings/pages/personal_connection_settings_pages.dart';
import '../../features/settings/pages/scheduled_task_settings_pages.dart';
import '../../features/settings/pages/workspace_page_ids.dart';
import '../../features/settings/pages/workspace_settings_pages.dart'
    show workspaceEditorPageId;
import '../../features/calendar/views/calendar_page.dart';

import 'package:conduit_core/features/integrations/personal_connection_settings.dart';

import '../../features/direct_connections/views/direct_mcp_server_editor_page.dart';
import '../../features/direct_connections/controllers/direct_mcp_server_editor.dart'
    show directMcpNewServerId;
import '../../features/settings/pages/direct_connection_page_ids.dart';
import '../../l10n/app_localizations.dart';

import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/navigation/route_redirect.dart';

// The redirect policy lives in conduit_core, where it is tested without
// Flutter. Re-exported for the router policy tests.
export 'package:conduit_core/navigation/route_redirect.dart'
    show
        incompleteHermesDestination,
        isDirectConnectionsLocation,
        isDirectOnlyAppLocation,
        isHermesOnlyAppLocation;

class RouterNotifier extends ChangeNotifier {
  RouterNotifier(this.ref) {
    _subscriptions = [
      for (final dependency in routeRedirectDependencies)
        ref.listen<Object?>(dependency, _onStateChanged),
    ];
  }

  final Ref ref;
  late final List<ProviderSubscription<dynamic>> _subscriptions;

  void _onStateChanged(dynamic previous, dynamic next) {
    // Debounce router refreshes to avoid thrashing on rapid state changes
    _scheduleRefresh();
  }

  Timer? _refreshDebounce;
  void _scheduleRefresh() {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 50), () {
      notifyListeners();
    });
  }

  String? redirect(BuildContext context, GoRouterState state) {
    // A browser sign-in's redirect that launched the app is not a page:
    // start the app as usual, without it.
    if (isStrayBrowserAuthCallback(state.uri)) return Routes.splash;
    final location = state.uri.path.isEmpty ? Routes.splash : state.uri.path;
    return resolveRouteRedirect(location, ref.read);
  }

  @override
  void dispose() {
    _refreshDebounce?.cancel();
    for (final sub in _subscriptions) {
      sub.close();
    }
    super.dispose();
  }
}

final routerNotifierProvider = Provider<RouterNotifier>((ref) {
  final notifier = RouterNotifier(ref);
  ref.onDispose(notifier.dispose);
  return notifier;
});

final goRouterProvider = Provider<GoRouter>((ref) {
  final notifier = ref.watch(routerNotifierProvider);

  final appRoutes = <RouteBase>[
    GoRoute(
      path: Routes.splash,
      name: RouteNames.splash,
      pageBuilder: (context, state) => _buildNoTransitionPage(
        state: state,
        child: const SplashLauncherPage(),
      ),
    ),
    // Retain each destination's existing widget state across menu selections.
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) => DrawerShellPage(
        child: SidebarDestinationScope(
          destination: sidebarTabRegistry[navigationShell.currentIndex].id,
          child: navigationShell,
        ),
      ),
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: Routes.chat,
              name: RouteNames.chat,
              pageBuilder: (context, state) =>
                  _buildNoTransitionPage(state: state, child: const ChatPage()),
            ),
            GoRoute(
              path: Routes.folder,
              name: RouteNames.folder,
              pageBuilder: (context, state) {
                final folderId = state.pathParameters['id']!;
                return _buildNoTransitionPage(
                  state: state,
                  child: FolderPage(
                    key: ValueKey(folderId),
                    folderId: folderId,
                  ),
                );
              },
            ),
            GoRoute(
              path: Routes.noteEditor,
              name: RouteNames.noteEditor,
              pageBuilder: (context, state) {
                final noteId = state.pathParameters['id'];
                if (noteId == null || noteId.isEmpty) {
                  return _buildNoTransitionPage(
                    state: state,
                    child: const NotesListPage(),
                  );
                }
                return _buildNoTransitionPage(
                  state: state,
                  child: NoteEditorPage(key: ValueKey(noteId), noteId: noteId),
                );
              },
            ),
            GoRoute(
              path: Routes.channel,
              name: RouteNames.channel,
              pageBuilder: (context, state) {
                final channelId = state.pathParameters['id']!;
                return _buildNoTransitionPage(
                  state: state,
                  child: ChannelPage(channelId: channelId),
                );
              },
            ),
            GoRoute(
              path: Routes.hermesRoom,
              name: RouteNames.hermesRoom,
              pageBuilder: (context, state) {
                final roomId = state.pathParameters['id']!;
                return _buildNoTransitionPage(
                  state: state,
                  child: HermesRoomPage(
                    key: ValueKey<String>('hermes-room-$roomId'),
                    roomId: roomId,
                  ),
                );
              },
            ),
          ],
        ),
        for (final tab in sidebarTabRegistry.where(
          (tab) => tab.id != SidebarTabId.chats,
        ))
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: tab.location,
                name: tab.id == SidebarTabId.hermes
                    ? RouteNames.hermesSessions
                    : tab.id.name,
                pageBuilder: (context, state) => _buildNoTransitionPage(
                  state: state,
                  child: SidebarDestinationPage(destination: tab.id),
                ),
              ),
            ],
          ),
      ],
    ),
    GoRoute(
      path: Routes.login,
      name: RouteNames.login,
      pageBuilder: (context, state) =>
          _buildPlatformPage(state: state, child: const ConnectAndSignInPage()),
    ),
    GoRoute(
      path: Routes.backendChooser,
      name: RouteNames.backendChooser,
      pageBuilder: (context, state) =>
          _buildPlatformPage(state: state, child: const BackendChooserPage()),
    ),
    GoRoute(
      path: Routes.libreChatSignIn,
      name: RouteNames.libreChatSignIn,
      pageBuilder: (context, state) =>
          _buildPlatformPage(state: state, child: const LibreChatSignInPage()),
    ),
    GoRoute(
      path: Routes.serverConnection,
      name: RouteNames.serverConnection,
      pageBuilder: (context, state) => _buildPlatformPage(
        state: state,
        child: ServerConnectionPage(
          handoff: state.extra is ServerConnectionHandoff
              ? state.extra as ServerConnectionHandoff
              : null,
        ),
      ),
    ),
    GoRoute(
      path: Routes.addServer,
      name: RouteNames.addServer,
      pageBuilder: (context, state) => _buildPlatformPage(
        state: state,
        child: ServerConnectionPage(
          addingAccount: true,
          serverId: switch (state.extra) {
            final String serverId => serverId,
            ServerConnectionHandoff(:final serverId) => serverId,
            _ => null,
          },
          handoff: state.extra is ServerConnectionHandoff
              ? state.extra as ServerConnectionHandoff
              : null,
        ),
      ),
    ),
    GoRoute(
      path: Routes.connectionIssue,
      name: RouteNames.connectionIssue,
      pageBuilder: (context, state) =>
          _buildPlatformPage(state: state, child: const ConnectionIssuePage()),
    ),
    GoRoute(
      path: Routes.authentication,
      name: RouteNames.authentication,
      pageBuilder: (context, state) {
        final extra = state.extra;
        // Support both AuthFlowConfig (new) and ServerConfig (legacy)
        if (extra is AuthFlowConfig) {
          return _buildPlatformPage(
            state: state,
            child: AuthenticationPage(
              serverConfig: extra.serverConfig,
              backendConfig: extra.backendConfig,
            ),
          );
        }
        return _buildPlatformPage(
          state: state,
          child: AuthenticationPage(
            serverConfig: extra is ServerConfig ? extra : null,
          ),
        );
      },
    ),
    GoRoute(
      path: Routes.ssoAuth,
      name: RouteNames.ssoAuth,
      pageBuilder: (context, state) {
        final config = state.extra;
        return _buildPlatformPage(
          state: state,
          child: SsoAuthPage(
            serverConfig: config is ServerConfig ? config : null,
          ),
        );
      },
    ),
    GoRoute(
      path: Routes.proxyAuth,
      name: RouteNames.proxyAuth,
      pageBuilder: (context, state) {
        final config = state.extra;
        if (config is! ProxyAuthConfig) {
          // Fallback - should not happen in normal flow
          return _buildPlatformPage(
            state: state,
            child: const ServerConnectionPage(),
          );
        }
        return _buildPlatformPage(
          state: state,
          child: ProxyAuthPage(config: config),
        );
      },
    ),
    GoRoute(
      path: Routes.profile,
      name: RouteNames.profile,
      pageBuilder: (context, state) =>
          _buildPlatformPage(state: state, child: const SettingsRootPage()),
    ),
    GoRoute(
      path: Routes.settingsPage,
      name: RouteNames.settingsPage,
      pageBuilder: (context, state) => _buildPlatformPage(
        state: state,
        // Opened again as the window narrows: the page was already showing.
        noTransition: state.extra is SettingsPageReopened ? true : null,
        // Settings's Calendar is the Flutter calendar wherever Flutter
        // draws Settings; the native sheet has a calendar page of its own.
        child: state.pathParameters['id'] == NativeSheetRoutes.calendar
            ? const SettingsFeaturePage(
                pageId: NativeSheetRoutes.calendar,
                child: CalendarPage(),
              )
            : SettingsDetailPage(
                key: ValueKey<String>(
                  'settings-page-${state.pathParameters['id']}',
                ),
                detailId: state.pathParameters['id']!,
                reopened: state.extra is SettingsPageReopened,
              ),
      ),
    ),
    GoRoute(
      path: Routes.personalization,
      name: RouteNames.personalization,
      pageBuilder: (context, state) =>
          _buildPlatformPage(
        state: state,
        child: const SettingsDetailPage(detailId: NativeSheetRoutes.aiMemory),
      ),
    ),
    GoRoute(
      path: Routes.audioSettings,
      name: RouteNames.audioSettings,
      pageBuilder: (context, state) => _buildPlatformPage(
        state: state,
        child: const SettingsDetailPage(detailId: NativeSheetRoutes.voice),
      ),
    ),
    GoRoute(
      path: Routes.voiceProviderSettings,
      name: RouteNames.voiceProviderSettings,
      pageBuilder: (context, state) => _buildPlatformPage(
        state: state,
        child: const SettingsDetailPage(
          detailId: NativeSheetRoutes.voiceProvider,
        ),
      ),
    ),
    GoRoute(
      path: Routes.accountSettings,
      name: RouteNames.accountSettings,
      pageBuilder: (context, state) => _buildPlatformPage(
        state: state,
        child: const SettingsDetailPage(detailId: NativeSheetRoutes.profile),
      ),
    ),
    GoRoute(
      path: Routes.accounts,
      name: RouteNames.accounts,
      pageBuilder: (context, state) => _buildPlatformPage(
        state: state,
        child: const SettingsDetailPage(detailId: nativeAccountsDetailId),
      ),
    ),
    GoRoute(
      path: Routes.serverAddresses,
      name: RouteNames.serverAddresses,
      pageBuilder: (context, state) {
        final serverId = state.extra;
        return _buildPlatformPage(
          state: state,
          child: SettingsDetailPage(
            detailId: serverId is String
                ? serverAddressesPageId(serverId)
                : nativeAccountsDetailId,
          ),
        );
      },
    ),
    GoRoute(
      path: Routes.serverAddressEditor,
      name: RouteNames.serverAddressEditor,
      pageBuilder: (context, state) {
        final request = state.extra;
        return _buildPlatformPage(
          state: state,
          child: switch (request) {
            // Handed over from Settings to sign in through a proxy: the
            // connection page carries on with the edit.
            ServerAddressEditorRequest(:final serverId, :final draft?) =>
              ServerConnectionPage(
                routesOfServerId: serverId,
                endpointId: request.endpointId,
                routeDraft: draft,
              ),
            ServerAddressEditorRequest(:final serverId, :final endpointId) =>
              SettingsDetailPage(
                detailId: serverAddressPageId(serverId, endpointId),
              ),
            _ => const SettingsDetailPage(detailId: nativeAccountsDetailId),
          },
        );
      },
    ),
    GoRoute(
      path: Routes.appearanceSettings,
      name: RouteNames.appearanceSettings,
      pageBuilder: (context, state) => _buildPlatformPage(
        state: state,
        child: const SettingsDetailPage(detailId: NativeSheetRoutes.appearance),
      ),
    ),
    GoRoute(
      path: Routes.chatSettings,
      name: RouteNames.chatSettings,
      pageBuilder: (context, state) => _buildPlatformPage(
        state: state,
        child: const SettingsDetailPage(detailId: NativeSheetRoutes.chats),
      ),
    ),
    GoRoute(
      path: Routes.dataConnectionSettings,
      name: RouteNames.dataConnectionSettings,
      pageBuilder: (context, state) => _buildPlatformPage(
        state: state,
        child: const SettingsDetailPage(
          detailId: NativeSheetRoutes.dataConnection,
        ),
      ),
    ),
    GoRoute(
      path: Routes.notificationSettings,
      name: RouteNames.notificationSettings,
      pageBuilder: (context, state) => _buildPlatformPage(
        state: state,
        child: const SettingsDetailPage(
          detailId: NativeSheetRoutes.notificationSettings,
        ),
      ),
    ),
    GoRoute(
      path: Routes.pushPrivacy,
      name: RouteNames.pushPrivacy,
      pageBuilder: (context, state) => _buildPlatformPage(
        state: state,
        child: const SettingsDetailPage(detailId: pushPrivacyPageId),
      ),
    ),
    GoRoute(
      path: Routes.personalConnections,
      name: RouteNames.personalConnections,
      pageBuilder: (context, state) => _buildPlatformPage(
        state: state,
        child: const SettingsDetailPage(detailId: personalConnectionsPageId),
      ),
    ),
    GoRoute(
      path: Routes.personalConnectionEditor,
      name: RouteNames.personalConnectionEditor,
      pageBuilder: (context, state) {
        final kind = personalConnectionKindFromRouteValue(
          state.pathParameters['kind'] ?? '',
        );
        final identity = state.pathParameters['identity']!;
        return _buildPlatformPage(
          state: state,
          child: SettingsDetailPage(
            detailId: kind == null
                ? personalConnectionsPageId
                : personalConnectionEditorPageId(
                    kind,
                    identity == personalConnectionNewRouteValue
                        ? null
                        : identity,
                  ),
          ),
        );
      },
    ),
    GoRoute(
      path: Routes.chatDataControls,
      name: RouteNames.chatDataControls,
      pageBuilder: (context, state) =>
          _buildPlatformPage(
            state: state,
            child: const SettingsDetailPage(
              detailId: NativeSheetRoutes.chatDataControls,
            ),
          ),
    ),
    GoRoute(
      path: Routes.scheduledTasks,
      name: RouteNames.scheduledTasks,
      pageBuilder: (context, state) => _buildPlatformPage(
        state: state,
        child: const SettingsDetailPage(detailId: scheduledTasksPageId),
      ),
    ),
    // `new` is declared before `:id` so it is never read as a task id.
    GoRoute(
      path: Routes.scheduledTaskNew,
      name: RouteNames.scheduledTaskNew,
      pageBuilder: (context, state) => _buildPlatformPage(
        state: state,
        child: SettingsDetailPage(detailId: scheduledTaskEditorPageId(null)),
      ),
    ),
    GoRoute(
      path: Routes.scheduledTaskDetail,
      name: RouteNames.scheduledTaskDetail,
      pageBuilder: (context, state) => _buildPlatformPage(
        state: state,
        child: SettingsDetailPage(
          detailId: scheduledTaskPageId(state.pathParameters['id']!),
        ),
      ),
    ),
    GoRoute(
      path: Routes.scheduledTaskEdit,
      name: RouteNames.scheduledTaskEdit,
      pageBuilder: (context, state) => _buildPlatformPage(
        state: state,
        child: SettingsDetailPage(
          detailId: scheduledTaskEditorPageId(state.pathParameters['id']!),
        ),
      ),
    ),
    GoRoute(
      path: Routes.calendar,
      name: RouteNames.calendar,
      pageBuilder: (context, state) =>
          _buildPlatformPage(state: state, child: const CalendarPage()),
    ),
    // Onboarding sets Direct up in pages of its own; afterwards Direct is
    // Settings's, in its pages.
    GoRoute(
      path: Routes.directConnections,
      name: RouteNames.directConnections,
      pageBuilder: (context, state) => _buildPlatformPage(
        state: state,
        child: _isOnboarding(state)
            ? const DirectConnectionsPage()
            : const SettingsDetailPage(detailId: directConnectionsPageId),
      ),
    ),
    GoRoute(
      path: Routes.directMcpServerEditor,
      name: RouteNames.directMcpServerEditor,
      pageBuilder: (context, state) {
        final serverId = state.pathParameters['id']!;
        return _buildPlatformPage(
          state: state,
          child: _isOnboarding(state)
              ? DirectMcpServerEditorPage(serverId: serverId)
              : SettingsDetailPage(
                  detailId: directMcpPageId(
                    serverId == directMcpNewServerId ? null : serverId,
                  ),
                ),
        );
      },
    ),
    GoRoute(
      path: Routes.directConnectionEditor,
      name: RouteNames.directConnectionEditor,
      pageBuilder: (context, state) {
        final mode = DirectConnectionEditorMode.fromRoute(
          profileId: state.pathParameters['id']!,
          source:
              state.uri.queryParameters['source'] ==
                  openWebUiDirectConnectionSourceQueryValue
              ? DirectConnectionEditorSource.openWebUi
              : DirectConnectionEditorSource.local,
        );
        return _buildPlatformPage(
          state: state,
          child: _isOnboarding(state)
              ? DirectConnectionEditorPage(
                  mode: mode,
                  isOnboarding: true,
                  entry: state.uri.queryParameters['entry'] == 'chooser'
                      ? DirectEditorEntry.chooser
                      : DirectEditorEntry.overview,
                )
              : SettingsDetailPage(
                  detailId: directConnectionPageId(mode.source, mode.profileId),
                ),
        );
      },
    ),
    GoRoute(
      path: Routes.hermesSettings,
      name: RouteNames.hermesSettings,
      pageBuilder: (context, state) => _buildPlatformPage(
        state: state,
        // Onboarding sets up the first connection directly; afterwards this
        // is Hermes Agent's page of Settings.
        child: state.extra == true
            ? const HermesSettingsPage(isOnboarding: true)
            : const SettingsDetailPage(detailId: hermesSettingsPageId),
      ),
    ),
    GoRoute(
      path: Routes.hermesConnectionEditor,
      name: RouteNames.hermesConnectionEditor,
      pageBuilder: (context, state) {
        final id = state.pathParameters['id']!;
        return _buildPlatformPage(
          state: state,
          child: SettingsDetailPage(
            key: ValueKey<String>('hermes-connection-editor-$id'),
            detailId: hermesConnectionPageId(
              id == Routes.hermesNewConnectionId ? null : id,
            ),
          ),
        );
      },
    ),
    GoRoute(
      path: Routes.hermesJobs,
      name: RouteNames.hermesJobs,
      pageBuilder: (context, state) => _buildPlatformPage(
        state: state,
        child: const SettingsDetailPage(detailId: hermesJobsPageId),
      ),
    ),
    GoRoute(
      path: Routes.hermesMcp,
      name: RouteNames.hermesMcp,
      pageBuilder: (context, state) => _buildPlatformPage(
        state: state,
        child: const SettingsDetailPage(detailId: hermesMcpPageId),
      ),
    ),
    GoRoute(
      path: Routes.hermesHiddenSessions,
      name: RouteNames.hermesHiddenSessions,
      pageBuilder: (context, state) => _buildPlatformPage(
        state: state,
        child: const SettingsDetailPage(detailId: hermesHiddenChatsPageId),
      ),
    ),
    GoRoute(
      path: Routes.about,
      name: RouteNames.about,
      pageBuilder: (context, state) => _buildPlatformPage(
        state: state,
        child: const SettingsDetailPage(detailId: NativeSheetRoutes.helpAbout),
      ),
    ),
    ..._workspaceRoutes(),
  ];

  final router = GoRouter(
    navigatorKey: NavigationService.navigatorKey,
    initialLocation: Routes.splash,
    refreshListenable: notifier,
    redirect: notifier.redirect,
    routes: appRoutes,
    observers: [
      NavigationLoggingObserver(),
      if (PlatformUiCapabilities.usesNativeIOS26) CNTabBarRouteObserver(),
    ],
    errorBuilder: (context, state) {
      final l10n = AppLocalizations.of(context);
      final message =
          l10n?.routeNotFound(state.uri.path) ??
          'Route not found: ${state.uri.path}';
      return AdaptiveRouteShell(
        body: Center(child: Text(message, textAlign: TextAlign.center)),
      );
    },
  );

  NavigationService.attachRouter(router);
  return router;
});

List<GoRoute> _workspaceRoutes() {
  /// A route of a section drawn as pages of Settings: the Settings page
  /// [detailId] names.
  GoRoute settingsRoute({
    required String path,
    required String name,
    required String Function(GoRouterState state) detailId,
  }) => GoRoute(
    path: path,
    name: name,
    pageBuilder: (context, state) => _buildPlatformPage(
      state: state,
      child: SettingsDetailPage(detailId: detailId(state)),
    ),
  );

  String editorPage(WorkspaceSection section, String? id) =>
      workspaceEditorPageId(section, id);

  return [
    settingsRoute(
      path: Routes.workspace,
      name: RouteNames.workspace,
      detailId: (_) => workspaceHubPageId,
    ),
    // Each section's routes open the matching page of Settings.
    for (final descriptor in workspaceRouteDescriptors) ...[
      settingsRoute(
        path: descriptor.collectionPath,
        name: descriptor.collectionName,
        detailId: (_) => workspaceSectionPageId(descriptor.section),
      ),
      settingsRoute(
        path: descriptor.createPattern,
        name: descriptor.createName,
        detailId: (_) => editorPage(descriptor.section, null),
      ),
      settingsRoute(
        path: descriptor.detailPattern,
        name: descriptor.detailName,
        detailId: (state) =>
            editorPage(descriptor.section, state.pathParameters['id']),
      ),
      settingsRoute(
        path: descriptor.editPattern,
        name: descriptor.editName,
        detailId: (state) =>
            editorPage(descriptor.section, state.pathParameters['id']),
      ),
    ],
  ];
}

class NavigationLoggingObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    final current = route.settings.name ?? route.settings.toString();
    final previous = previousRoute?.settings.name ?? previousRoute?.settings;
    DebugLogger.navigation('Pushed: $current (from ${previous ?? 'root'})');
    PerformanceProfiler.instance.instant(
      'route_push',
      scope: 'navigation',
      data: {'route': current, 'previous': previous?.toString() ?? 'root'},
    );
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    final current = route.settings.name ?? route.settings.toString();
    final previous = previousRoute?.settings.name ?? previousRoute?.settings;
    DebugLogger.navigation('Popped: $current');
    PerformanceProfiler.instance.instant(
      'route_pop',
      scope: 'navigation',
      data: {'route': current, 'revealed': previous?.toString() ?? 'root'},
    );
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    final current = newRoute?.settings.name ?? newRoute?.settings.toString();
    final previous = oldRoute?.settings.name ?? oldRoute?.settings.toString();
    PerformanceProfiler.instance.instant(
      'route_replace',
      scope: 'navigation',
      data: {'route': current ?? 'unknown', 'previous': previous ?? 'unknown'},
    );
  }
}

Page<void> _buildNoTransitionPage({
  required GoRouterState state,
  required Widget child,
}) {
  return NoTransitionPage<void>(
    key: state.pageKey,
    name: state.name,
    child: child,
  );
}

/// Whether [state] is a step of first-run setup rather than of Settings.
bool _isOnboarding(GoRouterState state) =>
    state.uri.queryParameters['onboarding'] == 'true';

Page<void> _buildPlatformPage({
  required GoRouterState state,
  required Widget child,
  bool? noTransition,
}) {
  if (noTransition ?? usesNoTransitionForNativeSheet(state.extra)) {
    return _buildNoTransitionPage(state: state, child: child);
  }

  switch (defaultTargetPlatform) {
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
      return CupertinoPage<void>(
        key: state.pageKey,
        name: state.name,
        child: child,
      );
    default:
      return MaterialPage<void>(
        key: state.pageKey,
        name: state.name,
        child: child,
      );
  }
}

@visibleForTesting
bool usesNoTransitionForNativeSheet(Object? extra) =>
    extra is NativeSheetNavigationOrigin;
