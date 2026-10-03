import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:riverpod/riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/services/navigation_service.dart';

import 'package:conduit_core/services/performance_profiler.dart';
import 'package:conduit_core/utils/debug_logger.dart';

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
import '../../shared/widgets/adaptive_route_shell.dart';
import '../../shared/widgets/platform_ui/platform_ui.dart';
import '../../features/channels/views/channel_page.dart';
import '../../features/notes/views/note_editor_page.dart';
import '../../features/profile/views/about_page.dart';
import '../../features/profile/views/account_settings_page.dart';
import '../../features/profile/views/app_customization_page.dart';
import '../../features/profile/views/audio_settings_page.dart';
import '../../features/hermes/views/hermes_settings_page.dart';
import '../../features/hermes/views/hermes_jobs_page.dart';
import '../../features/hermes/views/hermes_mcp_page.dart';
import '../../features/profile/views/personalization_page.dart';
import '../../features/profile/views/profile_page.dart';
import '../../features/notifications/views/notification_settings_page.dart';
import '../../features/workspace/views/workspace_page.dart';
import '../../features/workspace/workspace_navigation.dart';

import 'package:conduit_core/features/direct_connections/controllers/direct_connection_editor_draft.dart';

import '../../features/direct_connections/views/direct_connection_editor_page.dart';
import '../../features/direct_connections/views/direct_connections_page.dart';
import '../../features/direct_connections/views/direct_mcp_server_editor_page.dart';
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
    // ShellRoute keeps the drawer/sidebar mounted across page navigations
    // so it doesn't reload on tablets when switching between chat, channels,
    // and notes.
    ShellRoute(
      builder: (context, state, child) => DrawerShellPage(child: child),
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
              child: FolderPage(key: ValueKey(folderId), folderId: folderId),
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
      path: Routes.serverConnection,
      name: RouteNames.serverConnection,
      pageBuilder: (context, state) =>
          _buildPlatformPage(state: state, child: const ServerConnectionPage()),
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
          _buildPlatformPage(state: state, child: const ProfilePage()),
    ),
    GoRoute(
      path: Routes.personalization,
      name: RouteNames.personalization,
      pageBuilder: (context, state) =>
          _buildPlatformPage(state: state, child: const PersonalizationPage()),
    ),
    GoRoute(
      path: Routes.audioSettings,
      name: RouteNames.audioSettings,
      pageBuilder: (context, state) =>
          _buildPlatformPage(state: state, child: const AudioSettingsPage()),
    ),
    GoRoute(
      path: Routes.accountSettings,
      name: RouteNames.accountSettings,
      pageBuilder: (context, state) =>
          _buildPlatformPage(state: state, child: const AccountSettingsPage()),
    ),
    GoRoute(
      path: Routes.appearanceSettings,
      name: RouteNames.appearanceSettings,
      pageBuilder: (context, state) => _buildPlatformPage(
        state: state,
        child: const AppCustomizationPage(
          section: AppCustomizationSection.appearance,
        ),
      ),
    ),
    GoRoute(
      path: Routes.chatSettings,
      name: RouteNames.chatSettings,
      pageBuilder: (context, state) => _buildPlatformPage(
        state: state,
        child: const AppCustomizationPage(
          section: AppCustomizationSection.chat,
        ),
      ),
    ),
    GoRoute(
      path: Routes.dataConnectionSettings,
      name: RouteNames.dataConnectionSettings,
      pageBuilder: (context, state) => _buildPlatformPage(
        state: state,
        child: const AppCustomizationPage(
          section: AppCustomizationSection.dataConnection,
        ),
      ),
    ),
    GoRoute(
      path: Routes.notificationSettings,
      name: RouteNames.notificationSettings,
      pageBuilder: (context, state) => _buildPlatformPage(
        state: state,
        child: const NotificationSettingsPage(),
      ),
    ),
    GoRoute(
      path: Routes.directConnections,
      name: RouteNames.directConnections,
      pageBuilder: (context, state) => _buildPlatformPage(
        state: state,
        child: DirectConnectionsPage(
          isOnboarding: state.uri.queryParameters['onboarding'] == 'true',
        ),
      ),
    ),
    GoRoute(
      path: Routes.directMcpServerEditor,
      name: RouteNames.directMcpServerEditor,
      pageBuilder: (context, state) => _buildPlatformPage(
        state: state,
        child: DirectMcpServerEditorPage(serverId: state.pathParameters['id']!),
      ),
    ),
    GoRoute(
      path: Routes.directConnectionEditor,
      name: RouteNames.directConnectionEditor,
      pageBuilder: (context, state) => _buildPlatformPage(
        state: state,
        child: DirectConnectionEditorPage(
          mode: DirectConnectionEditorMode.fromRoute(
            profileId: state.pathParameters['id']!,
            source:
                state.uri.queryParameters['source'] ==
                    openWebUiDirectConnectionSourceQueryValue
                ? DirectConnectionEditorSource.openWebUi
                : DirectConnectionEditorSource.local,
          ),
          isOnboarding: state.uri.queryParameters['onboarding'] == 'true',
          entry: state.uri.queryParameters['entry'] == 'chooser'
              ? DirectEditorEntry.chooser
              : DirectEditorEntry.overview,
        ),
      ),
    ),
    GoRoute(
      path: Routes.hermesSettings,
      name: RouteNames.hermesSettings,
      pageBuilder: (context, state) => _buildPlatformPage(
        state: state,
        child: HermesSettingsPage(isOnboarding: state.extra == true),
      ),
    ),
    GoRoute(
      path: Routes.hermesJobs,
      name: RouteNames.hermesJobs,
      pageBuilder: (context, state) =>
          _buildPlatformPage(state: state, child: const HermesJobsPage()),
    ),
    GoRoute(
      path: Routes.hermesMcp,
      name: RouteNames.hermesMcp,
      pageBuilder: (context, state) =>
          _buildPlatformPage(state: state, child: const HermesMcpPage()),
    ),
    GoRoute(
      path: Routes.about,
      name: RouteNames.about,
      pageBuilder: (context, state) =>
          _buildPlatformPage(state: state, child: const AboutPage()),
    ),
    ..._workspaceRoutes(),
    GoRoute(
      path: Routes.notes,
      name: RouteNames.notes,
      pageBuilder: (context, state) =>
          _buildNoTransitionPage(state: state, child: const NotesListPage()),
    ),
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
  GoRoute route({
    required String path,
    required String name,
    required WorkspaceSection? section,
    WorkspaceRouteMode mode = WorkspaceRouteMode.collection,
  }) {
    return GoRoute(
      path: path,
      name: name,
      pageBuilder: (context, state) => _buildPlatformPage(
        state: state,
        noTransition: usesNoTransitionForWorkspaceRoute(mode, state.extra),
        child: WorkspacePage(
          section: section,
          mode: mode,
          resourceId: state.pathParameters['id'],
          openedFromNativeSheet: state.extra is NativeSheetNavigationOrigin,
        ),
      ),
    );
  }

  return [
    route(path: Routes.workspace, name: RouteNames.workspace, section: null),
    for (final descriptor in workspaceRouteDescriptors) ...[
      route(
        path: descriptor.collectionPath,
        name: descriptor.collectionName,
        section: descriptor.section,
      ),
      route(
        path: descriptor.createPattern,
        name: descriptor.createName,
        section: descriptor.section,
        mode: WorkspaceRouteMode.create,
      ),
      route(
        path: descriptor.detailPattern,
        name: descriptor.detailName,
        section: descriptor.section,
        mode: WorkspaceRouteMode.detail,
      ),
      route(
        path: descriptor.editPattern,
        name: descriptor.editName,
        section: descriptor.section,
        mode: WorkspaceRouteMode.edit,
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

/// Only a Workspace collection is entered from native Settings. Resource
/// pages are pushed over it in Flutter and keep the native-sheet origin for
/// their back target, but need a real transition so the edge swipe pops them.
@visibleForTesting
bool usesNoTransitionForWorkspaceRoute(
  WorkspaceRouteMode mode,
  Object? extra,
) =>
    mode == WorkspaceRouteMode.collection &&
    usesNoTransitionForNativeSheet(extra);
